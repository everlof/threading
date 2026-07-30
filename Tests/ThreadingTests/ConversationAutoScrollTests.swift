import XCTest
@testable import Threading

/// The conversation's scroll-intent machine, tested apart from any scroll view.
///
/// The transitions matter more than they look: t3code shipped the naive version — pin to
/// bottom per content change — and their own tracker records it fighting the reader (#3925).
final class ConversationAutoScrollTests: XCTestCase {

    func testStartsFollowing() {
        XCTAssertTrue(ConversationAutoScroll().followsNewContent)
    }

    func testAGestureAwayReleasesThePin() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        XCTAssertFalse(scroll.followsNewContent)
    }

    func testAGestureBackToTheBottomRePins() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        scroll.noteUserScrolled(nearBottom: true)
        XCTAssertTrue(scroll.followsNewContent)
    }

    func testSendingAnchorsAndStopsFollowing() {
        // The sent bubble holds its place while the reply streams in below it. Content
        // growth must not move the view — that is the whole point of the anchor.
        var scroll = ConversationAutoScroll()
        scroll.noteMessageSent()
        XCTAssertEqual(scroll.mode, .anchored)
        XCTAssertFalse(scroll.followsNewContent)
    }

    func testSendingAnchorsEvenAfterScrollingAway() {
        // Every send re-anchors: the newest question is what the user is waiting on.
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        scroll.noteMessageSent()
        XCTAssertEqual(scroll.mode, .anchored)
    }

    func testAMinimapJumpReleasesThePin() {
        var scroll = ConversationAutoScroll()
        scroll.noteJumpedToRow()
        XCTAssertFalse(scroll.followsNewContent)
    }

    func testOnlyAGestureEndsTheAnchor() {
        // Programmatic scrolls cannot change the mode at all — the controller only reports
        // gestures here. A gesture near the bottom resumes following; one anywhere else
        // leaves the user free.
        var scroll = ConversationAutoScroll()
        scroll.noteMessageSent()
        scroll.noteUserScrolled(nearBottom: true)
        XCTAssertTrue(scroll.followsNewContent)

        scroll.noteMessageSent()
        scroll.noteUserScrolled(nearBottom: false)
        XCTAssertEqual(scroll.mode, .free)
    }

    func testAFinishedReplayResumesFollowing() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        scroll.noteReplayFinished()
        XCTAssertTrue(scroll.followsNewContent)
    }
}
