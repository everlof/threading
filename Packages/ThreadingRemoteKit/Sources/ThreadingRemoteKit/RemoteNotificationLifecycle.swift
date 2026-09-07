/// Delivery policy is an exhaustive host-owned classification. Adding a notification kind must
/// choose a lifetime here; it cannot silently inherit the immediate-delivery bypass.
public enum RemoteNotificationLifecycle: Equatable, Sendable {
    case completedTurn
    case responseRequest
    case independentEvent
}

public extension RemoteNotificationKind {
    var lifecycle: RemoteNotificationLifecycle {
        switch self {
        case .turnCompleted: return .completedTurn
        case .agentQuestion, .permissionRequest: return .responseRequest
        case .sharedSession, .agentMessage, .attentionRequest: return .independentEvent
        }
    }

    var supportsRetraction: Bool { lifecycle != .independentEvent }
}
