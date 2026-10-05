import Foundation
import ThreadingController

// MARK: - Mailbox Handover

/// Moves a session's mailbox when its project's execution host changes.
///
/// A session's address names the host that runs it, so moving a project between this Mac and a
/// host, or between two hosts, changes every session's address (`agent-mail.md`, "Moving a
/// session"). At the hand-over, for each session:
///
/// 1. The new mailbox is made ready — registered on the new host's controller (as a launch would)
///    or on this Mac — and the store that will hold it is told to expect forwarded copies from
///    the old address (the forward written there is the owner's consent).
/// 2. The old store gets the forward and moves the session's unacknowledged mail to the new
///    address in one operation (`mail-move`), message ids unchanged; anything that still arrives
///    for the old address afterwards is forwarded once.
/// 3. The grants on the old mailbox — every one owner-written, by this Mac or its user — are
///    written on the new one, so who may write follows the session.
///
/// Moving between two hosts needs the old host to know the new one as a peer with a transport
/// (its supervisor does that exchange; this Mac does not relay). Without it the old mail stays
/// where it is, and the event log says so. Every step is idempotent, so a hand-over interrupted
/// halfway is completed by running it again.
@MainActor
final class MailboxHandover {

    /// One side of a move: this Mac's store, or a host controller's.
    enum Side: Equatable {
        case thisMac
        case host(RemoteControllerEndpoint)
    }

    struct Outcome: Equatable {
        var moved = 0
        var grantsCopied = 0
        var issues: [String] = []
    }

    static let shared = MailboxHandover()

    var mailbox: MacMailbox = .shared
    var mailboxes: RemoteSessionMailboxes = .shared
    var runner: (any RemoteHostCommandRunning)?
    var ensurePeered: @MainActor @Sendable (RemoteControllerEndpoint) async throws -> HostID = { try await MacMailSync.shared.ensurePeered($0) }
    var kick: (HostID) -> Void = { MacMailSync.shared.kick(host: $0) }

    private let observations = AppEventObservations()
    private var inFlight: Set<SessionID> = []
    /// A move asked for while this session's previous one is still running; run after it, in
    /// order, so a quick A→B→C ends with the mailbox at C and a forward at each step.
    private var queued: [SessionID: [(title: String, old: Side, new: Side)]] = [:]
    /// An old host that still holds a session's unmoved mail (it was down — often why the
    /// project moved — or its part failed). Kept per host, whatever later moves happen, and
    /// retried after that host's next successful sync, towards wherever the session lives then.
    struct PendingOld {
        let endpoint: RemoteControllerEndpoint
        let title: String
        var attempts: Int
        var retrying = false
    }
    private(set) var pending: [SessionID: [RemoteHostID: PendingOld]] = [:]

    func start() {
        observations.observe(ProjectExecutionHostDidChange.self) { [weak self] event in
            self?.projectMoved(event)
        }
    }

    private func projectMoved(_ event: ProjectExecutionHostDidChange) {
        let old = Self.side(for: event.oldHost)
        let new = Self.side(for: event.newHost)
        let sessions = (ProjectStore.shared.project(withID: event.projectID)?.sessions ?? [])
            .filter { !$0.isArchived }
            .prefix(MailboxHandoverDefaults.sessionsPerMove)
        for session in sessions {
            let id = session.id, title = session.displayTitle
            Task { @MainActor in _ = await self.move(id, title: title, from: old, to: new) }
        }
    }

    static func side(for host: ProjectExecutionHost?) -> Side {
        guard let id = host?.hostID, let record = RemoteHostStore.shared.host(withID: id),
              let endpoint = RemoteControllerEndpoint(record) else { return .thisMac }
        return .host(endpoint)
    }

    // MARK: - Moving

