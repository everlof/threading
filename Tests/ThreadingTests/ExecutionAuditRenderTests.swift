import AppKit
import WebKit
import XCTest
@testable import Threading

/// Renders the two user-facing audit states under every stock theme and both system appearances.
/// Assertions protect the factual filter contract; the PNGs exist for the visual review that
/// catches density, hierarchy, clipping, and the browser/audit relationship assertions cannot.
@MainActor
final class ExecutionAuditRenderTests: XCTestCase {
    private enum Render {
        static let size = NSSize(width: 1_280, height: 760)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        static let themes: [(String, AppTheme)] = [
            ("system", .system),
            ("threading", AppThemeStyles.threading),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist),
            ("neo-brutalism", AppThemeStyles.neoBrutalism),
            ("claymorphism", AppThemeStyles.claymorphism),
            ("vaporwave", AppThemeStyles.vaporwave)
        ]
    }

    func testRendersAuditInspectorAndBrowserSplitStorybook() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceNameValue) in Render.appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceNameValue))
                let fixture = try makeFixture()
                defer { try? FileManager.default.removeItem(at: fixture.directory) }

                let handler = AuditFixtureSchemeHandler()
                let browser = BrowserViewController(
                    urlSchemeHandlers: ["threading-audit": handler],
                    contextKind: .private
                )
                let controller = ExecutionAuditViewController(
                    sessionID: fixture.sessionID,
                    browser: browser,
                    store: fixture.store
                )
                let chromeHost: WindowChromeHostViewController?
                let windowController: NSViewController
                if theme.id == AppThemeStyles.threading.id, appearanceName == "dark" {
                    let host = WindowChromeHostViewController(workspace: controller)
                    chromeHost = host
                    windowController = host
                } else {
                    chromeHost = nil
                    windowController = controller
                }
                let window = makeWindow(controller: windowController, appearance: appearance)

                let categoryFilter = try XCTUnwrap(view(
                    withIdentifier: "executionAudit.categoryFilter",
                    under: controller.view
                ))
                let sourceFilter = try XCTUnwrap(view(
                    withIdentifier: "executionAudit.sourceFilter",
                    under: controller.view
                ))
                let search = try XCTUnwrap(view(
                    withIdentifier: "executionAudit.search",
                    under: controller.view
                ))
                XCTAssertEqual(categoryFilter.bounds.height, search.bounds.height, accuracy: 0.5)
                XCTAssertEqual(sourceFilter.bounds.height, search.bounds.height, accuracy: 0.5)

                try write(
                    snapshot(window: window, appearance: appearance),
                    named: "execution-audit-\(themeName)-\(appearanceName).png"
                )
                written += 1

                if let chromeHost {
                    chromeHost.setTitle("Threading")
                    chromeHost.setTakeoverActive(true)
                    chromeHost.bandView.fixtureIsKey = true
                    chromeHost.commandBandView.setLeadingControls(makeWindowControls())
                    chromeHost.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try write(
                        snapshot(window: window, appearance: appearance),
                        named: "execution-audit-threading-chrome-dark.png"
                    )
                    written += 1
                    chromeHost.setTakeoverActive(false)
                    chromeHost.view.layoutSubtreeIfNeeded()
                }

                controller.setMode(.browserSplit)
                let loaded = expectation(description: "fixture page loaded")
                browser.navigate(to: "threading-audit://fixture/run") { success, message in
                    XCTAssertTrue(success, message)
                    loaded.fulfill()
                }
                wait(for: [loaded], timeout: 3)
                let painted = expectation(description: "fixture page painted")
                browser.webView.takeSnapshot(with: nil) { image, error in
                    XCTAssertNil(error)
                    XCTAssertNotNil(image)
                    painted.fulfill()
                }
                wait(for: [painted], timeout: 3)
                window.makeFirstResponder(nil)

                try write(
                    snapshot(window: window, appearance: appearance),
                    named: "execution-audit-browser-split-\(themeName)-\(appearanceName).png"
                )
                written += 1

                // A `defer` here used to retain every window until the complete fourteen-cell
                // sweep returned. Close each cell at its ownership boundary instead, after
                // detaching the controller so neither AppKit nor WebKit can keep its window
                // registered through the next cell's autorelease pool.
                browser.webView.stopLoading()
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count * 2 + 1)
        print("Rendered execution audit storybook to \(Render.directory.path)")
    }

    /// The product capture uses the same command controls as MainWindowController. They remain
    /// inert here because this fixture verifies the real chrome and audit composition, not window
    /// navigation behavior, which has its own controller tests.
    private func makeWindowControls() -> [NSView] {
        let sidebar = ThemedIconButton(
            symbolName: "sidebar.leading",
            accessibility: L10n.string("Show or hide sidebar"),
            inkSource: .chrome
        )
        let back = ThemedIconButton(
            symbolName: "chevron.left",
            accessibility: L10n.string("Go back"),
            inkSource: .chrome
        )
        back.isEnabled = false
        let forward = ThemedIconButton(
            symbolName: "chevron.right",
            accessibility: L10n.string("Go forward"),
            inkSource: .chrome
        )
        forward.isEnabled = false
        return [sidebar, back, forward]
    }

    private func makeFixture() throws -> (
        store: ExecutionAuditStore,
        sessionID: SessionID,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-audit-render-\(UUID().uuidString)", isDirectory: true)
        let store = ExecutionAuditStore(directory: directory)
        let sessionID = SessionID()

        store.append(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            category: .lifecycle,
            phase: .completed,
            operation: "session.initialised",
            input: .object(["model": .string("gpt-5.3-codex")]),
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: "exec_command",
            callID: "shell-1",
            input: .object([
                "cmd": .string("npm test -- --runInBand"),
                "workdir": .string("/workspace")
            ]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: nil,
            callID: "shell-1",
            output: .object(["exit_code": .integer(0), "output": .string("24 tests passed")]),
            isError: false,
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: "apply_patch",
            callID: "patch-1",
            input: .object(["path": .string("Sources/App/AuditView.swift")]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: nil,
            callID: "patch-1",
            output: .object(["changed": .bool(true), "lines": .integer(42)]),
            isError: false,
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_navigate",
            callID: "browser-1",
            input: .object(["url": .string("https://threading.codes/")]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_navigate",
            callID: "browser-1",
            output: .object(["ok": .bool(true), "title": .string("Threading")]),
            isError: false,
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_snapshot",
            callID: "browser-2",
            input: .object(["interactive": .bool(true)]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_snapshot",
            callID: "browser-2",
            output: .object([
                "elements": .array([
                    .object(["ref": .string("e12"), "role": .string("link"), "name": .string("Themes")]),
                    .object(["ref": .string("e19"), "role": .string("link"), "name": .string("GitHub")])
                ])
            ]),
            isError: false,
            fidelity: .exact
        )
        store.append(
            sessionID: sessionID,
            source: .permissionBroker,
            provider: nil,
            category: .permission,
            phase: .requested,
            operation: "permission.request",
            input: .object(["tool": .string("browser_click"), "target": .string("link Themes")]),
            fidelity: .exact
        )
        store.append(
            sessionID: sessionID,
            source: .permissionBroker,
            provider: nil,
            category: .permission,
            phase: .allowed,
            operation: "permission.decision",
            output: .object(["decision": .string("allow_once")]),
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_click",
            callID: "browser-3",
            input: .object(["ref": .string("e12"), "button": .string("left")]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_click",
            callID: "browser-3",
            output: .object(["ok": .bool(true), "url": .string("https://threading.codes/themes")]),
            isError: false,
            fidelity: .exact
        )
        store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_snapshot",
            callID: "browser-4",
            input: .object(["interactive": .bool(true), "compact": .bool(true)]),
            fidelity: .exact
        )
        store.recordToolResult(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_snapshot",
            callID: "browser-4",
            output: .object([
                "page": .object([
                    "title": .string("Threading themes"),
                    "url": .string("https://threading.codes/themes"),
                    "heading": .string("One view. A completely different feel.")
                ]),
                "elements": .array([
                    .object(["ref": .string("e31"), "role": .string("link"), "name": .string("Product")]),
                    .object(["ref": .string("e32"), "role": .string("link"), "name": .string("Extensions")]),
                    .object(["ref": .string("e33"), "role": .string("link"), "name": .string("Themes")]),
                    .object(["ref": .string("e34"), "role": .string("link"), "name": .string("Compare")])
                ])
            ]),
            isError: false,
            fidelity: .exact
        )

        return (store, sessionID, directory)
    }

    private func makeWindow(
        controller: NSViewController,
        appearance: NSAppearance
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Render.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = controller
        window.setContentSize(Render.size)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        controller.view.frame = NSRect(origin: .zero, size: Render.size)
        controller.view.appearance = appearance
        AppThemeRefresh.repaint(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.makeFirstResponder(nil)
        return window
    }

    private func snapshot(window: NSWindow, appearance: NSAppearance) -> Data? {
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let host = window.contentView else { return }
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    private func write(_ data: Data?, named filename: String) throws {
        try XCTUnwrap(data, "Failed to render \(filename)")
            .write(to: Render.directory.appendingPathComponent(filename))
    }

    private func view(withIdentifier identifier: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = view(withIdentifier: identifier, under: child) { return found }
        }
        return nil
    }
}

private final class AuditFixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let data = Self.html.data(using: .utf8) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        task.didReceive(URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static let html = #"""
    <!doctype html>
    <html>
      <head>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { font: 15px -apple-system, sans-serif; color-scheme: light dark; }
          body { margin: 0; padding: 40px; background: Canvas; color: CanvasText; }
          main { max-width: 600px; margin: 0 auto; }
          .eyebrow { color: #6d67e4; font-size: 12px; font-weight: 700; letter-spacing: .12em; }
          h1 { font-size: 30px; margin: 10px 0 8px; }
          p { color: color-mix(in srgb, CanvasText 68%, transparent); line-height: 1.5; }
          .card { border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 14px;
                  margin-top: 28px; padding: 22px; }
          .row { display: flex; justify-content: space-between; padding: 10px 0; }
          button { background: #6d67e4; border: 0; border-radius: 8px; color: white; font: inherit;
                   font-weight: 650; margin-top: 18px; padding: 10px 16px; }
        </style>
      </head>
      <body>
        <main>
          <div class="eyebrow">LIVE BROWSER</div>
          <h1>Review order</h1>
          <p>The page remains usable while the exact browser-tool ledger stays visible beside it.</p>
          <section class="card">
            <div class="row"><span>Studio plan</span><strong>$24.00</strong></div>
            <div class="row"><span>Tax</span><strong>$4.80</strong></div>
            <button>Continue to payment</button>
          </section>
        </main>
      </body>
    </html>
    """#
}
