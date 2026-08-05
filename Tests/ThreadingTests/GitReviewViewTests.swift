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

    func testDiffLineContextKeepsProjectPathNumberAndExcerpt() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = DiffView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.text == "new line" })

        let reference = try XCTUnwrap(view.contextAttachment(atDisplayedLine: addedIndex))
        XCTAssertEqual(reference.source, .code)
        XCTAssertEqual(reference.title, "Sources/Foo.swift:2")
        XCTAssertEqual(reference.locator, "Sources/Foo.swift")
        XCTAssertEqual(reference.lineStart, 2)
        XCTAssertEqual(reference.lineEnd, 2)
        XCTAssertEqual(reference.excerpt, "new line")
    }

    func testCompactReviewDiffKeepsExactLineContextWithoutPerLineViews() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.text == "new line" })

        let reference = try XCTUnwrap(view.contextAttachment(atDisplayedLine: addedIndex))
        XCTAssertEqual(reference.title, "Sources/Foo.swift:2")
        XCTAssertEqual(reference.locator, "Sources/Foo.swift")
        XCTAssertEqual(reference.lineStart, 2)
        XCTAssertEqual(reference.excerpt, "new line")
        XCTAssertLessThan(
            view.subviews.count,
            lines.count,
            "the review renderer regressed to an AppKit view per diff line"
        )
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

    func testLargeComparisonDefaultsToExpandedState() throws {
        let file = GitDiffParser.files(fromUnifiedDiff: fixture)[0]
        let manyFiles = Array(
            repeating: file,
            count: 100
        )

        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(manyFiles))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual((host.subviews.first as? GitReviewFileRow)?.isOpen, true)
        XCTAssertLessThan(
            controller.instantiatedFileRowCount,
            manyFiles.count,
            "expanded state must not construct offscreen file bodies"
        )
    }

    func testTextFilesDefaultOpenButImageComparisonsStayLazy() throws {
        let text = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let image = GitFileDiff(
            path: "Screenshots/comparison.png",
            change: .binary,
            hunks: [],
            added: 0,
            removed: 0
        )

        XCTAssertTrue(GitReviewFileRow.expandsByDefault(text))
        XCTAssertTrue(GitReviewFileRow.isExpandable(image))
        XCTAssertFalse(
            GitReviewFileRow.expandsByDefault(image),
            "initial rendering must not fetch and decode image endpoint blobs"
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
        XCTAssertGreaterThan(controller.fileTableView.tableColumns[0].width, 450)
        let firstHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(firstHost.subviews.first as? GitReviewFileRow).bounds.width,
            400,
            "the file card did not follow the review pane's width"
        )
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

    /// The pane is one column: the mode chip, every file card and the overflow start and end on
    /// the same margin. They did not, and the reason is not visible in any of the three's own
    /// code — the file table's `.automatic` style resolves to `.inset`, which keeps 16pt of
    /// AppKit's own at each side, so cards sat 40pt in beneath a chip at 12. The overflow was
    /// the other half: pinned by its frame, a plain button hangs its glyph a further 4pt inside.
    func testHeaderChipFileCardsAndOverflowShareOneMargin() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
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
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let cardFrame = card.convert(card.bounds, to: controller.view)
        let chip = controller.modeChip
        let chipFrame = chip.convert(chip.bounds, to: controller.view)

        XCTAssertEqual(
            cardFrame.minX, chipFrame.minX, accuracy: 0.5,
            "a file card should start where the mode chip does"
        )
        XCTAssertEqual(
            controller.view.bounds.maxX - cardFrame.maxX, chipFrame.minX, accuracy: 0.5,
            "a file card's margins should be equal on both sides"
        )
        let diff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: card)
        )
        let diffFrame = diff.convert(diff.bounds, to: controller.view)
        XCTAssertEqual(
            diffFrame.minX, cardFrame.minX, accuracy: 0.5,
            "the expanded diff should use the card's full leading edge"
        )
        XCTAssertEqual(
            diffFrame.maxX, cardFrame.maxX, accuracy: 0.5,
            "the expanded diff should use the card's full trailing edge"
        )

        // Aligned by ink: the button's frame carries the hover surface, its stated inset is how
        // deep, and what has to land on the margin is what the eye sees.
        let overflow = try XCTUnwrap(
            controller.view.subviews
                .compactMap { $0 as? ThemedButton }
                .first { $0.toolTip == L10n.string("Diff options") }
        )
        XCTAssertEqual(
            overflow.frame.maxX - overflow.opticalHorizontalInset, cardFrame.maxX, accuracy: 0.5,
            "the overflow's glyph should end where a file card does"
        )

        // And the same margin vertically, so the header reads as the top of the list rather
        // than as a band above it: the row sat 6pt below the tab strip and 12pt above the
        // first card, which showed as the chip hugging the strip.
        let sideMargin = chipFrame.minX
        XCTAssertEqual(
            controller.view.bounds.maxY - chipFrame.maxY, sideMargin, accuracy: 0.5,
            "the header should sit the pane's own margin below the tab strip"
        )
        XCTAssertEqual(
            chipFrame.minY - cardFrame.maxY, sideMargin, accuracy: 0.5,
            "the gap under the header should match the pane's margin"
        )
    }

    /// The other half of moving the row gap out of `intercellSpacing` and into the row: cards
    /// still have to be separated by exactly one gap, not two and not none.
    func testCardsAreSeparatedByOneRowGap() throws {
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(Self.stressFiles(count: 3)))
        controller.view.layoutSubtreeIfNeeded()

        let frames = try (0..<2).map { row -> NSRect in
            let host = try XCTUnwrap(
                controller.fileTableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            )
            let card = try XCTUnwrap(host.subviews.first)
            return card.convert(card.bounds, to: controller.view)
        }

        XCTAssertEqual(
            frames[0].minY - frames[1].maxY, Design.Spacing.small, accuracy: 0.5,
            "consecutive file cards should be one gap apart"
        )
    }

    func testVirtualFileRowExpansionPersistsAndInvalidatesHeight() throws {
        let source = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let files = (0..<100).map { index in
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
        controller.expansionOverrides[files[0].path] = false
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
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5,
            "jump-to-end should reach AppKit's inset-aware terminal scroll position"
        )
        XCTAssertTrue(
            controller.jumpToEndButton.isHidden,
            "document=\(controller.scrollView.documentView?.frame.height ?? -1), "
                + "viewport=\(controller.scrollView.contentView.bounds.height), "
                + "offset=\(controller.scrollView.contentView.bounds.origin.y)"
        )
    }

    /// Automatic table height is first queried before the card has its real width. The compact
    /// TextKit body must replace that fallback measurement once it reaches the pane; otherwise
    /// a narrow 240pt measurement survives under a 500pt card as a large blank scroll region.
    func testDenseExpandedDiffFitsItsActualWidthAndUsedHeight() async throws {
        let file = try XCTUnwrap(Self.stressDenseFiles(count: 1, linesPerFile: 400).first)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let diff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: card)
        )
        let usedHeight = try XCTUnwrap(diff.layoutManager).usedRect(
            for: try XCTUnwrap(diff.textContainer)
        ).height

        XCTAssertEqual(diff.bounds.width, card.bounds.width, accuracy: 0.5)
        XCTAssertEqual(diff.bounds.height, ceil(usedHeight), accuracy: 0.5)
        XCTAssertLessThan(
            card.bounds.height - diff.bounds.height,
            120,
            "the card retained false scrollable height below the laid-out glyphs; "
                + "card=\(card.bounds.height) intrinsic=\(card.intrinsicContentSize.height) "
                + "host=\(host.bounds.height) fitting=\(host.fittingSize.height) "
                + "tableRow=\(controller.fileTableView.rect(ofRow: 0).height) "
                + "tableLookup=\(controller.fileTableView.row(for: card)) "
                + "cached=\(String(describing: controller.measuredFileRowHeights[file.path])) "
                + "initial=\(diff.initialMeasuredSize) diff=\(diff.bounds.height) used=\(usedHeight)"
        )

        controller.scrollToDiffEnd()
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5,
            "a dense measured row should have no hidden document tail"
        )

        controller.view.frame.size.width = 460
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(diff.bounds.width, card.bounds.width, accuracy: 0.5)
        XCTAssertEqual(
            card.bounds.height - diff.bounds.height,
            78,
            accuracy: 4,
            "resizing should replace both the TextKit and table-row height caches; "
                + "card=\(card.bounds.height) diff=\(diff.bounds.height) "
                + "row=\(controller.fileTableView.rect(ofRow: 0).height) "
                + "cache=\(String(describing: controller.measuredFileRowHeights[file.path]))"
        )
    }

    /// Offscreen files remain model rows, but their estimates must be close enough that the
    /// document and scrollbar do not acquire a new tail as the last viewport materializes.
    func testExpandedHeightEstimatesKeepTheDocumentExtentStable() async {
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        let files = Self.stressDenseFiles(count: 30, linesPerFile: 80)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let initialHeight = controller.fileTableView.frame.height

        controller.fileTableView.scrollRowToVisible(29)
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let discoveredHeight = controller.fileTableView.frame.height
        let firstEstimate = GitReviewFileRow.estimatedTableHeight(
            for: files[0],
            expanded: true,
            wraps: true,
            width: 596
        )

        XCTAssertLessThan(
            abs(discoveredHeight - initialHeight) / max(initialHeight, 1),
            0.01,
            "materializing the final viewport should not move the scrollbar's terminal extent; "
                + "initial=\(initialHeight) discovered=\(discoveredHeight) "
                + "measured=\(controller.measuredFileRowHeights.count) "
                + "estimate=\(firstEstimate) "
                + "first=\(String(describing: controller.measuredFileRowHeights[files[0].path])) "
                + "last=\(String(describing: controller.measuredFileRowHeights[files[29].path]))"
        )
        controller.scrollToDiffEnd()
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5
        )

        controller.view.frame.size.width = 460
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let resizedHeight = controller.fileTableView.frame.height
        let resizedEstimate = GitReviewFileRow.estimatedTableHeight(
            for: files[0],
            expanded: true,
            wraps: true,
            width: 436
        )
        XCTAssertLessThan(
            abs(resizedHeight - resizedEstimate * CGFloat(files.count))
                / max(resizedHeight, 1),
            0.01,
            "resizing should replace offscreen wrapping estimates as one table-height update"
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
        deepController.expansionOverrides[expandableFiles[targetIndex].path] = false
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

        // The original disclosure fixture above is deliberately tiny: it guards exact deep
        // navigation, but its two diff lines cannot reproduce the pause reported on a real
        // working tree. This one matches the production per-file display cap and the reported
        // 174-file index, and splits body construction from the table's cached-height layout.
        let denseFiles = Self.stressDenseFiles(
            count: 174,
            linesPerFile: GitReviewDefaults.fileDisplayCap
        )
        let denseController = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = denseController.view
        denseController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        denseController.expansionOverrides[denseFiles[87].path] = false
        denseController.show(.files(denseFiles))
        denseController.view.layoutSubtreeIfNeeded()

        let denseTarget = 87
        denseController.fileTableView.scrollRowToVisible(denseTarget)
        denseController.view.layoutSubtreeIfNeeded()
        let denseHost = try XCTUnwrap(
            denseController.fileTableView.view(
                atColumn: 0,
                row: denseTarget,
                makeIfNecessary: true
            )
        )
        let denseRow = try XCTUnwrap(denseHost.subviews.first as? GitReviewFileRow)

        let openSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(true)
        let openSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let openLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let closeSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(false)
        let closeSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let closeLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let reopenSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(true)
        let reopenSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let reopenLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let targetRect = denseController.fileTableView.rect(ofRow: denseTarget)
        let viewport = denseController.scrollView.bounds
        let scrollDistance = max(targetRect.height - viewport.height, 0)
        let scrollFrames = 48
        let scrollBitmap = try XCTUnwrap(
            denseController.scrollView.bitmapImageRepForCachingDisplay(in: viewport)
        )
        var scrollNanoseconds: UInt64 = 0
        var layoutNanoseconds: UInt64 = 0
        var drawNanoseconds: UInt64 = 0
        let scrollStarted = DispatchTime.now().uptimeNanoseconds
        for frame in 0..<scrollFrames {
            let fraction = CGFloat(frame) / CGFloat(max(scrollFrames - 1, 1))
            let frameStarted = DispatchTime.now().uptimeNanoseconds
            denseController.scrollView.contentView.scroll(
                to: NSPoint(x: 0, y: targetRect.minY + scrollDistance * fraction)
            )
            denseController.scrollView.reflectScrolledClipView(
                denseController.scrollView.contentView
            )
            let scrollEnded = DispatchTime.now().uptimeNanoseconds
            denseController.view.layoutSubtreeIfNeeded()
            let layoutEnded = DispatchTime.now().uptimeNanoseconds
            denseController.scrollView.cacheDisplay(in: viewport, to: scrollBitmap)
            let drawEnded = DispatchTime.now().uptimeNanoseconds
            scrollNanoseconds += scrollEnded - frameStarted
            layoutNanoseconds += layoutEnded - scrollEnded
            drawNanoseconds += drawEnded - layoutEnded
        }
        let scrollEnded = DispatchTime.now().uptimeNanoseconds

        print(
            "THREADING_PERF git-review-file-disclosure "
                + "files=174 row=\(denseTarget) lines=\(GitReviewDefaults.fileDisplayCap) "
                + "open_set_ms=\(Self.milliseconds(openSetEnded - openSetStarted)) "
                + "open_layout_ms=\(Self.milliseconds(openLayoutEnded - openSetEnded)) "
                + "close_set_ms=\(Self.milliseconds(closeSetEnded - closeSetStarted)) "
                + "close_layout_ms=\(Self.milliseconds(closeLayoutEnded - closeSetEnded)) "
                + "reopen_set_ms=\(Self.milliseconds(reopenSetEnded - reopenSetStarted)) "
                + "reopen_layout_ms=\(Self.milliseconds(reopenLayoutEnded - reopenSetEnded))"
        )
        print(
            "THREADING_PERF git-review-file-continuous-scroll "
                + "files=174 row=\(denseTarget) lines=\(GitReviewDefaults.fileDisplayCap) "
                + "frames=\(scrollFrames) "
                + "elapsed_ms=\(Self.milliseconds(scrollEnded - scrollStarted)) "
                + "per_frame_ms=\(Self.milliseconds((scrollEnded - scrollStarted) / UInt64(scrollFrames))) "
                + "scroll_ms=\(Self.milliseconds(scrollNanoseconds / UInt64(scrollFrames))) "
                + "layout_ms=\(Self.milliseconds(layoutNanoseconds / UInt64(scrollFrames))) "
                + "draw_ms=\(Self.milliseconds(drawNanoseconds / UInt64(scrollFrames)))"
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

    private static func stressDenseFiles(count: Int, linesPerFile: Int) -> [GitFileDiff] {
        (0..<count).map { fileIndex in
            let lines = (0..<linesPerFile).map { lineIndex in
                let number = lineIndex + 1
                let kind: GitDiffLine.Kind = switch lineIndex % 5 {
                case 0: .removed
                case 1: .added
                default: .context
                }
                return GitDiffLine(
                    kind: kind,
                    text: "let generatedValue\(lineIndex) = Feature\(fileIndex).value + \(lineIndex)",
                    oldNumber: kind == .added ? nil : number,
                    newNumber: kind == .removed ? nil : number
                )
            }
            return GitFileDiff(
                path: "Sources/Generated/Feature\(fileIndex)/DenseChangedFile\(fileIndex).swift",
                change: .modified,
                hunks: [GitHunk(header: "@@ -1,\(linesPerFile) +1,\(linesPerFile) @@", lines: lines)],
                added: lines.lazy.filter { $0.kind == .added }.count,
                removed: lines.lazy.filter { $0.kind == .removed }.count
            )
        }
    }

    private static func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        for child in root.subviews {
            if let match = child as? View { return match }
            if let match = firstDescendant(of: type, in: child) { return match }
        }
        return nil
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
