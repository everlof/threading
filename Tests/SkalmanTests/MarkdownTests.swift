import XCTest
@testable import Skalman

/// The reader table that turns an agent's reply into blocks.
///
/// `Markdown` is a hand-written CommonMark subset, and its correctness is mostly *precedence*:
/// each reader either consumes its block or returns nil for the next one to try, and the order
/// they sit in decides what a line means. Two of those orderings are load-bearing — fenced code
/// is read first and verbatim, so a `*` in a shell glob is never emphasis, and a quote is read
/// before a list, so `> - item` is a quote rather than a bullet inside one.
@MainActor
final class MarkdownTests: XCTestCase {

    private let style = MarkdownStyle.assistant

    private func blocks(_ text: String) -> [MarkdownBlock] {
        Markdown.parse(text, style: style)
    }

    private func text(of block: MarkdownBlock?) -> String {
        switch block {
        case .paragraph(let value), .heading(let value), .quote(let value):
            return value.string
        case .code(let value):
            return value
        case .bullets(let items), .ordered(let items):
            return items.map(\.string).joined(separator: "\n")
        case nil:
            return ""
        }
    }

    private func isCode(_ block: MarkdownBlock?) -> Bool {
        if case .code = block { return true }
        return false
    }

    // MARK: - Precedence

    /// The ordering that matters most. Inside a fence the text is content, not syntax: a shell
    /// glob is full of characters that are emphasis anywhere else, and an agent's reply is
    /// mostly commands.
    func testAFenceIsVerbatimAndNotStyled() {
        let parsed = blocks("""
        ```
        rm *.log && echo _done_
        ```
        """)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(isCode(parsed.first), "a fenced block was read as prose")
        XCTAssertEqual(text(of: parsed.first), "rm *.log && echo _done_")
    }

    /// A heading inside a fence is code. If the fence reader did not run first, every `#` in a
    /// shell script would become a heading.
    func testAHashInsideAFenceIsNotAHeading() {
        let parsed = blocks("""
        ```sh
        # not a heading
        ls
        ```
        """)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(text(of: parsed.first), "# not a heading\nls")
    }

    /// Quote reads before list, so this is one quote — not a bullet that happens to be quoted.
    func testAQuotedBulletIsAQuote() {
        let parsed = blocks("> - item")

        guard case .quote = parsed.first else {
            return XCTFail("a quoted bullet was read as a list")
        }
    }

    // MARK: - Blocks

    func testHeadingsBulletsOrderedListsAndParagraphs() {
        let parsed = blocks("""
        # Title

        Some prose.

        - one
        - two

        1. first
        2. second
        """)

        guard parsed.count == 4 else {
            return XCTFail("expected four blocks, got \(parsed.count)")
        }

        guard case .heading = parsed[0] else { return XCTFail("no heading") }
        guard case .paragraph = parsed[1] else { return XCTFail("no paragraph") }
        guard case .bullets(let bullets) = parsed[2] else { return XCTFail("no bullets") }
        guard case .ordered(let ordered) = parsed[3] else { return XCTFail("no ordered list") }

        XCTAssertEqual(bullets.map(\.string), ["one", "two"])
        XCTAssertEqual(ordered.map(\.string), ["first", "second"])
        XCTAssertEqual(text(of: parsed[0]), "Title")
    }

    /// Blank lines separate blocks and are not blocks themselves — an agent's reply is full of
    /// them, and a parser that emitted one per gap would draw a column of empty rows.
    func testBlankLinesProduceNoBlocks() {
        XCTAssertTrue(blocks("\n\n   \n\n").isEmpty)
        XCTAssertEqual(blocks("\n\nonly\n\n").count, 1)
    }

    /// Consecutive prose lines are one paragraph of *flowing* text, joined with a space rather
    /// than keeping the author's line breaks. A reply hard-wrapped at some width would otherwise
    /// arrive as a stack of one-line blocks, or keep breaks at a width the pane does not have.
    func testConsecutiveLinesBecomeOneFlowingParagraph() {
        let parsed = blocks("first line\nsecond line")

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(text(of: parsed.first), "first line second line")
    }

    // MARK: - Inline

    /// Emphasis and code spans are removed from the *text* — they are style, not content — so
    /// the string a screen reader or a copy carries is what was written, not the markup.
    func testInlineMarkupBecomesStyleRatherThanText() {
        XCTAssertEqual(text(of: blocks("**bold** and `code`").first), "bold and code")
        XCTAssertEqual(text(of: blocks("*italic* too").first), "italic too")
    }

    /// An unterminated fence still ends: it takes the rest of the document rather than looping
    /// or dropping everything after it. Agents produce these constantly by being cut off.
    func testAnUnterminatedFenceEndsAtTheDocument() {
        let parsed = blocks("""
        ```
        cut off here
        """)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(isCode(parsed.first))
        XCTAssertEqual(text(of: parsed.first), "cut off here")
    }
}
