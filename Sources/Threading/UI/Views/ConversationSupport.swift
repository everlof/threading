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

    /// A changed-files card asked for the immutable diff belonging to its exact turn.
    func conversation(
        _ controller: ConversationViewController,
        didRequestTurnDiff checkpointID: GitTurnCheckpointID
    )

    /// The handoff divider's direct source endpoint was chosen.
    func conversation(
        _ controller: ConversationViewController,
        didRequestOpenSession sessionID: SessionID
    )

    /// The app-owned `/usage` command asked the window to open Limit history for this login.
    func conversation(
        _ controller: ConversationViewController,
        didRequestUsageFor accountID: AccountID?
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
///   reserved below short content — the bubble rises as far as the content allows, and keeps
///   rising as the reply grows (`anchoredLanding`) until it reaches the top, where it holds.
///   That is the same reading position without the layout cost.
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

    /// The scroll view owns its position while the user's gesture, momentum, or elastic return
    /// is in flight. Following remains the standing intent during that interval; only the
    /// programmatic landing is deferred.
    private(set) var isUserScrolling = false
    private var hasDeferredFollow = false

    /// Whether appended or grown content should scroll into view.
    var followsNewContent: Bool { mode == .following }

    mutating func noteUserScrolled(nearBottom: Bool) {
        mode = nearBottom ? .following : .free
    }

    mutating func noteUserScrollBegan() {
        isUserScrolling = true
    }

    /// Claims a requested programmatic landing. While AppKit owns a live scroll, remember the
    /// request without writing the clip-view origin and canceling its rubber-band physics.
    mutating func claimFollowRequest() -> Bool {
        guard followsNewContent else { return false }
        guard !isUserScrolling else {
            hasDeferredFollow = true
            return false
        }
        return true
    }

    /// Ends AppKit's ownership and reports whether content arrived while following was deferred.
    /// Gesture-produced bounds changes have already decided `following` versus `free`, so content
    /// growth during the gesture cannot itself release the standing follow intent here.
    mutating func noteUserScrollEnded() -> Bool {
        isUserScrolling = false
        defer { hasDeferredFollow = false }
        return followsNewContent && hasDeferredFollow
    }

    mutating func noteMessageSent() {
        mode = .anchored
    }

    /// Where an anchored viewport moves as the reply grows beneath the sent message, or nil
    /// when it should stay where it is.
    ///
    /// The sent row rises toward `anchorOffset` (its top, less a margin) as far as the content
    /// below it allows. At the end of a long conversation the clip view's clamp first lands the
    /// bubble at the *bottom* of the pane, because nothing exists under it yet. Holding that
    /// origin still, as the anchor once did, meant the reply streamed in entirely below the
    /// viewport. The fix is to follow the reply until the bubble reaches the top, then hold.
    /// The view never moves back up: a settled turn folding its work away shrinks the document,
    /// and the clip view's own clamp is the only correction that needs.
    static func anchoredLanding(
        anchorOffset: CGFloat,
        currentOffset: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat? {
        let target = max(0, min(anchorOffset, maximumOffset))
        return target > currentOffset + ConversationDefaults.landingTolerance ? target : nil
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
