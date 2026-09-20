import Foundation

extension ControlRefusal {
    var toolWords: String {
        switch self {
        case .callerUnknown:
            "This session is no longer in the sidebar, so it has no project to act in."
        case .targetUnknown:
            """
            No session with that id is in this project. list_sessions names every one this \
            session can reach — sessions in other projects are out of reach by design.
            """
        case .targetArchived:
            "That session has been archived. The user restores it from Settings ▸ Archived."
        case .targetIsCaller:
            "That id is this session's own. Say it in your reply instead."
        case .targetNotRunning:
            "That session is dormant — no agent is running to receive a message."
        case .targetBusy:
            "That terminal is mid-turn or still starting, so input cannot safely be delivered."
        case .targetHeldByOwnLimit(let reason):
            "\(reason) This is the user's own limit, not the provider's."
        case .targetHeldByCurfew(let reason):
            "\(reason) The user set a curfew on this session; it lifts when they lift it."
        case .notPermitted(let operation):
            "This session was not granted permission to \(operation.supervisionToolName ?? "perform that operation")."
        case .terminalCannotBeWoken:
            "That terminal is dormant and may need a user answer before it can safely resume."
        case .planExceedsGrant(let field):
            "The requested \(field) exceeds this manager's grant."
        case .childrenAtCapacity(let limit):
            "This manager already has its maximum of \(limit) active child sessions."
        case .ceilingReached(let reason):
            "The manager's spend ceiling has been reached: \(reason)"
        case .sendRateReached(let limit):
            "This manager has reached its limit of \(limit) cross-session messages per minute."
        case .messageIsRelay:
            "Do not relay a child transcript through the manager; subscribe to child events instead."
        case .accountUnknown:
            "That account does not exist. List accounts again and use one of the returned ids."
        case .accountUnavailable(let reason):
            "That account cannot accept this session: \(reason)"
        case .accountMoveBudgetReached(let limit):
            "This manager has reached its limit of \(limit) account moves today."
        case .workspaceUnavailable:
            "This session has no managed workspace that can be finished."
        case .supervisionUnknown:
            "That supervision relationship no longer exists."
        case .messageEmpty:
            "Provide a message: whole sentences, as the receiving conversation will read them."
        case .messageTooLong(let limit):
            "The message is over the \(limit)-character limit. Send the conclusion, not the transcript."
        case .deliveryFailed:
            "The session did not take the message; it may be mid-launch or held by a remote participant."
        case .steerNeedsLiveChat:
            "Steering needs a running native chat turn. Send with the queue disposition instead."
        case .watcherAtCapacity(let limit):
            "This session already holds \(limit) watches; wait for one to settle or expire."
        case .watchDependencyCycle:
            "That watch would make the sessions wait on one another. Let the existing watch deliver its result instead."
        case .invalidWatchTimeout:
            "timeout_minutes must be a positive finite number, or omitted for this Threading run."
        case .steerUnavailable(let refusal):
            switch refusal {
            case .unsupported:
                "That provider has no steering primitive. Send with the queue disposition instead."
            case .noActiveTurn:
                "Nothing is running to steer. Send with the queue disposition instead."
            case .turnKindRefusesSteering:
                "The turn in flight refuses additions. Queue the message behind it instead."
            }
        }
    }
}
