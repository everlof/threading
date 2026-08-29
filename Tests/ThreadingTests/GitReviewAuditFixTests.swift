import AppKit
import XCTest
@testable import Threading

/// Regressions for the 2026-08-27 Review pane audit: each test names the papercut it pins.
@MainActor
final class GitReviewAuditFixTests: XCTestCase {

    private let fixture = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    index 1111111..2222222 100644
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -1,4 +1,4 @@
     context
    -old line
    +new line
    -older
    +newer
     tail
    """

    private var lines: [GitDiffLine] {
        GitDiffParser.files(fromUnifiedDiff: fixture).first?.hunks.flatMap(\.lines) ?? []
    }

    private func hostedDiffView() -> (view: GitReviewDiffTextView, window: NSWindow) {
        let view = GitReviewDiffTextView(gitLines: lines, displayCap: 100, path: "Sources/Foo.swift")
        view.onAddContextAttachment = { _ in }
        view.onRequestComment = { _, _ in }
        // Built, never shown — see the fixture-window rule in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = window.contentView!
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)
        return (view, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        )!
    }

    // MARK: - The comment sheet

    /// R1: a question is not a warning.
    func testTextPromptsAreInformationalNotWarnings() {
        let reference = ConversationContextAttachment(
            kind: .reference, source: .code, title: "Sources/Foo.swift:2",
            excerpt: "new line", locator: "Sources/Foo.swift", lineStart: 2, lineEnd: 2
        )
        let request = ContextCommentAlert.makeRequest(for: reference, preview: nil)
        let alert = TextPromptAlert.makeAlert(
            request,
            field: ThemedTextField(frame: NSRect(origin: .zero, size: request.fieldSize))
        )
        XCTAssertEqual(alert.alertStyle, .informational)
    }

    /// R2: the sheet trims neighbours before it trims the selection.
    func testPreviewShedsContextBeforeSelectedLines() throws {
        let preview = try XCTUnwrap(CodeContextPreview.make(totalLineCount: 20, target: 3...9) {
            CodeContextPreview.SourceLine(number: $0, change: .context, text: "line \($0)")
        })
        let rows = preview.rows.compactMap { row -> (Int?, Bool)? in
            guard case .line(let line, let isTarget) = row else { return nil }
            return (line.number, isTarget)
        }
        XCTAssertEqual(rows.count, 10, "ten code rows, no omission row")
        XCTAssertEqual(rows.count, preview.rows.count)
        XCTAssertEqual(rows.filter(\.1).map(\.0), Array(3...9), "every selected line is shown")
        XCTAssertEqual(rows.map(\.0), Array(1...10), "two neighbours above, one below")

        let exact = try XCTUnwrap(CodeContextPreview.make(totalLineCount: 20, target: 5...14) {
            CodeContextPreview.SourceLine(number: $0, change: .context, text: "line \($0)")
        })
        XCTAssertEqual(exact.rows.count, 10)
        XCTAssertTrue(exact.rows.allSatisfy {
            if case .line(_, true) = $0 { return true }
            return false
        }, "a selection that fills the sheet shows only itself")
    }

    /// R2: "1 more lines" is not a sentence.
    func testOmissionRowIsSingularForOneLine() throws {
        let preview = try XCTUnwrap(CodeContextPreview.make(totalLineCount: 11, target: 0...10) {
            CodeContextPreview.SourceLine(number: $0, change: .context, text: "line \($0)")
        })
        XCTAssertTrue(preview.rows.contains(.omission(1)))
        let view = CodeContextPreviewView(preview: preview)
        let labels = view.subviews.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("1 more line is not shown."), "\(labels)")
    }

    // MARK: - Line actions

    /// R3: the plate answers for the selection it sits in, exactly as a right-click does.
    func testPlateClickInsideASelectionKeepsTheWholeSpan() throws {
        let (view, _) = hostedDiffView()
        view.highlightLines(1...3)
        let plate = try XCTUnwrap(view.lineActionRectForTesting(atDisplayedLine: 2))
        let point = NSPoint(x: plate.midX, y: plate.midY)
        view.mouseMoved(with: mouse(.mouseMoved, at: point, in: view))
        XCTAssertEqual(view.hoveredLineIndex, 2)
        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))

        let selected = (view.string as NSString).substring(with: view.selectedRange())
        XCTAssertTrue(selected.contains("old line"))
        XCTAssertTrue(selected.contains("new line"))
        XCTAssertTrue(selected.contains("older"))
        XCTAssertFalse(selected.contains("context"))
        XCTAssertFalse(selected.contains("newer"))
        view.dismissContextMenuForTesting()
    }

    /// R6: a cancelled menu gives the selection back.
    func testCancellingTheLineMenuRestoresThePreviousSelection() throws {
        let (view, _) = hostedDiffView()
        let word = (view.string as NSString).range(of: "context")
        view.setSelectedRange(word)
        let outside = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 4))
        view.rightMouseDown(with: mouse(.rightMouseDown, at: NSPoint(x: 200, y: outside.midY), in: view))
        XCTAssertNotEqual(view.selectedRange(), word, "the menu lights the clicked line")

        view.dismissContextMenuForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.selectedRange(), word)
    }

    /// R7: what leaves on the pasteboard is source, not the gutter.
    func testCopyingASelectionDropsTheNumberAndSignPrefix() {
        let (view, _) = hostedDiffView()
        view.highlightLines(0...2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitReviewAuditFixTests"))
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "context\nold line\nnew line")
        XCTAssertEqual(view.selectedSourceText(), "context\nold line\nnew line")
    }

    /// R5: the plate has a gutter of its own before the numbers.
    func testThePlateSitsInItsOwnGutterBeforeTheNumberColumn() throws {
        let (view, _) = hostedDiffView()
        let plate = try XCTUnwrap(view.lineActionRectForTesting(atDisplayedLine: 1))
        XCTAssertLessThanOrEqual(plate.maxX, GitReviewDefaults.lineActionGutterWidth + 0.5)
        XCTAssertGreaterThanOrEqual(plate.minX, 0)
    }

    // MARK: - The pane

    private func pane(
        width: CGFloat,
        mode: GitReviewMode = .uncommitted,
        files: [GitFileDiff]? = nil,
        configure: ((GitReviewViewController) -> Void)? = nil
    ) -> GitReviewViewController {
        let controller = GitReviewViewController(
            sessionID: SessionID(), folderPath: NSTemporaryDirectory(), mode: mode
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        configure?(controller)
        controller.show(.files(files ?? GitDiffParser.files(fromUnifiedDiff: fixture)))
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func firstRow(_ controller: GitReviewViewController, _ index: Int = 0) -> GitReviewFileRow? {
        controller.view.layoutSubtreeIfNeeded()
        return controller.fileTableView.view(atColumn: 0, row: index, makeIfNecessary: true)?
            .subviews.first as? GitReviewFileRow
    }

    private func gitLine(_ kind: GitDiffLine.Kind, _ text: String, _ old: Int?, _ new: Int?) -> GitDiffLine {
        GitDiffLine(kind: kind, text: text, oldNumber: old, newNumber: new)
    }

    /// Two hunks with unmodified lines before, between and after them.
    private var twoHunkFile: GitFileDiff {
        GitFileDiff(path: "Sources/Two.swift", change: .modified, hunks: [
            GitHunk(header: "@@ -12,4 +12,4 @@", lines: [
                gitLine(.context, "a", 12, 12), gitLine(.removed, "b", 13, nil),
                gitLine(.added, "c", nil, 13), gitLine(.context, "d", 14, 14),
                gitLine(.context, "e", 15, 15),
            ]),
            GitHunk(header: "@@ -90,5 +90,5 @@", lines: [
                gitLine(.context, "f", 90, 90), gitLine(.added, "g", nil, 91),
                gitLine(.context, "h", 91, 92), gitLine(.context, "i", 92, 93),
                gitLine(.context, "j", 93, 94),
            ]),
        ], added: 2, removed: 1)
    }

    private var hugeFile: GitFileDiff {
        let lines = (0..<460).map { index -> GitDiffLine in
            let number = index + 1
            let kind: GitDiffLine.Kind = index % 4 == 0 ? .added : (index % 4 == 1 ? .removed : .context)
            return gitLine(kind, "let generatedValue\(index) = \(index)",
                           kind == .added ? nil : number, kind == .removed ? nil : number)
        }
        return GitFileDiff(path: "Sources/Generated/Huge.swift", change: .modified,
                           hunks: [GitHunk(header: "@@ -1,460 +1,460 @@", lines: lines)], added: 115, removed: 115)
    }

    /// R8: a bulk toggle reloads from estimates, not from the heights of the state it left.
    func testCollapseAllDropsExactHeightsBeforeReloading() throws {
        let controller = pane(width: 720)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.measuredFileRowHeights.isEmpty, "the visible row was measured")
        let expandedHeight = controller.tableView(controller.fileTableView, heightOfRow: 0)

        let collapse = try XCTUnwrap(controller.overflowMenuEntries().compactMap { entry -> ThemedMenuItem? in
            guard case .item(let item) = entry, item.title == L10n.string("Collapse all diffs") else { return nil }
            return item
        }.first)
        collapse.onChoose?()

        XCTAssertTrue(controller.measuredFileRowHeights.isEmpty)
        XCTAssertLessThan(
            controller.tableView(controller.fileTableView, heightOfRow: 0),
            expandedHeight / 2,
            "the first layout after the toggle already uses the collapsed estimate"
        )
    }

    /// R12: the totals never wrap, however narrow the pane.
    func testHeaderTotalsStayOnOneLineInANarrowPane() {
        let controller = pane(width: 360)
        XCTAssertTrue(controller.counterLabel.usesSingleLineMode)
        XCTAssertLessThanOrEqual(controller.counterLabel.frame.height, 24)
    }

    /// R12/R13: a narrow header folds its glyph runs into the ··· menu rather than over the totals.
    func testNarrowHeaderFoldsItsGlyphRunsIntoTheOverflowMenu() {
        let narrow = pane(width: 360)
        XCTAssertTrue(narrow.textSizeButtonGroup.isHidden)
        XCTAssertTrue(narrow.navigationButtonGroup.isHidden)
        let narrowTitles = narrow.overflowMenuEntries().compactMap { entry -> String? in
            guard case .item(let item) = entry else { return nil }
            return item.title
        }
        XCTAssertTrue(narrowTitles.contains(L10n.string("Jump to file")), "\(narrowTitles)")
        XCTAssertTrue(narrowTitles.contains(L10n.string("Increase diff text size")), "\(narrowTitles)")

        let wide = pane(width: 720)
        XCTAssertFalse(wide.textSizeButtonGroup.isHidden)
        XCTAssertFalse(wide.navigationButtonGroup.isHidden)
        let wideTitles = wide.overflowMenuEntries().compactMap { entry -> String? in
            guard case .item(let item) = entry else { return nil }
            return item.title
        }
        XCTAssertFalse(wideTitles.contains(L10n.string("Jump to file")))
    }

    /// R15: five switches, one convention.
    func testOverflowSwitchesAreCheckedStatesNotVerbs() {
        let controller = pane(width: 720)
        let items = controller.overflowMenuEntries().compactMap { entry -> ThemedMenuItem? in
            guard case .item(let item) = entry else { return nil }
            return item
        }
        let wrap = items.first { $0.title == L10n.string("Word wrap") }
        XCTAssertNotNil(wrap)
        XCTAssertEqual(wrap?.isSelected, true)
        XCTAssertFalse(items.contains { $0.title.hasPrefix("Disable") || $0.title.hasPrefix("Enable") })
    }

    // MARK: - PR strip and history

    /// R28: the number and title survive a narrow pane.
    func testChangeRequestTitleSurvivesANarrowPane() throws {
        let bar = GitReviewChangeRequestBar()
        bar.setProvider(.github)
        bar.configure(
            title: "#4821 · Give the review pane one clean margin and fix hunk contrast",
            detail: "feature/review-audit → master · Draft · 2 reviewers requested",
            status: "3 checks pending",
            statusColor: Design.Status.warning,
            actionTitle: "Push update",
            actionEnabled: true,
            showsOpen: true,
            policy: .reviewBeforePublishing
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 54))
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 420),
            host.heightAnchor.constraint(equalToConstant: 54),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let title = try XCTUnwrap(descendants(bar).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("#4821") })
        XCTAssertGreaterThan(title.frame.width, 120, "the PR number and title were squeezed out")
    }

    /// R29: a read in progress is copy, not a disabled primary button.
    func testLoadingChangeRequestShowsNoDisabledAction() {
        let bar = GitReviewChangeRequestBar()
        bar.setProvider(.github)
        bar.showLoading(branch: "feature/x")
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let loading = descendants(bar).compactMap { $0 as? ThemedButton }
            .first { $0.title == L10n.string("Loading…") }
        XCTAssertNil(loading)
    }

    /// R30: a commit made this second is "now", never "in 0 sec".
    func testAFreshCommitReadsAsNow() {
        let now = Date()
        let ahead = GitReviewCommitRow.relativeDescription(for: now.addingTimeInterval(2), relativeTo: now)
        let fresh = GitReviewCommitRow.relativeDescription(for: now, relativeTo: now)
        for text in [ahead, fresh] {
            XCTAssertFalse(text.hasPrefix("in "), text)
            XCTAssertFalse(text.contains("0 sec"), text)
        }
    }

    // MARK: - Round two

    /// R11: only the control that was pressed reports the read in progress.
    func testOnlyThePressedContextControlSaysExpanding() {
        let row = GitReviewFileRow(
            file: twoHunkFile, expanded: true, contextExpansionPendingSite: .between(1)
        )
        let titles = descendants(row).compactMap { ($0 as? ThemedButton)?.title }
        XCTAssertEqual(titles.filter { $0 == L10n.string("Expanding…") }.count, 1, "\(titles)")
        XCTAssertTrue(titles.contains { $0.contains(L10n.string("Show earlier unmodified lines")) })
        XCTAssertTrue(titles.contains { $0.contains(L10n.string("Show later unmodified lines")) })
    }

    /// R14: the file count stays beside the totals once they arrive.
    func testHeaderKeepsTheFileCountBesideTheTotals() {
        let controller = pane(width: 720)
        XCTAssertTrue(
            controller.counterLabel.stringValue.hasPrefix(
                L10n.string("1 file") + GitReviewUIDefaults.subtitleSeparator
            ),
            controller.counterLabel.stringValue
        )
    }

    /// R19: the header's one-press action opens the file in an editor; Finder stays in the menu.
    func testHeaderHoverOffersOpenInEditorNotFinder() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let url = URL(fileURLWithPath: "/tmp/Sources/Foo.swift")
        let row = GitReviewFileRow(file: file, expanded: false, fileURL: url)
        var opened: ExternalAppTarget?
        row.openInEditorHandler = { target, _ in opened = target }
        let buttons = row.subviews.compactMap { $0 as? ThemedIconButton }
        let open = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier() == "git-review.file.open-in-editor"
        })
        XCTAssertNil(buttons.first { $0.accessibilityIdentifier() == "git-review.file.reveal-in-finder" })
        XCTAssertTrue(open.performPrimaryAction())
        XCTAssertEqual(opened?.url, url)
    }

    /// R22: a split choice in a narrow pane shows unified, and returns with the room.
    func testSplitFallsBackToUnifiedInANarrowPane() {
        let narrow = pane(width: 520, configure: { $0.diffLayout = .split })
        XCTAssertEqual(narrow.effectiveDiffLayout, .unified)
        XCTAssertTrue(descendants(narrow.view).contains { $0 is GitReviewDiffTextView })
        XCTAssertFalse(descendants(narrow.view).contains { $0 is GitReviewSplitDiffView })

        let wide = pane(width: 900, configure: { $0.diffLayout = .split })
        XCTAssertEqual(wide.effectiveDiffLayout, .split)
        XCTAssertTrue(descendants(wide.view).contains { $0 is GitReviewSplitDiffView })
    }

    /// R23: the cap ends in a control, and pressing it shows the next page of the file.
    func testTheCapOffersTheRemainingLines() throws {
        let huge = hugeFile
        let controller = pane(width: 720, files: [huge])
        let row = try XCTUnwrap(firstRow(controller))
        let title = L10n.format("Show the remaining %lld lines", Int64(60))
        let button = try XCTUnwrap(descendants(row).compactMap { $0 as? ThemedButton }.first { $0.title == title })
        XCTAssertFalse(descendants(row).compactMap { $0 as? GitReviewDiffTextView }
            .contains { $0.string.contains("generatedValue459") })

        XCTAssertTrue(button.performPrimaryAction())
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.displayCapByPath[huge.path], GitReviewDefaults.fileDisplayCap * 2)
        let reloaded = try XCTUnwrap(firstRow(controller))
        XCTAssertTrue(descendants(reloaded).compactMap { $0 as? GitReviewDiffTextView }
            .contains { $0.string.contains("generatedValue459") })
        XCTAssertNil(descendants(reloaded).compactMap { $0 as? ThemedButton }.first { $0.title == title })
    }

    /// R24: a write error stands across refreshes until dismissed; a success line is one-shot.
    func testWriteErrorsPersistAcrossRefreshesUntilDismissed() throws {
        let controller = pane(width: 720)
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        controller.notice = ("The index is locked by another git process. Try again.", true)
        controller.show(.files(files))
        XCTAssertNotNil(controller.notice)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.filePreludeViews.count, 1)
        let notice = try XCTUnwrap(controller.filePreludeViews.first as? PaneNoticeView)

        XCTAssertTrue(try XCTUnwrap(notice.dismissControl).performPrimaryAction())
        XCTAssertNil(controller.notice)
        XCTAssertTrue(controller.filePreludeViews.isEmpty)

        controller.notice = ("Committed: something", false)
        controller.show(.files(files))
        XCTAssertNil(controller.notice, "a success line does not outlive its render")
    }

    /// R26: single-child directory chains fold into one row.
    func testNavigatorFoldsSingleChildDirectoryChains() {
        let navigator = GitReviewPathNavigatorViewController(rootURL: URL(fileURLWithPath: "/tmp"))
        navigator.update(files: [
            GitFileDiff(path: "Sources/Threading/Core/Agent/Runner.swift", change: .modified, hunks: [], added: 1, removed: 0),
            GitFileDiff(path: "Sources/Threading/UI/Views/Row.swift", change: .modified, hunks: [], added: 1, removed: 0),
        ])
        XCTAssertEqual(navigator.rootPathsForTesting, ["Sources/Threading"])
    }

    /// R27: the number column widens for long files, once per file.
    func testNumberColumnWidensForLongFiles() {
        let short = GitFileDiff(path: "a.swift", change: .modified, hunks: [
            GitHunk(header: "@@", lines: [gitLine(.context, "x", 1, 1)])
        ], added: 0, removed: 0)
        let long = GitFileDiff(path: "b.swift", change: .modified, hunks: [
            GitHunk(header: "@@", lines: [gitLine(.context, "x", 123_456, 123_456)])
        ], added: 0, removed: 0)
        let shortColumns = GitReviewFileRow.numberColumns(for: short, textSize: .standard)
        let longColumns = GitReviewFileRow.numberColumns(for: long, textSize: .standard)
        XCTAssertGreaterThanOrEqual(longColumns, 6)
        XCTAssertGreaterThan(longColumns, shortColumns)
    }

    /// R31: an opened commit names its author and age, not only its hash.
    func testCommitDetailHeaderCarriesAuthorAndAge() throws {
        let commit = GitCommitSummary(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Fix the thing", author: "David Everlöf", date: Date(),
            added: 1, removed: 1, parents: [], refs: ["HEAD"]
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(), folderPath: NSTemporaryDirectory(), mode: .commit
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        controller.show(.commitDetail(commit, GitDiffParser.files(fromUnifiedDiff: fixture)))
        controller.view.layoutSubtreeIfNeeded()
        _ = controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let byline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "git-review.commit.byline" })
        XCTAssertTrue(byline.stringValue.contains("David Everlöf"), byline.stringValue)
        XCTAssertTrue(byline.stringValue.contains("aaaaaaa"))
        XCTAssertTrue(byline.stringValue.contains("HEAD"))
    }

    // MARK: - Find

    /// ⌘F: revealing the first match must not select the query, or the second keystroke
    /// replaces the first.
    func testTypingIntoFindKeepsTheCaretAfterTheFirstMatchIsRevealed() throws {
        let controller = GitReviewViewController(
            sessionID: SessionID(), folderPath: NSTemporaryDirectory(), mode: .uncommitted
        )
        // Built, never shown — see the fixture-window rule in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = window.contentView!
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        window.layoutIfNeeded()
        controller.show(.files(GitDiffParser.files(fromUnifiedDiff: fixture)))
        controller.view.layoutSubtreeIfNeeded()

        controller.showFind()
        let field = controller.findBar.queryField
        XCTAssertNotNil(field.currentEditor(), "the bar took the keyboard")

        // The first keystroke, as the field reports it.
        field.stringValue = "c"
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 1, length: 0)
        }
        controller.findBar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        let deadline = Date().addingTimeInterval(3)
        while controller.findMatches.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(controller.findMatches.isEmpty, "the fixture contains “context”")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(window.firstResponder === editor, "the keyboard stayed in the field")
        XCTAssertEqual(editor.selectedRange.length, 0, "the query is not selected after a reveal")
        XCTAssertEqual(editor.selectedRange.location, 1)
        XCTAssertEqual(field.stringValue, "c")
    }
}
