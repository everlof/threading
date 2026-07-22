import XCTest
@testable import Skalman

/// The turn rail's arithmetic, tested without a window.
///
/// Two rules here are worth more than the rest and are the reason this is a separate type at
/// all: the rail **indexes** the conversation rather than scaling it, and it **disappears**
/// rather than encroach on the text. Both are invisible in a screenshot of a wide window,
/// which is where this would be looked at.
final class ConversationMinimapTests: XCTestCase {

    private let column = Design.Size.readableWidth

    // MARK: - Availability

    func testANarrowPaneGetsNoRailAtAll() {
        // The case that matters: Skalman is a three-pane window, and the conversation is
        // routinely the narrow one. A rail drawn here would sit on top of the text.
        for paneWidth in [stride(from: 320.0, through: column, by: 40.0)].joined() {
            XCTAssertEqual(
                ConversationMinimap.railWidth(paneWidth: paneWidth, columnWidth: column), 0,
                "A \(Int(paneWidth))pt pane has no gutter but was offered a rail"
            )
        }
    }

    func testARailAppearsOnceThereIsGutterToSpare() {
        // The column is capped, so every point past the cap is gutter — half of it each side.
        let paneWidth = column + 2 * (ConversationMinimap.Metrics.gutterInset + 20)
        XCTAssertEqual(ConversationMinimap.railWidth(paneWidth: paneWidth, columnWidth: column), 20)
    }

    func testTheRailNeverGrowsPastItsCapHoweverWideTheWindow() {
        // Otherwise a maximised window gives a 400pt rail, which reads as a third pane rather
        // than as a control.
        let width = ConversationMinimap.railWidth(paneWidth: 4000, columnWidth: column)
        XCTAssertEqual(width, ConversationMinimap.Metrics.maximumWidth)
    }

    func testARailIsOnlyPersistentWhenTheGutterIsComfortable() {
        let tight = column + 2 * (ConversationMinimap.Metrics.persistentGutter - 1)
        let roomy = column + 2 * ConversationMinimap.Metrics.persistentGutter

        XCTAssertFalse(ConversationMinimap.isPersistent(paneWidth: tight, columnWidth: column))
        XCTAssertTrue(ConversationMinimap.isPersistent(paneWidth: roomy, columnWidth: column))
    }

    func testOneTurnEarnsNoRail() {
        // Same "earns its level" rule the sidebar's grouping uses: an index of one item is not
        // an index.
        let wide = column + 400

        XCTAssertFalse(ConversationMinimap.isAvailable(turnCount: 0, paneWidth: wide, columnWidth: column))
        XCTAssertFalse(ConversationMinimap.isAvailable(turnCount: 1, paneWidth: wide, columnWidth: column))
        XCTAssertTrue(ConversationMinimap.isAvailable(turnCount: 2, paneWidth: wide, columnWidth: column))
    }

    // MARK: - Geometry

    func testMarksAreEvenlySpacedRatherThanScaledToTheConversation() {
        // The whole design decision, pinned. A turn that ran forty tool calls and one that ran
        // none are one exchange each; spacing by length would give the long one a long stretch
        // of rail that says nothing about how much was *said*.
        let height: CGFloat = 100

        XCTAssertEqual(ConversationMinimap.markerCenterY(index: 0, turnCount: 5, railHeight: height), 0)
        XCTAssertEqual(ConversationMinimap.markerCenterY(index: 2, turnCount: 5, railHeight: height), 50)
        XCTAssertEqual(ConversationMinimap.markerCenterY(index: 4, turnCount: 5, railHeight: height), 100)
    }

    func testASingleMarkSitsInTheMiddleRatherThanAtTheTop() {
        XCTAssertEqual(ConversationMinimap.markerCenterY(index: 0, turnCount: 1, railHeight: 100), 50)
    }

    func testAnOutOfRangeIndexIsClampedRatherThanRunningOffTheRail() {
        XCTAssertEqual(ConversationMinimap.markerCenterY(index: 99, turnCount: 5, railHeight: 100), 100)
        XCTAssertEqual(ConversationMinimap.markerCenterY(index: -3, turnCount: 5, railHeight: 100), 0)
    }

    func testRailHeightGrowsWithTheTurnCountButIsBoundedByThePane() {
        let spacing = ConversationMinimap.Metrics.markerSpacing

        XCTAssertEqual(ConversationMinimap.railHeight(turnCount: 5, paneHeight: 900), 4 * spacing)

        // A conversation of two hundred turns must not produce a rail taller than the window.
        let tall = ConversationMinimap.railHeight(turnCount: 200, paneHeight: 900)
        XCTAssertEqual(tall, 900 * ConversationMinimap.Metrics.maximumHeightFraction)
    }

    // MARK: - Pointer

    func testThePointerPicksTheNearestMark() {
        let height: CGFloat = 100

        XCTAssertEqual(ConversationMinimap.index(atY: 0, turnCount: 5, railHeight: height), 0)
        XCTAssertEqual(ConversationMinimap.index(atY: 26, turnCount: 5, railHeight: height), 1)
        XCTAssertEqual(ConversationMinimap.index(atY: 51, turnCount: 5, railHeight: height), 2)
        XCTAssertEqual(ConversationMinimap.index(atY: 100, turnCount: 5, railHeight: height), 4)
    }

    func testPointingPastTheRailClampsRatherThanReturningNothing() {
        // The hit area is taller than the rail — it spans the pane — so a pointer above the
        // first mark or below the last should still resolve, to the end it is nearest.
        XCTAssertEqual(ConversationMinimap.index(atY: -500, turnCount: 5, railHeight: 100), 0)
        XCTAssertEqual(ConversationMinimap.index(atY: 900, turnCount: 5, railHeight: 100), 4)
    }

