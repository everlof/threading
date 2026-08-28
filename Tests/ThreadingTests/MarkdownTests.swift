import XCTest
@testable import Threading

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
        case .table(let table):
            return (table.headers + table.rows.flatMap { $0 })
                .map(\.string)
                .joined(separator: "\n")
        case nil:
            return ""
        }
    }

    private func isCode(_ block: MarkdownBlock?) -> Bool {
        if case .code = block { return true }
        return false
    }

    private func kind(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph: "paragraph"
        case .heading: "heading"
        case .bullets: "bullets"
        case .ordered: "ordered"
        case .code: "code"
        case .quote: "quote"
        case .table: "table"
        }
    }

    private func paragraph(_ text: String) -> NSAttributedString {
        guard case .paragraph(let value) = blocks(text).first else {
            XCTFail("inline fixture did not produce a paragraph")
            return NSAttributedString()
        }
        return value
    }

    private func fontTraits(
        in value: NSAttributedString,
        matching text: String
    ) throws -> NSFontTraitMask {
        let range = try attributedRange(in: value, matching: text)
        let font = try XCTUnwrap(
            value.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        )
        return NSFontManager.shared.traits(of: font)
    }

    private func attributedRange(
        in value: NSAttributedString,
        matching text: String
    ) throws -> NSRange {
        let range = (value.string as NSString).range(of: text)
        return try XCTUnwrap(
            range.location == NSNotFound ? nil : range,
            "missing inline fixture text: \(text)"
        )
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

    func testGFMTableKeepsColumnsRowsAlignmentAndInlineCode() {
        let parsed = blocks("""
        | Name | Command | Result |
        | :--- | :-----: | -----: |
        | Audit | `rg "NSAlert"` | **44 sites** |
        | Escaped | left \\| right | Done |
        """)

        guard parsed.count == 1, case .table(let table) = parsed[0] else {
            return XCTFail("a valid GFM table was flattened into prose")
        }
        XCTAssertEqual(table.headers.map(\.string), ["Name", "Command", "Result"])
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows.map { $0.map(\.string) }, [
            ["Audit", "rg \"NSAlert\"", "44 sites"],
            ["Escaped", "left | right", "Done"]
        ])
    }

    func testPipesWithoutADelimiterRemainProse() {
        let parsed = blocks("This | remains prose\nbecause | this is not a delimiter")

        XCTAssertEqual(parsed.count, 1)
        guard case .paragraph = parsed[0] else {
            return XCTFail("ordinary pipe-delimited prose became a table")
        }
    }

    // MARK: - Inline

    /// Emphasis and code spans are removed from the *text* — they are style, not content — so
    /// the string a screen reader or a copy carries is what was written, not the markup.
    func testInlineMarkupBecomesStyleRatherThanText() {
        XCTAssertEqual(text(of: blocks("**bold** and `code`").first), "bold and code")
        XCTAssertEqual(text(of: blocks("*italic* too").first), "italic too")
    }

    /// Delimiters face content before they become syntax. Coding prose is dense with identifiers,
    /// multiplication and globs; none may borrow a later marker and style everything between.
    func testEmphasisUsesFlankingRulesAroundIdentifiersAndArithmetic() throws {
        let attributed = paragraph(
            "call process_arguments then max_retries; 2 * 3 * 4; *styled* and _also_"
        )

        XCTAssertEqual(
            attributed.string,
            "call process_arguments then max_retries; 2 * 3 * 4; styled and also"
        )
        XCTAssertFalse(
            try fontTraits(in: attributed, matching: "process_arguments")
                .contains(.italicFontMask)
        )
        XCTAssertFalse(
            try fontTraits(in: attributed, matching: "3")
                .contains(.italicFontMask)
        )
        XCTAssertTrue(
            try fontTraits(in: attributed, matching: "styled")
                .contains(.italicFontMask)
        )
        XCTAssertTrue(
            try fontTraits(in: attributed, matching: "also")
                .contains(.italicFontMask)
        )

        let transcript = paragraph(
            "Not shoal_ar — **MES dale_gorse tide** — then copse_br"
        )
        XCTAssertEqual(
            transcript.string,
            "Not shoal_ar — MES dale_gorse tide — then copse_br"
        )
        XCTAssertFalse(
            try fontTraits(in: transcript, matching: "shoal_ar").contains(.italicFontMask)
        )
        XCTAssertTrue(
            try fontTraits(in: transcript, matching: "dale_gorse").contains(.boldFontMask)
        )
    }

    /// Strong and emphasis are containers, not terminal text tokens. Their children keep live
    /// links and code styling while inheriting the outer font traits.
    func testInlineContainersRecurseAndMergeTheirTraits() throws {
        let link = paragraph("**[PR 12](https://example.com/pull/12)** shipped")
        XCTAssertEqual(link.string, "PR 12 shipped")
        let linkRange = try attributedRange(in: link, matching: "PR 12")
        XCTAssertEqual(
            link.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.com/pull/12")
        )
        XCTAssertTrue(
            try fontTraits(in: link, matching: "PR 12").contains(.boldFontMask)
        )
        let refused = paragraph("**[local](file:///Users/person/private)**")
        let refusedRange = try attributedRange(in: refused, matching: "local")
        XCTAssertNil(
            refused.attribute(.link, at: refusedRange.location, effectiveRange: nil),
            "nesting bypassed the Markdown URL-scheme policy"
        )

        let code = paragraph("*italic with `file_name.py` inside*")
        XCTAssertEqual(code.string, "italic with file_name.py inside")
        let codeRange = try attributedRange(in: code, matching: "file_name.py")
        XCTAssertEqual(
            code.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil)
                as? NSColor,
            style.codeBackground
        )
        XCTAssertTrue(
            try fontTraits(in: code, matching: "file_name.py").contains(.italicFontMask)
        )

        let nested = paragraph("**bold with *italic* inside**")
        XCTAssertEqual(nested.string, "bold with italic inside")
        let nestedTraits = try fontTraits(in: nested, matching: "italic")
        XCTAssertTrue(nestedTraits.contains(.boldFontMask))
        XCTAssertTrue(nestedTraits.contains(.italicFontMask))

        let adjacent = paragraph("**one****two** and ***both***")
        XCTAssertEqual(adjacent.string, "onetwo and both")
        XCTAssertTrue(
            try fontTraits(in: adjacent, matching: "one").contains(.boldFontMask)
        )
        XCTAssertTrue(
            try fontTraits(in: adjacent, matching: "two").contains(.boldFontMask)
        )
        let combinedTraits = try fontTraits(in: adjacent, matching: "both")
        XCTAssertTrue(combinedTraits.contains(.boldFontMask))
        XCTAssertTrue(combinedTraits.contains(.italicFontMask))
    }

    /// The opposite delimiter widths nest too: the inner `**` run must not close the outer `*`.
    func testStrongCanNestInsideEmphasis() throws {
        let attributed = paragraph("*italic with **bold** inside*")

        XCTAssertEqual(attributed.string, "italic with bold inside")
        let traits = try fontTraits(in: attributed, matching: "bold")
        XCTAssertTrue(traits.contains(.boldFontMask))
        XCTAssertTrue(traits.contains(.italicFontMask))
    }

    /// Provider text is unbounded. Past the supported nesting depth, remaining delimiters are
    /// rendered literally instead of allocating another scanner and growing the call stack.
    func testInlineNestingHasABoundedLiteralFallback() {
        var source = "leaf"
        for depth in 0..<(MarkdownDefaults.maximumInlineNestingDepth + 8) {
            source = depth.isMultiple(of: 2) ? "**\(source)**" : "_\(source)_"
        }

        let attributed = paragraph(source)
        XCTAssertTrue(attributed.string.contains("leaf"))
        XCTAssertTrue(
            attributed.string.contains("*") || attributed.string.contains("_"),
            "the nesting ceiling did not leave its bounded literal remainder"
        )
    }

    /// Assistant prose is untrusted. AppKit hands a live link attribute to the registered system
    /// handler, so only ordinary web navigation may cross from Markdown into an external app.
    func testOnlyHTTPAndHTTPSMarkdownTargetsBecomeLiveLinks() {
        let parsed = blocks("""
        [secure](HTTPS://example.com/a) [web](http://example.com/b) \
        [file](file:///Users/person/private) [custom](someapp://run) \
        [script](javascript:alert) [relative](/documentation)
        """)
        guard case .paragraph(let attributed) = parsed.first else {
            return XCTFail("links did not parse as a paragraph")
        }

        var liveLabels: [String] = []
        var liveSchemes: [String] = []
        attributed.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let url = value as? URL else { return }
            liveLabels.append(attributed.attributedSubstring(from: range).string)
            liveSchemes.append(url.scheme?.lowercased() ?? "")
        }

        XCTAssertEqual(liveLabels, ["secure", "web"])
        XCTAssertEqual(liveSchemes, ["https", "http"])
        for refused in ["file", "custom", "script", "relative"] {
            let range = (attributed.string as NSString).range(of: refused)
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertNil(attributed.attribute(.link, at: range.location, effectiveRange: nil))
            XCTAssertNil(
                attributed.attribute(.underlineStyle, at: range.location, effectiveRange: nil)
            )
            XCTAssertEqual(
                attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
                    as? NSColor,
                style.textColor
            )
        }
    }

    /// Reasoning is structurally Markdown without becoming answer-strength prose: provider
    /// markers disappear and convey emphasis, while every run keeps the quiet thinking ink.
    func testThinkingMarkdownParsesMarkersWithTertiaryInk() throws {
        let parsed = Markdown.parse("**Inspect** `routing.swift`", style: .thinking)
        guard case .paragraph(let attributed) = parsed.first else {
            return XCTFail("thinking Markdown did not produce a paragraph")
        }

        XCTAssertEqual(attributed.string, "Inspect routing.swift")
        XCTAssertTrue(try fontTraits(in: attributed, matching: "Inspect").contains(.boldFontMask))
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            XCTAssertEqual(value as? NSColor, Design.Text.tertiary)
        }
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

    /// Virtualized transcripts retain raw blocks and style only the viewport. The structural
    /// splitter must therefore consume exactly the same units, in the same precedence order,
    /// as the eager parser it replaces outside the viewport.
    func testSourceBlocksRoundTripThroughTheStyledParser() {
        let source = """
        # Heading

        First prose line
        second prose line

        > quoted
        > - still quoted

        - one
        - two

        1. first
        2. second

        | Name | Value |
        | :--- | ----: |
        | pipe | `a | b` |

        ```sh
        # not a heading
        rm *.log
        ```
        """

        let eager = blocks(source)
        let deferred = Markdown.sourceBlocks(source).flatMap(blocks)

        XCTAssertEqual(deferred.map(kind), eager.map(kind))
        XCTAssertEqual(deferred.map { text(of: $0) }, eager.map { text(of: $0) })
    }
}
