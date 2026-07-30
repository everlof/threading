import XCTest
@testable import Threading

/// Builds the review pane's views from parsed fixtures — no git process, just the rendering
/// path that a live diff would take.
@MainActor
final class GitReviewViewTests: XCTestCase {

    private let fixture = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    index 1111111..2222222 100644
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -1,3 +1,3 @@
     context
    -old line
    +new line
    @@ -10,2 +10,2 @@
    -older
    +newer
    """

    func testNumberedDiffViewBuildsOneRowPerLine() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let lines = files[0].hunks.flatMap(\.lines)

        let view = DiffView(gitLines: lines, displayCap: 100)
        XCTAssertEqual(view.arrangedSubviews.count, lines.count)

        // Numbered rows carry three labels: number, gutter sign, text.
        XCTAssertEqual(view.arrangedSubviews[0].subviews.count, 3)
    }

    func testNumberedDiffViewTruncatesAtCap() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let lines = files[0].hunks.flatMap(\.lines)

        let view = DiffView(gitLines: lines, displayCap: 2)
        // Two line rows plus the "… N more lines" note.
        XCTAssertEqual(view.arrangedSubviews.count, 3)
    }

    func testEditToolDiffViewKeepsTwoLabelRows() {
        let view = DiffView(lines: [
            DiffLine(kind: .removed, text: "a"),
            DiffLine(kind: .added, text: "b")
        ])
        XCTAssertEqual(view.arrangedSubviews.count, 2)

        // The tool-row path must not grow a number column: gutter sign and text only.
        XCTAssertEqual(view.arrangedSubviews[0].subviews.count, 2)
    }

    func testFileRowExpandsWithHunkHeaders() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(file: files[0], expanded: true)

        // Force layout to surface any conflicting constraints as a crash/log here, not in the app.
        row.layoutSubtreeIfNeeded()

        let body = row.subviews.compactMap { $0 as? NSStackView }.first
        XCTAssertNotNil(body)
        // Two hunks: header + diff, header + diff.
        XCTAssertEqual(body?.arrangedSubviews.count, 4)
    }

    func testCollapsedFileRowBuildsNoBody() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(file: files[0], expanded: false)

        let body = row.subviews.compactMap { $0 as? NSStackView }.first
        XCTAssertEqual(body?.arrangedSubviews.count, 0)
        XCTAssertEqual(body?.isHidden, true)
    }

    func testLargeComparisonStartsAsAFileIndex() {
        let file = GitDiffParser.files(fromUnifiedDiff: fixture)[0]
        let manyFiles = Array(
            repeating: file,
            count: GitReviewDefaults.largeDiffFileThreshold + 1
        )

        XCTAssertEqual(GitReviewViewController.initialExpandBudget(for: manyFiles), 0)
        XCTAssertEqual(
            GitReviewViewController.initialExpandBudget(for: [file]),
            GitReviewDefaults.autoExpandTotalLineLimit
        )
    }

    func testLongDiffShowsSummaryAndScrollToEndControl() {
        let lines = (1...80).map { number in
            GitDiffLine(
                kind: .context,
                text: "let value\(String(number)) = \(String(number))",
                oldNumber: number,
                newNumber: number
            )
        }
        let file = GitFileDiff(
            path: "Sources/Long.swift",
            change: .modified,
            hunks: [GitHunk(header: "@@ -1,80 +1,80 @@", lines: lines)],
            added: 0,
            removed: 0
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .unstaged
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 280)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()
        controller.updateScrollControls()

        XCTAssertFalse(controller.summaryPill.isHidden)
        XCTAssertFalse(controller.jumpToEndButton.isHidden)

        controller.scrollToDiffEnd()
        XCTAssertTrue(
            controller.jumpToEndButton.isHidden,
            "document=\(controller.scrollView.documentView?.frame.height ?? -1), "
                + "viewport=\(controller.scrollView.contentView.bounds.height), "
                + "offset=\(controller.scrollView.contentView.bounds.origin.y)"
        )
    }
}
