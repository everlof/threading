import AppKit
import WebKit
import XCTest
@testable import Threading

final class MermaidPreviewLoaderTests: XCTestCase {
    func testRenderBudgetCountsLinesLikeAnEditor() {
        let limit = MermaidPreviewLimits.maximumRenderLines
        XCTAssertTrue(MermaidPreviewLoader.canRender("graph TD; A-->B"))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "a", count: MermaidPreviewLimits.maximumRenderBytes + 1)))
        // Exactly at the budget is admitted whether or not the last line is terminated.
        XCTAssertTrue(MermaidPreviewLoader.canRender(String(repeating: "A\n", count: limit)))
        XCTAssertTrue(MermaidPreviewLoader.canRender(String(repeating: "A\n", count: limit - 1) + "A"))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "A\n", count: limit + 1)))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "A\n", count: limit) + "A"))
        // "\r\n" is one Character that is not "\n": a CRLF file once counted as no lines at all.
        XCTAssertTrue(MermaidPreviewLoader.canRender(String(repeating: "A\r\n", count: limit)))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "A\r\n", count: limit + 1)))
        XCTAssertFalse(MermaidPreviewLoader.canRender(String(repeating: "A\r", count: limit + 1)))
        XCTAssertEqual(MermaidPreviewLoader.lineCount(of: "".utf8), 0)
        XCTAssertEqual(MermaidPreviewLoader.lineCount(of: "a".utf8), 1)
        XCTAssertEqual(MermaidPreviewLoader.lineCount(of: "a\n".utf8), 1)
        XCTAssertEqual(MermaidPreviewLoader.lineCount(of: "a\r\nb".utf8), 2)
        XCTAssertEqual(MermaidPreviewLoader.lineCount(of: "a\r\rb\n".utf8), 3)
    }

    func testOnlyTextRendersAndOtherBytesStayReadable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mermaid-\(UUID()).mmd")
        defer { try? FileManager.default.removeItem(at: file) }
        // A Windows-1252 é: readable source, never handed to the renderer.
        try (Data("graph TD; ".utf8) + Data([0xE9]) + Data("-->B".utf8)).write(to: file)
        let legacy = try await MermaidPreviewLoader.document(at: file)
        XCTAssertEqual(legacy.admission, .notText)
        XCTAssertEqual(legacy.source, "graph TD; \u{FFFD}-->B")
        let text = "graph TD; Å-->B\n"
        try (Data([0xFF, 0xFE]) + XCTUnwrap(text.data(using: .utf16LittleEndian))).write(to: file)
        let utf16 = try await MermaidPreviewLoader.document(at: file)
        XCTAssertEqual(utf16.admission, .render)
        XCTAssertEqual(utf16.source, text)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: file)
        let utf8BOM = try await MermaidPreviewLoader.document(at: file)
        XCTAssertEqual(utf8BOM.source, text)
        try Data(repeating: 65, count: MermaidPreviewLimits.maximumSourceBytes + 1).write(to: file)
        do {
            _ = try await MermaidPreviewLoader.document(at: file)
            XCTFail("Oversized source was read")
        } catch { XCTAssertEqual(error as? BoundedFileReadError, .exceedsLimit(maximumBytes: MermaidPreviewLimits.maximumSourceBytes)) }
    }

    func testSourceCapIsTheAttachmentPanesOne() {
        XCTAssertEqual(MermaidPreviewLimits.maximumSourceBytes, SessionAttachmentsDefaults.maximumSourcePreviewBytes)
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

    /// Tall and narrow: fits the width at full scale and leaves plenty to scroll.
    static let tallFixture = "graph TD\n" + (0..<60).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")

    private static let scaleScript = "parseFloat(document.getElementById('diagram').style.width) / document.querySelector('#diagram svg').viewBox.baseVal.width"

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

    private func pane(at files: [URL], root: URL) throws -> (SessionAttachmentsViewController, NSWindow, MermaidPreviewView) {
        let session = SessionID()
        _ = SessionAttachmentStore.shared.record(urls: files, sessionID: session, projectRoot: root)
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

    private func pane(at file: URL, root: URL) throws -> (SessionAttachmentsViewController, NSWindow, MermaidPreviewView) {
        try pane(at: [file], root: root)
    }

    private func select(_ url: URL, in pane: SessionAttachmentsViewController, preview: MermaidPreviewView) throws {
        let table = pane.tableViewForTesting
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if preview.currentURL == url { return }
        }
        XCTFail("No row shows \(url.lastPathComponent)")
    }

    private func zoomButton(_ operation: String, in preview: MermaidPreviewView) throws -> ThemedIconButton {
        try XCTUnwrap(descendants(preview).compactMap { $0 as? ThemedIconButton }.first { $0.identifier?.rawValue == operation })
    }

    private func call<T: Sendable>(_ script: String, in web: WKWebView) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? T)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testBothMermaidSuffixesRenderOfflineWithSourceAndZoom() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); AppThemePalette.set(.system) }
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
            XCTAssertTrue(try zoomButton("in", in: preview).accessibilityPerformPress())
            let after = try await web.evaluateJavaScript("document.getElementById('diagram').style.width") as? String
            XCTAssertNotEqual(before, after)
            pane.refresh()
            await preview.waitForSourceReadForTesting()
            XCTAssertTrue(preview.webViewForTesting === web, "An unchanged file rebooted its renderer")
            let refreshedWidth = try await web.evaluateJavaScript("document.getElementById('diagram').style.width") as? String
            XCTAssertEqual(after, refreshedWidth, "Refreshing the attachment list reset zoom")
            let changed = expectation(description: "Live theme repaints the same diagram")
            let previousScale = try await web.evaluateJavaScript(Self.scaleScript) as? Double
            preview.onStateChange = { if $0 == .ready { changed.fulfill() } }
            AppThemePalette.set(AppThemeStyles.cyberpunk)
            AppThemeRefresh.repaint(pane.view)
            await fulfillment(of: [changed], timeout: 20)
            preview.onStateChange = nil
            let themedScale = try await web.evaluateJavaScript(Self.scaleScript) as? Double
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

    /// The bundled renderer is `@mermaid-js/tiny`: every common diagram type renders, and the two
    /// it leaves out — mindmap and architecture, the only users of cytoscape — show their source.
    func testTheTinyBuildRendersCommonDiagramsAndShowsSourceForItsExclusions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendered: [(String, String)] = [
            ("flowchart", Self.fixture),
            ("sequence", "sequenceDiagram\n  Agent->>Pane: attachment\n  Pane-->>Agent: preview"),
            ("class", "classDiagram\n  class Reader {\n    +String source\n    +render()\n  }\n  Reader <|-- MermaidReader"),
            ("state", "stateDiagram-v2\n  [*] --> Loading\n  Loading --> Ready\n  Ready --> [*]"),
            ("er", "erDiagram\n  SESSION ||--o{ ATTACHMENT : records"),
            ("gantt", "gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section Build\n  Reader :a1, 2026-10-01, 3d"),
            ("pie", "pie title Reader\n  \"Tiny\" : 2.8\n  \"Full\" : 5.5"),
            ("journey", "journey\n  title Review\n  section Fix\n    Read: 5: Agent"),
            ("git", "gitGraph\n  commit\n  branch fix\n  commit\n  checkout main\n  merge fix"),
            ("timeline", "timeline\n  title Mermaid\n  2026-10-08 : Tiny build")
        ]
        let excluded: [(String, String)] = [
            ("mindmap", "mindmap\n  root((Threading))\n    Attachments\n    Terminal"),
            ("architecture", "architecture-beta\n  service api(server)[API]\n  service db(database)[DB]\n  api:R --> L:db")
        ]
        let first = root.appendingPathComponent("first.mmd")
        try Data(Self.fixture.utf8).write(to: first)
        let (_, window, preview) = try pane(at: first, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        for (name, source) in rendered + excluded {
            let file = root.appendingPathComponent("\(name).mmd")
            try Data(source.utf8).write(to: file)
            preview.display(file)
            await preview.waitForSourceReadForTesting()
            await settled(preview)
            let expected: MermaidPreviewView.State = excluded.contains { $0.0 == name } ? .sourceOnly : .ready
            XCTAssertEqual(preview.state, expected, "\(name): \(preview.rendererFailureForTesting ?? "no renderer failure")")
            XCTAssertEqual(preview.source, source)
        }
        XCTAssertEqual(preview.rendererLaunchCountForTesting, 1, "A diagram that failed to parse cost a canvas")
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
        // A page that answered "not a diagram" is healthy: it stays loaded, out of sight.
        XCTAssertEqual(preview.webViewForTesting?.isHidden, true)
        let launches = preview.rendererLaunchCountForTesting
        let large = String(repeating: "A", count: MermaidPreviewLimits.maximumRenderBytes + 1)
        try Data(large.utf8).write(to: file)
        preview.display(file)
        await preview.waitForSourceReadForTesting()
        await settled(preview)
        XCTAssertEqual(preview.state, .sourceOnly)
        XCTAssertEqual(preview.source, large)
        XCTAssertEqual(preview.rendererLaunchCountForTesting, launches, "Over-budget input booted WebKit")
        // The old worker result may finish, but it must never mount after the user leaves.
        preview.display(file)
        preview.clear()
        XCTAssertNil(preview.webViewForTesting)
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

    func testBytesThatAreNotTextShowSourceWithoutBootingWebKit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.mmd")
        try (Data("graph TD; ".utf8) + Data([0xE9]) + Data("-->B".utf8)).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .sourceOnly)
        XCTAssertEqual(preview.source, "graph TD; \u{FFFD}-->B")
        let text = try XCTUnwrap(descendants(preview).compactMap { $0 as? ThemedTextView }.first)
        XCTAssertEqual(text.string, preview.source, "Readable source was replaced by an empty view")
        XCTAssertFalse(text.enclosingScrollView?.isHidden ?? true)
        XCTAssertEqual(preview.rendererLaunchCountForTesting, 0)
        let status = try XCTUnwrap(descendants(preview).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "attachments.mermaid-status" })
        XCTAssertEqual(status.stringValue, L10n.string("This diagram is not UTF-8 text. Showing source."))
    }

    func testSourceCannotRelaxPolicyFetchResourcesOrNavigate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untrusted.mmd")
        try Data("""
        %%{init: {"securityLevel":"loose", "maxEdges":999999, "dompurifyConfig":{"ADD_TAGS":["style"]}, "fontFamily":"Papyrus"}}%%
        graph TD
          A["<img src='https://example.invalid/probe'>Device"] --> B["Reader<style>#diagram svg{display:none}</style>"]
          click A "https://example.invalid/navigation"
        """.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        let security = try await web.evaluateJavaScript("mermaid.mermaidAPI.getConfig().securityLevel") as? String
        let edges = try await web.evaluateJavaScript("mermaid.mermaidAPI.getConfig().maxEdges") as? Int
        // Mermaid resets directive configuration after each render, so what a directive changed is
        // read from the drawing rather than from `getConfig()`.
        let directiveFont = try await web.evaluateJavaScript("document.getElementById('diagram').innerHTML.includes('Papyrus')") as? Bool
        let activeLinks = try await web.evaluateJavaScript("document.querySelectorAll('a[href],a[*|href],script:not([src])').length") as? Int
        let authoredStyles = try await web.evaluateJavaScript("document.querySelectorAll('#diagram foreignObject style').length") as? Int
        XCTAssertEqual(security, "strict")
        XCTAssertEqual(edges, MermaidPreviewLimits.maximumEdges)
        XCTAssertEqual(directiveFont, false, "A directive replaced the host's font")
        XCTAssertEqual(activeLinks, 0)
        XCTAssertEqual(authoredStyles, 0, "A label carried a stylesheet into the canvas")
        // A request to an unresolvable host fails with or without a policy, so the proof is the
        // policy's own report, not the failure.
        let violations: [String] = try await call("""
            const seen = [];
            document.addEventListener('securitypolicyviolation', (event) => seen.push(event.effectiveDirective));
            try { await fetch('https://example.invalid/probe'); } catch {}
            const image = new Image();
            const loaded = new Promise((resolve) => { image.onerror = resolve; image.onload = resolve; });
            image.src = 'https://example.invalid/probe.png';
            document.body.appendChild(image);
            await loaded;
            for (let attempt = 0; attempt < 50 && seen.length < 2; attempt++) {
              await new Promise((resolve) => setTimeout(resolve, 20));
            }
            image.remove();
            return seen;
            """, in: web) ?? []
        XCTAssertTrue(violations.contains("connect-src"), "Violations: \(violations)")
        XCTAssertTrue(violations.contains("img-src"), "Violations: \(violations)")
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

    func testCanvasIsReusedAcrossSelectionsAndInPlaceUpdates() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mmd")
        let second = root.appendingPathComponent("second.mermaid")
        try Data(Self.fixture.utf8).write(to: first)
        try Data(Self.tallFixture.utf8).write(to: second)
        let (pane, window, preview) = try pane(at: [first, second], root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        let shown = try XCTUnwrap(preview.currentURL)
        let other = shown == first ? second : first
        try select(other, in: pane, preview: preview)
        XCTAssertNotEqual(preview.state, .ready, "The previous diagram stood in for the new selection")
        XCTAssertTrue(web.isHidden)
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        XCTAssertTrue(preview.webViewForTesting === web, "Moving between two diagrams launched a second canvas")
        XCTAssertEqual(preview.rendererLaunchCountForTesting, 1)
        XCTAssertEqual(preview.source, try String(contentsOf: other, encoding: .utf8))

        XCTAssertTrue(try zoomButton("in", in: preview).accessibilityPerformPress())
        let zoomed = try await web.evaluateJavaScript(Self.scaleScript) as? Double
        let rewritten = (try String(contentsOf: other, encoding: .utf8)) + "\n  Extra --> Node"
        try Data(rewritten.utf8).write(to: other)
        pane.refresh()
        await preview.waitForSourceReadForTesting()
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        XCTAssertEqual(preview.source, rewritten)
        XCTAssertTrue(preview.webViewForTesting === web, "An in-place update rebooted the canvas")
        let labels = try await web.evaluateJavaScript("document.querySelector('svg').textContent") as? String
        XCTAssertTrue(labels?.contains("Extra") == true)
        let updatedScale = try await web.evaluateJavaScript(Self.scaleScript) as? Double
        XCTAssertEqual(try XCTUnwrap(zoomed), try XCTUnwrap(updatedScale), accuracy: 0.001,
                       "An in-place update reset the reader's zoom")
    }

    func testHidingKeepsZoomScrollAndSourceChoice() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tall.mmd")
        try Data(Self.tallFixture.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        XCTAssertTrue(try zoomButton("in", in: preview).accessibilityPerformPress())
        let zoomedValue = try await web.evaluateJavaScript(Self.scaleScript)
        let zoomed = try XCTUnwrap(zoomedValue as? Double)
        _ = try await web.evaluateJavaScript("scrollTo(0, 400); window.dispatchEvent(new Event('scroll')); scrollY")
        for _ in 0..<100 where preview.viewport?.y != 400 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(preview.viewport?.y, 400)

        preview.isHidden = true
        XCTAssertNil(preview.webViewForTesting, "A hidden reader kept its canvas")
        preview.isHidden = false
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let restored = try XCTUnwrap(preview.webViewForTesting)
        XCTAssertFalse(restored === web)
        let restoredValue = try await restored.evaluateJavaScript(Self.scaleScript)
        let restoredScale = try XCTUnwrap(restoredValue as? Double)
        let restoredScroll = try await restored.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(zoomed, restoredScale, accuracy: 0.001, "Hiding the pane reset the reader's zoom")
        XCTAssertEqual(restoredScroll, 400, "Hiding the pane reset the reader's scroll position")

        preview.showSource(true)
        preview.isHidden = true
        preview.isHidden = false
        await settled(preview)
        let text = try XCTUnwrap(descendants(preview).compactMap { $0 as? ThemedTextView }.first)
        XCTAssertFalse(text.enclosingScrollView?.isHidden ?? true, "Hiding the pane forgot the Source choice")
        XCTAssertEqual(preview.webViewForTesting?.isHidden, true)
    }

    func testThemeChangeDuringTheFirstRenderIsNotLost() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); AppThemePalette.set(.system) }
        let file = root.appendingPathComponent("architecture.mmd")
        try Data(Self.fixture.utf8).write(to: file)
        let (pane, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        for _ in 0..<2_000 where !preview.isRendering {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(preview.isRendering, "The first render never started")
        XCTAssertEqual(preview.state, .loading)
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(pane.view)
        for _ in 0..<4_000 where preview.state != .ready || preview.isRendering {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        var expected = ""
        preview.effectiveAppearance.performAsCurrentDrawingAppearance { expected = Design.Surface.ground.hexString }
        let painted = try await web.evaluateJavaScript("mermaid.mermaidAPI.getConfig().themeVariables.background") as? String
        XCTAssertEqual(painted?.lowercased(), expected.lowercased(), "The diagram kept the palette captured before the theme changed")
    }

    func testTransientRendererFailuresRetryOnRefreshWithinABudget() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("architecture.mmd")
        try Data(Self.fixture.utf8).write(to: file)
        let (pane, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        for attempt in 1...MermaidPreviewLimits.maximumRendererRetries {
            preview.webViewWebContentProcessDidTerminate(try XCTUnwrap(preview.webViewForTesting))
            XCTAssertEqual(preview.state, .sourceOnly)
            XCTAssertNil(preview.webViewForTesting)
            pane.refresh()
            await preview.waitForSourceReadForTesting()
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, "Retry \(attempt) did not recover: \(preview.rendererFailureForTesting ?? "")")
        }
        preview.webViewWebContentProcessDidTerminate(try XCTUnwrap(preview.webViewForTesting))
        let launches = preview.rendererLaunchCountForTesting
        pane.refresh()
        await preview.waitForSourceReadForTesting()
        XCTAssertEqual(preview.state, .sourceOnly, "An unchanged file retried without bound")
        XCTAssertEqual(preview.rendererLaunchCountForTesting, launches)
        // Showing the pane again is the reader asking: a fresh attempt.
        preview.isHidden = true
        preview.isHidden = false
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
    }

    func testAFailedLoadFallsBackImmediately() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("architecture.mmd")
        try Data(Self.fixture.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        let web = try XCTUnwrap(preview.webViewForTesting)
        preview.webView(web, didFail: nil, withError: URLError(.cannotOpenFile))
        XCTAssertEqual(preview.state, .sourceOnly)
        XCTAssertNil(preview.webViewForTesting)
        XCTAssertEqual(preview.source, Self.fixture)
    }

    func testFontFamiliesAreCSSStrings() {
        XCTAssertEqual(MermaidPreviewView.cssString("3270 Nerd Font"), "\"3270 Nerd Font\"")
        XCTAssertEqual(MermaidPreviewView.cssString("Font Awesome 6 Free"), "\"Font Awesome 6 Free\"")
        XCTAssertEqual(MermaidPreviewView.cssString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(MermaidPreviewView.cssString("a\nb"), "\"a\\a b\"")
    }

    /// Amiga's Topaz exists only inside this process, so the canvas is handed its bytes.
    func testProcessLocalThemeFaceReachesTheCanvas() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.amiga)
        let font = Design.Typography.body()
        let family = try XCTUnwrap(font.familyName)
        XCTAssertTrue(family.hasPrefix("Topaz"), "Amiga's body face is \(family)")
        let fontFile = try XCTUnwrap(MermaidPreviewView.processLocalFontFile(for: font))
        XCTAssertTrue(fontFile.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path),
                      "\(fontFile.path) is not inside \(Bundle.main.bundleURL.path)")
        let file = root.appendingPathComponent("architecture.mmd")
        try Data(Self.fixture.utf8).write(to: file)
        let (_, window, preview) = try pane(at: file, root: root)
        defer { preview.clear(); window.orderOut(nil) }
        await settled(preview)
        XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
        let web = try XCTUnwrap(preview.webViewForTesting)
        let faces: [String] = try await call(
            "return [...document.fonts].map((face) => `${face.family}|${face.status}`);", in: web
        ) ?? []
        XCTAssertTrue(faces.contains { $0.contains(family) && $0.hasSuffix("|loaded") }, "Faces: \(faces)")
        let labelFont = try await web.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#diagram .nodeLabel')).fontFamily"
        ) as? String
        XCTAssertTrue(labelFont?.replacingOccurrences(of: "\"", with: "").hasPrefix(family) == true,
                      "Labels are set in \(labelFont ?? "nothing")")
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
        XCTAssertEqual(preview.rendererLaunchCountForTesting, 1, "Re-displaying a diagram launched another canvas")
        for _ in 0..<2 {
            let begin = DispatchTime.now().uptimeNanoseconds
            preview.isHidden = true
            preview.isHidden = false
            await settled(preview)
            XCTAssertEqual(preview.state, .ready, preview.rendererFailureForTesting ?? "")
            print("MERMAID_STRESS_RESUME total_ms=\(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000) install_ms=\(preview.rendererInstallMillisecondsForTesting) engine_ms=\(preview.renderMetrics["renderMilliseconds"] ?? -1)")
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
            ("win98", AppThemeStyles.win98, .aqua),
            ("amiga", AppThemeStyles.amiga, .aqua)
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
