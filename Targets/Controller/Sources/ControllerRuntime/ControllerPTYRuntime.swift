import Foundation
import ThreadingController
import ThreadingDomain
import ThreadingPTYClient
import ThreadingPTYHostKit

public enum ControllerRuntimeError: Error {
    case unavailable, timedOut, protocolFailure, overflow
    case spawnRefused(PTYHostSpawnRefusal)
    /// ptyd's fork failed for this spawn: definitely no process, recorded and requeued.
    case spawnFailed(errorNumber: Int32?)
    /// ptyd reports a different process under this execution's identity than the one recorded.
    case processIdentityMismatch
}

extension PTYHostSpawnRefusal {
    /// The host could not start anything right now; the recipe is not at fault. Work returns to
    /// the queue and the worker stays enabled. Any other definite refusal (an executable that is
    /// not there, a channel this host does not serve) is the recipe's, and pauses the worker.
    public var isTransient: Bool { self == .retiring || self == .capacity }
}

public struct LaunchObservation: Codable, Sendable {
    public enum Presence: String, Codable, Sendable { case running, stopped, absent }
    public let presence: Presence
    public let launch: ControllerLaunchStatus
    init(presence: Presence, launch: ControllerLaunch) {
        self.presence = presence; self.launch = ControllerLaunchStatus(launch)
    }
}

/// Everything one host said about its sessions in one bounded exchange: the inventory, the
/// retained endings of controller-owned sessions, and the loss its current daemon reported.
public struct HostEvidence: Sendable {
    let sessions: [PTYHostSessionSummary]
    let receipts: [PTYHostSessionIdentity: PTYHostReceipt]
    let lost: Set<PTYHostSessionIdentity>
    let lossIncident: UUID?
    let servesReceipts: Bool
}

/// Host-local execution adapter. The core imports no PTY or provider code. These async entry
/// points run on the generic executor; bounded socket waits never run on the application's UI.
public enum ControllerPTYRuntime {
    static let spawnGrid = PTYHostGrid(cols: 120, rows: 40)

    /// `agentAccess` decides how the child reaches its tools: through the supervisor's broker
    /// (no store path in its environment) or, in the same-account compatibility mode, by opening
    /// the store itself. The caller resolves it before anything is consumed.
    public static func dispatch(store: ControllerStore, executionID: ExecutionID, database: String,
                                controllerBinary: String, agentAccess: ControllerAgentAccess) async throws -> ControllerLaunch {
        let intent = try await store.launch(executionID)
        // Secrets are read by name before the spawn right is consumed: a missing one leaves the
        // intent prepared and dispatchable once the owner stores it.
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        var secrets: [String: String] = [:]
        for (variable, name) in intent.spec.secrets { secrets[variable] = try ControllerSourcePoller.secret(name, root: root) }
        let peer = try ControllerPeer(path: intent.spec.socketPath)
        defer { peer.close() }
        // Connecting is harmless to retry. The commit below consumes the only spawn right.
        let launch = try await store.beginLaunch(executionID)
        let credential = try await store.launchCredential(executionID)
        var environment = launch.spec.environment.merging(secrets) { _, secret in secret }
        environment["THREADING_CONTROLLER_BIN"] = controllerBinary
        switch agentAccess {
        case .broker(let socket):
            // Never the store path, not even one a recipe named itself.
            environment[ControllerAgentAccess.socketEnvironment] = socket
            environment[ControllerAgentAccess.databaseEnvironment] = nil
        case .legacyDatabase(let path):
            environment[ControllerAgentAccess.databaseEnvironment] = path
            environment[ControllerAgentAccess.socketEnvironment] = nil
            try? await store.recordLegacyAgentDatabase(executionID)
        }
        environment["THREADING_EXECUTION_ID"] = executionID.description
        environment["THREADING_EXECUTION_CREDENTIAL"] = credential
        let identity = identity(executionID)
        // `retainReceipt`: this owner may look long after the exit, or after ptyd restarted, and
        // is owed the ending until it acknowledges it. An older daemon ignores the field.
        try peer.send(.spawn(.init(id: identity, channel: .pty(grid: spawnGrid),
            executable: launch.spec.executable, arguments: launch.spec.arguments.map {
                $0 == "${THREADING_EXECUTION_ID}" ? executionID.description : $0
            },
            environment: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
            cwd: launch.spec.directory, retainReceipt: true)))
        let reply = try peer.wait { frame in
            switch frame {
            case .spawned(let value): return value.id == identity
            case .spawnRefused(let value): return value.id == identity
            // This connection carries exactly one spawn, so a fork failure on it is this spawn's
            // even from a daemon that predates naming the identity in the frame.
            case .error(let value): return value.code == .spawnFailed && (value.id == nil || value.id == identity)
            default: return false
            }
        }
        switch reply {
        case .spawned(let child):
            return try await store.recordSpawn(executionID, pid: child.pid,
                seconds: child.startTime.seconds, microseconds: child.startTime.microseconds)
        case .spawnRefused(let refusal):
            // alreadyExists is evidence of an existing process, not proof that none was started.
            if refusal.reason != .alreadyExists {
                _ = try await store.recordLaunchStopped(executionID, evidence: .spawnRefused(refusal.reason.rawValue),
                                                        requeue: refusal.reason.isTransient)
            }
            throw ControllerRuntimeError.spawnRefused(refusal.reason)
        case .error(let failure):
            _ = try await store.recordLaunchStopped(executionID, evidence: .spawnFailed(errorNumber: failure.errorNumber),
                                                    requeue: true)
            throw ControllerRuntimeError.spawnFailed(errorNumber: failure.errorNumber)
        default: throw ControllerRuntimeError.protocolFailure
        }
    }

