import AppKit
import XCTest
@testable import ThreadingMarkdownKit

final class MarkdownPreviewTests: XCTestCase {
    @MainActor
    func testQuickLookUsesNativeBlocksAndEscapesActiveContent() {
        let source = """
        # Guidelines

        **Bold**, *italic* and `code`.

        > A quoted thought.

        | Name | Meaning |
        | --- | --- |
        | Source | Markdown |

        <script>alert('bad')</script>

        [safe](https://example.com/?a=1&b=2) [unsafe](file:///tmp/private)
        """
        let document = MarkdownPreviewDocument(source: source)
        let html = MarkdownPreviewHTML.render(document, themes: nil, title: "Guidelines.md", excerptMessage: "Excerpt")
        XCTAssertFalse(document.isExcerpt)
        XCTAssertTrue(html.range(of: "<h1>.*Guidelines.*</h1>", options: .regularExpression) != nil)
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"file:"))
        XCTAssertTrue(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    /// Emphasis survives a theme family that has no bold or italic face, and the backdrop
    /// pattern covers the whole canvas rather than ending with the article.
    @MainActor
    func testThemeFontsAndPatternsCannotEraseStructure() {
        var theme = MarkdownPreviewTheme.system(dark: false)
        theme.fontName = "A family with no bold face"
        theme.codeFontName = "A code family Quick Look cannot load"
        theme.pattern = .init(kind: "diagonal_grid", color: "#00ff00", spacing: 24, width: 1)
        let themes = MarkdownPreviewThemes(light: theme, dark: theme)
        let html = MarkdownPreviewHTML.render(
            MarkdownPreviewDocument(source: "   ## Indented\n\n**Bold** and *italic*."),
            themes: themes, title: "Note.md", excerptMessage: "Excerpt"
        )
        XCTAssertTrue(html.contains("<h2>Indented</h2>"))
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("ui-monospace"), "An unloadable code family must fall back to a monospace face")
        XCTAssertTrue(html.contains("repeating-linear-gradient(45deg"))
        XCTAssertTrue(html.range(of: "html \\{[^}]*min-height: 100%[^}]*background-image", options: .regularExpression) != nil)
    }

    func testSourceBlocksReportTheLineEachStartsOn() {
        let blocks = Markdown.sourceBlockLines("# Title\n\nOne\ntwo\n\n```\ncode\n\nmore\n```\n- item")
        XCTAssertEqual(blocks.map(\.line), [0, 2, 5, 10])
        XCTAssertEqual(blocks.map(\.source), Markdown.sourceBlocks("# Title\n\nOne\ntwo\n\n```\ncode\n\nmore\n```\n- item"))
        XCTAssertEqual(Markdown.headingLevel(ofSource: "  ### Three"), 3)
        XCTAssertNil(Markdown.headingLevel(ofSource: "#hashtag"))
        XCTAssertNil(Markdown.headingLevel(ofSource: "Paragraph"))
    }

    func testLargePreviewIsExplicitlyBoundedBeforeStyling() {
        let source = String(repeating: "## Heading\n\nA small paragraph.\n\n", count: 10_000)
        let document = MarkdownPreviewDocument(source: source)
        XCTAssertTrue(document.isExcerpt)
        XCTAssertEqual(document.blocks.count, MarkdownPreviewDocument.maximumBlocks)
        XCTAssertLessThanOrEqual(document.blocks.reduce(0) { $0 + $1.utf8.count }, MarkdownPreviewDocument.maximumPreviewBytes)
        let longBlock = MarkdownPreviewDocument(source: String(repeating: "a", count: 32_769))
        XCTAssertTrue(longBlock.isExcerpt)
        XCTAssertTrue(longBlock.blocks.isEmpty)
    }

    func testQuickLookWorkerRejectsInvalidAndUnboundedFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xff]).write(to: url)
        do { _ = try await MarkdownPreviewWorker.shared.read(url); XCTFail("Invalid UTF-8 accepted") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadInapplicableStringEncoding.rawValue) }
        try Data(repeating: 0x61, count: MarkdownPreviewDocument.maximumFileBytes + 1).write(to: url)
        do { _ = try await MarkdownPreviewWorker.shared.read(url); XCTFail("Unbounded file accepted") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadTooLarge.rawValue) }
    }
}
