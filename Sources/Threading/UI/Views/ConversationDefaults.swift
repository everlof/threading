import AppKit

// MARK: - Conversation Defaults

enum ConversationDefaults {
    /// How hard a transcript row insists on being exactly as wide as its column — see
    /// `ConversationVirtualRowHost.setColumnWidth`. One below required so that a row which
    /// cannot fit loses the argument in its own content rather than in an unsatisfiable
    /// required set, and well above the 750 a label defends its text at.
    static let columnWidthPriority = ConversationRowDefaults.columnWidthPriority

    /// A pane-level column must beat content hugging (250) but yield to the display pane's
    /// holding priority (260). A drag or restored divider can arrive before the next layout
    /// pass updates the column's measured width; at 400, that stale constant pulled the pane
    /// back. Below 250, the reply box instead shrank to its content's fitting width.
    /// Transcript rows keep their separate 999 because they live in the scroll document.
    static let statedColumnPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 1
    )

    /// The reply box's column: the transcript's column plus the box's own padding.
    ///
    /// The box is padded by `Design.Spacing.inset` before its text starts, so a box this wide
    /// puts the line being typed on exactly the column the conversation above it is read on —
    /// one edge down the whole pane rather than a box that spans the window under a centred
    /// column. It is a cap: a pane narrower than this keeps the box inset from its edges.
    @MainActor static var composerWidth: CGFloat { Design.Chat.columnWidth + Design.Spacing.inset * 2 }

    /// Tool output beyond this is truncated. Generous, because output is collapsed by
    /// default — the cost of keeping it is layout, not attention.
    static let toolResultLimit = ConversationTimelineDefaults.toolResultLimit

    /// Shown above a replay that dropped older turns, so the conversation does not appear to
    /// have begun where the replay does.
    static var truncated: String {
        L10n.string("Earlier messages are not shown.")
    }

    /// How close to the end still counts as "at the bottom" when re-pinning after a gesture.
    /// Exact-bottom comparisons fail on the fractional offsets a trackpad leaves behind.
    static let bottomTolerance: CGFloat = 40

    /// Below this, a programmatic landing is a fraction of a point of layout noise and not
    /// worth a bounds write.
    static let landingTolerance: CGFloat = 0.5

    /// One landing to reveal the destination's rows, one to land on the height they measured
    /// at — see `ConversationViewController.landMeasuringWhatItReveals`.
    static let measuredLandingPasses = 2

    /// Past either of these, a user bubble collapses behind a fade — t3code's thresholds.
    /// The check counts characters and hard newlines rather than measuring wrapped lines,
    /// so the decision is pure and the same for every pane width; the visual cap of
    /// `longMessageLineCap` rendered lines is the label's own `maximumNumberOfLines`.
    static let longMessageCharacterCap = ConversationUserRowDefaults.longMessageCharacterCap
    static let longMessageLineCap = ConversationUserRowDefaults.longMessageLineCap

    /// Whether a user message is long enough to collapse: a pasted log or a briefing is
    /// context the user already knows — they wrote it — and drawn in full it drowns the
    /// answer it was written to get.
    static func collapsesUserMessage(_ text: String) -> Bool {
        ConversationUserRowDefaults.collapsesUserMessage(text)
    }

    /// How long after the last gesture event a bounds change is still read as the user's.
    /// Momentum events keep refreshing it, so a flick stays covered to its end.
    static let gestureAttribution: TimeInterval = 0.15
}
