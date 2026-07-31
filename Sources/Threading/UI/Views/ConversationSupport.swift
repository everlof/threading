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

    /// A finished replay lands at the bottom — how a resumed conversation ended is what
    /// matters about it — and following resumes from there.
    mutating func noteReplayFinished() {
        mode = .following
    }
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
