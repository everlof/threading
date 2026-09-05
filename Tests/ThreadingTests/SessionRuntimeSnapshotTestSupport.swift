@testable import Threading

extension SessionRuntimeSnapshot {
    static func test(
        activity: SessionActivity,
        continuation: SessionContinuationState? = nil,
        reportsOwnTurns: Bool = true
    ) -> SessionRuntimeSnapshot {
        let process: SessionProcessState = activity == .dormant ? .dormant : .ready
        let turn: SessionTurnState
        switch activity {
        case .working, .awaitingUser:
            turn = .inFlight(reportsOwnTurns ? .reported : .inferred)
        case .dormant, .idle, .readyWithBackgroundWork, .needsAttention, .limitReached:
            turn = .none
        }
        let resolvedContinuation = continuation
            ?? (activity == .readyWithBackgroundWork ? .standing : .none)
        let blocker: SessionRuntimeBlocker
        switch activity {
        case .awaitingUser: blocker = .awaitingUser
        case .limitReached: blocker = .usageLimit
        default: blocker = .none
        }
        return SessionRuntimeSnapshot(
            process: process,
            turn: turn,
            continuation: resolvedContinuation,
            blocker: blocker,
            activity: activity,
            reportsOwnTurns: reportsOwnTurns
        )
    }
}