    /// Inventory is read-only; it does not steal an attached TUI or claim absence means death.
    public static func observe(store: ControllerStore, executionID: ExecutionID) async throws -> LaunchObservation {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return LaunchObservation(presence: .stopped, launch: launch) }
        let evidence = try evidence(socketPath: launch.spec.socketPath)
        let observation = try await observe(store: store, executionID: executionID, evidence: evidence)
        _ = await acknowledgeRecorded(store: store, socketPath: launch.spec.socketPath, evidence: evidence)
        return observation
    }

    /// One bounded exchange: `list`, plus `receiptList` when the daemon serves it. The `lost`
    /// frame a daemon sends after every `hello` has arrived before the `sessions` reply.
    static func evidence(socketPath: String) throws -> HostEvidence {
        let peer = try ControllerPeer(path: socketPath)
        defer { peer.close() }
        try peer.send(.list)
        let response = try peer.wait { if case .sessions = $0 { return true }; return false }
        guard case .sessions(let sessions) = response else { throw ControllerRuntimeError.protocolFailure }
        var receipts: [PTYHostSessionIdentity: PTYHostReceipt] = [:]
        if peer.servesReceipts {
            try peer.send(.receiptList)
            let reply = try peer.wait { if case .receipts = $0 { return true }; return false }
            guard case .receipts(let body) = reply else { throw ControllerRuntimeError.protocolFailure }
            for receipt in body.receipts { receipts[receipt.id] = receipt }
        }
        let loss = peer.reportedLoss
        return HostEvidence(sessions: sessions, receipts: receipts, lost: Set(loss?.ids ?? []),
                            lossIncident: loss?.incidentID, servesReceipts: peer.servesReceipts)
    }

    /// Evidence is consumed in order of strength: a retained receipt, a live inventory entry
    /// (with its exit, if any), then the current daemon's loss report. Each establishes a stop
    /// by itself; their absence establishes nothing.
    static func observe(store: ControllerStore, executionID: ExecutionID,
                        evidence: HostEvidence) async throws -> LaunchObservation {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return LaunchObservation(presence: .stopped, launch: launch) }
        let identity = identity(executionID)
        if let receipt = evidence.receipts[identity] {
            guard launch.pid == nil || launch.pid == receipt.pid else { throw ControllerRuntimeError.processIdentityMismatch }
            let stop: ControllerStopEvidence = receipt.ending == .lost
                ? .hostLost(incident: receipt.incidentID)
                : .exited(status: receipt.status ?? -1, signalled: receipt.signalled ?? false, tail: receipt.tail)
            return LaunchObservation(presence: .stopped, launch: try await store.recordLaunchStopped(executionID, evidence: stop))
        }
        if let child = evidence.sessions.first(where: { $0.id == identity }) {
            guard launch.pid == nil || launch.pid == child.pid else { throw ControllerRuntimeError.processIdentityMismatch }
            if let status = child.exit {
                let stopped = try await store.recordLaunchStopped(executionID,
                    evidence: .exited(status: status, signalled: false, tail: nil))
                return LaunchObservation(presence: .stopped, launch: stopped)
            }
            return LaunchObservation(presence: .running, launch: launch)
        }
        if evidence.lost.contains(identity) {
            let stopped = try await store.recordLaunchStopped(executionID, evidence: .hostLost(incident: evidence.lossIncident))
            return LaunchObservation(presence: .stopped, launch: stopped)
        }
        return LaunchObservation(presence: .absent, launch: launch)
    }

    /// Acknowledges the host receipts this store has durably recorded, so ptyd can forget them.
    /// Only identities whose launch exists here and is stopped are named: a receipt for another
    /// owner, or for a launch not yet recorded, is left for its owner. Best effort; a receipt
    /// that stays is bounded by ptyd and re-acknowledged on a later observation.
    @discardableResult
    static func acknowledgeRecorded(store: ControllerStore, socketPath: String, evidence: HostEvidence) async -> Int {
        guard evidence.servesReceipts, !evidence.receipts.isEmpty else { return 0 }
        var recorded: [PTYHostSessionIdentity] = []
        for id in evidence.receipts.keys {
            guard case .agentSession(let session) = id.identity,
                  let launch = try? await store.launchIfPresent(ExecutionID(session.rawValue)),
                  launch.state == .stopped else { continue }
            recorded.append(id)
        }
        guard !recorded.isEmpty, let peer = try? ControllerPeer(path: socketPath) else { return 0 }
        defer { peer.close() }
        do {
            for start in stride(from: 0, to: recorded.count, by: PTYHostReceiptLimits.acknowledgedPerFrame) {
                let chunk = recorded[start..<min(recorded.count, start + PTYHostReceiptLimits.acknowledgedPerFrame)]
                try peer.send(.acknowledge(PTYHostAcknowledge(ids: Array(chunk))))
            }
            // Frames on one connection are served in order: this answer means they were applied.
            try peer.send(.list)
            _ = try peer.wait { if case .sessions = $0 { return true }; return false }
            return recorded.count
        } catch { return 0 }
    }

    public static func stop(store: ControllerStore, executionID: ExecutionID) async throws -> ControllerLaunch {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return launch }
        // A child that already ended, or was lost, is recorded from that evidence; attaching to
        // it would only be told the identity is unknown.
        if let observed = try? await observe(store: store, executionID: executionID), observed.presence == .stopped {
            return try await store.launch(executionID)
        }
        let peer = try ControllerPeer(path: launch.spec.socketPath)
        defer { peer.close() }
        let identity = identity(executionID)
        try peer.send(.attach(.init(id: identity, replayBudget: PTYHostReplayDefaults.minimumBudgetBytes)))
        let reply = try peer.wait { if case .attached(let value) = $0 { return value.id == identity }; return false }
        guard case .attached(let child) = reply, launch.pid == nil || child.pid == launch.pid else {
            throw ControllerRuntimeError.protocolFailure
        }
        try peer.send(.kill(.init(id: identity, escalate: true)))
        let ending = try peer.wait { if case .exited(let value) = $0 { return value.id == identity }; return false }
        guard case .exited(let value) = ending else { throw ControllerRuntimeError.protocolFailure }
        return try await store.recordLaunchStopped(executionID,
            evidence: .exited(status: value.status, signalled: value.signalled, tail: nil))
    }

    static func identity(_ id: ExecutionID) -> PTYHostSessionIdentity { .agentSession(SessionID(id.rawValue)) }
}

