import AppKit

// MARK: - Delegate

@MainActor
protocol ConversationViewControllerDelegate: AnyObject {
    func conversation(_ controller: ConversationViewController, didExitWithCode code: Int32)

    /// The session's sidebar-visible state changed — it began or finished needing attention.
    func conversationDidChangeActivity(_ controller: ConversationViewController)

    /// Child-agent counts or rows changed. The terminal container projects this into the
    /// top-right status card and refreshes an already-open Subagents pane.
    func conversationSubagentsDidChange(_ controller: ConversationViewController)

    /// The user chose a child in the Subagents pane and wants its live transcript revealed.
    func conversation(
        _ controller: ConversationViewController,
        didSelectSubagent agent: SubagentTimeline.Agent
    )

    /// The selected child changed while its detail may be open. This must not reveal or create
    /// a surface: closing the detail is a user decision that a later stream event cannot undo.
    func conversation(
        _ controller: ConversationViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent
    )

    /// The latest turn's changed-files card asked for its diff — Git Review's Last Turn scope.
    func conversationDidRequestTurnDiff(_ controller: ConversationViewController)

    /// The handoff divider's direct source endpoint was chosen.
    func conversation(
        _ controller: ConversationViewController,
        didRequestOpenSession sessionID: SessionID
    )
}

// MARK: - Flipped Clip View

/// Makes the scroll view fill from the top, so a short conversation sits under the toolbar
/// rather than floating at the bottom of the pane.
final class FlippedClipView: ThemedClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Auto Scroll

/// The conversation's scroll intent — t3code's three-mode machine, in the shape AppKit allows.
///
/// The failure mode this exists to close is their own auto-scroll bug: pin-to-bottom applied
/// per content change yanks the view away from whatever the user scrolled up to read. So
/// following is a *mode*, and only three things change it:
///
/// - **A real gesture.** Near the bottom re-pins; anywhere else releases the pin. AppKit
///   already separates gestures from programmatic scrolls — `scrollWheel` and the live-scroll
///   notifications fire for the user's hand only — so the generation counter t3code needs to
///   tell them apart comes free.
/// - **Sending a message** anchors the sent bubble toward the top and stops following: the
///   reply streams into the space below it while the question holds still. No blank space is
///   reserved below short content — the bubble rises as far as the content allows and holds
///   once it reaches the top, which is the same reading position without the layout cost.
/// - **A minimap jump** releases the pin: the user deliberately went somewhere.
/// - **The floating down-arrow** returns to the live end and resumes following.
///
/// Pure, so the transitions are testable without a scroll view.
struct ConversationAutoScroll: Equatable {

    enum Mode: Equatable {
        /// Pinned to the bottom; new content scrolls into view.
        case following

        /// The just-sent message holds its place while the reply grows below it.
        case anchored

        /// The user scrolled away; nothing moves the view but them.
        case free
    }

    private(set) var mode: Mode = .following

    /// Whether appended or grown content should scroll into view.
    var followsNewContent: Bool { mode == .following }

    mutating func noteUserScrolled(nearBottom: Bool) {
        mode = nearBottom ? .following : .free
    }

    mutating func noteMessageSent() {
        mode = .anchored
    }

    mutating func noteJumpedToRow() {
        mode = .free
    }

    mutating func noteJumpedToBottom() {
        mode = .following
    }

    /// A finished replay lands at the bottom — how a resumed conversation ended is what
    /// matters about it — and following resumes from there.
    mutating func noteReplayFinished() {
        mode = .following
    }
}

// MARK: - Conversation Defaults

enum ConversationDefaults {
    /// Used only until an automatic table row has been measured. Most collapsed tool/fold rows
    /// land near this value; prose replaces it with a cached identity-specific height as soon as
    /// it enters the viewport.
    static let estimatedRowHeight: CGFloat = 48

    /// How hard a transcript row insists on being exactly as wide as its column — see
    /// `ConversationVirtualRowHost.setColumnWidth`. One below required so that a row which
    /// cannot fit loses the argument in its own content rather than in an unsatisfiable
    /// required set, and well above the 750 a label defends its text at.
    static let columnWidthPriority = NSLayoutConstraint.Priority(999)

    /// How hard a pane-level column — the reply box's, the sticky step's — holds the width the
    /// layout pass states for it: above the hugging its content answers with, below everything
    /// the split view says about the pane.
    ///
    /// A column that sits in the pane itself must be a *stated constant*, the way the transcript
    /// rows state theirs, and never an equality to the pane's width. An equality-to-pane under a
    /// required cap cannot be satisfied in a pane wider than the cap, and the solver reduces the
    /// error with whatever is cheapest — which, at any priority above the 250 an
    /// `NSSplitViewItem` positions its pane with, is *the pane*: at `.defaultHigh` each such
    /// column clamped the whole conversation pane down to its own cap and the divider would not
    /// move, reported as "the chat can't be made wider than the textarea". Nor can the equality
    /// simply drop below 250 — the composer's footer hugs at exactly that default, so a weaker
    /// pull loses to the chips and the box collapses to their width instead of filling the pane.
    /// A constant the layout pass has already made satisfiable pulls on nothing; the priority
    /// only has to beat the hug (250) and stay under the divider's own drag (490) — and under
    /// the 500 at which a content-derived constant starts sizing the window (see
    /// `window-chrome.md`). The transcript rows may keep their 999 because they live in the
    /// scroll view's document, where no constraint can reach the pane.
    static let statedColumnPriority = NSLayoutConstraint.Priority(400)

    /// The reply box's column: the transcript's readable measure plus the box's own padding.
    ///
    /// The box is padded by `Design.Spacing.inset` before its text starts, so a box this wide
    /// puts the line being typed on exactly the column the conversation above it is read on —
    /// one edge down the whole pane rather than a box that spans the window under a centred
    /// column. It is a cap: a pane narrower than this keeps the box inset from its edges.
    static var composerWidth: CGFloat { Design.Size.readableWidth + Design.Spacing.inset * 2 }

    /// Tool output beyond this is truncated. Generous, because output is collapsed by
    /// default — the cost of keeping it is layout, not attention.
    static let toolResultLimit = 20_000

    /// Shown above a replay that dropped older turns, so the conversation does not appear to
    /// have begun where the replay does.
    static var truncated: String {
        L10n.string("Earlier messages are not shown.")
    }

    /// How close to the end still counts as "at the bottom" when re-pinning after a gesture.
    /// Exact-bottom comparisons fail on the fractional offsets a trackpad leaves behind.
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
