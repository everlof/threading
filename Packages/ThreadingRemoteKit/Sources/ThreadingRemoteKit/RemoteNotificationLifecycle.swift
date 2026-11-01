/// Delivery policy is an exhaustive host-owned classification. Adding a notification kind must
/// choose a lifetime here; it cannot silently inherit the immediate-delivery bypass.
public enum RemoteNotificationLifecycle: Equatable, Sendable {
    case completedTurn
    case responseRequest
    case independentEvent
    /// Delivered at once like an independent event, but the sender withdraws it the moment it no
    /// longer applies: an invitation whose answer is the person showing up.
    case expiringOffer
}

public extension RemoteNotificationKind {
    var lifecycle: RemoteNotificationLifecycle {
        switch self {
        case .turnCompleted: return .completedTurn
        case .agentQuestion, .permissionRequest: return .responseRequest
        case .sharedSession, .agentMessage, .attentionRequest, .secretApproval: return .independentEvent
        case .mirrorInvite: return .expiringOffer
        }
    }

    var supportsRetraction: Bool { lifecycle != .independentEvent }

    /// The session slot, and so the thread, of every Face ID approval alert: a machine token, so
    /// a newer alert replaces an older one and nothing mistakes it for a chat.
    static let secretApprovalThread = "secret-approval"
}
