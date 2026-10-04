import Foundation
import ThreadingController
import ThreadingDomain
import ThreadingPTYClient
import ThreadingPTYHostKit

public enum ControllerRuntimeError: Error {
    case unavailable, timedOut, protocolFailure, overflow
    case spawnRefused(PTYHostSpawnRefusal)
}
public struct LaunchObservation: Codable, Sendable {
    public enum Presence: String, Codable, Sendable { case running, stopped, absent }
    public let presence: Presence
    public let launch: ControllerLaunchStatus
    init(presence: Presence, launch: ControllerLaunch) {
        self.presence = presence; self.launch = ControllerLaunchStatus(launch)
    }
}

/// Host-local execution adapter. The core imports no PTY or provider code. These async entry
/// points run on the generic executor; bounded socket waits never run on the application's UI.
public enum ControllerPTYRuntime {
    public static func dispatch(store: ControllerStore, executionID: ExecutionID,
                                database: String, controllerBinary: String) async throws -> ControllerLaunch {
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
        environment["THREADING_CONTROLLER_DATABASE"] = database
        environment["THREADING_EXECUTION_ID"] = executionID.description
        environment["THREADING_EXECUTION_CREDENTIAL"] = credential
        let identity = identity(executionID)
        try peer.send(.spawn(.init(id: identity, channel: .pty(grid: .init(cols: 120, rows: 40)),
            executable: launch.spec.executable, arguments: launch.spec.arguments.map {
                $0 == "${THREADING_EXECUTION_ID}" ? executionID.description : $0
            },
            environment: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }, cwd: launch.spec.directory)))
        let reply = try peer.wait { frame in
            switch frame {
            case .spawned(let value): return value.id == identity
            case .spawnRefused(let value): return value.id == identity
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
                _ = try await store.confirmLaunchStopped(executionID, exitStatus: nil)
            }
            throw ControllerRuntimeError.spawnRefused(refusal.reason)
        default: throw ControllerRuntimeError.protocolFailure
        }
    }

    /// Inventory is read-only; it does not steal an attached TUI or claim absence means death.
    public static func observe(store: ControllerStore, executionID: ExecutionID) async throws -> LaunchObservation {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return LaunchObservation(presence: .stopped, launch: launch) }
        let sessions = try inventory(socketPath: launch.spec.socketPath)
        return try await observe(store: store, executionID: executionID, sessions: sessions)
    }

    static func inventory(socketPath: String) throws -> [PTYHostSessionSummary] {
        let peer = try ControllerPeer(path: socketPath)
        defer { peer.close() }
        try peer.send(.list)
        let response = try peer.wait { if case .sessions = $0 { return true }; return false }
        guard case .sessions(let sessions) = response else { throw ControllerRuntimeError.protocolFailure }
        return sessions
    }

    static func observe(store: ControllerStore, executionID: ExecutionID,
                        sessions: [PTYHostSessionSummary]) async throws -> LaunchObservation {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return LaunchObservation(presence: .stopped, launch: launch) }
        guard let child = sessions.first(where: { $0.id == identity(executionID) }) else {
            return LaunchObservation(presence: .absent, launch: launch)
        }
        guard launch.pid == nil || launch.pid == child.pid else { throw ControllerRuntimeError.protocolFailure }
        if let status = child.exit {
            let stopped = try await store.confirmLaunchStopped(executionID, exitStatus: status)
            return LaunchObservation(presence: .stopped, launch: stopped)
        }
        return LaunchObservation(presence: .running, launch: launch)
    }

    public static func stop(store: ControllerStore, executionID: ExecutionID) async throws -> ControllerLaunch {
        let launch = try await store.launch(executionID)
        if launch.state == .stopped { return launch }
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
        return try await store.confirmLaunchStopped(executionID, exitStatus: value.status)
    }

    private static func identity(_ id: ExecutionID) -> PTYHostSessionIdentity { .agentSession(SessionID(id.rawValue)) }
}

private final class ControllerPeer {
    private let inbox: ControllerFrameInbox
    private let client: PTYHostClient
    init(path: String) throws {
        let inbox = ControllerFrameInbox()
        self.inbox = inbox
        client = PTYHostClient(socketPath: path, build: "controller-v2",
            events: .init(frame: { inbox.append($0) }, closed: { _ in inbox.close() }),
            journal: { _, _ in }, connectTimeout: 3, helloTimeout: 3, retiresOlderDaemon: false)
        do { _ = try client.connect() } catch { client.close(); throw ControllerRuntimeError.unavailable }
    }
    func close() { client.close() }
    func send(_ frame: PTYHostFrame) throws { try client.send(frame) }
    func wait(matching: (PTYHostFrame) -> Bool) throws -> PTYHostFrame {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            let frame = try inbox.next(timeout: deadline - ProcessInfo.processInfo.systemUptime)
            if case .error = frame { throw ControllerRuntimeError.protocolFailure }
            if matching(frame) { return frame }
        }
    }
}

/// Output is discarded at the shared transport callback; this client never retains transcripts
/// or answers terminal queries. Control backlog has both byte and item limits.
private final class ControllerFrameInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [(PTYHostFrame, Int)] = []
    private var bytes = 0
    private var failure: ControllerRuntimeError?
    func append(_ frame: PTYHostFrame) {
        let cost = (try? JSONEncoder().encode(frame).count) ?? Int.max
        condition.lock(); defer { condition.unlock() }
        guard failure == nil else { return }
        guard cost <= 4_194_304 - bytes, frames.count < 64 else {
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
