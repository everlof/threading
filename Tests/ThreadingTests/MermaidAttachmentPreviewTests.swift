import AppKit
import WebKit
import XCTest
@testable import Threading

final class MermaidPreviewLoaderTests: XCTestCase {
    func testInputBudgetsAndStrictUTF8() async throws {
        XCTAssertTrue(MermaidPreviewLoader.canRender("graph TD; A-->B"))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "a", count: MermaidPreviewLimits.maximumRenderBytes + 1)))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "A\n", count: MermaidPreviewLimits.maximumRenderLines)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mermaid-\(UUID()).mmd")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0xFF]).write(to: file)
        do {
            _ = try await MermaidPreviewLoader.shared.document(at: file)
            XCTFail("Invalid UTF-8 was admitted")
        } catch { XCTAssertTrue(error is CocoaError) }
        try Data(repeating: 65, count: MermaidPreviewLimits.maximumSourceBytes + 1).write(to: file)
        do {
            _ = try await MermaidPreviewLoader.shared.document(at: file)
            XCTFail("Oversized source was read")
        } catch { XCTAssertEqual(error as? BoundedFileReadError, .exceedsLimit(maximumBytes: MermaidPreviewLimits.maximumSourceBytes)) }
    }
}

@MainActor
final class MermaidAttachmentPreviewTests: HostedStoreTestCase {
    static let fixture = """
    graph TB
      subgraph SHARED["Shared framework"]
        Manager["Connection manager"] --> Watch["Watch<br/>(state machine)"]
        Watch --> Backend["Device backend"]
      end
      subgraph IOS["iOS application"]
        Discovery["Device discovery"] --> Bluetooth["Bluetooth service"]
        Bluetooth --> Device["Connected device"]
      end
      Device --> Backend
      Discovery --> Manager
    """

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mermaid-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settled(_ preview: MermaidPreviewView) async {
        if preview.state == .ready && !preview.isRendering || preview.state == .sourceOnly { return }
        let completion = expectation(description: "Mermaid preview settled")
        preview.onStateChange = { state in
            if state == .ready || state == .sourceOnly { completion.fulfill() }
        }
        await fulfillment(of: [completion], timeout: 20)
        preview.onStateChange = nil
    }

