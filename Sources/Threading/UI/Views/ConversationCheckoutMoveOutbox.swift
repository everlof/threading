import Foundation

/// Hands the native queue across the runtime replacement after the old controller has applied
/// `turnFinished`, leaving only prompts that still belong in the destination checkout.
extension ConversationViewController {
    func checkoutMoveOutboxSnapshot() -> ConversationOutbox? {
        outbox.isEmpty ? nil : outbox
    }

    func restoreCheckoutMoveOutbox(_ outbox: ConversationOutbox) {
        self.outbox = outbox
        if isViewLoaded { refreshOutboxRail() }
    }
}
