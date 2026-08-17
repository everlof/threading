import Foundation

struct ManagerActionNoticeDidChange: AppEvent {
    static let name = Notification.Name("managerActionNoticeDidChange")
    let sessionID: SessionID
}

/// Ephemeral, actionable receipts for manager operations that change how a child opens.
///
/// The durable audit lives in `supervision_event`; this store retains the previous account
/// object only long enough to offer the pane's Undo action in the current app run.
@MainActor
final class ManagerActionNoticeStore {
    struct Move: Equatable {
        let sessionID: SessionID
        let managerID: SessionID
        let source: AgentAccount?
        let destination: AgentAccount
        let at: Date
    }

    static let shared = ManagerActionNoticeStore()

    private var moves: [SessionID: Move] = [:]

    func recordMove(
        sessionID: SessionID,
        managerID: SessionID,
        from source: AgentAccount?,
        to destination: AgentAccount,
        at: Date = Date()
    ) {
        moves[sessionID] = Move(
            sessionID: sessionID,
            managerID: managerID,
            source: source,
            destination: destination,
            at: at
        )
        NotificationCenter.default.post(ManagerActionNoticeDidChange(sessionID: sessionID))
    }

    func move(for sessionID: SessionID) -> Move? { moves[sessionID] }

    func dismissMove(for sessionID: SessionID) {
        guard moves.removeValue(forKey: sessionID) != nil else { return }
        NotificationCenter.default.post(ManagerActionNoticeDidChange(sessionID: sessionID))
    }
}