    private func pane(at file: URL, root: URL) throws -> (SessionAttachmentsViewController, NSWindow, MermaidPreviewView) {
        let session = SessionID()
        _ = SessionAttachmentStore.shared.record(urls: [file], sessionID: session, projectRoot: root)
        let pane = SessionAttachmentsViewController(sessionID: session)
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = pane
        window.orderFront(nil)
        pane.view.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? MermaidPreviewView }.first)
        return (pane, window, preview)
    }

    func testBothMermaidSuffixesRenderOfflineWithSourceAndZoom() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["mmd", "mermaid"] {
            let file = root.appendingPathComponent("architecture.\(suffix)")
            try Data(Self.fixture.utf8).write(to: file)
            let (pane, window, preview) = try pane(at: file, root: root)
            defer { preview.clear(); window.orderOut(nil) }
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "No renderer failure")
            XCTAssertEqual(preview.renderMetrics["nodes"], 6)
            let web = try XCTUnwrap(preview.webViewForTesting)
            pane.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
            XCTAssertGreaterThan(web.bounds.height, 300)
            let labels = try await web.evaluateJavaScript("document.querySelector('svg').textContent") as? String
            XCTAssertTrue(labels?.contains("Connection manager") == true)
            preview.showSource(true)
            let text = try XCTUnwrap(descendants(preview).compactMap { $0 as? ThemedTextView }.first)
            XCTAssertEqual(text.string, Self.fixture)
            XCTAssertFalse(text.isEditable)
            XCTAssertTrue(web.isHidden)
            preview.showSource(false)
            XCTAssertFalse(web.isHidden)
            let before = try await web.evaluateJavaScript("document.getElementById('diagram').style.width") as? String
            let zoom = try XCTUnwrap(descendants(preview).compactMap { $0 as? ThemedButton }.first { $0.identifier?.rawValue == "in" })
            XCTAssertTrue(zoom.accessibilityPerformPress())
            let after = try await web.evaluateJavaScript("document.getElementById('diagram').style.width") as? String
            XCTAssertNotEqual(before, after)
            pane.refresh()
            await preview.waitForSourceReadForTesting()
            XCTAssertTrue(preview.webViewForTesting === web, "An unchanged file rebooted its renderer")
            let refreshedWidth = try await web.evaluateJavaScript("document.getElementById('diagram').style.width") as? String
            XCTAssertEqual(after, refreshedWidth, "Refreshing the attachment list reset zoom")
            let changed = expectation(description: "Live theme repaints the same diagram")
            let scaleScript = "parseFloat(document.getElementById('diagram').style.width) / document.querySelector('#diagram svg').viewBox.baseVal.width"
            let previousScale = try await web.evaluateJavaScript(scaleScript) as? Double
            preview.onStateChange = { if $0 == .ready { changed.fulfill() } }
            AppThemePalette.set(AppThemeStyles.cyberpunk)
            AppThemeRefresh.repaint(pane.view)
            await fulfillment(of: [changed], timeout: 20)
            preview.onStateChange = nil
            let themedScale = try await web.evaluateJavaScript(scaleScript) as? Double
            XCTAssertEqual(try XCTUnwrap(previousScale), try XCTUnwrap(themedScale), accuracy: 0.001,
                           "A theme switch reset the reader's zoom")
            AppThemePalette.set(.system)
            XCTAssertTrue(ThemeBoundaryAudit.violations(in: pane.view).isEmpty)
            preview.isHidden = true
            preview.display(file)
            XCTAssertEqual(preview.state, .empty)
            XCTAssertNil(preview.webViewForTesting, "A hidden attachment mounted its renderer")
            preview.isHidden = false
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        }
    }

    func testFailureBudgetAndSelectionCancellationPreserveSource() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.mmd")
        let invalid = "This is ordinary Markdown, not a diagram."
        try Data(invalid.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .sourceOnly)
        XCTAssertEqual(preview.source, invalid)
        XCTAssertNil(preview.webViewForTesting)
        let large = String(repeating: "A", count: MermaidPreviewLimits.maximumRenderBytes + 1)
        try Data(large.utf8).write(to: file)
        preview.display(file)
        await settled(preview)
        XCTAssertEqual(preview.state, .sourceOnly)
        XCTAssertEqual(preview.source, large)
        XCTAssertNil(preview.webViewForTesting, "Over-budget input booted WebKit")
        // The old worker result may finish, but it must never mount after the user leaves.
        preview.display(file)
        preview.clear()
        let next = root.appendingPathComponent("next.mermaid")
        try Data("graph TD; New-->Selection".utf8).write(to: next)
        preview.display(next)
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        XCTAssertEqual(preview.source, "graph TD; New-->Selection")
        preview.clear()
        XCTAssertEqual(preview.state, .empty)
        XCTAssertEqual(preview.source, "")
        XCTAssertNil(preview.webViewForTesting)
    }

    func testSourceCannotRelaxPolicyFetchResourcesOrNavigate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untrusted.mmd")
        try Data("""
        %%{init: {"securityLevel":"loose", "maxEdges":999999}}%%
        graph TD
          A["<img src='https://example.invalid/probe'>Device"] --> B["Reader"]
          click A "https://example.invalid/navigation"
        """.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        let security = try await web.evaluateJavaScript("mermaid.mermaidAPI.getConfig().securityLevel") as? String
        let edges = try await web.evaluateJavaScript("mermaid.mermaidAPI.getConfig().maxEdges") as? Int
        let activeLinks = try await web.evaluateJavaScript("document.querySelectorAll('a[href],a[*|href],script:not([src])').length") as? Int
        XCTAssertEqual(security, "strict")
        XCTAssertEqual(edges, MermaidPreviewLimits.maximumEdges)
        XCTAssertEqual(activeLinks, 0)
        let blocked: Bool = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(
                "try { await fetch('https://example.invalid/probe'); return false; } catch { return true; }",
                arguments: [:], in: nil, in: .page
            ) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool ?? false)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertTrue(blocked)
        let entry = web.url
        let before = preview.deniedNavigationCountForTesting
        web.load(URLRequest(url: URL(string: "https://example.invalid/navigation")!))
        for _ in 0..<100 {
            if preview.deniedNavigationCountForTesting > before { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(preview.deniedNavigationCountForTesting, before)
        let refused = try await web.evaluateJavaScript("location.protocol") as? String
        XCTAssertEqual(refused, "file:")
        // WKWebView.url can momentarily carry the provisional URL even when policy cancels it.
        XCTAssertEqual(entry?.scheme, "file")
    }

    func testStressKeepsOneCanvasAndReportsRenderCost() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("stress.mmd")
        let source = "graph TD\n" + (0..<200).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        try Data(source.utf8).write(to: file)
        // DOT still uses the pre-Mermaid source-only path; keep its cost beside the new engine.
        let control = root.appendingPathComponent("source-control.dot")
        try Data(source.utf8).write(to: control)
        var sourceSamples: [Double] = []
        for _ in 0..<3 {
            let id = SessionID()
            _ = SessionAttachmentStore.shared.record(urls: [control], sessionID: id, projectRoot: root)
            let begin = DispatchTime.now().uptimeNanoseconds
            let sourcePane = SessionAttachmentsViewController(sessionID: id)
            NSLayoutConstraint.activate([
                sourcePane.view.widthAnchor.constraint(equalToConstant: 420),
                sourcePane.view.heightAnchor.constraint(equalToConstant: 700)
            ])
            sourcePane.view.layoutSubtreeIfNeeded()
            sourceSamples.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let (pane, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        XCTAssertEqual(preview.renderMetrics["nodes"], 201)
        XCTAssertEqual(descendants(pane.view).compactMap { $0 as? WKWebView }.count, 1)
        XCTAssertLessThan(descendants(pane.view).count, 150, "Native view count grew with graph nodes")
        print("MERMAID_STRESS total_ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) install_ms=\(preview.rendererInstallMillisecondsForTesting) engine_ms=\(preview.renderMetrics["renderMilliseconds"] ?? -1) native_views=\(descendants(pane.view).count)")
        print("MERMAID_SOURCE_CONTROL mount_layout_ms=\(sourceSamples)")
        for _ in 0..<2 {
            let begin = DispatchTime.now().uptimeNanoseconds
            preview.display(file)
            await preview.waitForSourceReadForTesting()
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
            print("MERMAID_STRESS total_ms=\(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000) install_ms=\(preview.rendererInstallMillisecondsForTesting) engine_ms=\(preview.renderMetrics["renderMilliseconds"] ?? -1) native_views=\(descendants(pane.view).count)")
        }
    }

    func testRendersMermaidAttachmentInShippingShell() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); AppThemePalette.set(.system) }
        let file = root.appendingPathComponent("architecture.mmd")
        try Data(Self.fixture.utf8).write(to: file)
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex, usesNativeUI: true, title: "Architecture"))
        _ = SessionAttachmentStore.shared.record(urls: [file], sessionID: session.id, projectRoot: root)
        let shell = makeMainWindowController()
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1400, height: 900))
        shell.displayPaneController.showSession(session.id)
        shell.setDisplayPaneVisible(true, animated: false, remembersSessionChoice: false)
        let pane = try XCTUnwrap(shell.displayPaneController.activateAttachments(for: session.id))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? MermaidPreviewView }.first)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, theme, appearance) in [
            ("system-light", AppTheme.system, NSAppearance.Name.aqua),
            ("system-dark", AppTheme.system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("win98", AppThemeStyles.win98, .aqua)
        ] {
            AppThemePalette.set(theme)
            window.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            pane.refresh()
            await preview.waitForSourceReadForTesting()
            content.layoutSubtreeIfNeeded()
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
            try await capture(shell.displayPaneController.view, preview: preview,
                              to: directory.appendingPathComponent("attachment-mermaid-\(name).png"))
            if name == "system-dark" {
                try await capture(content, preview: preview, to: directory.appendingPathComponent("attachment-mermaid-shell.png"))
                preview.showSource(true)
                try await capture(shell.displayPaneController.view, preview: preview,
                                  to: directory.appendingPathComponent("attachment-mermaid-source.png"))
                preview.showSource(false)
            }
        }
        try Data("graph TD; A --> [".utf8).write(to: file)
        pane.refresh()
        await preview.waitForSourceReadForTesting()
        await settled(preview)
        XCTAssertEqual(preview.state, .sourceOnly)
        try await capture(shell.displayPaneController.view, preview: preview,
                          to: directory.appendingPathComponent("attachment-mermaid-error.png"))
        XCTAssertFalse(window.isVisible)
        preview.clear()
    }

    private func capture(_ root: NSView, preview: MermaidPreviewView, to url: URL) async throws {
        root.layoutSubtreeIfNeeded()
        let page: NSImage?
        if let web = preview.webViewForTesting, !web.isHidden {
            let visibleNodes = try await web.evaluateJavaScript("document.querySelectorAll('#diagram svg .node').length") as? Int
            XCTAssertEqual(visibleNodes, 6, "An empty WebKit canvas must not become visual evidence")
            page = try await web.takeSnapshot(configuration: nil)
        } else { page = nil }
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
        bitmap.size = root.bounds.size
        if let page, let web = preview.webViewForTesting {
            var destination = web.convert(web.bounds, to: root)
            if root.isFlipped { destination.origin.y = root.bounds.height - destination.maxY }
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            page.draw(in: destination)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
