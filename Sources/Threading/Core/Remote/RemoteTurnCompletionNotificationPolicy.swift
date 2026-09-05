import Foundation

/// Decides whether a provider-neutral activity edge is a completed agent turn worth sending to
/// the device that initiated it.
///
/// A terminal without declared lifecycle boundaries repeatedly crosses working/idle as output
/// goes quiet, so it must never produce this notification. A declared turn may finish either
/// read (`idle`) or unread (`needsAttention`); refusals, dormant sessions, and questions are not
/// successful completion edges.
enum RemoteTurnCompletionNotificationPolicy {
    static func shouldNotify(_ transition: SessionRuntimeTransition) -> Bool {
        guard transition.current.reportsOwnTurns,
              transition.completedPendingOutcome else { return false }
        return transition.current.activity == .idle
            || transition.current.activity == .needsAttention
    }
}

enum RemoteNotificationInteractionActor: Equatable, Hashable {
    case owner
    case member(id: String, name: String)
}

extension RemoteNotificationInteractionActor {
    var notificationParticipantID: RemoteNotificationParticipantID {
        switch self {
        case .owner: .owner
        case .member(let id, _): .member(id)
        }
    }
}

/// A completion goes only to the participant who supplied the current turn, and only through an
/// authorization that still represents that exact participant. Session scope and notification
/// consent remain separate delivery gates in `RemoteNotificationService`.
enum RemoteTurnCompletionRecipientPolicy {
    static func matches(
        _ actor: RemoteNotificationInteractionActor,
        authorization: RemoteAuthorization
    ) -> Bool {
        switch actor {
        case .owner:
            return authorization.principal == .ownerDevice
        case .member(let id, _):
            return authorization.principal == .guest && authorization.member?.id == id
        }
    }
}
