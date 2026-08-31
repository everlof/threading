/// Decides whether a provider-neutral activity edge is a completed agent turn worth sending to
/// the device that initiated it.
///
/// A terminal without declared lifecycle boundaries repeatedly crosses working/idle as output
/// goes quiet, so it must never produce this notification. A declared turn may finish either
/// read (`idle`) or unread (`needsAttention`); refusals, dormant sessions, and questions are not
/// successful completion edges.
enum RemoteTurnCompletionNotificationPolicy {
    static func shouldNotify(
        from old: SessionActivity,
        to new: SessionActivity,
        reportsOwnTurns: Bool
    ) -> Bool {
        guard reportsOwnTurns, old.hasTurnInFlight else { return false }
        return new == .idle || new == .needsAttention
    }
}

enum RemoteNotificationInteractionActor: Equatable {
    case owner
    case member(id: String, name: String)
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
