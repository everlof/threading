import Foundation
import ThreadingController

// MARK: - Remote Session Mailboxes

/// Where a remote-host session's mailbox lives: on the host that runs it.
///
/// Decided in `agent-mail.md` ("Mailbox location"): each computer keeps its agents' input and
/// output on that computer. A session whose project runs on a host whose controller is set up
/// (the Remote automations page saves its executable and database) gets its mailbox registered on
/// that controller at launch; the agent reaches it through a host-local `threading-controller
/// agent-mcp` and is told about mail by `threading-controller agent-notice` hooks on the host, so
/// mail and notices never depend on this Mac being reachable. This Mac then stops offering the
/// mail tools and answering notices for that session (one answer per tool), and reads the
/// mailbox over owner SSH for its Info panel, shown stale with its age while the host is away.
///
/// A host without a controller keeps the Mac-side mailbox, reached through the reverse tunnel,
/// and the Info panel says so.
@MainActor
final class RemoteSessionMailboxes {

    // MARK: - Types

    /// What a launch needs to give a session its host-local mailbox.
    struct Binding: Equatable, Sendable {
        let endpoint: RemoteControllerEndpoint
        let address: MailAddress
        let credential: String
    }

    /// Where a session's mail is delivered *now*, asked before routing anything to it.
    enum Resolution: Equatable {
        /// The project runs on this Mac, or on a host with no controller: this Mac's mailbox.
        case thisMac
        /// On the host, through its controller.
        case host(Binding)
        /// The project runs on a host with a controller that could not be asked. Nothing may be
        /// addressed to the host mailbox on a guess; a caller either keeps the mail on this Mac
        /// (it moves to the host at the next bind) or refuses.
        case unknown(RemoteControllerEndpoint)
    }

    /// Where a session's mail is kept, for the Info panel's note.
    enum Location: Equatable {
        case thisMac
        /// On the host, through its controller.
        case host(Binding)
        /// The session runs on a host whose controller is not set up; its mail stays here.
        case thisMacForHost(String)
    }

    // MARK: - Properties

    static let shared = RemoteSessionMailboxes()

    private(set) var bindings: [SessionID: Binding] = [:]
    /// One provisioning per session at a time; a second caller (a launch racing a handover)
    /// waits for the first one's answer instead of concluding there is no host mailbox.
    private var provisioning: [SessionID: (endpoint: RemoteControllerEndpoint, task: Task<Binding?, Never>)] = [:]
    /// The last mailbox read for each host-backed session, kept so an unreachable host still
    /// shows what was last seen, with its age.
    private var lastRead: [SessionID: (presentation: SessionMailPresentation, at: Date)] = [:]
    /// When provisioning last failed for a session, so routing to a host that is down asks it
    /// once per interval rather than once per message.
    private var failedAt: [SessionID: Date] = [:]

    /// The owner-SSH runner. Injected for tests.
    var runner: any RemoteHostCommandRunning = SystemSSHCommandRunner(maximumOutputBytes: MailTransportLimits.responseBytes)
    /// Ensures the peering the session's mail will travel over. Injected for tests.
    var ensurePeered: (RemoteControllerEndpoint) async throws -> HostID = { try await MacMailSync.shared.ensurePeered($0) }
    var mailbox: MacMailbox = .shared
    /// The controller of the host the session's project runs on now. Injected for tests.
    var endpointForSession: @MainActor (SessionID) -> RemoteControllerEndpoint? = { RemoteSessionMailboxes.endpoint(for: $0) }
    /// The session's title for a mailbox registered while routing. Injected for tests.
    var titleForSession: @MainActor (SessionID) -> String = {
        ProjectStore.shared.session(withID: $0)?.displayTitle ?? MacMailDefaults.unnamedSession
    }
    /// Whether a session id is one of this Mac's sessions. Injected for tests.
    var isOwnSession: @MainActor (SessionID) -> Bool = { ProjectStore.shared.session(withID: $0) != nil }
    /// Called once a session's host mailbox is bound in this run, to move whatever mail this
    /// Mac's mailbox still holds for it to the host (`MailboxHandover` wires it at start).
    var onBound: (@MainActor (SessionID, String, RemoteControllerEndpoint) -> Void)?

    // MARK: - Queries

    func binding(for sessionID: SessionID) -> Binding? { bindings[sessionID] }

    /// Whether this Mac must leave mail tools and notices to the host for this session.
    func keepsMailOnHost(_ sessionID: SessionID) -> Bool { bindings[sessionID] != nil }

    /// The Mac session a host-local mailbox address belongs to.
    func session(forAddress address: MailAddress) -> SessionID? {
        bindings.first { $0.value.address == address }?.key
    }

