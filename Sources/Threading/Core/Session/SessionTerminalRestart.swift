import Foundation
import ThreadingPTYHostKit

/// Explicit recovery of one terminal, independent of the app's cached running flag.
/// The menu is host-owned: process authority never comes from extension presentation.
@MainActor
final class SessionTerminalRestart {
    static let shared = SessionTerminalRestart()
    private var pending: Set<SessionID> = []
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = Defaults.queueLabel
        queue.maxConcurrentOperationCount = Defaults.maximumWorkers
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private enum Defaults {
        static let queueLabel = "codes.threading.terminal-restart"
        static let maximumWorkers = 4
        static let exitTimeout: TimeInterval = 5
        static let pollInterval: TimeInterval = 0.025
    }

    func contains(_ sessionID: SessionID) -> Bool { pending.contains(sessionID) }

    /// One user action, one bounded host survey (normally tens of sessions, stress 1,000),
    /// one matching stop, and one local PID wait. All I/O stays on four bounded workers;
    /// the main actor only fences the target and discards its presentation.
    func run(
        sessionID: SessionID,
        localPID: Int32?,
        decision: PTYHostDecision,
        survey: PTYHostHoldingsSurvey = .connecting(),
        stopper: @escaping PTYHostArchiveStop.Stopper = { identity, socket, build in
            PTYHostSessionStop.run(identity, socketPath: socket, build: build)
        },
        discard: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard pending.insert(sessionID).inserted else { return }
        let probeDecision = PTYHostDecision(
            isEnabled: true,
            helperURL: decision.helperURL,
            socketPath: decision.socketPath,
            socketPathBytes: decision.socketPathBytes,
            build: decision.build
        )
        Self.queue.addOperation {
            // Capture before discard clears the runtime's PID. This identity is only waited on,
            // never signalled; the owning terminal/reaper remains the authority for local kills.
            let started = localPID.flatMap { ProcessUtility.startTime(forPid: $0) }
            DispatchQueue.main.async {
                discard()
                Self.queue.addOperation {
                    let stopped = Self.stopHosted(
                        sessionID: sessionID, decision: probeDecision,
                        survey: survey, stopper: stopper
                    ) && Self.waitForLocalExit(pid: localPID, started: started)
                    DispatchQueue.main.async {
                        self.pending.remove(sessionID)
                        completion(stopped)
                    }
                }
            }
        }
    }

    nonisolated static func stopHosted(
        sessionID: SessionID,
        decision: PTYHostDecision,
        survey: PTYHostHoldingsSurvey,
        stopper: PTYHostArchiveStop.Stopper
    ) -> Bool {
        guard let holdings = survey.holdings(for: decision) else {
            // A reachable rendezvous that did not answer is uncertainty, not proof of no child.
            // Nil means the path cannot fit a Unix socket address: no daemon can own a
            // child at that rendezvous. Local terminals must still be restartable there.
            guard let socketPath = decision.socketPath else { return true }
            return !FileManager.default.fileExists(atPath: socketPath)
        }
        guard let target = holdings.sessions.first(where: { $0.sessionID == sessionID }) else {
            return true
        }
        if target.exit != nil { return true }
        return stopper(target.id, holdings.socketPath, decision.build)
    }

    nonisolated private static func waitForLocalExit(
        pid: Int32?, started: ProcessStartTime?
    ) -> Bool {
        guard let pid, let started else { return true }
        let deadline = Date().addingTimeInterval(Defaults.exitTimeout)
        while ProcessUtility.startTime(forPid: pid) == started {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: Defaults.pollInterval)
        }
        return true
    }
}
