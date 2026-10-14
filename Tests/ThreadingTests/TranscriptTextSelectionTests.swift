import AppKit
import XCTest
@testable import Threading

/// Text selection that runs across a native transcript's rows and blocks.
///
/// Every paragraph, heading, list item, code block and table cell is its own label, and AppKit
/// lets one label hold a selection at a time — so a drag stopped at the edge of the block it
/// began in, reported as "I can't select between sections". These tests drive the transcript's
/// own selection through the shipping conversation pane and read back both what is painted and
/// what would be copied.
@MainActor
final class TranscriptTextSelectionTests: XCTestCase {

    // MARK: - Range

    func testARangeCoversWholeMiddleSegmentsAndTheChosenPartsOfItsEnds() {
        let range = TranscriptTextRange(
            anchor: TranscriptTextPosition(item: 3, segment: 1, offset: 4),
            focus: TranscriptTextPosition(item: 1, segment: 2, offset: 5)
        )

        XCTAssertEqual(range.start, TranscriptTextPosition(item: 1, segment: 2, offset: 5))
        XCTAssertEqual(range.range(inItem: 1, segment: 2, length: 10), NSRange(location: 5, length: 5))
        XCTAssertNil(range.range(inItem: 1, segment: 1, length: 10), "a segment before the start")
        XCTAssertEqual(range.range(inItem: 2, segment: 7, length: 3), NSRange(location: 0, length: 3))
        XCTAssertEqual(range.range(inItem: 3, segment: 1, length: 10), NSRange(location: 0, length: 4))
        XCTAssertNil(range.range(inItem: 3, segment: 2, length: 10), "a segment after the end")
        XCTAssertNil(range.range(inItem: 4, segment: 0, length: 10))
    }

    func testAWholeItemIsKnownWithoutItsSegments() {
        let all = TranscriptTextRange(anchor: .start(ofItem: 0), focus: .end(ofItem: 5))
        XCTAssertTrue(all.coversWhole(item: 0))
        XCTAssertTrue(all.coversWhole(item: 5))

        let partial = TranscriptTextRange(
            anchor: TranscriptTextPosition(item: 1, segment: 0, offset: 3),
            focus: TranscriptTextPosition(item: 4, segment: 1, offset: 2)
        )
        XCTAssertFalse(partial.coversWhole(item: 1), "begins three characters in")
        XCTAssertTrue(partial.coversWhole(item: 2))
        XCTAssertFalse(partial.coversWhole(item: 4), "ends inside its second segment")
    }

    // MARK: - Segments

    func testOnlyMarkedProseIsTranscriptTextAndNeverAControlsTitle() {
        let host = NSView()
        let prose = NSTextField(labelWithString: "An answer.")
        prose.identifier = .transcriptText
        let plain = NSTextField(labelWithString: "Ran swift test")
        let button = ThemedButton(title: "Copy", target: nil, action: nil)
        let titled = NSTextField(labelWithString: "Inside a control")
        titled.identifier = .transcriptText
        button.addSubview(titled)
        for view in [prose, plain, button] { host.addSubview(view) }

        XCTAssertTrue(TranscriptTextSegments.isText(prose, within: host))
        XCTAssertFalse(TranscriptTextSegments.isText(plain, within: host), "an unmarked label is chrome")
        XCTAssertFalse(
            TranscriptTextSegments.isText(titled, within: host),
            "a press on a control's own text belongs to the control"
        )
    }

    // MARK: - Selecting Across Blocks

    func testADragFromTheHeadingToTheLastParagraphTakesEveryBlockBetween() throws {
        let (controller, host) = NativeChatShowcaseTests.fixture(.answer)
        Self.draw(host)
        let table = controller.transcript
        let heading = try XCTUnwrap(segment(containing: "A calmer chat", in: table))
        let closing = try XCTUnwrap(segment(containing: "for the source research", in: table))

        table.textSelection.select(
            fromTablePoint: NSPoint(x: heading.frame.minX + 1, y: heading.frame.midY),
            to: NSPoint(x: closing.frame.maxX - 1, y: closing.frame.midY)
        )
        let text = try XCTUnwrap(table.textSelection.selectedText())

        XCTAssertTrue(text.hasPrefix("A calmer chat\n\nThe transcript keeps"), text)
        XCTAssertTrue(text.contains("Component\tBehavior"), "table cells copy as a tab-separated row")
        XCTAssertTrue(text.contains("func greeting(for name: String) -> String {"), "the code block")
        XCTAssertTrue(text.hasSuffix("for the source research."), text)
    }

