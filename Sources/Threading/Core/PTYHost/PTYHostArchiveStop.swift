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
    /// and performs at most one stop.
    static func run(
        sessionID: SessionID,
        decision: PTYHostDecision? = nil,
        survey: PTYHostHoldingsSurvey = .connecting(),
        queue: DispatchQueue = DispatchQueue(
            label: "codes.threading.ptyhost.archive-stop",
            qos: .userInitiated
        ),
        stopper: @escaping Stopper = { identity, socketPath, build in
            PTYHostSessionStop.run(identity, socketPath: socketPath, build: build)
        },
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        AgentRuntime.shared.discard(sessionID: sessionID)

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

        queue.async {
            let holdings = survey.holdings(for: archiveDecision)
            let summary = holdings?.sessions.first { summary in
                summary.sessionID == sessionID && summary.exit == nil
            }
            if let holdings, let summary {
                _ = stopper(summary.id, holdings.socketPath, archiveDecision.build)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }
}
