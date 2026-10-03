import AppKit
import XCTest
@testable import Threading

final class MarkdownEditorFileTests: XCTestCase {
    func testUTF8RoundTripAndExternalEditCannotBeOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        let worker = MarkdownEditorFileStore()
        let original = "# Notes\n\nHej 👋\n"
        let baseline = try await worker.save(original, to: url, baseline: nil)
        let opened = try await worker.read(url)
        XCTAssertEqual(opened.text, original)
        let saved = try await worker.save(original + "Edited\n", to: url, baseline: baseline)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try Data("External edit".utf8).write(to: url)
        do {
            _ = try await worker.save("My edit", to: url, baseline: saved)
            XCTFail("An external edit was overwritten")
        } catch MarkdownEditorFileStore.Failure.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "External edit")
        let copy = directory.appendingPathComponent("copy.md")
        _ = try await worker.save("My edit", to: copy, baseline: nil)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "My edit")
    }

    func testInvalidEncodingAndOversizeFilesAreRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let worker = MarkdownEditorFileStore()
        try Data([0xFF, 0xFE]).write(to: url)
        do {
            _ = try await worker.read(url)
            XCTFail("Invalid UTF-8 was accepted")
        } catch MarkdownEditorFileStore.Failure.invalidUTF8 {}
        try Data(repeating: 0x61, count: MarkdownEditorFileStore.maximumBytes + 1).write(to: url)
        do {
            _ = try await worker.read(url)
            XCTFail("An unbounded file was accepted")
        } catch MarkdownEditorFileStore.Failure.tooLarge {}
    }
}