    func testASelectionRunsFromTheUsersMessageIntoTheAnswer() throws {
        let (controller, host) = NativeChatShowcaseTests.fixture(.answer)
        Self.draw(host)
        let table = controller.transcript
        let request = try XCTUnwrap(segment(containing: "Polish the greeting", in: table))
        let heading = try XCTUnwrap(segment(containing: "A calmer chat", in: table))

        table.textSelection.select(
            fromTablePoint: NSPoint(x: request.frame.minX + 1, y: request.frame.midY),
            to: NSPoint(x: heading.frame.maxX - 1, y: heading.frame.midY)
        )

        let text = try XCTUnwrap(table.textSelection.selectedText())
        XCTAssertTrue(text.hasPrefix("Polish the greeting"), text)
        XCTAssertTrue(text.hasSuffix("A calmer chat"), text)
        XCTAssertFalse(text.contains("Worked for"), "the work fold is not what was said")
    }

    func testTheHighlightIsPaintedIntoEachLabelAndGivenBack() throws {
        let (controller, host) = NativeChatShowcaseTests.fixture(.answer)
        Self.draw(host)
        let table = controller.transcript
        let heading = try XCTUnwrap(segment(containing: "A calmer chat", in: table))
        let paragraph = try XCTUnwrap(segment(containing: "The transcript keeps", in: table))
        let original = heading.field.attributedStringValue

        table.textSelection.select(
            fromTablePoint: NSPoint(x: heading.frame.minX + 1, y: heading.frame.midY),
            to: NSPoint(x: paragraph.frame.maxX - 1, y: paragraph.frame.maxY - 1)
        )
        XCTAssertNotNil(
            heading.field.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil),
            "the heading inside the selection is not highlighted"
        )
        XCTAssertNotNil(
            paragraph.field.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil),
            "the paragraph inside the selection is not highlighted"
        )

        // A click that is not a drag lets go, the way a page does.
        table.textSelection.clear()
        XCTAssertNil(table.textSelection.range)
        XCTAssertTrue(heading.field.attributedStringValue.isEqual(to: original), "the label kept the highlight")
        XCTAssertFalse(table.tableView.canCopy?() ?? true, "nothing chosen, nothing to copy")
    }

    func testSelectAllCopiesRowsThatAreNotOnScreen() throws {
        // Short enough that most of the conversation has no views at all.
        let (controller, host) = NativeChatShowcaseTests.fixture(.answer, width: 900, height: 160)
        let table = controller.transcript
        table.tableView.scroll(.zero)
        Self.draw(host)
        XCTAssertNil(
            table.materializedHost(ofItem: table.selectableItemCount - 1),
            "the fixture should leave the end of the conversation without views"
        )

        XCTAssertEqual(table.tableView.onSelectAll?(), true)
        let text = try XCTUnwrap(table.textSelection.selectedText())

        XCTAssertTrue(text.hasPrefix("Polish the greeting"), text)
        XCTAssertTrue(text.contains("A calmer chat"))
        XCTAssertTrue(text.hasSuffix("for the source research."), text)
        XCTAssertTrue(table.tableView.canCopy?() ?? false)
    }

    func testChangingRowsUnderTheSelectionLetsItGo() throws {
        let (controller, host) = NativeChatShowcaseTests.fixture(.answer)
        Self.draw(host)
        let selection = controller.transcript.textSelection
        selection.selectAll()
        XCTAssertNotNil(selection.range)

        selection.itemsChanged(from: controller.transcript.selectableItemCount)
        XCTAssertNotNil(selection.range, "an append past the end leaves the selection alone")

        selection.itemsChanged(from: 0)
        XCTAssertNil(selection.range, "rows moved under the selection's numbers")
    }

    // MARK: - Helpers

    /// Drawing is what makes an unshown table ask for the cells it would show.
    private static func draw(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        host.layoutSubtreeIfNeeded()
    }

    private struct Found {
        let field: NSTextField
        /// In the table's coordinates.
        let frame: NSRect
    }

    private func segment(
        containing text: String,
        in table: ConversationTranscriptTable<ConversationViewController>
    ) -> Found? {
        for item in 0..<table.selectableItemCount {
            guard let host = table.materializedHost(ofItem: item) else { continue }
            host.layoutSubtreeIfNeeded()
            let segments = TranscriptTextSegments.collect(in: host, relativeTo: table.tableView)
            if let match = segments.first(where: { $0.field.stringValue.contains(text) }) {
                return Found(field: match.field, frame: match.frame)
            }
        }
        return nil
    }
}
