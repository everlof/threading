import Foundation

/// Routes captured operational transitions to Mac alert policy. Presentation events carry no
/// authority to post: restoring a durable unread receipt is not a new completion.
/// Each event costs O(1), with no session scan or per-session transition cache.
@MainActor
final class AttentionAlertRuntimeObserver {
    private let observations = AppEventObservations()

    init(
        appIsActive: @escaping @MainActor () -> Bool,
        isSnoozed: @escaping @MainActor (SessionID) -> Bool,
        currentSnapshot: @escaping @MainActor (SessionID) -> SessionRuntimeSnapshot = {
            AgentRuntime.shared.runtimeSnapshot(sessionID: $0)
        },
        receive: @escaping @MainActor (SessionRuntimeDidChange, AttentionAlertPolicy.Action) -> Void
    ) {
        observations.observe(SessionRuntimeDidChange.self) { event in
            Task { @MainActor in
                let transition = event.transition
                let action = AttentionAlertPolicy.action(
                    from: transition.previous.activity,
                    to: transition.current.activity,
                    appIsActive: appIsActive(),
                    reportsOwnTurns: transition.current.reportsOwnTurns,
                    isSnoozed: isSnoozed(event.sessionID)
                )
                // Rendering/notification work is deferred out of the lifecycle callback. A
                // question answered or a turn restarted before this job runs is already stale.
                if case .post = action,
                   currentSnapshot(event.sessionID) != transition.current { return }
                receive(event, action)
            }
        }
    }
}