    @discardableResult
    func move(_ sessionID: SessionID, title: String, from old: Side, to new: Side) async -> Outcome {
        guard !Self.sameStore(old, new) else { return Outcome() }
        guard !inFlight.contains(sessionID) else {
            queued[sessionID, default: []].append((title, old, new))
            return Outcome()
        }
        inFlight.insert(sessionID)
        var outcome = await moveNow(sessionID, title: title, from: old, to: new)
        while let next = queued[sessionID]?.first {
            queued[sessionID]?.removeFirst()
            if queued[sessionID]?.isEmpty == true { queued[sessionID] = nil }
            let later = await moveNow(sessionID, title: next.title, from: next.old, to: next.new)
            outcome.moved += later.moved; outcome.grantsCopied += later.grantsCopied; outcome.issues += later.issues
        }
        inFlight.remove(sessionID)
        return outcome
    }

    /// Moves the mail an old host still holds, now that `endpoint` answered, to wherever each
    /// session lives *now* — not where the move that failed was going, which a later move may have
    /// changed. Hosts are matched by id, so editing a host's record does not lose its retry. A
    /// retry already running is not started twice.
    @discardableResult
    func retryPending(reachable endpoint: RemoteControllerEndpoint) -> [Task<Outcome, Never>] {
        var started: [Task<Outcome, Never>] = []
        for (sessionID, olds) in pending {
            // One retry at a time per session: a session with a move already running is retried
            // after a later sync, rather than queued behind it as a second copy.
            guard let entry = olds[endpoint.hostID], !entry.retrying, !inFlight.contains(sessionID) else { continue }
            guard let current = currentSide(sessionID) else {
                moved(sessionID, from: endpoint)
                EventLog.shared.record(.mcp, "Unmoved mail left on its old host: the session no longer exists", [
                    "session": sessionID.uuidString, "host": entry.endpoint.name
                ])
                continue
            }
            if case .host(let now) = current, now.hostID == endpoint.hostID {
                moved(sessionID, from: endpoint) // The session lives there again.
                continue
            }
            pending[sessionID]?[endpoint.hostID]?.retrying = true
            started.append(Task { @MainActor in
                let outcome = await self.move(sessionID, title: entry.title, from: .host(endpoint), to: current)
                self.pending[sessionID]?[endpoint.hostID]?.retrying = false
                if self.pending[sessionID]?.isEmpty == true { self.pending[sessionID] = nil }
                return outcome
            })
        }
        return started
    }

    /// Where the session's project runs now. Injected for tests.
    var currentSide: (SessionID) -> Side? = { sessionID in
        ProjectStore.shared.project(forSessionID: sessionID).map { MailboxHandover.side(for: $0.executionHost) }
    }

    /// Records that an old host still holds this session's mail. Counted per host: the first
    /// failure and each failed retry add one, and after the first move plus
    /// `retryAttempts` retries a reason that does not go away (no transport peer between two
    /// hosts) ends in the event log instead of a retry on every sync.
    private func deferOld(_ sessionID: SessionID, title: String, endpoint: RemoteControllerEndpoint, reason: String) {
        var entry = pending[sessionID]?[endpoint.hostID] ?? PendingOld(endpoint: endpoint, title: title, attempts: 0)
        entry.attempts += 1
        guard entry.attempts <= MailboxHandoverDefaults.retryAttempts else {
            pending[sessionID]?[endpoint.hostID] = nil
            if pending[sessionID]?.isEmpty == true { pending[sessionID] = nil }
            EventLog.shared.record(.mcp, "Mailbox move given up after repeated failures", [
                "session": sessionID.uuidString, "host": endpoint.name, "reason": reason
            ])
            return
        }
        pending[sessionID, default: [:]][endpoint.hostID] = entry
    }

    private func moved(_ sessionID: SessionID, from endpoint: RemoteControllerEndpoint) {
        pending[sessionID]?[endpoint.hostID] = nil
        if pending[sessionID]?.isEmpty == true { pending[sessionID] = nil }
    }

