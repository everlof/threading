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
        XCTAssertEqual(Rhythm.gap(between: .work, and: .work), Design.Spacing.tight)
        XCTAssertEqual(Rhythm.gap(between: .work, and: .answer), Design.Spacing.small)
        XCTAssertEqual(Rhythm.gap(between: .answer, and: .work), Design.Spacing.small)
        XCTAssertEqual(Rhythm.gap(between: .answer, and: .boundary), Design.Chat.turnSpacing)
        XCTAssertEqual(Rhythm.gap(between: .boundary, and: .exchange), Design.Spacing.small)
        XCTAssertEqual(Rhythm.gap(between: .seam, and: .exchange), Design.Chat.turnSpacing)
        XCTAssertEqual(
            Rhythm.gap(between: .answer, and: .answer),
            Design.Chat.blockSpacing,
            "an answer split into rows keeps the document's block spacing"
        )
        XCTAssertEqual(
            MarkdownDefaults.blockSpacing,
            Design.Chat.blockSpacing,
            "a document's blocks and a split answer are spaced by one token"
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
            case .assistant:
                XCTAssertEqual(rhythm, .answer)
                seen.insert("answer")
            case .thinking, .toolCall:
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
            Design.Spacing.medium,      // bubble → thinking: the bubble's own step, not the work's
            Design.Spacing.tight,       // thinking → the tool fold: work against work
            Design.Spacing.small,       // fold → the answer's first block
            Design.Chat.blockSpacing,   // block → block of one answer
            Design.Spacing.small,       // block → a lone tool call
            Design.Spacing.small        // tool call → the final answer
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
}
