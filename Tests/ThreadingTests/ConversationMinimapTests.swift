import XCTest
@testable import Threading

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
        // The case that matters: Threading is a three-pane window, and the conversation is
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

    // MARK: - Placement

    func testTheRailStaysByThePaneEdgeAsTheWindowGrows() {
        // The bug this fixes, seen in the running app: anchored to the column's leading edge,
        // the rail drifted inward with the centred column and ended up stranded in the middle
        // of an empty margin, attached to nothing.
        let wide = ConversationMinimap.railLeading(paneWidth: 1400, columnWidth: column)
        let wider = ConversationMinimap.railLeading(paneWidth: 2600, columnWidth: column)

        XCTAssertEqual(wide, ConversationMinimap.Metrics.edgeInset)
        XCTAssertEqual(wider, ConversationMinimap.Metrics.edgeInset, "The rail drifted with the column")
    }

    func testTheRailGivesUpTheEdgeRatherThanItsClearanceFromTheText() {
        // In a tight gutter the two cannot both be had. Clearance from the text wins: a rail
        // touching the column is worse than one sitting closer in than usual.
        let paneWidth = column + 2 * 60
        let leading = ConversationMinimap.railLeading(paneWidth: paneWidth, columnWidth: column)
        let width = ConversationMinimap.railWidth(paneWidth: paneWidth, columnWidth: column)

        XCTAssertLessThan(leading, ConversationMinimap.Metrics.edgeInset)
        XCTAssertLessThanOrEqual(
            leading + width,
            60 - ConversationMinimap.Metrics.gutterInset,
            "The rail crossed into its clearance from the column"
        )
    }

    func testTheRailNeverStartsOffThePane() {
        for paneWidth in [stride(from: 320.0, through: 2000.0, by: 40.0)].joined() {
            XCTAssertGreaterThanOrEqual(
                ConversationMinimap.railLeading(paneWidth: paneWidth, columnWidth: column), 0,
                "A \(Int(paneWidth))pt pane put the rail off its own leading edge"
            )
        }
    }

    func testTheRailNeverTouchesTheColumnAtAnyWidth() {
        // The one thing it must never do, checked across every width rather than at the two
        // that happened to be looked at.
        for paneWidth in [stride(from: 320.0, through: 2600.0, by: 20.0)].joined() {
            let leading = ConversationMinimap.railLeading(paneWidth: paneWidth, columnWidth: column)
            let width = ConversationMinimap.railWidth(paneWidth: paneWidth, columnWidth: column)
            let columnLeading = ConversationMinimap.gutter(paneWidth: paneWidth, columnWidth: column)

            guard width > 0 else { continue }
            XCTAssertLessThanOrEqual(
                leading + width + ConversationMinimap.Metrics.gutterInset, columnLeading,
                "At \(Int(paneWidth))pt the rail came within \(ConversationMinimap.Metrics.gutterInset)pt of the text"
            )
        }
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

        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: 0, markCount: 5, railHeight: height), 0)
        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: 2, markCount: 5, railHeight: height), 50)
        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: 4, markCount: 5, railHeight: height), 100)
    }

    func testASingleMarkSitsInTheMiddleRatherThanAtTheTop() {
        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: 0, markCount: 1, railHeight: 100), 50)
    }

    func testAnOutOfRangeIndexIsClampedRatherThanRunningOffTheRail() {
        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: 99, markCount: 5, railHeight: 100), 100)
        XCTAssertEqual(ConversationMinimap.markerCenterY(mark: -3, markCount: 5, railHeight: 100), 0)
    }

    func testRailHeightGrowsWithTheTurnCountButIsBoundedByThePane() {
        let spacing = ConversationMinimap.Metrics.markerSpacing

        XCTAssertEqual(ConversationMinimap.railHeight(turnCount: 5, paneHeight: 900), 4 * spacing)

        // A conversation of two hundred turns must not produce a rail taller than the window.
        let tall = ConversationMinimap.railHeight(turnCount: 200, paneHeight: 900)
        XCTAssertEqual(tall, 900 * ConversationMinimap.Metrics.maximumHeightFraction)
    }

    // MARK: - The Spacing Floor

    func testMarksNeverCrowdCloserThanAPointerCanSeparate() {
        // The defect this fixes. `railHeight` caps at a fraction of the pane while spacing was
        // that height divided by the turns, so every exchange past the cap packed the marks
        // tighter with no floor — at two hundred turns they were under three points apart and
        // the rail was answering a question no hand could ask. Swept rather than sampled,
        // because the previous version was correct at every count anyone had thought to try.
        let floor = ConversationMinimap.Metrics.minimumMarkerSpacing

        for paneHeight in stride(from: 400.0, through: 1400.0, by: 100.0) {
            for turnCount in [2, 5, 27, 28, 29, 60, 200, 1000, 2000] {
                let height = ConversationMinimap.railHeight(
                    turnCount: turnCount, paneHeight: paneHeight
                )
                let marks = ConversationMinimap.markCount(turnCount: turnCount, railHeight: height)
                guard marks > 1 else { continue }

                let first = ConversationMinimap.markerCenterY(
                    mark: 0, markCount: marks, railHeight: height
                )
                let second = ConversationMinimap.markerCenterY(
                    mark: 1, markCount: marks, railHeight: height
                )
                XCTAssertGreaterThanOrEqual(
                    second - first, floor,
                    "\(turnCount) turns in a \(Int(paneHeight))pt pane put marks \(second - first)pt apart"
                )
            }
        }
    }

    func testEveryTurnKeepsItsOwnMarkUntilTheFloorForbidsIt() {
        // Bucketing is a real loss, so it must not start early. Below the threshold the two
        // spaces are the same space and the maps are the identity.
        let height = ConversationMinimap.railHeight(turnCount: 20, paneHeight: 900)
        let marks = ConversationMinimap.markCount(turnCount: 20, railHeight: height)

        XCTAssertEqual(marks, 20)
        for turn in 0..<20 {
            XCTAssertEqual(
                ConversationMinimap.markIndex(forTurn: turn, markCount: marks, turnCount: 20), turn
            )
            XCTAssertEqual(
                ConversationMinimap.turnIndex(forMark: turn, markCount: marks, turnCount: 20), turn
            )
        }
    }

    func testABucketedRailStillReachesBothEndsAndNeverGoesBackwards() {
        // What a bucketed mark may not do: skip the conversation's first or last exchange, or
        // resolve out of order — either would make a click land somewhere the eye did not point.
        let turnCount = 500
        let height = ConversationMinimap.railHeight(turnCount: turnCount, paneHeight: 900)
        let marks = ConversationMinimap.markCount(turnCount: turnCount, railHeight: height)

        XCTAssertLessThan(marks, turnCount, "A 500-turn rail was not bucketed at all")

        let resolved = (0..<marks).map {
            ConversationMinimap.turnIndex(forMark: $0, markCount: marks, turnCount: turnCount)
        }
        XCTAssertEqual(resolved.first, 0, "The first mark did not stand for the first turn")
        XCTAssertEqual(resolved.last, turnCount - 1, "The last mark did not stand for the last turn")
        XCTAssertEqual(resolved, resolved.sorted(), "Marks resolved to turns out of order")
        XCTAssertTrue(
            resolved.allSatisfy { (0..<turnCount).contains($0) },
            "A mark resolved to a turn that does not exist"
        )
    }

    func testAPointerLandsOnTheMarkItWasDrawnAt() {
        // The round trip the preview card depends on: hovering a mark's own centre must resolve
        // to that mark, or the card describes one turn while a click lands on another.
        let turnCount = 500
        let height = ConversationMinimap.railHeight(turnCount: turnCount, paneHeight: 900)
        let marks = ConversationMinimap.markCount(turnCount: turnCount, railHeight: height)

        for mark in 0..<marks {
            let centre = ConversationMinimap.markerCenterY(
                mark: mark, markCount: marks, railHeight: height
            )
            XCTAssertEqual(
                ConversationMinimap.mark(atY: centre, markCount: marks, railHeight: height), mark,
                "Pointing at mark \(mark)'s own centre resolved elsewhere"
            )
        }
    }

    // MARK: - Pointer

    func testThePointerPicksTheNearestMark() {
        let height: CGFloat = 100

        XCTAssertEqual(ConversationMinimap.mark(atY: 0, markCount: 5, railHeight: height), 0)
        XCTAssertEqual(ConversationMinimap.mark(atY: 26, markCount: 5, railHeight: height), 1)
        XCTAssertEqual(ConversationMinimap.mark(atY: 51, markCount: 5, railHeight: height), 2)
        XCTAssertEqual(ConversationMinimap.mark(atY: 100, markCount: 5, railHeight: height), 4)
    }

    func testPointingPastTheRailClampsRatherThanReturningNothing() {
        // The hit area is taller than the rail — it spans the pane — so a pointer above the
        // first mark or below the last should still resolve, to the end it is nearest.
        XCTAssertEqual(ConversationMinimap.mark(atY: -500, markCount: 5, railHeight: 100), 0)
        XCTAssertEqual(ConversationMinimap.mark(atY: 900, markCount: 5, railHeight: 100), 4)
    }

    func testPointingAtAnEmptyRailResolvesToNothing() {
        XCTAssertNil(ConversationMinimap.mark(atY: 10, markCount: 0, railHeight: 100))
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

    func testTheTunedWidthsSurviveAtWholeMarks() {
        // The stops are the design and the interpolation is only smoothness, so the smooth form
        // must agree with the sampled one everywhere the sampled one had an opinion. If this
        // fails the rail has been retuned by accident rather than on purpose.
        typealias Metrics = ConversationMinimap.Metrics

        XCTAssertEqual(ConversationMinimap.markerWidth(distance: 0), Metrics.activeMarkerWidth)
        XCTAssertEqual(ConversationMinimap.markerWidth(distance: 1), Metrics.neighbourMarkerWidths[0])
        XCTAssertEqual(ConversationMinimap.markerWidth(distance: 2), Metrics.neighbourMarkerWidths[1])
        XCTAssertEqual(ConversationMinimap.markerWidth(distance: 3), Metrics.restingMarkerWidth)
        XCTAssertEqual(ConversationMinimap.markerWidth(distance: 40), Metrics.restingMarkerWidth)
    }

    func testTheTaperFollowsThePointerRatherThanTheMarkItIsNearest() {
        // The bug this fixes, and the reason the rail felt stepped: widths were sampled at the
        // *nearest* mark, so the pointer could travel most of the way between two marks with
        // nothing moving, and then every mark in the taper changed width in a single frame as
        // it crossed the midpoint. Swept across the whole rail, no step may exceed a point.
        let turnCount = 12
        let height = ConversationMinimap.railHeight(turnCount: turnCount, paneHeight: 900)
        let marks = ConversationMinimap.markCount(turnCount: turnCount, railHeight: height)
        var previous = (0..<marks).map {
            ConversationMinimap.markerWidth(mark: $0, pointerY: 0, markCount: marks, railHeight: height)
        }

        for step in stride(from: 0.5, through: height, by: 0.5) {
            let widths = (0..<marks).map {
                ConversationMinimap.markerWidth(
                    mark: $0, pointerY: step, markCount: marks, railHeight: height
                )
            }
            for index in widths.indices {
                XCTAssertLessThan(
                    abs(widths[index] - previous[index]), 1,
                    "Mark \(index) jumped as the pointer passed \(step)pt"
                )
            }
            previous = widths
        }
    }

    func testTheTaperIsMeasuredInMarksSoItKeepsItsShapeWhenTheyBunch() {
        // Past its cap the rail packs its marks closer than `markerSpacing`. A taper measured in
        // *points* would then reach across a third of the rail and stop picking anything out;
        // measured in marks it covers the same three either side at every density.
        let sparse = ConversationMinimap.railHeight(turnCount: 5, paneHeight: 900)
        let packed = ConversationMinimap.railHeight(turnCount: 200, paneHeight: 900)

        let sparseMarks = ConversationMinimap.markCount(turnCount: 5, railHeight: sparse)
        let packedMarks = ConversationMinimap.markCount(turnCount: 200, railHeight: packed)

        let sparseNeighbour = ConversationMinimap.markerDistance(
            mark: 1,
            pointerY: ConversationMinimap.markerCenterY(
                mark: 0, markCount: sparseMarks, railHeight: sparse
            ),
            markCount: sparseMarks,
            railHeight: sparse
        )
        let packedNeighbour = ConversationMinimap.markerDistance(
            mark: 1,
            pointerY: ConversationMinimap.markerCenterY(
                mark: 0, markCount: packedMarks, railHeight: packed
            ),
            markCount: packedMarks,
            railHeight: packed
        )

        XCTAssertEqual(sparseNeighbour, 1, accuracy: 0.0001)
        XCTAssertEqual(packedNeighbour, 1, accuracy: 0.0001, "The taper widened when the marks bunched")
    }

    func testColourAndWidthAgreeAboutWhereThePointerIs() {
        // Three hard colour buckets under a smooth taper read as a rendering fault: the widths
        // flowed and the tones snapped, on the same marks in the same frame. Emphasis rides the
        // same curve, so it peaks under the pointer and is spent at the edge of the taper.
        let outermost = CGFloat(ConversationMinimap.Metrics.markerWidthProfile.count - 1)

        XCTAssertEqual(ConversationMinimap.markerEmphasis(distance: 0), 1)
        XCTAssertEqual(ConversationMinimap.markerEmphasis(distance: outermost), 0)
        XCTAssertEqual(ConversationMinimap.markerEmphasis(distance: outermost + 5), 0)

        var previous = ConversationMinimap.markerEmphasis(distance: 0)
        for step in stride(from: 0.1, through: outermost, by: 0.1) {
            let emphasis = ConversationMinimap.markerEmphasis(distance: step)
            XCTAssertLessThanOrEqual(emphasis, previous + 0.0001, "Emphasis rose as the pointer moved away")
            previous = emphasis
        }
    }

    // MARK: - Preview Placement

    /// The card the rail hangs beside a mark, and the two ways it went wrong at once.
    ///
    /// Shipped, this drew an **empty** translucent panel in the pane's bottom-left corner,
    /// underneath the composer — see the composer redesign. Both causes are asserted here
    /// because either alone puts it back: it was attached visible with no mark to describe,
    /// and it was positioned by an assigned frame while Auto Layout owned its geometry, so the
    /// next layout pass resolved the position it had never been given as the origin.
    @MainActor
    func testTheTurnPreviewStaysHiddenUntilAMarkIsPointedAtAndHoldsItsPlaceThrough() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container

        let rail = ConversationMinimapView(frame: NSRect(x: 0, y: 0, width: 24, height: 600))
        container.addSubview(rail)
        rail.setTurns((1...8).map {
            ConversationTimeline.Turn(
                rowIndex: $0,
                endIndex: $0,
                finalAssistantIndex: $0,
                userText: "Question \($0)",
                assistantText: "Answer \($0)",
                duration: nil
            )
        })
        rail.attachPreview(to: container)
        container.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(
            container.subviews.first { $0 is ConversationTurnPreview },
            "The rail attached no preview at all"
        )
        XCTAssertTrue(
            card.isHidden,
            "An unpointed rail left its preview on screen, describing nothing"
        )

        rail.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: rail.convert(NSPoint(x: rail.bounds.midX, y: 300), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )))
        container.layoutSubtreeIfNeeded()

        XCTAssertFalse(card.isHidden, "Pointing at a mark showed no preview")
        let placed = card.frame
        XCTAssertGreaterThan(placed.minX, rail.frame.maxX, "The card covered the rail it hangs off")

        // The pass that used to lose it. Nothing about the pointer changed, so nothing about
        // the card may either.
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.frame, placed, "A layout pass moved the card out from under the pointer")
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
            .assistantMessage(blocks: [.toolUse(id: "1", tool: .bash, input: ["command": "swift test"])]),
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
