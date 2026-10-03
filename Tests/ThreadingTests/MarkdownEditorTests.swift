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
