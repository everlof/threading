import AppKit

// MARK: - Delegate

protocol ConversationViewControllerDelegate: AnyObject {
    func conversation(_ controller: ConversationViewController, didExitWithCode code: Int32)

    /// The session's sidebar-visible state changed — it began or finished needing attention.
    func conversationDidChangeActivity(_ controller: ConversationViewController)
}

// MARK: - Flipped Clip View

/// Makes the scroll view fill from the top, so a short conversation sits under the toolbar
/// rather than floating at the bottom of the pane.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Conversation Defaults

enum ConversationDefaults {
    /// Tool output beyond this is truncated. Generous, because output is collapsed by
    /// default — the cost of keeping it is layout, not attention.
    static let toolResultLimit = 20_000

    /// Shown above a replay that dropped older turns, so the conversation does not appear to
    /// have begun where the replay does.
    static let truncated = "Earlier messages are not shown."
}