    private func moveNow(_ sessionID: SessionID, title: String, from old: Side, to new: Side) async -> Outcome {
        var outcome = Outcome()
        do {
            let macHost = try await mailbox.host().id
            // The new mailbox, ready before anything is moved to it.
            let newAddress: MailAddress
            switch new {
            case .thisMac:
                newAddress = try await mailbox.register(sessionID, name: title)
                mailboxes.forget(sessionID)
            case .host(let endpoint):
                guard let binding = await mailboxes.provision(sessionID, name: title, endpoint: endpoint) else {
                    throw RemoteControllerRPC.Failure.transport("the new host's controller did not answer")
                }
                newAddress = binding.address
            }

            // A mailbox coming back to an address it once left: that forward ends here.
            try await clearForward(newAddress, on: new)

            // Where the old mail can be: this Mac's address always (a host that could not be
            // reached at launch left it here), and the old host's when it has a controller. Each
            // is moved on its own, so an old host that is down does not hold back this Mac's.
            var olds: [(Side, MailAddress)] = [(.thisMac, MailAddress(host: macHost, kind: .session, id: sessionID.rawValue))]
            if case .host(let endpoint) = old {
                do {
                    let host = try await ensurePeered(endpoint)
                    olds.append((old, MailAddress(host: host, kind: .session, id: sessionID.rawValue)))
                } catch {
                    deferOld(sessionID, title: title, endpoint: endpoint, reason: RemoteControllerRPC.describe(error))
                    outcome.issues.append(RemoteControllerRPC.describe(error))
                    EventLog.shared.record(.mcp, "Old host unreachable; its mail moves when it answers again", [
                        "session": sessionID.uuidString,
                        "reason": RemoteControllerRPC.describe(error)
                    ])
                }
            }

            for (side, oldAddress) in olds where oldAddress != newAddress {
                do {
                    guard try await hasMailbox(oldAddress, on: side) else { continue }
                    if !Self.sameStore(side, new) {
                        try await setForward(from: oldAddress, to: newAddress, on: new)
                    }
                    outcome.moved += try await moveMail(from: oldAddress, to: newAddress, on: side)
                    outcome.grantsCopied += try await copyGrants(from: oldAddress, on: side, to: newAddress, on: new)
                    if case .host(let endpoint) = side { kick(newAddress.host); moved(sessionID, from: endpoint) }
                } catch {
                    if case .host(let endpoint) = side {
                        deferOld(sessionID, title: title, endpoint: endpoint, reason: RemoteControllerRPC.describe(error))
                    }
                    outcome.issues.append(RemoteControllerRPC.describe(error))
                }
            }
            if case .host = new { kick(newAddress.host) }
        } catch {
            outcome.issues.append(RemoteControllerRPC.describe(error))
            // The whole move failed before the old host's part ran (the new side could not be
            // made ready): that host's mail is still to move, and this failure counts.
            if case .host(let endpoint) = old {
                deferOld(sessionID, title: title, endpoint: endpoint, reason: RemoteControllerRPC.describe(error))
            }
            EventLog.shared.record(.mcp, "Mailbox not moved with its session", [
                "session": sessionID.uuidString,
                "reason": RemoteControllerRPC.describe(error)
            ])
        }
        return outcome
    }

    // MARK: - Store operations

    private static func sameStore(_ a: Side, _ b: Side) -> Bool {
        switch (a, b) {
        case (.thisMac, .thisMac): return true
        case (.host(let x), .host(let y)): return x.hostID == y.hostID
        default: return false
        }
    }

    private func rpc(_ endpoint: RemoteControllerEndpoint) -> RemoteControllerRPC {
        RemoteControllerRPC(endpoint: endpoint, runner: runner ?? mailboxes.runner)
    }

    private func hasMailbox(_ address: MailAddress, on side: Side) async throws -> Bool {
        switch side {
        case .thisMac:
            let store = try await mailbox.controllerStore()
            return try await store.hasMailbox(address)
        case .host:
            // The host's own `mail-move` finds nothing for an address it never held.
            return true
        }
    }

    private func setForward(from old: MailAddress, to new: MailAddress, on side: Side) async throws {
        switch side {
        case .thisMac:
            let store = try await mailbox.controllerStore()
            guard try await store.mailForward(old)?.to != new else { return }
            _ = try await store.setMailForward(from: old, to: new, expectedRevision: try await store.mailForwardRevision(old))
        case .host(let endpoint):
            let rpc = rpc(endpoint)
            let current: MailForward? = try await rpc.owner("mail-forward", [.init(value: old.description)])
            guard current?.to != new else { return }
            let revision: Int = try await rpc.owner("mail-forward-revision", [.init(value: old.description)])
            let _: MailForward = try await rpc.owner("mail-forward-set", [
                .init(value: old.description), .init(value: new.description), .init(value: String(revision))
            ])
        }
    }

