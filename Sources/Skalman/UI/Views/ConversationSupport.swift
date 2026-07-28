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
final class FlippedClipView: ThemedClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Conversation Defaults

enum ConversationDefaults {
    /// Tool output beyond this is truncated. Generous, because output is collapsed by
    /// default — the cost of keeping it is layout, not attention.
    static let toolResultLimit = 20_000

    /// Shown above a replay that dropped older turns, so the conversation does not appear to
    /// have begun where the replay does.
    static var truncated: String {
        L10n.string("Earlier messages are not shown.")
    }

    /// How close to the end still counts as "at the bottom" — both for re-pinning after a
    /// gesture and for the subagent summary's follow decision. Exact-bottom comparisons fail
    /// on the fractional offsets a trackpad leaves behind.
    static let bottomTolerance: CGFloat = 40

    /// Past either of these, a user bubble collapses behind a fade — t3code's thresholds.
    /// The check counts characters and hard newlines rather than measuring wrapped lines,
    /// so the decision is pure and the same for every pane width; the visual cap of
    /// `longMessageLineCap` rendered lines is the label's own `maximumNumberOfLines`.
    static let longMessageCharacterCap = 600
    static let longMessageLineCap = 8

    /// Whether a user message is long enough to collapse: a pasted log or a briefing is
    /// context the user already knows — they wrote it — and drawn in full it drowns the
    /// answer it was written to get.
    static func collapsesUserMessage(_ text: String) -> Bool {
        text.count > longMessageCharacterCap
            || text.split(separator: "\n", omittingEmptySubsequences: false).count
                > longMessageLineCap
    }

    /// How long after the last gesture event a bounds change is still read as the user's.
    /// Momentum events keep refreshing it, so a flick stays covered to its end.
    static let gestureAttribution: TimeInterval = 0.15
}
