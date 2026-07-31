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

    func testLargeComparisonUsesVirtualFileRows() throws {
        let files = Self.stressFiles(count: 1_000)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)

        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.fileTableView.numberOfRows, files.count)
        XCTAssertLessThan(
            controller.instantiatedFileRowCount,
            files.count,
            "the table must not construct every file row to show the first viewport"
        )

        controller.fileTableView.scrollRowToVisible(files.count - 1)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.fileTableView.numberOfRows, files.count)
        XCTAssertLessThan(controller.instantiatedFileRowCount, files.count)
    }

    func testVirtualFileRowExpansionPersistsAndInvalidatesHeight() throws {
        let source = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let files = (0...GitReviewDefaults.largeDiffFileThreshold).map { index in
            GitFileDiff(
                path: "Sources/Feature\(index)/Foo.swift",
                change: source.change,
                hunks: source.hunks,
                added: source.added,
                removed: source.removed
            )
        }
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        XCTAssertFalse(fileRow.isOpen)
        let collapsedHeight = controller.fileTableView.rect(ofRow: 0).height

        fileRow.setExpanded(true)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.expansionOverrides[files[0].path], true)
        XCTAssertGreaterThan(controller.fileTableView.rect(ofRow: 0).height, collapsedHeight)

        controller.fileTableView.reloadData()
        controller.view.layoutSubtreeIfNeeded()
        let reloadedHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual((reloadedHost.subviews.first as? GitReviewFileRow)?.isOpen, true)
    }

    func testVirtualFileRowRetainsExactEditorDestination() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = "Sources/Threading/UI/Views/GitReviewRendering.swift"
        let file = GitFileDiff(
            path: path,
            change: .modified,
            hunks: [
                GitHunk(
                    header: "@@ -41,1 +41,2 @@",
                    lines: [
                        GitDiffLine(
                            kind: .context,
                            text: "let oldValue = 1",
                            oldNumber: 41,
                            newNumber: 41
                        ),
                        GitDiffLine(
                            kind: .added,
                            text: "let exactValue = 2",
                            oldNumber: nil,
                            newNumber: 42
                        )
                    ]
                )
            ],
            added: 1,
            removed: 0
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: repository.path,
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        XCTAssertEqual(
            fileRow.openInTarget,
            .file(repository.appendingPathComponent(path), line: 42),
            "reconstructing a virtual row lost the exact new-file line from its diff"
        )

        controller.show(.files([
            GitFileDiff(path: path, change: .binary, hunks: [], added: 0, removed: 0)
        ]))
        controller.view.layoutSubtreeIfNeeded()
        let binaryHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual(
            (binaryHost.subviews.first as? GitReviewFileRow)?.openInTarget,
            .file(repository.appendingPathComponent(path), line: nil),
            "a file without numbered diff lines invented an editor position"
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

    /// Opt-in rather than part of the fast suite: this is a repeatable workload for `sample`,
    /// `xctrace`, and before/after measurements of the pane's large-file-index path.
    ///
    /// Run with:
    /// `THREADING_GIT_STRESS=1 scripts/test.sh fast
    /// -only-testing:ThreadingTests/GitReviewViewTests/testStressLargeFileIndexesWhenEnabled`
    func testStressLargeFileIndexesWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_GIT_STRESS"] == "1",
            "Set THREADING_GIT_STRESS=1 to run the large Git Review sweep."
        )

        for fileCount in [10, 100, 500, 1_000] {
            let controller = GitReviewViewController(
                sessionID: SessionID(),
                folderPath: NSTemporaryDirectory(),
                mode: .uncommitted
            )
            _ = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)

            let files = Self.stressFiles(count: fileCount)
            let renderStarted = DispatchTime.now().uptimeNanoseconds
            controller.show(.files(files))
            let renderEnded = DispatchTime.now().uptimeNanoseconds
            controller.view.layoutSubtreeIfNeeded()
            let layoutEnded = DispatchTime.now().uptimeNanoseconds

            print(
                "THREADING_PERF git-review-file-index "
                    + "files=\(fileCount) instantiated=\(controller.instantiatedFileRowCount) "
                    + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                    + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                    + "elapsed_ms=\(Self.milliseconds(layoutEnded - renderStarted))"
            )

            let scrollStarted = DispatchTime.now().uptimeNanoseconds
            controller.fileTableView.scrollRowToVisible(fileCount - 1)
            controller.view.layoutSubtreeIfNeeded()
            let scrollElapsed = DispatchTime.now().uptimeNanoseconds - scrollStarted
            print(
                "THREADING_PERF git-review-file-deep-scroll "
                    + "files=\(fileCount) instantiated=\(controller.instantiatedFileRowCount) "
                    + "elapsed_ms=\(Self.milliseconds(scrollElapsed))"
            )
        }

        let targetIndex = 777
        let expandableFiles = Self.stressExpandableFiles(count: 1_000)
        let deepController = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = deepController.view
        deepController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        deepController.show(.files(expandableFiles))
        deepController.view.layoutSubtreeIfNeeded()
        deepController.fileTableView.scrollRowToVisible(targetIndex)
        deepController.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            deepController.fileTableView.view(
                atColumn: 0,
                row: targetIndex,
                makeIfNecessary: true
            )
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let openStarted = DispatchTime.now().uptimeNanoseconds
        fileRow.setExpanded(true)
        deepController.view.layoutSubtreeIfNeeded()
        let openElapsed = DispatchTime.now().uptimeNanoseconds - openStarted

        XCTAssertEqual(deepController.expansionOverrides[expandableFiles[targetIndex].path], true)
        XCTAssertEqual(GitReviewFileRow.firstChangedLine(in: expandableFiles[targetIndex]), 779)
        print(
            "THREADING_PERF git-review-file-open "
                + "files=1000 row=\(targetIndex) exact_line=779 "
                + "elapsed_ms=\(Self.milliseconds(openElapsed))"
        )
    }

    // MARK: - Stress Fixtures

    private static func stressFiles(count: Int) -> [GitFileDiff] {
        (0..<count).map { index in
            GitFileDiff(
                path: "Sources/Generated/Feature\(index)/ChangedFile\(index).swift",
                change: .binary,
                hunks: [],
                added: index % 17,
                removed: index % 11
            )
        }
    }

    private static func stressExpandableFiles(count: Int) -> [GitFileDiff] {
        (0..<count).map { index in
            let line = index + 2
            return GitFileDiff(
                path: "Sources/Generated/Feature\(index)/ChangedFile\(index).swift",
                change: .modified,
                hunks: [
                    GitHunk(
                        header: "@@ -\(line),2 +\(line),2 @@",
                        lines: [
                            GitDiffLine(
                                kind: .removed,
                                text: "let oldValue = \(index)",
                                oldNumber: line,
                                newNumber: nil
                            ),
                            GitDiffLine(
                                kind: .added,
                                text: "let newValue = \(index)",
                                oldNumber: nil,
                                newNumber: line
                            )
                        ]
                    )
                ],
                added: 1,
                removed: 1
            )
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