    func testPointingAtAnEmptyRailResolvesToNothing() {
        XCTAssertNil(ConversationMinimap.index(atY: 10, turnCount: 0, railHeight: 100))
    }

    // MARK: - Fisheye

    func testMarksTaperWithDistanceFromThePointer() {
        // The taper is what makes the rail read as a position rather than as a row of identical
        // ticks — it says "you are here" without a label.
        typealias Metrics = ConversationMinimap.Metrics

        XCTAssertEqual(ConversationMinimap.markerWidth(index: 5, activeIndex: 5), Metrics.activeMarkerWidth)
        XCTAssertEqual(ConversationMinimap.markerWidth(index: 6, activeIndex: 5), Metrics.neighbourMarkerWidths[0])
        XCTAssertEqual(ConversationMinimap.markerWidth(index: 3, activeIndex: 5), Metrics.neighbourMarkerWidths[1])
        XCTAssertEqual(ConversationMinimap.markerWidth(index: 9, activeIndex: 5), Metrics.restingMarkerWidth)
    }

    func testWithNoPointerEveryMarkRests() {
        for index in 0..<6 {
            XCTAssertEqual(
                ConversationMinimap.markerWidth(index: index, activeIndex: nil),
                ConversationMinimap.Metrics.restingMarkerWidth
            )
        }
    }
}

// MARK: - Turns

/// What the rail indexes: the conversation's exchanges, derived from its rows.
final class ConversationTurnTests: XCTestCase {

    private func timeline(_ events: [StreamEvent]) -> ConversationTimeline {
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return timeline
    }

    func testATurnIsAUserMessageAndTheAgentsConclusion() {
        // The *last* assistant message, not the first: an agent narrates on the way to an
        // answer, and the preview should show what it concluded rather than what it said while
        // still working it out.
        let timeline = self.timeline([
            .userMessage("Fix the failing test"),
            .assistantMessage(blocks: [.text("Let me look.")]),
            .assistantMessage(blocks: [.toolUse(id: "1", name: "Bash", input: ["command": "swift test"])]),
            .assistantMessage(blocks: [.text("Fixed — it was an off-by-one.")])
        ])

        XCTAssertEqual(timeline.turns.count, 1)
        XCTAssertEqual(timeline.turns[0].rowIndex, 0)
        XCTAssertEqual(timeline.turns[0].userText, "Fix the failing test")
        XCTAssertEqual(timeline.turns[0].assistantText, "Fixed — it was an off-by-one.")
    }

    func testATurnInFlightHasNoConclusionYet() {
        let timeline = self.timeline([.userMessage("Start the build")])

        XCTAssertEqual(timeline.turns.count, 1)
        XCTAssertNil(timeline.turns[0].assistantText)
    }

    func testATurnDoesNotBorrowTheNextTurnsAnswer() {
        let timeline = self.timeline([
            .userMessage("First"),
            .assistantMessage(blocks: [.text("Answer to first.")]),
            .userMessage("Second"),
            .assistantMessage(blocks: [.text("Answer to second.")])
        ])

        XCTAssertEqual(timeline.turns.map(\.userText), ["First", "Second"])
        XCTAssertEqual(timeline.turns.map(\.assistantText), ["Answer to first.", "Answer to second."])
    }

    func testPreviewsAreOneLineEvenWhenTheMessageIsNot() {
        // The preview is a glance while the pointer moves. A markdown message with headings and
        // bullets rendered into it verbatim would be a paragraph in a floating card.
        let timeline = self.timeline([
            .userMessage("Do   the\n\n  thing"),
            .assistantMessage(blocks: [.text("## Done\n\n- one\n- two\n")])
        ])

        XCTAssertEqual(timeline.turns[0].userText, "Do the thing")
        XCTAssertEqual(timeline.turns[0].assistantText, "## Done - one - two")
    }

    func testRowIndexPointsAtTheUserMessageSoTheRailCanScrollToIt() {
        let timeline = self.timeline([
            .assistantMessage(blocks: [.text("Resumed.")]),
            .userMessage("Carry on"),
            .assistantMessage(blocks: [.text("Carrying on.")])
        ])

        let turn = timeline.turns[0]
        XCTAssertEqual(turn.rowIndex, 1)
        XCTAssertEqual(timeline.rows[turn.rowIndex], .userMessage("Carry on"))
    }

    func testARealConversationYieldsARailWorthDrawing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/claude-edit-heavy.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let (events, _) = TranscriptReplay.read(at: url, kind: .claude)
        let turns = timeline(events).turns

        // Far fewer than the fixture's `type: "user"` record count, and correctly so: Claude
        // wraps every tool *result* in a user record too, and only what was actually typed
        // opens a turn. The rail indexes exchanges, not records.
        XCTAssertGreaterThanOrEqual(
            turns.count, ConversationMinimap.Metrics.minimumTurns,
            "A real conversation should index to enough turns to earn a rail"
        )
        XCTAssertTrue(turns.allSatisfy { !$0.userText.isEmpty }, "A turn with no subject line")
        XCTAssertTrue(turns.allSatisfy { !$0.userText.contains("\n") }, "A preview ran to several lines")

        // Ordered, and each pointing at a genuine user row.
        XCTAssertEqual(turns.map(\.rowIndex), turns.map(\.rowIndex).sorted())
    }
}
