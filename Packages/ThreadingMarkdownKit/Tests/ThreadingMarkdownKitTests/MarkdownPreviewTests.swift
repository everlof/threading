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