    /// Where the session's mail goes now. Bindings live only in memory — the credential they hold
    /// is not written down — so after a relaunch the first message to a hosted session finds
    /// none and provisions it here, from the project's execution host, before anything is
    /// routed. Before this, such a message went to this Mac's mailbox for the session, which the
    /// agent on its host never reads.
    func resolve(_ sessionID: SessionID) async -> Resolution {
        if let binding = bindings[sessionID] {
            if endpointForSession(sessionID)?.hostID == binding.endpoint.hostID { return .host(binding) }
        }
        guard let endpoint = endpointForSession(sessionID) else { return .thisMac }
        if let failed = failedAt[sessionID],
           Date().timeIntervalSince(failed) < RemoteSessionMailboxDefaults.resolutionRetryInterval {
            return .unknown(endpoint)
        }
        guard let binding = await provision(sessionID, name: titleForSession(sessionID), endpoint: endpoint) else {
            failedAt[sessionID] = Date()
            return .unknown(endpoint)
        }
        return .host(binding)
    }

    /// The Mac session a host address names, when it names one: a session-kind address on
    /// another host whose id is one of this Mac's sessions. Answered from the id, not from the
    /// bindings, so the same-project rule applies to such an address whether or not this run has
    /// bound that session yet.
    func ownSession(spelledAs address: MailAddress) -> SessionID? {
        guard address.kind == .session else { return nil }
        let candidate = SessionID(address.id)
        return isOwnSession(candidate) ? candidate : nil
    }

    /// The controller of the host a session's project runs on, when it is set up.
    static func endpoint(for sessionID: SessionID, projects: ProjectStore = .shared) -> RemoteControllerEndpoint? {
        guard let host = projects.project(forSessionID: sessionID)?.executionHost,
              let id = host.hostID, let record = RemoteHostStore.shared.host(withID: id) else { return nil }
        return RemoteControllerEndpoint(record)
    }

    func location(for sessionID: SessionID, projects: ProjectStore = .shared) -> Location {
        if let binding = bindings[sessionID] { return .host(binding) }
        guard let host = projects.project(forSessionID: sessionID)?.executionHost else { return .thisMac }
        return .thisMacForHost(host.destination)
    }

    // MARK: - Provisioning

    /// Registers the session's mailbox on its host's controller and returns what the launch
    /// needs, or nil when the host has no controller or cannot be reached in time — the launch
    /// then keeps today's Mac-side mailbox rather than waiting.
    ///
    /// Owner work, in order: peer the two stores (`MacMailSync.ensurePeered`), `mail-register`
    /// the address under the session's title, read its `mail-credential`, and grant this Mac's
    /// sessions `notify` on it (`<macHost>/*`). That grant is the host-side half of the
    /// same-project rule: this Mac's control plane admits a sender before anything is queued for
    /// a host mailbox, so the host need not know the project.
    ///
    /// `movesMacMail` is false only for `MailboxHandover`, which is itself the move.
    func provision(
        _ sessionID: SessionID,
        name: String,
        endpoint: RemoteControllerEndpoint,
        movesMacMail: Bool = true
    ) async -> Binding? {
        if let binding = bindings[sessionID], binding.endpoint == endpoint { return binding }
        // Wait out whatever is in flight. The same host: its answer is ours. Another host: look
        // again, because another waiter may already have started provisioning ours.
        while let running = provisioning[sessionID] {
            let binding = await running.task.value
            if running.endpoint == endpoint { return binding }
            if provisioning[sessionID]?.task == running.task { provisioning[sessionID] = nil }
        }
        if let binding = bindings[sessionID], binding.endpoint == endpoint { return binding }
        let task = Task { await self.register(sessionID, name: name, endpoint: endpoint, movesMacMail: movesMacMail) }
        provisioning[sessionID] = (endpoint, task)
        let binding = await task.value
        if provisioning[sessionID]?.task == task { provisioning[sessionID] = nil }
        return binding
    }

    private func register(
        _ sessionID: SessionID,
        name: String,
        endpoint: RemoteControllerEndpoint,
        movesMacMail: Bool
    ) async -> Binding? {
        let rpc = RemoteControllerRPC(endpoint: endpoint, runner: runner, timeout: RemoteControllerRPCDefaults.launchTimeout)
        do {
            let host = try await ensurePeered(endpoint)
            let macHost = try await mailbox.host().id
            let address = MailAddress(host: host, kind: .session, id: sessionID.rawValue)
            let _: MailMailbox = try await rpc.owner("mail-register", [
                .init(value: address.description), .init(value: MacMailbox.mailboxName(name))
            ])
            let credential: String = try await rpc.owner("mail-credential", [.init(value: address.description)])
            let pattern = "\(macHost)/*"
            let grants: ControllerPage<MailGrant> = try await rpc.owner("mail-grants", [.init(value: address.description)])
            let prior = grants.items.first { $0.sender == pattern }
            if prior == nil {
                let _: MailGrant = try await rpc.owner("mail-grant-set", [
                    .init(value: address.description), .init(value: pattern),
                    .init(value: String(prior?.revision ?? 0)), .init(value: MailMode.notify.rawValue),
                    .init(value: MailPriority.interrupt.rawValue)
                ])
            }
            let binding = Binding(endpoint: endpoint, address: address, credential: credential)
            bindings[sessionID] = binding
            failedAt[sessionID] = nil
            // Mail this Mac kept for the session while its host mailbox was unknown — the host was
            // down at launch, or the app had just started — goes to the host now, ids unchanged.
            if movesMacMail { onBound?(sessionID, name, endpoint) }
            return binding
        } catch {
            EventLog.shared.record(.mcp, "Remote session mailbox not provisioned; keeping it on this Mac", [
                "session": sessionID.uuidString,
                "host": endpoint.name,
                "reason": RemoteControllerRPC.describe(error)
            ])
            return nil
        }
    }