    private func clearForward(_ address: MailAddress, on side: Side) async throws {
        switch side {
        case .thisMac:
            let store = try await mailbox.controllerStore()
            guard try await store.mailForward(address) != nil else { return }
            try await store.clearMailForward(address, expectedRevision: try await store.mailForwardRevision(address))
        case .host(let endpoint):
            let rpc = rpc(endpoint)
            let current: MailForward? = try await rpc.owner("mail-forward", [.init(value: address.description)])
            guard current != nil else { return }
            let revision: Int = try await rpc.owner("mail-forward-revision", [.init(value: address.description)])
            let _: Int = try await rpc.owner("mail-forward-clear", [.init(value: address.description), .init(value: String(revision))])
        }
    }

    private func moveMail(from old: MailAddress, to new: MailAddress, on side: Side) async throws -> Int {
        switch side {
        case .thisMac:
            let store = try await mailbox.controllerStore()
            return try await store.moveMail(from: old, to: new)
        case .host(let endpoint):
            return try await rpc(endpoint).owner("mail-move", [.init(value: old.description), .init(value: new.description)])
        }
    }

    private func copyGrants(from old: MailAddress, on oldSide: Side, to new: MailAddress, on newSide: Side) async throws -> Int {
        let grants: [MailGrant]
        switch oldSide {
        case .thisMac:
            let store = try await mailbox.controllerStore()
            grants = try await store.mailGrants(recipient: old, limit: MacMailDefaults.grantPage).items
        case .host(let endpoint):
            let page: ControllerPage<MailGrant> = try await rpc(endpoint).owner("mail-grants", [.init(value: old.description)])
            grants = page.items
        }
        var copied = 0
        for grant in grants where grant.mode != nil {
            switch newSide {
            case .thisMac:
                try await mailbox.ensureGrant(recipient: new, sender: grant.sender, mode: grant.mode,
                                              allowsInterrupt: grant.allowsInterrupt, chainTokenBudget: .set(grant.chainTokenBudget))
            case .host(let endpoint):
                let rpc = rpc(endpoint)
                let page: ControllerPage<MailGrant> = try await rpc.owner("mail-grants", [.init(value: new.description)])
                let prior = page.items.first { $0.sender == grant.sender }
                guard prior?.mode != grant.mode || prior?.allowsInterrupt != grant.allowsInterrupt
                        || prior?.chainTokenBudget != grant.chainTokenBudget else { continue }
                // The chain budget is the spend fuse; a grant that lost it on the way would let a
                // moved mailbox's conversations start unlimited work.
                var arguments: [RemoteControllerRPC.OwnerArgument] = [
                    .init(value: new.description), .init(value: grant.sender), .init(value: String(prior?.revision ?? 0)),
                    .init(value: grant.mode!.rawValue),
                    .init(value: grant.allowsInterrupt ? MailPriority.interrupt.rawValue : MailPriority.normal.rawValue)
                ]
                if let budget = grant.chainTokenBudget { arguments.append(.init(value: String(budget))) }
                let _: MailGrant = try await rpc.owner("mail-grant-set", arguments)
            }
            copied += 1
        }
        return copied
    }
}

/// A project's execution host changed: `nil` is this Mac.
struct ProjectExecutionHostDidChange: AppEvent {
    static let name = Notification.Name("projectExecutionHostDidChange")
    let projectID: ProjectID
    let oldHost: ProjectExecutionHost?
    let newHost: ProjectExecutionHost?
}

enum MailboxHandoverDefaults {
    /// Sessions moved per project change. A project is a handful of sessions; this only bounds
    /// a pathological one.
    static let sessionsPerMove = 64
    /// Times an old host's unmoved part is retried after a successful sync, beyond the move that
    /// first failed, before it is given up and left in the event log.
    static let retryAttempts = 5
}
