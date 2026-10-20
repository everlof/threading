import Foundation
import ThreadingDomain
import ThreadingPTYClient
import ThreadingPTYHostKit

enum PTYHostSessionStopDefaults {
    /// How long a stopped child is given to die before the connection is dropped.
    static let timeout: TimeInterval = 3
    /// A stop-only attach asks for the daemon's minimum replay and never consumes output.
    static let replayBudget = PTYHostReplayDefaults.minimumBudgetBytes
}

// MARK: - Stopping one session

/// Ends one child the daemon is holding.
///
/// **Attach, then kill, on a connection of its own.** `kill` names a session, and the daemon
/// only accepts a frame naming the session the connection is *bound* to — one connection is one
/// session, which is what lets terminal bytes travel with no envelope. Ending another held child
/// therefore binds a dedicated lifecycle connection first. This keeps output from competing
/// with the ending. The replay
/// budget remains at the floor for older hosts that do not yet honor that attachment mode.
///
/// **Blocking**; never on the main actor.
enum PTYHostSessionStop {

    @discardableResult
    static func run(
        _ identity: PTYHostSessionIdentity,
        socketPath: String,
        build: String,
        eventLog: EventLog = .shared
    ) -> Bool {
        let exited = PTYHostLatch<Void>()
        let events = PTYHostClient.Events(
            frame: { frame in
                guard case .exited(let ending) = frame, ending.id == identity else { return }
                exited.complete(())
            },
            closed: { _ in exited.abandon() }
        )
        #if os(Linux)
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: events,
            journal: { message, detail in eventLog.record(.session, message, detail) }
        )
        #else
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: events,
            eventLog: eventLog
        )
        #endif
        defer { client.close() }

        guard (try? client.connect()) != nil else { return false }
        do {
            try client.attach(PTYHostAttach(
                id: identity,
                replayBudget: PTYHostSessionStopDefaults.replayBudget,
                receivesOutput: false
            ))
            try client.kill(PTYHostKill(id: identity, escalate: true))
        } catch {
            return false
        }
        let didExit = exited.wait(PTYHostSessionStopDefaults.timeout) != nil
        if didExit { NotificationCenter.default.post(PTYHostMayHaveDrained()) }
        return didExit
    }
}