@MainActor
final class MarkdownEditorTests: XCTestCase {
    func testEmptyEditorFillsItsViewportAndResizesWithoutChangingTheWindow() throws {
        let controller = MarkdownEditorWindowController()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let source = controller.editor.sourceScroll
        XCTAssertGreaterThanOrEqual(source.textView.frame.height, source.contentView.bounds.height)
        window.setContentSize(NSSize(width: 800, height: 520))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.bounds.width, 800, accuracy: 1)
        XCTAssertEqual(root.bounds.height, 520, accuracy: 1)
        controller.editor.splitView.setPosition(300, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.editor.splitView.subviews[0].frame.width, 300, accuracy: 1)
    }
    func testSplitEditorUsesNativeRendererAndTracksUndo() async throws {
        let controller = MarkdownEditorWindowController()
        controller.editor.sourceScroll.textView.insertText("# Heading\n", replacementRange: NSRange(location: 0, length: 0))
        await controller.editor.waitForPreview()
        XCTAssertTrue(controller.isDirty)
        XCTAssertTrue(controller.window?.isDocumentEdited == true)
        XCTAssertTrue(controller.editor.splitView.isVertical)
        XCTAssertTrue(controller.editor.splitView.isDescendant(of: controller.editor.view))
        XCTAssertEqual(controller.editor.splitView.arrangedSubviews.count, 2)
        XCTAssertTrue(descendants(controller.editor.previewScroll).contains { $0 is MarkdownView })
        controller.editor.sourceScroll.textView.undoManager?.undo()
        XCTAssertEqual(controller.editor.source, "")
        XCTAssertFalse(controller.isDirty)
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: try XCTUnwrap(controller.window)).isEmpty)
    }

    func testPreviewPreparationAndThemeChangeKeepTheSourceAndSelection() async throws {
        let controller = MarkdownEditorWindowController()
        controller.editor.setSource(MarkdownEditorRenderTests.fixture)
        let textView = controller.editor.sourceScroll.textView
        textView.setSelectedRange(NSRange(location: 2, length: 7))
        await controller.editor.waitForPreview()
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(try XCTUnwrap(controller.window?.contentView))
        XCTAssertEqual(textView.string, MarkdownEditorRenderTests.fixture)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 7))
        XCTAssertTrue(descendants(controller.editor.previewScroll).contains { $0 is MarkdownView })
    }

    func testLargeBlockPausesPreviewWithoutDroppingSource() async {
        let controller = MarkdownEditorViewController()
        let source = String(repeating: "a", count: MarkdownEditorDefaults.maximumPreviewBlockBytes + 1)
        controller.setSource(source)
        await controller.waitForPreview()
        XCTAssertEqual(controller.source, source)
        XCTAssertFalse(descendants(controller.previewScroll).contains { $0 is MarkdownView })
    }

    /// A README longer than one bounded page must not snap the preview back to its first page
    /// on every keystroke, and a theme change must not either.
    func testPreviewFollowsTheEditedPageAndKeepsItAcrossThemeChanges() async throws {
        let controller = MarkdownEditorWindowController()
        let source = (1...200).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        controller.editor.setSource(source)
        await controller.editor.waitForPreview()
        XCTAssertEqual(controller.editor.renderedPreview?.currentPage, 0)
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        text.insertText(" edited", replacementRange: text.selectedRange())
        await controller.editor.waitForPreview()
        let lastPage = MarkdownView.preparePages(controller.editor.source).count - 1
        XCTAssertGreaterThan(lastPage, 0)
        XCTAssertEqual(controller.editor.renderedPreview?.currentPage, lastPage)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeID.system))
        await Task.yield()
        XCTAssertEqual(controller.editor.renderedPreview?.currentPage, lastPage)
    }

    /// The standalone document sets heading levels apart; a chat answer keeps its single step.
    func testDocumentPreviewSetsHeadingLevelsApart() async throws {
        let controller = MarkdownEditorViewController()
        let source = "# Title\n\n## Section\n\n### Detail\n\nBody"
        controller.setSource(source)
        await controller.waitForPreview()
        let document = fontSizes(in: controller.previewScroll)
        let title = try XCTUnwrap(document["Title"]), section = try XCTUnwrap(document["Section"])
        let detail = try XCTUnwrap(document["Detail"]), body = try XCTUnwrap(document["Body"])
        XCTAssertGreaterThan(title, section)
        XCTAssertGreaterThan(section, detail)
        XCTAssertGreaterThan(detail, body)
        let conversation = fontSizes(in: MarkdownView(markdown: source))
        XCTAssertEqual(conversation["Title"], conversation["Detail"])
    }

    func testWordCountIgnoresMarkdownMarksAndEmptyDocumentsInvite() async throws {
        let controller = MarkdownEditorViewController()
        controller.setSource("# Title\n\n- one *two*\n\n| a | b |\n| --- | --- |\n\n```\nlet x = 1\n```\n")
        await controller.waitForPreview()
        XCTAssertEqual(controller.wordCount.stringValue, L10n.format("%lld words", Int64(8)))
        controller.setSource("  \n")
        await controller.waitForPreview()
        XCTAssertNil(controller.renderedPreview)
        XCTAssertTrue(descendants(controller.previewScroll).contains {
            ($0 as? NSTextField)?.stringValue == L10n.string("Start writing to see the preview.")
        })
    }

    func testSourceMarksRecedeWithoutTouchingTextOrUndo() throws {
        let highlighter = MarkdownSourceHighlighter()
        XCTAssertEqual(highlighter.marks(in: "## Title"), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(highlighter.marks(in: "- **bold** and `code`"), [
            NSRange(location: 0, length: 1), NSRange(location: 2, length: 2), NSRange(location: 8, length: 2),
            NSRange(location: 15, length: 1), NSRange(location: 20, length: 1)
        ])
        XCTAssertEqual(highlighter.marks(in: "```swift"), [NSRange(location: 0, length: 8)])
        XCTAssertEqual(highlighter.marks(in: "| --- | :-: |"), [NSRange(location: 0, length: 13)])
        XCTAssertEqual(highlighter.marks(in: "See [docs](https://x.y) now"), [
            NSRange(location: 4, length: 1), NSRange(location: 9, length: 14)
        ])
        XCTAssertEqual(highlighter.marks(in: "snake_case #tag"), [])

        let controller = MarkdownEditorWindowController()
        controller.editor.setSource("# Title\n\nBody")
        let text = controller.editor.sourceScroll.textView
        let storage = try XCTUnwrap(text.textStorage)
        func ink(_ location: Int) -> NSColor? {
            storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        }
        XCTAssertNotEqual(ink(0), ink(2), "A heading's hashes recede from its words")
        text.setSelectedRange(NSRange(location: 9, length: 0))
        text.insertText("## ", replacementRange: text.selectedRange())
        XCTAssertEqual(ink(9), ink(0))
        XCTAssertEqual(ink(12), ink(2))
        AppThemeRefresh.repaint(try XCTUnwrap(controller.window?.contentView))
        XCTAssertEqual(ink(9), ink(0), "A theme repaint keeps the tint")
        text.undoManager?.undo()
        XCTAssertEqual(controller.editor.source, "# Title\n\nBody")
        XCTAssertEqual(ink(9), ink(2))
    }

    /// A large document tints its opening synchronously and the rest in bounded slices, and an
    /// edit made before the slices finish moves the remainder with it.
    func testLargeSourceTintsInBoundedSlices() async throws {
        let controller = MarkdownEditorWindowController()
        let line = "- item with **bold** text\n"
        let source = String(repeating: line, count: 2 * MarkdownSourceHighlighter.chunkLength / line.utf16.count)
        let started = ContinuousClock.now
        controller.editor.setSource(source)
        let loaded = started.duration(to: .now)
        let highlighter = controller.editor.highlighter
        let storage = try XCTUnwrap(controller.editor.sourceScroll.textView.textStorage)
        let pending = try XCTUnwrap(highlighter.untintedLocation)
        XCTAssertGreaterThanOrEqual(pending, MarkdownSourceHighlighter.chunkLength)
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.insertText("# ", replacementRange: text.selectedRange())
        XCTAssertEqual(highlighter.untintedLocation, pending + 2)
        await highlighter.waitUntilTinted()
        XCTAssertNil(highlighter.untintedLocation)
        let mark = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let lastBullet = storage.length - line.utf16.count
        XCTAssertEqual(storage.attribute(.foregroundColor, at: lastBullet, effectiveRange: nil) as? NSColor, mark)
        print("MARKDOWN_TINT bytes=\(source.utf8.count) load=\(loaded)")
    }

    func testMarkdownRoutingAndOptInBundleDeclaration() throws {
        XCTAssertTrue(MarkdownFileAssociation.accepts(URL(fileURLWithPath: "/tmp/NOTE.MD")))
        XCTAssertTrue(MarkdownFileAssociation.accepts(URL(fileURLWithPath: "/tmp/note.mc")))
        XCTAssertFalse(MarkdownFileAssociation.accepts(URL(fileURLWithPath: "/tmp/source.swift")))
        XCTAssertFalse(MarkdownFileAssociation.accepts(URL(string: "https://example.com/note.md")!))
        let documentTypes = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let markdown = try XCTUnwrap(documentTypes.first { ($0["LSItemContentTypes"] as? [String])?.contains(MarkdownFileAssociation.typeIdentifier) == true })
        XCTAssertEqual(markdown["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(markdown["CFBundleTypeRole"] as? String, "Editor")
    }

    func testStressPreviewKeepsOnlyOneBoundedNativePage() async throws {
        let controller = MarkdownEditorWindowController()
        let paragraph = "## A note\n\nOne paragraph with **emphasis** and `code`.\n\n"
        let source = String(repeating: paragraph, count: 10_000)
        XCTAssertLessThan(source.utf8.count, MarkdownEditorFileStore.maximumBytes)
        let started = ContinuousClock.now
        controller.editor.setSource(source)
        await controller.editor.waitForPreview()
        let preparedAndMounted = started.duration(to: .now)
        let root = try XCTUnwrap(controller.window?.contentView)
        let layoutStarted = ContinuousClock.now
        root.layoutSubtreeIfNeeded()
        let laidOut = layoutStarted.duration(to: .now)
        let liveViews = descendants(controller.editor.previewScroll).count
        XCTAssertLessThan(liveViews, 600, "A document-sized AppKit tree was constructed")
        XCTAssertEqual(controller.editor.source, source)
        print("MARKDOWN_STRESS bytes=\(source.utf8.count) blocks=20000 preparation=\(controller.editor.previewPreparationDuration) mount=\(controller.editor.previewMountDuration) total=\(preparedAndMounted) layout=\(laidOut) preview_views=\(liveViews)")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func fontSizes(in view: NSView) -> [String: CGFloat] {
        var sizes: [String: CGFloat] = [:]
        for case let field as NSTextField in descendants(view) where field.attributedStringValue.length > 0 {
            let font = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            sizes[field.stringValue] = font?.pointSize
        }
        return sizes
    }
}

@MainActor
final class MarkdownEditorRenderTests: XCTestCase {
    static let fixture = """
        # A place to think

        Write in **Markdown**, read it in *Threading*.

        ## Today's notes

        - Keep the source close to the result
        - Give the words room to breathe
        - Use the same native rendering as our chats

        > A small window for ideas that are still taking shape.

        | Part | Purpose |
        | --- | --- |
        | Source | Plain text, with undo |
        | Preview | Native Markdown, live |

        ```swift
        let thought = "Hello, world"
        print(thought)
        ```

        Save with `⌘S` when you're ready.
        """

    func testRendersEditorInShippingWindow() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("win98", AppThemeStyles.win98, .aqua)
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let controller = MarkdownEditorWindowController()
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance)
            controller.editor.setSource(Self.fixture)
            await controller.editor.waitForPreview()
            let root = try XCTUnwrap(window.contentView)
            window.appearance?.performAsCurrentDrawingAppearance {
                AppThemeRefresh.repaint(root)
                root.layoutSubtreeIfNeeded()
            }
            let split = controller.editor.splitView
            XCTAssertGreaterThan(split.subviews[0].frame.width, MarkdownEditorDefaults.paneMinimum)
            XCTAssertGreaterThan(split.subviews[1].frame.width, MarkdownEditorDefaults.paneMinimum)
            XCTAssertEqual(split.subviews[0].frame.width, split.subviews[1].frame.width, accuracy: 1)
            XCTAssertEqual(root.bounds.width, MarkdownEditorDefaults.windowSize.width, accuracy: 1)
            for scroll in scrollViews(in: controller.editor.previewScroll) where scroll.hasHorizontalScroller && !scroll.hasVerticalScroller {
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height + 1, document.frame.height,
                                            "A horizontal block hides its last row behind scrollbar chrome")
                for case let field as NSTextField in document.subviews {
                    XCTAssertGreaterThanOrEqual(field.frame.height + 1, field.intrinsicContentSize.height,
                                                "The code block clips a source line")
                }
            }
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            window.appearance?.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("markdown-editor-\(name).png"))

            // The standing notice a file changed on disk under unsaved edits puts in the source pane.
            controller.editor.showNotice(PaneNoticeView(
                tone: .attention,
                message: L10n.format("“%@” changed on disk. Reload it, or keep editing — saving will ask before replacing it.", "README.md"),
                actions: [PaneNoticeAction(title: L10n.string("Reload")) {}],
                onDismiss: {}
            ))
            window.appearance?.performAsCurrentDrawingAppearance {
                AppThemeRefresh.repaint(root)
                root.layoutSubtreeIfNeeded()
            }
            let notice = try XCTUnwrap(controller.editor.notice)
            let pane = try XCTUnwrap(controller.editor.sourceScroll.superview)
            let noticeFrame = notice.convert(notice.bounds, to: pane)
            XCTAssertGreaterThan(noticeFrame.height, 0)
            XCTAssertEqual(controller.editor.sourceScroll.frame.maxY, noticeFrame.minY, accuracy: 1,
                           "The notice is pushed into layout above the source, not drawn over it")
            let noticed = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            window.appearance?.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: noticed) }
            try XCTUnwrap(noticed.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("markdown-editor-notice-\(name).png"))
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
    }
}

