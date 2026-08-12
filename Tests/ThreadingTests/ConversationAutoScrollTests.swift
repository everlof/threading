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

    func testJumpingToTheBottomResumesFollowing() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        scroll.noteJumpedToBottom()
        XCTAssertTrue(scroll.followsNewContent)
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

@MainActor
final class ConversationAutoScrollLayoutTests: XCTestCase {

    func testADeepNewMessageIsBroughtIntoTheViewport() throws {
        let controller = makeDeepConversationController()

        controller.autoScroll.noteMessageSent()
        let newIndex = controller.timeline.rows.count
        controller.apply(controller.timeline.appendUserMessage(
            ConversationUserMessage(text: "Newest question")
        ))
        controller.anchorSentMessage(at: newIndex)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()

        let tableRow = try XCTUnwrap(controller.presentationRow(forTimelineIndex: newIndex))
        let rowRect = controller.tableView.rect(ofRow: tableRow)
        let visibleRect = controller.scrollView.contentView.documentVisibleRect
        XCTAssertTrue(
            rowRect.intersects(visibleRect),
            "The newly sent message \(rowRect) remained outside \(visibleRect)"
        )
    }

    func testFloatingEndControlReturnsToLatestMessageAndResumesFollowing() {
        let controller = makeDeepConversationController()
        let maximumOffset = controller.maximumConversationScrollOffsetY()
        XCTAssertGreaterThan(maximumOffset, 0)

        controller.scrollView.contentView.scroll(to: .zero)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.autoScroll.noteUserScrolled(nearBottom: false)
        controller.updateScrollToEndControl()

        XCTAssertTrue(controller.jumpToEndButton.isFloatingPresent)

        controller.scrollToConversationEnd()

        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            maximumOffset,
            accuracy: 0.5
        )
        // The arrow stops being on offer the moment the jump is taken; whether it is still
        // *drawn* is the length of its departure, which `FloatingScrollTargetMotionTests` owns.
        XCTAssertFalse(controller.jumpToEndButton.isFloatingPresent)
        XCTAssertTrue(controller.autoScroll.followsNewContent)
    }

    private func makeDeepConversationController() -> ConversationViewController {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Scroll anchor", usesNativeUI: true),
            project: Project(
                name: "Scroll anchor",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        controller.isReplaying = true
        for turn in 0..<30 {
            for change in controller.timeline.apply(.userMessage("Question \(turn)")) {
                controller.apply(change)
            }
            for change in controller.timeline.apply(.assistantMessage(
                blocks: [.text(String(repeating: "Answer \(turn). ", count: 30))]
            )) {
                controller.apply(change)
            }
            for change in controller.timeline.apply(.turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(duration: 1)
            )) {
                controller.apply(change)
            }
        }
        controller.finishReplayRendering()
        controller.isReplaying = false
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }
}
