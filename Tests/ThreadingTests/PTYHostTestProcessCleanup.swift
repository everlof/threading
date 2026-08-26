import Foundation
import ThreadingPTYHostKit
@testable import Threading

/// Test-only shutdown for a scratch `threading-ptyd` rendezvous.
///
/// A daemon owns process groups, not just sockets. Killing the daemon first strands those groups,
/// so every fixture uses the shipping attach/kill protocol, waits for the children, and retires
/// the daemon only after it has drained. The caller still owns waiting for the daemon process
/// itself, because only the fixture owns that `Process` instance.
enum PTYHostTestProcessCleanup {
    static let childTimeout: TimeInterval = 8
    static let replyTimeout: TimeInterval = 3

    static func daemonIsReady(socketPath: String) -> Bool {
        PTYHostClient.probe(socketPath: socketPath, build: "test-cleanup") == .ready
    }

    /// Ends every live detached session, then asks the daemon to retire.
    ///
    /// Attached sessions are expected to be stopped or disconnected by the owning fixture first.
    /// They are retried until the deadline because a socket close and the inventory request are
    /// independent events on the daemon queue.
    @discardableResult
    static func stopSessionsAndRetire(
        socketPath: String,
        timeout: TimeInterval = childTimeout
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var drained = false

        while Date() < deadline {
            guard let held = sessions(socketPath: socketPath) else {
                // A daemon that retired between the last child ending and this inventory is done.
                drained = PTYHostClient.probe(socketPath: socketPath, build: "test-cleanup")
                    != .ready
                break
            }
            let live = held.filter { $0.exit == nil }
            if live.isEmpty {
                drained = true
                break
            }

            var attemptedStop = false
            for session in live where !session.isAttached {
                attemptedStop = true
                _ = PTYHostSessionStop.run(
                    session.id,
                    socketPath: socketPath,
                    build: "test-cleanup"
                )
            }
            if !attemptedStop { Thread.sleep(forTimeInterval: 0.05) }
        }

        // Retirement releases already-ended sessions immediately and exits after the last live
        // session. Send it even after a failed drain so a late ending cannot leave an idle daemon.
        let retireSent = retire(socketPath: socketPath)
        return drained && retireSent
    }

    private static func sessions(socketPath: String) -> [PTYHostSessionSummary]? {
        let answer = PTYHostLatch<[PTYHostSessionSummary]>()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: "test-cleanup",
            events: PTYHostClient.Events(
                frame: { frame in
                    guard case .sessions(let sessions) = frame else { return }
                    answer.complete(sessions)
                },
                closed: { _ in answer.abandon() }
            )
        )
        defer { client.close() }

        guard (try? client.connect()) != nil else { return nil }
        do {
            try client.list()
        } catch {
            return nil
        }
        return answer.wait(replyTimeout)
    }

    private static func retire(socketPath: String) -> Bool {
        let client = PTYHostClient(
            socketPath: socketPath,
            build: "test-cleanup",
            events: .ignored
        )
        defer { client.close() }

        guard (try? client.connect()) != nil else {
            return PTYHostClient.probe(socketPath: socketPath, build: "test-cleanup") != .ready
        }
        do {
            try client.retire()
            return client.drainWrites(until: Date().addingTimeInterval(replyTimeout))
        } catch {
            return false
        }
    }
}
