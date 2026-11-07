import XCTest
@testable import ThreadingMarkdownModel

/// The shared reading of agent-written Markdown: what each block and run becomes, what stays
/// literal, and what its HTML lets through.
final class MarkdownModelTests: XCTestCase {

    // MARK: - Blocks

    func testAQuestionWithEveryBlockReadsAsWritten() {
        let document = MarkdownDocument(parsing: """
            ## Avrundning

            Momsen räknas **per rad**.
            Inte på totalen.

            - första
            - andra

            3. tredje
            4. fjärde

            > Källa: avtalet

            | Rad | Belopp | Moms |
            |:----|------:|:---:|
            | 1 | 100 kr | 25 |
            | 2 | 80 kr |

            ```swift
            let total = rows.map(\\.vat)
            ```

            ---
            """)

        XCTAssertEqual(document.blocks.count, 8)
        XCTAssertEqual(document.blocks[0], .heading(level: 2, [.text("Avrundning")]))
        XCTAssertEqual(document.blocks[1], .paragraph([
            .text("Momsen räknas "), .strong([.text("per rad")]), .text("."), .lineBreak, .text("Inte på totalen.")
        ]), "a line break the author wrote is kept")
        XCTAssertEqual(document.blocks[2], .bullets([[.text("första")], [.text("andra")]]))
        XCTAssertEqual(document.blocks[3], .ordered(start: 3, [[.text("tredje")], [.text("fjärde")]]))
        XCTAssertEqual(document.blocks[4], .quote([.text("Källa: avtalet")]))
        guard case .table(let table) = document.blocks[5] else { return XCTFail("no table") }
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.headers.map(MarkdownInline.plainText), ["Rad", "Belopp", "Moms"])
        XCTAssertEqual(table.rows.map { $0.map(MarkdownInline.plainText) },
                       [["1", "100 kr", "25"], ["2", "80 kr", ""]], "a short row is padded")
        XCTAssertEqual(document.blocks[6], .code(language: "swift", text: "let total = rows.map(\\.vat)"))
        XCTAssertEqual(document.blocks[7], .rule)
    }

    func testAPipeInASentenceIsNotATableAndALongRowKeepsItsCells() {
        XCTAssertEqual(MarkdownDocument(parsing: "Välj a | b om du vill.").blocks,
                       [.paragraph([.text("Välj a | b om du vill.")])])
        let wide = MarkdownDocument(parsing: "| a | b |\n|---|---|\n| 1 | 2 | 3 |")
        guard case .table(let table)? = wide.blocks.first else { return XCTFail("no table") }
        XCTAssertEqual(table.rows.first?.map(MarkdownInline.plainText), ["1", "2 | 3"])
    }

    func testFencedCodeIsVerbatimAndAnUnclosedFenceRunsToTheEnd() {
        let document = MarkdownDocument(parsing: "```\nrm -rf *.tmp **x**\n")
        XCTAssertEqual(document.blocks, [.code(language: "", text: "rm -rf *.tmp **x**\n")])
    }

    // MARK: - Inline

    func testInlineRunsNestAndUnmatchedDelimitersStayLiteral() {
        XCTAssertEqual(MarkdownInlineParser.parse("*kursiv **fet** kursiv*"), [
            .emphasis([.text("kursiv "), .strong([.text("fet")]), .text(" kursiv")])
        ])
        XCTAssertEqual(MarkdownInlineParser.parse("***båda***"), [.strong([.emphasis([.text("båda")])])])
        XCTAssertEqual(MarkdownInlineParser.parse("~~bort~~ kvar"), [.strikethrough([.text("bort")]), .text(" kvar")])
        XCTAssertEqual(MarkdownInlineParser.parse("`a*b*c` och `x`"), [.code("a*b*c"), .text(" och "), .code("x")])
        XCTAssertEqual(MarkdownInlineParser.parse("2 * 3 * 4"), [.text("2 * 3 * 4")], "arithmetic is not emphasis")
        XCTAssertEqual(MarkdownInlineParser.parse("snake_case_name"), [.text("snake_case_name")])
        XCTAssertEqual(MarkdownInlineParser.parse("**halvskriven"), [.text("**halvskriven")])
        XCTAssertEqual(MarkdownInlineParser.parse("se [avtalet](https://example.com/a) nu"), [
            .text("se "), .link(label: [.text("avtalet")], url: "https://example.com/a"), .text(" nu")
        ])
    }

    func testNestingPastTheCeilingIsLiteralRatherThanUnbounded() {
        let depth = MarkdownModelLimits.maximumInlineNestingDepth + 8
        let text = String(repeating: "*_", count: depth) + "x" + String(repeating: "_*", count: depth)
        // Reads at all, in bounded time, and keeps every character.
        let runs = MarkdownInlineParser.parse(text)
        XCTAssertTrue(MarkdownInline.plainText(runs).contains("x"))
    }

    // MARK: - HTML

    func testHTMLEscapesEverythingTheTextCarries() {
        let html = MarkdownHTML.render(markdown: "<script>alert(1)</script> **\"fet\"** `<b>` & 'citat'")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("<strong>&quot;fet&quot;</strong>"))
        XCTAssertTrue(html.contains("<code>&lt;b&gt;</code>"))
        XCTAssertTrue(html.contains("&amp; &#39;citat&#39;"))
        XCTAssertFalse(html.contains("style="), "a strict content-security policy forbids style attributes")
    }

    func testOnlyAWebURLBecomesALink() {
        XCTAssertTrue(MarkdownHTML.render(markdown: "[a](https://example.com)")
            .contains("<a href=\"https://example.com\" rel=\"noopener noreferrer nofollow\" target=\"_blank\">a</a>"))
        for unsafe in ["javascript:alert(1)", "file:///etc/passwd", "threading://pair#x", "data:text/html,x", "//evil.test"] {
            let html = MarkdownHTML.render(markdown: "[klicka](\(unsafe))")
            XCTAssertFalse(html.contains("<a "), unsafe)
            XCTAssertTrue(html.contains("klicka"), unsafe)
        }
        XCTAssertNil(MarkdownLinkPolicy.webURL("https://"))
    }

    func testATableAndHeadingsRenderUnderThePagesOwnHeadings() {
        let html = MarkdownHTML.render(markdown: "# Titel\n\n| a | b |\n|:---:|---:|\n| 1 | 2 |")
        XCTAssertTrue(html.hasPrefix("<h3 class=\"md-heading\">Titel</h3>"))
        XCTAssertTrue(html.contains("<div class=\"md-table\"><table><thead><tr><th class=\"md-center\">a</th><th class=\"md-trailing\">b</th></tr></thead>"))
        XCTAssertTrue(html.contains("<tbody><tr><td class=\"md-center\">1</td><td class=\"md-trailing\">2</td></tr></tbody>"))
    }

    func testPlainTextDropsTheMarkup() {
        let document = MarkdownDocument(parsing: "**Fet** och [länk](https://example.com)\n\n- a\n- b")
        XCTAssertEqual(document.plainText, "Fet och länk\na\nb")
    }
}
