import Foundation
import ThreadingController

// MARK: - Mac Mailbox

/// The Mac's own agent-mail store: a `ControllerStore` opened as this Mac's mailbox file.
///
/// Agent mail is a controller feature (schema v7, `ControllerMail.swift`); the Mac does not
/// reimplement it. It opens a controller store of its own — never a remote host's — so a Mac
/// session's mailbox lives on the Mac, which is the host that runs its process
/// (`docs/feature-drafts/agent-mail.md`, "Mailbox location"). Every call here is an `await` on
/// this actor and then on the store's: nothing touches SQLite on the main actor.
///
/// **Session mailboxes are registered lazily**, the first time a session sends, is sent to or is
/// shown, under its current title. Registration is idempotent in the store; the in-memory name
/// cache keeps a stream of reads from rewriting the row on every call.
///
/// **An unreadable file is never recreated.** The controller refuses a schema newer than it
/// knows and a damaged file fails to open; either way the mailbox reports itself unavailable,
/// every mail operation refuses with that reason, and the bytes stay where they are for a build
/// that can read them (`persistence.md`: quarantine, no silent recreate).
actor MacMailbox {

    // MARK: - Types

    enum Failure: Error, Equatable, Sendable {
        /// The mailbox file could not be opened. Carries the controller's own reason.
        case unavailable(String)
        /// The controller refused the operation, with its own typed reason.
        case refused(ControllerError)
    }

    /// A session's mail, shaped for display: what is waiting for it and what it sent lately.
    struct Snapshot: Equatable, Sendable {
        let address: MailAddress
        let open: [MailMessage]
        let sent: [MailMessage]
        let peerNames: [HostID: String]
        let localHost: HostID
    }

    // MARK: - Properties

    static let shared = MacMailbox(databaseURL: MacMailbox.liveDatabaseURL())

    let databaseURL: URL
    private var store: ControllerStore?
    private var localHost: ControllerHost?
    private var openFailure: String?
    private var opening: Task<(ControllerStore, ControllerHost), any Error>?
    /// Names already written for a session mailbox. Bounded by the session count.
    private var registeredNames: [SessionID: String] = [:]

    // MARK: - Initialization

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// `~/Library/Application Support/Threading/Mail/mailbox.db`, or the hosted-test scratch
    /// directory when this process is a test bundle hosted in the app — the same redirect
    /// `StateManager` applies, so a test never opens the developer's mailbox.
    nonisolated static func liveDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base: URL
        if StateManager.isHostedTest {
            base = StateManager.hostedTestDirectory(fileManager: fileManager)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            base = support.appendingPathComponent("Threading", isDirectory: true)
        }
        return base
            .appendingPathComponent(MacMailDefaults.directoryName, isDirectory: true)
            .appendingPathComponent(MacMailDefaults.databaseFileName)
    }

    // MARK: - Identity

    /// This Mac's mail host, minted once by the store.
    func host() async throws -> ControllerHost {
        _ = try await openStore()
        guard let localHost else { throw Failure.unavailable("host") }
        return localHost
    }

    /// The address a session's mailbox has on this Mac. Does not register it.
    func address(for sessionID: SessionID) async throws -> MailAddress {
        MailAddress(host: try await host().id, kind: .session, id: sessionID.rawValue)
    }

    /// Registers (or renames) a session's mailbox and returns its address.
    @discardableResult
    func register(_ sessionID: SessionID, name: String) async throws -> MailAddress {
        let store = try await openStore()
        let address = try await address(for: sessionID)
        let bounded = Self.mailboxName(name)
        guard registeredNames[sessionID] != bounded else { return address }
        try await refusing { _ = try await store.registerMailbox(address, name: bounded) }
        registeredNames[sessionID] = bounded
        return address
    }

    // MARK: - Mail

    /// Sends from a Mac session. `ownerAdmitted` is the control plane having already decided a
    /// local recipient is in scope; it never reaches another host.
    func send(
        from sender: SessionID,
        senderName: String,
        to recipient: MailAddress,
        id: UUID,
        text: String,
        replyTo: UUID?,
        priority: MailPriority,
        ownerAdmitted: Bool
    ) async throws -> MailMessage {
        let store = try await openStore()
        let from = try await register(sender, name: senderName)
        return try await refusing {
            try await store.sendMail(
                from: from, to: recipient, id: id, text: text, replyTo: replyTo,
                priority: priority, ownerAdmitted: ownerAdmitted
            )
        }
    }

    func inbox(for sessionID: SessionID, name: String, after: Int64, limit: Int) async throws
        -> ControllerPage<MailInboxItem> {
        let store = try await openStore()
        let address = try await register(sessionID, name: name)
        return try await refusing { try await store.inbox(address, after: after, limit: limit) }
    }

    func acknowledge(for sessionID: SessionID, name: String, ids: [UUID]) async throws -> [MailMessage] {
        let store = try await openStore()
        let address = try await register(sessionID, name: name)
        return try await refusing { try await store.acknowledgeMail(mailbox: address, ids: ids) }
    }

    /// Grants and contacts this store knows for the session. Same-project siblings are the
    /// control plane's to add; this is only what the store can say.
    func storeDirectory(for sessionID: SessionID, name: String) async throws -> [MailContact] {
        let store = try await openStore()
        let address = try await register(sessionID, name: name)
        return try await refusing { try await store.mailDirectory(for: address) }
    }

    /// One host-authored notice for a hook or an adapter, or nil. Never registers: a session
    /// that has never had mail has nothing to announce, and a tool-call hook must not write a
    /// row on every call to learn that.
    func notice(for sessionID: SessionID, event: MailNoticeEvent) async -> String? {
        guard let store = try? await openStore(), let address = try? await address(for: sessionID) else {
            return nil
        }
        return try? await store.mailNotice(address, event: event)
    }

    /// Whether the session has mail it has not been told about. Indexed and bounded.
    func hasUnannouncedMail(for sessionID: SessionID) async -> Bool {
        guard let store = try? await openStore(), let address = try? await address(for: sessionID),
              let page = try? await store.inbox(address, after: 0, limit: MacMailDefaults.unannouncedProbe) else {
            return false
        }
        return page.items.contains { $0.message.state == .inbox }
    }

    func snapshot(for sessionID: SessionID, limit: Int) async throws -> Snapshot {
        let store = try await openStore()
        let address = try await address(for: sessionID)
        return try await refusing {
            let open = try await store.inbox(address, after: 0, limit: limit).items.map(\.message)
            let sent = try await store.recentSentMail(address, limit: limit)
            var names: [HostID: String] = [:]
            for peer in try await store.mailPeers(limit: MacMailDefaults.peerPage).items { names[peer.host] = peer.name }
            return Snapshot(address: address, open: open, sent: sent, peerNames: names, localHost: address.host)
        }
    }

    // MARK: - Owner configuration

    /// `chainTokenBudget`: `.keep` leaves a stored budget as it is — the default, so a caller that
    /// does not deal in budgets (re-applying a mode) never removes the spend fuse; `.set` writes
    /// exactly the value given, nil meaning none (a grant copied as it was).
    enum BudgetChange: Equatable { case keep, set(Int64?) }

    /// Records the control plane's admission of a project sibling's host-local address on a Mac
    /// session mailbox — only where no grant for that exact sender exists yet. A grant the owner
    /// set (any mode) is never changed, and a revocation is answered `false`: the owner's decision
    /// outranks the same-project default.
    func admitSibling(recipient: MailAddress, sender: MailAddress) async throws -> Bool {
        let store = try await openStore()
        return try await refusing {
            let prior = try await store.mailGrants(recipient: recipient, limit: MacMailDefaults.grantPage).items
                .first { $0.sender == sender.description }
            if let prior { return prior.mode != nil }
            _ = try await store.setMailGrant(recipient: recipient, sender: sender.description, expectedRevision: 0,
                                             mode: .notify, allowsInterrupt: false)
            return true
        }
    }

    /// Grants `sender` (an address, `<host>/*` or `*`) `mode` on a session mailbox here, unless an
    /// equal grant already stands. Owner-only: no agent tool reaches this.
    @discardableResult
    func ensureGrant(recipient: MailAddress, sender: String, mode: MailMode?, allowsInterrupt: Bool = false,
                     chainTokenBudget: BudgetChange = .keep) async throws -> MailGrant {
        let store = try await openStore()
        return try await refusing {
            let prior = try await store.mailGrants(recipient: recipient, limit: MacMailDefaults.grantPage).items
                .first { $0.sender == sender }
            let budget: Int64?
            switch chainTokenBudget {
            case .keep: budget = prior?.chainTokenBudget
            case .set(let value): budget = value
            }
            if let prior, prior.mode == mode, prior.allowsInterrupt == (mode != nil && allowsInterrupt),
               prior.chainTokenBudget == budget { return prior }
            return try await store.setMailGrant(
                recipient: recipient, sender: sender, expectedRevision: prior?.revision ?? 0,
                mode: mode, allowsInterrupt: allowsInterrupt, chainTokenBudget: mode == nil ? nil : budget
            )
        }
    }

    /// The grants on a session's mailbox, live ones first. Bounded to one page.
    func grants(for sessionID: SessionID, name: String) async throws -> [MailGrant] {
        let store = try await openStore()
        let address = try await register(sessionID, name: name)
        return try await refusing {
            try await store.mailGrants(recipient: address, limit: MacMailDefaults.grantPage).items
                .sorted { ($0.mode != nil ? 0 : 1) < ($1.mode != nil ? 0 : 1) }
        }
    }

    /// Names (or, with nil, removes) an address in this Mac's directory.
    func setContact(_ address: MailAddress, name: String?) async throws {
        let store = try await openStore()
        try await refusing { _ = try await store.setMailContact(address, name: name) }
    }

    func contacts() async throws -> [MailContact] {
        let store = try await openStore()
        return try await refusing { try await store.mailContacts(limit: MacMailDefaults.grantPage).items }
    }

    /// The newest open message a wake grant lets start this session, within its chain budget.
    func wakeCandidate(for sessionID: SessionID) async -> MailMessage? {
        guard let store = try? await openStore(), let address = try? await address(for: sessionID) else { return nil }
        return try? await store.mailWakeCandidate(address)
    }

    /// The store itself, for the sync engine. Owner operations only.
    func controllerStore() async throws -> ControllerStore {
        try await openStore()
    }

    // MARK: - Private

    /// Opens once. The open is a task so two callers arriving together share it instead of
    /// racing two connections and two host reads across the actor's suspension point.
    private func openStore() async throws -> ControllerStore {
        if let store { return store }
        if let openFailure { throw Failure.unavailable(openFailure) }
        let url = databaseURL
        let task = opening ?? Task.detached(priority: .utility) { () throws -> (ControllerStore, ControllerHost) in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: MacMailDefaults.directoryPermissions]
            )
            let opened = try ControllerStore(path: url.path)
            return (opened, try await opened.host())
        }
        opening = task
        do {
            let (opened, host) = try await task.value
            if store == nil { store = opened; localHost = host }
            opening = nil
            return store ?? opened
        } catch {
            opening = nil
            let reason = Self.describe(error)
            if openFailure == nil {
                openFailure = reason
                // Durable: a mailbox that will not open is invisible from every agent's side —
                // each send just refuses — and this line is what explains it.
                EventLog.shared.record(.mcp, "Mail store unavailable; left untouched", [
                    "path": url.path,
                    "reason": reason
                ])
            }
            throw Failure.unavailable(reason)
        }
    }

    private func refusing<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let failure as Failure {
            throw failure
        } catch let error as ControllerError {
            throw Failure.refused(error)
        } catch {
            throw Failure.unavailable(Self.describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ControllerError { return error.description }
        if let error = error as? Failure {
            switch error {
            case .unavailable(let reason): return reason
            case .refused(let error): return error.description
            }
        }
        return "io_error"
    }

    /// A session title as a mailbox name: one line, bounded, never empty.
    static func mailboxName(_ title: String) -> String {
        let line = WorkspaceControlPlane.safeHeaderTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(line.prefix(MacMailDefaults.maximumNameLength))
        return bounded.isEmpty ? MacMailDefaults.unnamedSession : bounded
    }
}

// MARK: - Defaults

enum MacMailDefaults {
    static let directoryName = "Mail"
    static let databaseFileName = "mailbox.db"
    static let directoryPermissions = 0o700
    /// The controller bounds a mailbox name at 256 bytes; titles are cut well inside that.
    static let maximumNameLength = 120
    static let unnamedSession = "Untitled session"
    /// How many open messages the "anything unannounced?" probe reads. One page is enough to
    /// answer the question; it is not a listing.
    static let unannouncedProbe = 20
    static let peerPage = 50
    static let grantPage = 50
    /// Project siblings granted `notify` from a host-local session mailbox.
    static let siblingGrantLimit = 32
    /// One inbox page for an agent: the controller's own default.
    static let inboxPage = 20
    /// Rows the session's Mail section shows in each list.
    static let snapshotRows = 12
}