@MainActor
final class MarkdownSettingsRenderTests: HostedStoreTestCase {
    func testRendersFileAssociationSettingsInShippingShell() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(.system)
        let shell = makeMainWindowController()
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1_100, height: 740))
        shell.showSettingsPage(id: SettingsPages.markdownID)
        let content = try XCTUnwrap(window.contentView)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            content.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            XCTAssertNotNil(SettingsRowAnchor.locate(title: L10n.string("Open .mc files in Threading"), in: content))
            XCTAssertTrue(ThemeBoundaryAudit.violations(in: content).isEmpty)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("markdown-settings-\(name).png"))
        }
    }
}

/// The file under an open document is shared with agents, git and other editors. These drive
/// the real watcher against real writes in a scratch folder.
@MainActor
final class MarkdownDocumentDiskTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnUneditedDocumentFollowsOutsideWritesAndUndoBringsTheLastOneBack() async throws {
        let (controller, url) = try await openDocument("# Plan\n\nFirst draft.\n")
        separateUndoSteps(controller)
        // An agent's save: a new inode under the same name.
        try Data("# Plan\n\nSecond draft.\n".utf8).write(to: url, options: .atomic)
        let followed = await eventually { controller.editor.source == "# Plan\n\nSecond draft.\n" }
        XCTAssertTrue(followed)
        XCTAssertFalse(controller.isDirty)
        // An in-place append after the inode changed is still seen.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("More.\n".utf8))
        try handle.close()
        let appended = await eventually { controller.editor.source.hasSuffix("More.\n") }
        XCTAssertTrue(appended)
        controller.editor.sourceScroll.textView.undoManager?.undo()
        XCTAssertEqual(controller.editor.source, "# Plan\n\nSecond draft.\n")
        XCTAssertTrue(controller.isDirty, "Undoing a reload is an edit against the file")
    }

    func testEditsAreKeptWhenTheFileChangesAndReloadIsUndoable() async throws {
        let (controller, url) = try await openDocument("Original\n")
        let undo = separateUndoSteps(controller)
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: 8, length: 0))
        undo.beginUndoGrouping()
        text.insertText(" mine", replacementRange: text.selectedRange())
        undo.endUndoGrouping()
        try Data("Theirs\n".utf8).write(to: url, options: .atomic)
        let noticed = await eventually { controller.editor.notice != nil }
        XCTAssertTrue(noticed)
        XCTAssertEqual(controller.editor.source, "Original mine\n")
        XCTAssertTrue(controller.isDirty)
        let reload = try XCTUnwrap(controller.editor.notice?.actionControls.first)
        XCTAssertEqual(reload.title, L10n.string("Reload"))
        reload.performClick()
        let reloaded = await eventually { controller.editor.source == "Theirs\n" }
        XCTAssertTrue(reloaded)
        XCTAssertFalse(controller.isDirty)
        XCTAssertNil(controller.editor.notice)
        text.undoManager?.undo()
        XCTAssertEqual(controller.editor.source, "Original mine\n")
    }

    func testOwnSavesAreNotMistakenForOutsideChanges() async throws {
        let (controller, _) = try await openDocument("A\n")
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: 1, length: 0))
        text.insertText(" B", replacementRange: text.selectedRange())
        let saved = await withCheckedContinuation { done in controller.save { done.resume(returning: $0) } }
        XCTAssertTrue(saved)
        try await Task.sleep(for: .milliseconds(600))
        await controller.waitForDiskCheck()
        XCTAssertNil(controller.editor.notice)
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.editor.source, "A B\n")
    }

    func testADeletedFileKeepsTheDocumentAndSaveWritesItBack() async throws {
        let (controller, url) = try await openDocument("Keep me\n")
        try FileManager.default.removeItem(at: url)
        let missing = await eventually { controller.fileIsMissing }
        XCTAssertTrue(missing)
        XCTAssertTrue(controller.isDirty, "Closing now would lose the only copy")
        XCTAssertNotNil(controller.editor.notice)
        let saved = await withCheckedContinuation { done in controller.save { done.resume(returning: $0) } }
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Keep me\n")
        XCTAssertFalse(controller.isDirty)
        XCTAssertNil(controller.editor.notice)
    }

    func testReplaceWritesOverAChangedFileOnlyWhenAsked() async throws {
        let (controller, url) = try await openDocument("Base\n")
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: 4, length: 0))
        text.insertText(" edit", replacementRange: text.selectedRange())
        try Data("Other\n".utf8).write(to: url, options: .atomic)
        do {
            _ = try await MarkdownEditorFileStore.shared.save(controller.editor.source, to: url, baseline: Data("Base\n".utf8))
            XCTFail("An ordinary save replaced a file that changed underneath it")
        } catch MarkdownEditorFileStore.Failure.changedOnDisk {}
        let replaced = await withCheckedContinuation { done in controller.replaceOnDisk { done.resume(returning: $0) } }
        XCTAssertTrue(replaced)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Base edit\n")
        XCTAssertFalse(controller.isDirty)
    }

    /// A quit or close pressed while a save is in flight waits for it: refusing made ⌘Q during
    /// a save do nothing at all.
    func testReviewDuringASaveWaitsForItInsteadOfRefusing() async throws {
        let (controller, _) = try await openDocument("A\n")
        let text = controller.editor.sourceScroll.textView
        text.setSelectedRange(NSRange(location: 1, length: 0))
        text.insertText("B", replacementRange: text.selectedRange())
        controller.save()
        XCTAssertTrue(controller.needsQuitReview)
        let mayClose = await withCheckedContinuation { done in
            controller.reviewUnsavedChanges { done.resume(returning: $0) }
        }
        XCTAssertTrue(mayClose)
        XCTAssertFalse(controller.isDirty)
    }

    private func openDocument(_ text: String) async throws -> (MarkdownEditorWindowController, URL) {
        let url = directory.appendingPathComponent("note.md")
        try Data(text.utf8).write(to: url)
        let contents = try await MarkdownEditorFileStore.shared.read(url)
        let controller = MarkdownEditorWindowController(url: url, contents: contents)
        // The watcher arms on its own queue; a write before it has looked would be its baseline.
        try await Task.sleep(for: .milliseconds(200))
        return (controller, contents.url)
    }

    /// A hosted test never ends a run-loop event, so every edit would share one undo group.
    /// Each step here is grouped explicitly instead, the way separate events group them.
    @discardableResult
    private func separateUndoSteps(_ controller: MarkdownEditorWindowController) -> UndoManager {
        let undo = controller.editor.sourceScroll.textView.undoManager!
        undo.groupsByEvent = false
        return undo
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// While a document is key the menu bar shows its keys, and the main window's commands on the
/// same chords show none; both come back when the document stops being key.
@MainActor
final class MarkdownDocumentShortcutTests: XCTestCase {
    func testTheMenuBarShowsTheKeyDocumentsShortcutsAndNoCompetingOnes() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }
        let delegate = AppDelegate()
        delegate.setupMenuBar()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let chords = Set(MarkdownEditorDefaults.documentShortcuts.values)

        delegate.applyShortcutBindings(documentIsKey: true)
        for (id, chord) in MarkdownEditorDefaults.documentShortcuts {
            let item = try XCTUnwrap(item(id, in: menu))
            let bound = ShortcutOverrideStore.shared.shortcut(forID: id) ?? chord
            XCTAssertEqual(item.keyEquivalent, bound.key, id)
            XCTAssertEqual(item.keyEquivalentModifierMask, bound.modifiers, id)
        }
        for item in allItems(in: menu) where !MarkdownEditorDefaults.documentShortcuts.keys.contains(item.representedObject as? String ?? "") {
            let shown = KeyboardShortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            XCTAssertFalse(chords.contains(shown), "\(item.title) still shows a document key")
        }

        delegate.applyShortcutBindings(documentIsKey: false)
        let sidebar = try XCTUnwrap(item(AppCommands.ID.toggleSidebar, in: menu))
        let sidebarChord = ShortcutOverrideStore.shared.shortcut(forID: AppCommands.ID.toggleSidebar)
        XCTAssertEqual(sidebar.keyEquivalent, sidebarChord?.key ?? "")
        let save = try XCTUnwrap(item(AppCommands.ID.saveMarkdown, in: menu))
        XCTAssertEqual(save.keyEquivalent, ShortcutOverrideStore.shared.shortcut(forID: AppCommands.ID.saveMarkdown)?.key ?? "")
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        allItems(in: menu).first { $0.representedObject as? String == id }
    }
}

