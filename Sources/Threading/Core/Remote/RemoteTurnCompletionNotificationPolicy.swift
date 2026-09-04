import Foundation

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

/// A routine completion is a fallback for an owner who has stepped away from Threading on the
/// Mac. It is not an urgent alert, so an active Mac owns the presentation while the iPhone stays
/// quiet. Guest completions cannot use the owner's Mac activity: that would let one participant
/// accidentally silence another participant's notification.
enum RemoteTurnCompletionDeviceActivityPolicy {
    enum Decision: Equatable {
        case deliverNow
        case deferUntilMacInactive(deadlineUptime: TimeInterval)
    }

    /// Long enough for the ordinary pause between submitting a turn and reading its result, but
    /// short enough that a Mac left frontmost becomes an inactive device without a setting.
    static let recentMacInteractionSeconds: TimeInterval = 2 * 60

    static func deliveryDecision(
        actor: RemoteNotificationInteractionActor,
        applicationIsActive: Bool,
        lastInteractionUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Decision {
        guard case .owner = actor,
              applicationIsActive,
              let lastInteractionUptime else { return .deliverNow }
        let age = nowUptime - lastInteractionUptime
        guard age >= 0, age < recentMacInteractionSeconds else { return .deliverNow }
        return .deferUntilMacInactive(
            deadlineUptime: lastInteractionUptime + recentMacInteractionSeconds
        )
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
