import Foundation

/// Covers account resolution as well as the human wait: Stop may arrive while a usage fetch
/// is still in flight, before there is a card to dismiss. A late result never revives that call.
@MainActor
final class SubagentLaunchLifetime {
    private(set) var isCancelled = false
    var onCancel: (() -> Void)?
    private let observations = AppEventObservations()

    init(parentID: SessionID) {
        observations.observe(SessionWorkDidChange.self) { [weak self] event in
            if event.sessionID == parentID, event.kind == .turnEnded { self?.cancel() }
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            if event.sessionID == parentID { self?.cancel() }
        }
    }

    func finish() {
        observations.removeAll()
        onCancel = nil
    }

    private func cancel() {
        isCancelled = true
        let callback = onCancel
        finish()
        callback?()
    }
}