/// Classic themes draw a real scroller track. A code block or table reserves room for one only
/// while its content is wider than the block; an always-reserved track was an empty trough.
@MainActor
final class MarkdownStripScrollerTests: XCTestCase {
    func testClassicScrollersTakeRoomOnlyWhileABlockOverflows() throws {
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.win98)

        let short = try codeBlock("let x = 1")
        XCTAssertEqual(short.strip, short.text, accuracy: 1, "A block that fits keeps no empty track")
        let wide = try codeBlock(String(repeating: "wide ", count: 120))
        XCTAssertGreaterThan(wide.strip, wide.text + 4, "A block that overflows keeps its last line clear of the track")

        func table(offered width: CGFloat) -> CGFloat {
            let cell = NSAttributedString(string: "cell")
            return ThemedDocumentTableView(
                headers: [cell, cell, cell], rows: [[cell, cell, cell]],
                alignments: [.left, .left, .left], availableWidth: width, minimumColumnWidth: 120
            ).intrinsicContentSize.height
        }
        XCTAssertGreaterThan(table(offered: 300), table(offered: 400) + 4, "Only the overflowing table reserves a track")
    }

    private func codeBlock(_ code: String) throws -> (strip: CGFloat, text: CGFloat) {
        let view = MarkdownView(markdown: "```\n\(code)\n```")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
        let strip = try XCTUnwrap(descendants(view).compactMap { $0 as? ThemedScrollView }.first { $0.fittedDocumentHeight != nil })
        return (strip.frame.height, try XCTUnwrap(strip.fittedDocumentHeight))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
