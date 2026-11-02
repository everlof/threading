import AppKit
import XCTest
@testable import Threading

/// The transcript's vertical rhythm is a property of each row kind, composed by one rule in
/// `ConversationTranscriptTable`. These pin the rule, the declarations, and the gaps the table
/// actually lays out, so a wrong gap fails here rather than being noticed in a screenshot.
@MainActor
final class ConversationRhythmTests: XCTestCase {
    private typealias Rhythm = Design.Chat.Rhythm

    func testNeighboursCollapseToTheLargerFacingMargin() {
        XCTAssertEqual(
            Rhythm.gap(between: .exchange, and: .work),
            Design.Spacing.medium,
            "a bubble keeps its own step before the work that answers it"
        )
        XCTAssertEqual(Rhythm.gap(between: .work, and: .work), Design.Spacing.hairline)
        XCTAssertEqual(
            Rhythm.gap(between: .answer, and: .work),
            Design.Spacing.tight,
            "a sentence stands close to the calls it announced"
        )
        XCTAssertEqual(
            Rhythm.gap(between: .work, and: .answer),
            Design.Chat.stepSpacing,
            "and the space belongs between one step and the next"
        )
        XCTAssertEqual(Rhythm.gap(between: .answer, and: .boundary), Design.Chat.turnSpacing)
        XCTAssertEqual(Rhythm.gap(between: .boundary, and: .exchange), Design.Spacing.medium)
        XCTAssertEqual(Rhythm.gap(between: .seam, and: .exchange), Design.Chat.turnSpacing)
        XCTAssertEqual(
            Rhythm.gap(between: .answer, and: .answerBlock),
            Design.Chat.blockSpacing,
            "an answer split into rows keeps the document's block spacing"
        )
        XCTAssertEqual(
            MarkdownDefaults.blockSpacing,
            Design.Chat.blockSpacing,
            "a document's blocks and a split answer are spaced by one token"
        )
        XCTAssertEqual(
            Rhythm.gap(between: .answer, and: .heading),
            Design.Chat.headingLeading,
            "a heading stands clear of the paragraph before it"
        )
        XCTAssertEqual(
            Rhythm.gap(between: .heading, and: .answerBlock),
            Design.Chat.blockSpacing,
            "and asks nothing extra of the section beneath it"
        )
        XCTAssertGreaterThan(
            Design.Chat.blockSpacing,
            Design.Chat.lineSpacing(
                for: Design.Typography.reading(),
                multiple: Design.Chat.readingLineHeight
            ),
            "paragraphs must stand further apart than the lines inside one"
        )
    }

    func testEveryRowKindDeclaresItsRhythm() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        let events: [StreamEvent] = [
            .userMessage("Audit the retained-parent capacity regression."),
            .assistantMessage(blocks: [
                .thinking("I should inspect the admission path first."),
                .toolUse(id: "tool-1", tool: .bash, input: ["command": "swift test"]),
                .text("The focused regression now passes.")
            ]),
            .turnFinished(text: nil, outcome: .stopped, metrics: .empty)
        ]
        for event in events { _ = timeline.apply(event) }
        _ = timeline.appendNotice("Transcript truncated.", kind: .muted)