    /// Lets this Mac's project siblings receive mail from a host-local session mailbox: a
    /// `notify` grant per sibling on the Mac's store, naming the remote address exactly. Bounded
    /// by the project's session count; never a pattern, so another host session gains nothing.
    func admitSiblings(of sessionID: SessionID, address: MailAddress, projects: ProjectStore = .shared) {
        let siblings = (projects.project(forSessionID: sessionID)?.sessions ?? [])
            .filter { $0.id != sessionID && !$0.isArchived }
            .prefix(MacMailDefaults.siblingGrantLimit)
            .map { ($0.id, $0.displayTitle) }
        let mailbox = mailbox
        Task {
            for (sibling, title) in siblings {
                guard let recipient = try? await mailbox.register(sibling, name: title) else { continue }
                _ = try? await mailbox.admitSibling(recipient: recipient, sender: address)
            }
        }
    }

    // MARK: - Sending

    /// Sends as a host-local mailbox, through its host's controller, so the reply comes back to
    /// the mailbox the agent actually reads. The Mac's control plane has already admitted the
    /// pair, so a recipient on that host is owner-admitted; one elsewhere is queued and its own
    /// host's grants decide (this Mac's are written for project siblings at launch).
    func send(as binding: Binding, to recipient: MailAddress, text: String) async throws -> MailMessage {
        let rpc = RemoteControllerRPC(endpoint: binding.endpoint, runner: runner, timeout: RemoteControllerRPCDefaults.launchTimeout)
        return try await rpc.owner("mail-send", [
            .init(value: binding.address.description), .init(value: recipient.description),
            .init(value: UUID().uuidString), .init(text: text),
            .init(value: MailPriority.normal.rawValue), .init(value: MailOwnerRPCWords.ownerAdmitted)
        ])
    }

    // MARK: - Reading

    /// The session's host mailbox for the Info panel: open mail and recent sent mail over
    /// `owner-rpc` (`mailbox`, `mail-sent`). A failed read returns the last one, marked stale.
    func read(_ sessionID: SessionID, sessionTitle: @escaping @MainActor (SessionID) -> String?) async -> SessionMailPresentation? {
        guard let binding = bindings[sessionID] else { return nil }
        let rpc = RemoteControllerRPC(endpoint: binding.endpoint, runner: runner, timeout: RemoteControllerRPCDefaults.launchTimeout)
        do {
            let open: ControllerPage<MailInboxItem> = try await rpc.owner("mailbox", [.init(value: binding.address.description)])
            let sent: [MailMessage] = try await rpc.owner("mail-sent", [.init(value: binding.address.description)])
            let macHost = try await mailbox.host().id
            let snapshot = MacMailbox.Snapshot(
                address: binding.address,
                open: Array(open.items.map(\.message).prefix(MacMailDefaults.snapshotRows)),
                sent: Array(sent.prefix(MacMailDefaults.snapshotRows)),
                peerNames: [binding.address.host: binding.endpoint.name],
                localHost: macHost
            )
            let presentation = SessionMailPresentation(snapshot, sessionTitle: sessionTitle)
                .located(L10n.format("Kept on %@.", binding.endpoint.name))
            lastRead[sessionID] = (presentation, Date())
            return presentation
        } catch {
            guard let last = lastRead[sessionID] else {
                return SessionMailPresentation(received: [], sent: [])
                    .located(L10n.format("Kept on %@, which can’t be reached right now.", binding.endpoint.name))
            }
            return last.presentation.located(L10n.format(
                "Kept on %@, which can’t be reached; as of %@.",
                binding.endpoint.name,
                Self.ageFormatter.localizedString(for: last.at, relativeTo: Date())
            ))
        }
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Forgets everything. Tests only.
    func reset() {
        bindings.removeAll()
        lastRead.removeAll()
        failedAt.removeAll()
    }

    func install(_ binding: Binding, for sessionID: SessionID) { bindings[sessionID] = binding }

    /// The session's mailbox is this Mac's again.
    func forget(_ sessionID: SessionID) {
        bindings[sessionID] = nil
        lastRead[sessionID] = nil
        failedAt[sessionID] = nil
    }
}

enum RemoteSessionMailboxDefaults {
    /// How long a failed provisioning answers `.unknown` before routing asks the host again.
    static let resolutionRetryInterval: TimeInterval = 30
}
