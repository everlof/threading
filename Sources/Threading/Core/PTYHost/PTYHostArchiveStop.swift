import Foundation
import ThreadingDomain
import ThreadingPTYHostKit

/// Stops every writer Threading owns before a provider moves an archived conversation.
///
/// `AgentRuntime.discard` covers a controller cached by this process. It cannot see a child that
/// `threading-ptyd` kept alive across an app restart, so archiving also surveys the daemon and
/// stops the matching child before `codex archive` is allowed to touch the rollout file.
@MainActor
enum PTYHostArchiveStop {

    private static let surveyQueue = DispatchQueue(
        label: "codes.threading.ptyhost.archive-stop.survey",
        qos: .userInitiated
    )

    private static let stopQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "codes.threading.ptyhost.archive-stop"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    typealias Stopper = @Sendable (
        _ identity: PTYHostSessionIdentity,
        _ socketPath: String,
        _ build: String
    ) -> Bool

    /// Stops the in-process surface immediately, then performs the bounded daemon round trip.
    /// Completion is delivered on the main actor exactly once.
    ///
    /// Scaling: archive is a user-frequency action. The daemon already returns one bounded list;
    /// this scans it once for the target id (ordinary: tens, stress: 1,000), constructs no views,
    /// and performs at most one stop on the shared bounded queue.
    static func run(
        sessionID: SessionID,
        decision: PTYHostDecision? = nil,
        survey: PTYHostHoldingsSurvey = .connecting(),
        stopper: @escaping Stopper = { identity, socketPath, build in
            PTYHostSessionStop.run(identity, socketPath: socketPath, build: build)
        },
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        run(
            sessionIDs: [sessionID],
            decision: decision,
            survey: survey,
            stopper: stopper,
            completion: completion
        )
    }

    /// Stops a reconciliation batch after one daemon survey. Stop calls themselves are bounded
    /// because each one performs an attach/kill round trip and can wait for its own deadline.
    static func run(
        sessionIDs: [SessionID],
        decision: PTYHostDecision? = nil,
        survey: PTYHostHoldingsSurvey = .connecting(),
        stopper: @escaping Stopper = { identity, socketPath, build in
            PTYHostSessionStop.run(identity, socketPath: socketPath, build: build)
        },
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let wanted = Set(sessionIDs)
        for sessionID in wanted {
            AgentRuntime.shared.discard(sessionID: sessionID)
        }

        guard !wanted.isEmpty else {
            completion()
            return
        }

        let resolvedDecision = decision ?? PTYHostDecision.live(
            settings: .shared,
            bundle: .main
        )
        // Turning the feature off deliberately leaves a daemon that still owns live children
        // registered and reachable. Archive is an explicit stop, so unlike new-session admission
        // it must probe that rendezvous even while the master switch is now off.
        let archiveDecision = PTYHostDecision(
            isEnabled: true,
            helperURL: resolvedDecision.helperURL,
            socketPath: resolvedDecision.socketPath,
            socketPathBytes: resolvedDecision.socketPathBytes,
            build: resolvedDecision.build
        )

        let stopQueue = self.stopQueue
        surveyQueue.async {
            let holdings = survey.holdings(for: archiveDecision)
            let summaries = holdings?.sessions.filter { summary in
                summary.sessionID.map(wanted.contains) == true && summary.exit == nil
            } ?? []
            guard let holdings, !summaries.isEmpty else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
                return
            }

            let stops = DispatchGroup()
            for summary in summaries {
                stops.enter()
                stopQueue.addOperation {
                    _ = stopper(summary.id, holdings.socketPath, archiveDecision.build)
                    stops.leave()
                }
            }
            stops.notify(queue: .main) {
                MainActor.assumeIsolated { completion() }
            }
        }
    }
}
