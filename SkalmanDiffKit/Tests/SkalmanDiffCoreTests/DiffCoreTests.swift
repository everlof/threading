import XCTest
@testable import SkalmanDiffCore

final class DiffCoreTests: XCTestCase {
    func testUnifiedParserBuildsSummaryAndRanges() {
        let files = UnifiedDiffParser.files(from: """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -10,2 +10,3 @@
         context
        -old
        +new
        +extra
        """)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(DiffDocument(files: files).summary, DiffSummary(files: 1, added: 2, removed: 1))
        XCTAssertEqual(files[0].hunks[0].lineRange, 10...12)
        XCTAssertEqual(DiffPresentation.rangeTitle(for: files[0].hunks[0]), "Lines 10–12")
    }

    func testLargeDocumentsDoNotAutoExpand() {
        let line = DiffLine(kind: .added, text: "new", newNumber: 1)
        let file = DiffFile(
            path: "File.swift",
            change: .modified,
            hunks: [DiffHunk(header: "@@", lines: [line])],
            added: 1,
            removed: 0
        )
        let document = DiffDocument(files: Array(repeating: file, count: 101))

        XCTAssertTrue(DiffPresentationPolicy.default.initiallyExpandedPaths(in: document).isEmpty)
    }

    func testPresentationSplitsFilenameAndDirectory() {
        let file = DiffFile(
            path: "Sources/App/File.swift",
            change: .renamed(from: "Old.swift"),
            hunks: [],
            added: 0,
            removed: 0
        )

        XCTAssertEqual(file.fileName, "File.swift")
        XCTAssertEqual(file.directory, "Sources/App")
        XCTAssertEqual(DiffPresentation.changeGlyph(for: file.change), "→")
    }
}