private final class ControllerPeer {
    private static let connectSeconds: TimeInterval = 3
    private static let replySeconds: TimeInterval = 5
    private let inbox: ControllerFrameInbox
    private let client: PTYHostClient
    private let hello: PTYHostHello
    init(path: String) throws {
        let inbox = ControllerFrameInbox()
        self.inbox = inbox
        client = PTYHostClient(socketPath: path, build: "controller-v2",
            events: .init(frame: { inbox.append($0) }, closed: { _ in inbox.close() }),
            journal: { _, _ in }, connectTimeout: Self.connectSeconds, helloTimeout: Self.connectSeconds,
            retiresOlderDaemon: false)
        do { hello = try client.connect() } catch { client.close(); throw ControllerRuntimeError.unavailable }
    }
    var servesReceipts: Bool { hello.serves(PTYHostFeature.retainedReceipts) }
    var reportedLoss: PTYHostLost? { client.reportedLoss }
    func close() { client.close() }
    func send(_ frame: PTYHostFrame) throws { try client.send(frame) }
    /// The matcher sees every frame first, so a caller can accept a specific `error` (a fork
    /// failure that answers its spawn); any other `error` ends the wait.
    func wait(matching: (PTYHostFrame) -> Bool) throws -> PTYHostFrame {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.replySeconds
        while true {
            let frame = try inbox.next(timeout: deadline - ProcessInfo.processInfo.systemUptime)
            if matching(frame) { return frame }
            if case .error = frame { throw ControllerRuntimeError.protocolFailure }
        }
    }
}

/// Output is discarded at the shared transport callback; this client never retains transcripts
/// or answers terminal queries. Control backlog has both byte and item limits.
private final class ControllerFrameInbox: @unchecked Sendable {
    private static let maximumBytes = 4_194_304
    private static let maximumFrames = 64
    private let condition = NSCondition()
    private var frames: [(PTYHostFrame, Int)] = []
    private var bytes = 0
    private var failure: ControllerRuntimeError?
    func append(_ frame: PTYHostFrame) {
        let cost = (try? JSONEncoder().encode(frame).count) ?? Int.max
        condition.lock(); defer { condition.unlock() }
        guard failure == nil else { return }
        guard cost <= Self.maximumBytes - bytes, frames.count < Self.maximumFrames else {
            failure = .overflow; frames.removeAll(); bytes = 0; condition.broadcast(); return
        }
        frames.append((frame, cost)); bytes += cost; condition.signal()
    }
    func close() {
        condition.lock(); defer { condition.unlock() }
        if failure == nil { failure = .unavailable }
        condition.broadcast()
    }
    func next(timeout: TimeInterval) throws -> PTYHostFrame {
        condition.lock(); defer { condition.unlock() }
        guard timeout > 0 else { throw ControllerRuntimeError.timedOut }
        let until = Date().addingTimeInterval(timeout)
        while frames.isEmpty && failure == nil {
            guard condition.wait(until: until) else { throw ControllerRuntimeError.timedOut }
        }
        if !frames.isEmpty { let (frame, cost) = frames.removeFirst(); bytes -= cost; return frame }
        throw failure ?? ControllerRuntimeError.unavailable
    }
}
