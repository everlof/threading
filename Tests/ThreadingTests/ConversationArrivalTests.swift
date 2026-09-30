import AppKit
import XCTest
@testable import Threading

/// What moves when something arrives in a conversation, and what must not.
///
/// A live row makes an entrance; everything that was already there — replayed history, a
/// reload, the finished form of a reply the reader watched stream in — appears in silence. The
/// last is the one that matters most: animating it would blink the reply out and fade it back
/// at the moment it completes.
@MainActor
final class ConversationArrivalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Design.Motion.reduceMotionOverrideForTesting = false
    }

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    func testALiveReplyMakesAnEntrance() throws {
        let controller = makeController()
        XCTAssertTrue(try arrives(in: controller) {
            appendReply("Here is what I found.", to: controller)
        })
    }

    func testReplayedRowsAppearInSilence() throws {
        let controller = makeController()
        XCTAssertEqual(controller.transcript.arrivalsPlayed, 0)
    }

    func testAStreamedReplyTakesItsPlaceInSilence() throws {
        let controller = makeController()
        XCTAssertTrue(try arrives(in: controller) {
            for change in controller.timeline.apply(.textDelta("Streaming the ")) {
                controller.apply(change)
            }
            return nil
        }, "the placeholder, as the reply begins, makes the entrance")
        XCTAssertFalse(try arrives(in: controller) {
            appendReply("Streaming the answer.", to: controller)
        })

        // Consumed by that one row: the next thing to arrive makes its own entrance.
        XCTAssertTrue(try arrives(in: controller) {
            appendReply("And one more thing.", to: controller)
        })
    }

    func testAnArrivalMissedWhileScrolledAwayIsNotPlayedLater() throws {
        let controller = makeController()
        var now: TimeInterval = 100
        controller.transcript.arrivalClock = { now }
        // The reader is up in the history when the row lands, and comes back after the window.
        controller.scrollView.contentView.scroll(to: .zero)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.autoScroll.noteUserScrolled(nearBottom: false)
        let before = controller.transcript.arrivalsPlayed
        let index = appendReply("Later.", to: controller)
        settle(controller)
        now += Design.Chat.arrivalWindow + 1
        controller.scrollToConversationEnd()
        settle(controller)
        _ = try materialize(timelineRow: index, in: controller)
        XCTAssertEqual(controller.transcript.arrivalsPlayed, before)
    }

    func testReduceMotionPlaysNoEntrance() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        let controller = makeController()
        XCTAssertFalse(try arrives(in: controller) {
            appendReply("Here is what I found.", to: controller)
        })
    }

    func testMessageActionsAreQuietUntilThePointerArrives() throws {
        let message = ConversationMessageContextView(content: NSView(), speaker: .agent)
        message.copyText = "Hi! What's on your mind?"
        XCTAssertFalse(message.showsActions)

        message.mouseEntered(with: try pointerEvent(.mouseEntered))
        XCTAssertTrue(message.showsActions)

        message.mouseExited(with: try pointerEvent(.mouseExited))
        XCTAssertFalse(message.showsActions)
    }

    // MARK: - Fixture

    private func makeController() -> ConversationViewController {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Arrivals", usesNativeUI: true),
            project: Project(
                name: "Arrivals",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        controller.isReplaying = true
        // Taller than the pane, so the live end and the history are different places.
        for turn in 0..<8 {
            for change in controller.timeline.apply(.userMessage("Question \(turn)")) {
                controller.apply(change)
            }
            for change in controller.timeline.apply(.assistantMessage(
                blocks: [.text(String(repeating: "Answer \(turn). ", count: 20))]
            )) {
                controller.apply(change)
            }
        }
        controller.finishReplayRendering()
        controller.isReplaying = false
        // Frozen: what is under test is which rows arrive, not how quickly the host app yields.
        controller.transcript.arrivalClock = { 0 }
        settle(controller)
        return controller
    }

    /// Appends a reply and answers its timeline index; the row is left for `arrives` to show.
    private func appendReply(_ text: String, to controller: ConversationViewController) -> Int {
        let index = controller.timeline.rows.count
        for change in controller.timeline.apply(.assistantMessage(blocks: [.text(text)])) {
            controller.apply(change)
        }
        return index
    }

    /// Whether what `append` adds makes an entrance once shown: the row at the index it
    /// answers, or with nil, whatever the follow pass reveals. Counted from before the append,
    /// since a row appended inside the viewport may be built during the insertion itself.
    private func arrives(
        in controller: ConversationViewController,
        _ append: () -> Int?
    ) throws -> Bool {
        let before = controller.transcript.arrivalsPlayed
        let index = append()
        settle(controller)
        if let index { _ = try materialize(timelineRow: index, in: controller) }
        return controller.transcript.arrivalsPlayed > before
    }

    private func settle(_ controller: ConversationViewController) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        controller.view.layoutSubtreeIfNeeded()
    }

    private func materialize(
        timelineRow index: Int,
        in controller: ConversationViewController
    ) throws -> ConversationVirtualRowHost {
        let row = try XCTUnwrap(controller.presentationRow(forTimelineIndex: index))
        return try XCTUnwrap(
            controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? ConversationVirtualRowHost
        )
    }

    private func pointerEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }
}