        var seen: Set<String> = []
        for row in timeline.rows {
            let rhythm = ConversationRowView.rhythm(for: row)
            switch row {
            case .userMessage:
                XCTAssertEqual(rhythm, .exchange)
                seen.insert("exchange")
            case .assistant, .thinking:
                XCTAssertEqual(rhythm, .answer, "a thought and a sentence open a step alike")
                seen.insert("answer")
            case .toolCall:
                XCTAssertEqual(rhythm, .work)
                seen.insert("work")
            case .turnOutcome, .notice:
                XCTAssertEqual(rhythm, .chrome)
                seen.insert("chrome")
            }
        }
        XCTAssertEqual(seen, ["exchange", "answer", "work", "chrome"])
    }

    /// The child pane, because it is the narrow one and the one whose bubble sat four points
    /// above the thinking beneath it while standing a turn's step under the heading.
    func testTheChildTranscriptLaysOutTheDeclaredGaps() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        let threadID = "child-rhythm"
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: threadID,
            nickname: "Rhythm child",
            prompt: "Audit the retained-parent capacity regression."
        )))
        timeline.apply(.state(threadID: threadID, status: .working, message: "Working"))
        let events: [StreamEvent] = [
            .userMessage("Audit the retained-parent capacity regression."),
            .assistantMessage(blocks: [
                .thinking("I should inspect the admission path first."),
                .toolUse(
                    id: "tool-1",
                    tool: .bash,
                    input: ["command": "swift test --filter CapacityRegression"]
                ),
                .toolUse(
                    id: "tool-2",
                    tool: .read,
                    input: ["path": "Sources/Threading/Core/Agent/ConversationTimeline.swift"]
                ),
                .text("The focused regression now passes.\n\nA second paragraph is a second block."),
                .toolUse(id: "tool-3", tool: .bash, input: ["command": "scripts/test.sh fast"]),
                .text("The final validation passes.")
            ])
        ]
        for event in events {
            timeline.apply(.conversation(threadID: threadID, event: event))
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 720))
        let controller = SubagentTranscriptViewController()
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]
        host.addSubview(controller.view)
        controller.update(timeline, selectedThreadID: threadID)
        host.layoutSubtreeIfNeeded()

        let transcript = controller.transcript
        let table = controller.transcriptTableView
        XCTAssertEqual(
            transcript.items.count,
            9,
            "navigator, heading, bubble, thinking, a two-call fold, two answer blocks, a lone call, "
                + "the final answer"
        )

        let expected: [CGFloat] = [
            Design.Spacing.small,       // navigator → heading: chrome meets the seam
            Design.Chat.turnSpacing,    // heading → the bubble: the transcript opens under the seam
            Design.Chat.stepSpacing,    // bubble → thinking: a thought opens a step
            Design.Spacing.tight,       // thinking → the tool fold: a step and its own calls
            Design.Chat.stepSpacing,    // fold → the answer's first block: the next step
            Design.Chat.blockSpacing,   // block → block of one answer
            Design.Spacing.tight,       // block → a lone tool call: its own call
            Design.Chat.stepSpacing     // tool call → the final answer
        ]
        XCTAssertEqual(
            (1..<transcript.items.count).map { transcript.gap(above: $0) },
            expected
        )

        // What the table lays out is what the tokens say, and no row view adds an outer margin
        // of its own; a view that did would show up here as a gap the rule never composed.
        var contents: [NSView] = []
        for row in 0..<table.numberOfRows {
            let hostView = try XCTUnwrap(
                table.view(atColumn: 0, row: row, makeIfNecessary: true),
                "row \(row) was not materialized"
            )
            contents.append(try XCTUnwrap(hostView.subviews.first, "row \(row) holds no content"))
        }
        host.layoutSubtreeIfNeeded()
        for row in 1..<contents.count {
            let upper = table.convert(contents[row - 1].bounds, from: contents[row - 1])
            let lower = table.convert(contents[row].bounds, from: contents[row])
            XCTAssertEqual(
                lower.minY - upper.maxY,
                expected[row - 1],
                accuracy: 0.5,
                "the gap above row \(row) is not the composed rhythm"
            )
        }
    }

    /// The fault the rhythm was rebuilt to remove: every assistant row wore an invisible action
    /// line, so the gap under a sentence measured 24 points more than the same gap under a thought
    /// and the page stepped between loose and tight for no reason a reader could see.
    func testAnAgentMessageReservesNoLineForItsActions() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let message = ConversationMessageContextView(content: content, speaker: .agent)
        message.widthAnchor.constraint(equalToConstant: 400).isActive = true
        XCTAssertEqual(message.fittingSize.height, 40, accuracy: 0.5)
    }

    func testAUserMessagesActionsStandBesideItsBubble() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let message = ConversationMessageContextView(
            content: ConversationRowView.userBubble("A short instruction"),
            speaker: .user
        )
        host.addSubview(message)
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: host.topAnchor),
            message.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            message.widthAnchor.constraint(equalToConstant: 600)
        ])
        host.layoutSubtreeIfNeeded()

        let plate = try XCTUnwrap(message.subviews.first { $0 is ConversationMessageActionPlate })
        let row = try XCTUnwrap(descendant(ConversationUserRowView.self, in: message))
        let bubble = row.bubble.convert(row.bubble.bounds, to: message)
        XCTAssertLessThanOrEqual(plate.frame.maxX, bubble.minX, "the actions cover the bubble")
        XCTAssertGreaterThanOrEqual(plate.frame.minX, 0, "the actions left the row")
    }

    func testAnUndrawnActionPlateDoesNotTakeAPressFromTheWordsBeneathIt() {
        let plate = ConversationMessageActionPlate(actions: NSView())
        plate.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        XCTAssertNil(plate.hitTest(NSPoint(x: 10, y: 10)))
        plate.alphaValue = 1
        XCTAssertNotNil(plate.hitTest(NSPoint(x: 10, y: 10)))
    }

    /// The fill is one colour flattened against the ground, so nothing resolves it again by itself:
    /// without its own observers a plate kept the ground and theme it was built under.
    func testAnActionPlateIsMeasuredAgainWhenItsGroundOrThemeMoves() throws {
        let previousTheme = AppThemePalette.current
        let previousBackdrop = WindowBackdrop.ground
        defer {
            AppThemePalette.set(previousTheme)
            WindowBackdrop.set(previousBackdrop)
        }
        // System's panel is translucent, so this is the theme where the ground decides the fill.
        AppThemePalette.set(.system)
        WindowBackdrop.set(.terminal(.black))
        let plate = ConversationMessageActionPlate(actions: NSView())
        let onBlack = try XCTUnwrap(plate.layer?.backgroundColor)

        WindowBackdrop.set(.terminal(.white))
        let onWhite = try XCTUnwrap(plate.layer?.backgroundColor)
        XCTAssertNotEqual(onWhite, onBlack, "the plate kept the previous ground")
        XCTAssertEqual(onWhite.alpha, 1, accuracy: 0.001, "the words beneath would show through")

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))
        XCTAssertNotEqual(plate.layer?.backgroundColor, onWhite, "the plate kept the previous theme")
    }

    /// Quiet to the eye only: the plate rests at zero alpha, and VoiceOver still reaches its actions.
    func testActionsAtRestStayReachableByVoiceOver() throws {
        let message = ConversationMessageContextView(content: NSView(), speaker: .agent)
        message.copyText = "A reply"
        let plate = try XCTUnwrap(message.subviews.first { $0 is ConversationMessageActionPlate })
        let action = try XCTUnwrap(descendant(ThemedIconButton.self, in: plate))

        XCTAssertEqual(plate.alphaValue, 0)
        XCTAssertFalse(action.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(action.accessibilityRole(), .button)
        XCTAssertFalse(try XCTUnwrap(action.accessibilityTitle()).isEmpty)
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}
