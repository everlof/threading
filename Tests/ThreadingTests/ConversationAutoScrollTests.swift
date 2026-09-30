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

    func testAnAnchoredViewRisesWithTheReplyUntilTheMessageReachesTheTop() {
        // Short content: the sent row's top is out of reach, so the view goes as far as the
        // content allows — the reply growing under it is what makes room.
        XCTAssertEqual(
            ConversationAutoScroll.anchoredLanding(
                anchorOffset: 900,
                currentOffset: 400,
                maximumOffset: 520
            ),
            520
        )
        // Enough reply to lift the row all the way: it stops at the top rather than following.
        XCTAssertEqual(
            ConversationAutoScroll.anchoredLanding(
                anchorOffset: 900,
                currentOffset: 520,
                maximumOffset: 2_000
            ),
            900
        )
    }

    func testAnAnchoredViewNeverMovesBackUp() {
        // Already at the anchor, or past it after a settled turn folded its work away.
        XCTAssertNil(ConversationAutoScroll.anchoredLanding(
            anchorOffset: 900,
            currentOffset: 900,
            maximumOffset: 2_000
        ))
        XCTAssertNil(ConversationAutoScroll.anchoredLanding(
            anchorOffset: 900,
            currentOffset: 950,
            maximumOffset: 700
        ))
    }

    func testAFinishedReplayResumesFollowing() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrolled(nearBottom: false)
        scroll.noteReplayFinished()
        XCTAssertTrue(scroll.followsNewContent)
    }

    func testOrdinaryFollowRequestStillLandsImmediately() {
        var scroll = ConversationAutoScroll()
        XCTAssertTrue(scroll.claimFollowRequest())
    }

    func testFollowRequestWaitsForTheUsersScrollToEnd() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrollBegan()

        XCTAssertFalse(scroll.claimFollowRequest())
        XCTAssertTrue(scroll.followsNewContent, "deferring a landing released autofollow intent")
        XCTAssertTrue(scroll.noteUserScrollEnded())
        XCTAssertFalse(scroll.isUserScrolling)
    }

    func testDeferredFollowDoesNotPullBackAUserWhoScrolledAway() {
        var scroll = ConversationAutoScroll()
        scroll.noteUserScrollBegan()
        XCTAssertFalse(scroll.claimFollowRequest())

        scroll.noteUserScrolled(nearBottom: false)

        XCTAssertFalse(scroll.noteUserScrollEnded())
        XCTAssertEqual(scroll.mode, .free)
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

    /// The reported bug: a reply that arrives in one piece, at the end of a long conversation,
    /// drew entirely below the viewport. The send's anchor clamps to the bottom — nothing exists
    /// under the new message yet — and the anchor then held that origin while the reply landed
    /// under it.
    func testAWholeReplyUnderANewMessageIsBroughtIntoView() throws {
        let controller = makeDeepConversationController()
        let sentIndex = sendMessage("hi", to: controller)

        let replyIndex = controller.timeline.rows.count
        for change in controller.timeline.apply(.assistantMessage(
            blocks: [.text("Hi! What's on your mind?")]
        )) {
            controller.apply(change)
        }
        settle(controller)

        let visible = controller.scrollView.contentView.documentVisibleRect
        let reply = try rect(ofTimelineRow: replyIndex, in: controller)
        XCTAssertGreaterThanOrEqual(
            visible.intersection(reply).height,
            reply.height - 1,
            "the reply \(reply) arrived outside the viewport \(visible)"
        )
        XCTAssertTrue(visible.intersects(try rect(ofTimelineRow: sentIndex, in: controller)))
        XCTAssertEqual(controller.autoScroll.mode, .anchored)
    }

    /// A reply longer than the pane lifts the question to the top and stops there, so the
    /// reader starts the answer from its first line rather than from wherever it ended.
    func testALongReplyLiftsTheSentMessageToTheTopAndHoldsIt() throws {
        let controller = makeDeepConversationController()
        let sentIndex = sendMessage("Explain it all", to: controller)

        for paragraph in 0..<3 {
            for change in controller.timeline.apply(.assistantMessage(
                blocks: [.text(String(repeating: "Paragraph \(paragraph) of the answer. ", count: 60))]
            )) {
                controller.apply(change)
            }
            settle(controller)
        }

        let origin = controller.scrollView.contentView.bounds.origin.y
        let sent = try rect(ofTimelineRow: sentIndex, in: controller)
        XCTAssertEqual(origin, sent.minY - Design.Spacing.large, accuracy: 1)
        XCTAssertLessThan(
            origin,
            controller.maximumConversationScrollOffsetY() - 1,
            "the anchor followed the reply to its end instead of holding the question"
        )
    }

    /// Following was only ever asked by streamed text and tool results. A message, tool call or
    /// notice appended in one piece left a reader at the bottom looking at the row before it.
    func testAWholeRowAppendedAtTheBottomIsFollowed() {
        let controller = makeDeepConversationController()
        XCTAssertTrue(controller.autoScroll.followsNewContent)

        for change in controller.timeline.apply(.assistantMessage(
            blocks: [.text(String(repeating: "A late addition. ", count: 40))]
        )) {
            controller.apply(change)
        }
        settle(controller)

        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumConversationScrollOffsetY(),
            accuracy: 0.5
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

    func testStreamingDoesNotMoveALiveBottomScrollAndCatchesUpAfterward() {
        let controller = makeDeepConversationController()

        // Materialise the streaming row before the gesture so the next delta follows the exact
        // production path that used to write the bottom once per token.
        for change in controller.timeline.apply(.textDelta("Starting")) {
            controller.apply(change)
        }
        controller.view.layoutSubtreeIfNeeded()
        for change in controller.timeline.apply(.textDelta(" reply")) {
            controller.apply(change)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()

        let bottomBeforePull = controller.maximumConversationScrollOffsetY()
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: controller.scrollView
        )
        // A detached clip view constrains a programmatic out-of-range origin, so the harness
        // cannot manufacture AppKit's real elastic offset. A position inside the bottom
        // tolerance exercises the same live-scroll ownership gate while remaining following.
        let livePullOffset = bottomBeforePull - 24
        controller.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: livePullOffset))

        for change in controller.timeline.apply(.textDelta(" token")) {
            controller.apply(change)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            livePullOffset,
            accuracy: 0.5,
            "a streaming follow replaced AppKit's live-scroll position"
        )
        XCTAssertTrue(controller.autoScroll.followsNewContent)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: controller.scrollView
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumConversationScrollOffsetY(),
            accuracy: 0.5
        )
        XCTAssertFalse(controller.autoScroll.isUserScrolling)
        XCTAssertTrue(controller.autoScroll.followsNewContent)
    }

    /// Sends the way `recordSentTurn` does — anchor first, then the echo — and answers the row.
    private func sendMessage(_ text: String, to controller: ConversationViewController) -> Int {
        controller.autoScroll.noteMessageSent()
        let index = controller.timeline.rows.count
        controller.apply(controller.timeline.appendUserMessage(
            ConversationUserMessage(text: text)
        ))
        controller.anchorSentMessage(at: index)
        settle(controller)
        return index
    }

    private func settle(_ controller: ConversationViewController) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()
    }

    private func rect(
        ofTimelineRow index: Int,
        in controller: ConversationViewController
    ) throws -> NSRect {
        let row = try XCTUnwrap(controller.presentationRow(forTimelineIndex: index))
        return controller.tableView.rect(ofRow: row)
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
