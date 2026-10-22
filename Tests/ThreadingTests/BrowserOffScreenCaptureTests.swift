import AppKit
import WebKit
import XCTest
@testable import Threading

/// Exercises the shipping browser after its host stops being visible. A successful capture
/// must contain a mutation performed while hidden: old pixels and timeouts both fail.
/// Real visibility transitions require WindowServer, so this class stays in the all plan.
@MainActor
final class BrowserOffScreenCaptureTests: HostedStoreTestCase {

    private enum Fixture {
        /// A page that is one flat, unmistakable colour, so "did it render" is one pixel read
        /// rather than an image comparison.
        static let html = """
            <html><style>@keyframes reveal { from { opacity:0 } to { opacity:1 } }</style>
            <body style='margin:0;background:#FF0000'>
            <button id='change' onclick="requestAnimationFrame(() => {
              this.textContent='Frame rendered';
              const field=document.querySelector('#text');
              field.onanimationend=() => { document.body.style.background='#00FF00'; };
              field.style.animation='reveal 0.05s linear';
            })">Change</button>
            <input id='text' aria-label='Text'>
            </body></html>
            """
        static let size = NSSize(width: 480, height: 320)
        static let operationLimit: TimeInterval = 5
    }

    private var window: NSWindow?
    private var browser: BrowserViewController?

    override func tearDown() async throws {
        // Ordered out before release. Closing a live WKWebView window synchronously can retire
        // WebKit/AppKit state while XCTest is still draining the case's autorelease pool; the
        // all-plan tripwire owns only one fixture at a time, so it needs no shared host.
        window?.orderOut(nil)
        window = nil
        browser = nil
        try await super.tearDown()
    }

    // MARK: - Measurements

    func testAVisibleWindowCaptures() async throws {
        let browser = try await loadedBrowser()
        let reading = await capture(browser)

        XCTAssertEqual(
            reading, .rendered,
            "the baseline itself failed, so nothing else this class reports means anything"
        )
    }

    func testAMiniaturizedWindowCapture() async throws {
        let browser = try await loadedBrowser()
        let window = try XCTUnwrap(self.window)

        window.miniaturize(nil)
        defer { window.deminiaturize(nil) }
        try await settle()

        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        record("miniaturized", reading)
        XCTAssertEqual(
            reading, .rendered,
            "a minimized browser must capture the mutation performed while hidden"
        )
    }

    func testAWindowMovedOffTheVisibleFrameCapture() async throws {
        let browser = try await loadedBrowser()
        let window = try XCTUnwrap(self.window)

        // This verifies off-display geometry, not a Space switch. A titled window normally
        // constrains this back onto a screen, so the fixture explicitly disables that clamp.
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        try await settle()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })

        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        record("off the visible frame", reading)
        XCTAssertEqual(
            reading, .rendered,
            "an off-display browser must capture the mutation performed while hidden"
        )
    }

    func testAFullyOccludedWindowCapture() async throws {
        let browser = try await loadedBrowser()
        let covered = try XCTUnwrap(self.window)

        let cover = NSWindow(
            contentRect: covered.frame.insetBy(dx: -80, dy: -80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        cover.animationBehavior = .none
        cover.isOpaque = true
        cover.backgroundColor = .black
        cover.level = .floating
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        try await settle()

        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        record("fully occluded", reading)
        XCTAssertEqual(
            reading, .rendered,
            "a covered browser must capture the mutation performed while hidden"
        )
    }

    // MARK: - Reading

    private enum Reading: Equatable {
        /// The page's own colour came back.
        case rendered
        /// A capture arrived, but not of this page — the failure that cannot be reported,
        /// because an agent cannot tell a white capture from a white page.
        case blank
        /// A timeout or failed capture is a regression too.
        case none
    }

    private func capture(_ browser: BrowserViewController, green: Bool = false) async -> Reading {
        let started = Date()
        let shot: BrowserScreenshotCapture
        do { shot = try await browser.screenshot() }
        catch {
            XCTFail("Capture failed: \(error.localizedDescription)")
            return .none
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, Fixture.operationLimit)
        print("[off-screen capture] screenshot completed in \(elapsed)s")
        let attachment = XCTAttachment(data: shot.data, uniformTypeIdentifier: "public.png")
        attachment.name = green ? "background-rendered-frame" : "initial-frame"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let bitmap = NSBitmapImageRep(data: shot.data),
              let colour = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        else { return .none }

        let srgb = colour.usingColorSpace(.sRGB) ?? colour
        let read = (
            red: Int((srgb.redComponent * 255).rounded()),
            green: Int((srgb.greenComponent * 255).rounded()),
            blue: Int((srgb.blueComponent * 255).rounded())
        )
        print(
            "[off-screen capture] sampled rgb(\(read.red), \(read.green), \(read.blue)) "
                + "from \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
        )
        // Dominance, not fidelity. A capture of `#FF0000` comes back as rgb(255, 38, 0) here:
        // the snapshot carries a wide-gamut profile and the round trip back to sRGB lifts the
        // other channels. The question this class asks is only "is this the page or a blank
        // surface", so it asks whether red overwhelmingly dominates — true of the fixture in any
        // colour space, false of the white, grey or black a non-rendering capture yields.
        let matches = green
            ? read.green >= 200 && read.red <= 100 && read.blue <= 100
            : read.red >= 200 && read.green <= 100 && read.blue <= 100
        return matches ? .rendered : .blank
    }

    private func record(_ condition: String, _ reading: Reading) {
        let described: String
        switch reading {
        case .rendered: described = "captured the page"
        case .blank: described = "captured something that is not the page"
        case .none: described = "returned no capture"
        }
        print("[off-screen capture] \(condition): \(described)")
    }

    // MARK: - Fixture

    /// Served over a custom scheme and loaded through the browser's own `navigate`, which is the
    /// shape the on-screen integration tests already prove works in this host. An earlier
    /// version used `loadHTMLString` and never finished loading — which would have read as a
    /// platform finding rather than a broken fixture, so the baseline case exists to catch
    /// exactly that.
    private func loadedBrowser() async throws -> BrowserViewController {
        let browser = BrowserViewController(
            urlSchemeHandlers: ["threading-capture": FlatColourSchemeHandler(html: Fixture.html)],
            contextKind: .shared
        )
        self.browser = browser

        let window = UnconstrainedCaptureWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(Fixture.size)
        browser.view.frame = window.contentView?.bounds
            ?? NSRect(origin: .zero, size: Fixture.size)
        window.center()
        // Establish the visible baseline before each real visibility transition.
        window.animationBehavior = .none
        window.orderFront(nil)
        self.window = window
        browser.view.layoutSubtreeIfNeeded()

        let outcome: (success: Bool, message: String) = await withCheckedContinuation {
            continuation in
            browser.navigate(to: "threading-capture://fixture/flat") { success, message in
                continuation.resume(returning: (success: success, message: message))
            }
        }
        XCTAssertTrue(outcome.success, "the fixture page never loaded: \(outcome.message)")
        try await settle(0.3)
        return browser
    }

    /// Lets AppKit and WebKit act on what was just asked of them. A window's miniaturize,
    /// move or occlusion is not observable to the compositor on the same turn of the run loop.
    private func settle(_ seconds: TimeInterval = 0.4) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func changeWhileHidden(_ browser: BrowserViewController) async throws {
        let started = Date()
        let outcome = try await browser.agentClick(ref: nil, selector: "#change")
        XCTAssertTrue(outcome.ok, outcome.message)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, Fixture.operationLimit)
        print("[off-screen capture] click completed in \(elapsed)s")
        let context = try await browser.captureContext()
        XCTAssertGreaterThan(context.viewportWidth, 0)
        XCTAssertGreaterThan(context.viewportHeight, 0)
        let snapshot = try await browser.agentSnapshot()
        XCTAssertTrue(snapshot.agentText.contains("Frame rendered"), snapshot.agentText)
    }

    func testActionsAndElementCaptureDoNotDependOnPageTimers() async throws {
        let browser = try await loadedBrowser()
        browser.view.removeFromSuperview()
        window?.orderOut(nil)
        // Deterministically model a throttled isolated-world timer. The 70-second platform
        // tripwire beside this varies with other pages sharing WebKit's process assertions.
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            browser.webView.callAsyncJavaScript(
                "globalThis.setTimeout = () => { throw new Error('DOM timer used by agent action'); }; return true;",
                arguments: [:], in: nil, in: .defaultClient
            ) { continuation.resume(with: $0.map { _ in () }) }
        }
        try await changeWhileHidden(browser)
        let typed = try await browser.agentType(
            ref: nil, selector: "#text", text: "abc", slowly: true, submit: false
        )
        XCTAssertTrue(typed.ok, typed.message)
        let value = try await browser.evaluate("document.querySelector('#text').value") as? String
        XCTAssertEqual(value, "abc")
        let shot = try await browser.screenshot(ref: nil, selector: "#change")
        XCTAssertTrue(shot.target.ok, shot.target.message)
        XCTAssertNotNil(shot.capture)
        let pageCanUseHostTimer = try await browser.evaluate(
            "typeof window.webkit?.messageHandlers?.threadingAgentDelay !== 'undefined'"
        ) as? Bool
        XCTAssertEqual(pageCanUseHostTimer, false, "host timers belong only to the isolated agent world")
    }

    func testHostDelayRejectsInvalidAndExcessRequests() async throws {
        let browser = try await loadedBrowser()
        let result: String? = try await withCheckedThrowingContinuation { continuation in
            browser.webView.callAsyncJavaScript(
                """
                const delay = (milliseconds, index) =>
                  webkit.messageHandlers.threadingAgentDelay.postMessage({milliseconds, token: String(index)});
                const invalid = await Promise.allSettled([-1, 1001, '50', null].map(delay));
                const batch = await Promise.allSettled(Array.from({length: 65}, (_, index) => delay(1000, index)));
                return JSON.stringify({
                  invalid: invalid.filter(r => r.status === 'rejected').length,
                  completed: batch.filter(r => r.status === 'fulfilled').length,
                  refused: batch.filter(r => r.status === 'rejected').length
                });
                """,
                arguments: [:], in: nil, in: .defaultClient
            ) { continuation.resume(with: $0.map { $0 as? String }) }
        }
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(counts, ["invalid": 4, "completed": 64, "refused": 1])
    }

    func testDetachedIdlePageCanClickAndCaptureFreshPixels() async throws {
        let browser = try await loadedBrowser()
        browser.view.removeFromSuperview()
        window?.orderOut(nil)
        // Allow WebKit's default idle policy to take effect before starting the action.
        try await settle(70)
        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        XCTAssertEqual(reading, .rendered)
    }

    func testNewTabInBackgroundSessionHasAViewportAndCanBeDriven() async throws {
        let host = DisplayPaneController(browserFactory: { _, _ in
            BrowserViewController(
                urlSchemeHandlers: ["threading-capture": FlatColourSchemeHandler(html: Fixture.html)],
                contextKind: .private
            )
        })
        let window = UnconstrainedCaptureWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        self.window = window
        let sessionID = SessionID()
        host.showSession(SessionID())
        let browser = try XCTUnwrap(host.addBrowserTab(for: sessionID, contextKind: .private))
        self.browser = browser
        XCTAssertNil(browser.view.window)
        // Do not force fixture layout: the tool path must prepare a tab whose window has
        // never received an onscreen layout/display pass.
        let success = await withCheckedContinuation { continuation in
            browser.navigate(to: "threading-capture://fixture/new") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        XCTAssertTrue(success)
        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        XCTAssertEqual(reading, .rendered)
        XCTAssertFalse(window.isVisible)
    }

    func testRenderingFollowsChatSwitchesWithoutMovingTheControllerOrFocus() async throws {
        let host = DisplayPaneController(browserFactory: { _, _ in
            BrowserViewController(
                urlSchemeHandlers: ["threading-capture": FlatColourSchemeHandler(html: Fixture.html)],
                contextKind: .private
            )
        })
        let window = UnconstrainedCaptureWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        // A view controller's initial frame can resize its window during installation. Use a
        // realistic pane after mounting; a clipped, few-pixel viewport is not handoff evidence.
        window.setContentSize(NSSize(width: 1_024, height: 768))
        host.view.frame = try XCTUnwrap(window.contentView).bounds
        window.center()
        window.orderFrontRegardless()
        self.window = window
        let session = SessionID()
        let otherSession = SessionID()
        host.showSession(session)
        let browser = try XCTUnwrap(host.addBrowserTab(for: session, contextKind: .private))
        self.browser = browser
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(browser.webView.bounds.height, 400)
        let success = await withCheckedContinuation { continuation in
            browser.navigate(to: "threading-capture://fixture/switch") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        XCTAssertTrue(success)
        try await settle()
        let parent = try XCTUnwrap(browser.webView.superview)
        let keyWindow = NSApp.keyWindow
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let finish = browser.beginAgentOperation()
        defer { finish() }

        host.showSession(otherSession)
        try await settle()
        let renderWindow = try XCTUnwrap(browser.webView.window)
        XCTAssertNil(browser.view.window, "Only the page moves; dialogs keep their ordinary host")
        XCTAssertFalse(renderWindow === window)
        XCTAssertEqual(renderWindow.alphaValue, 0)
        XCTAssertTrue(renderWindow.ignoresMouseEvents)
        XCTAssertFalse(renderWindow.canBecomeKey)
        XCTAssertFalse(renderWindow.canBecomeMain)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        try await changeWhileHidden(browser)
        let reading = await capture(browser, green: true)
        XCTAssertEqual(reading, .rendered)

        _ = try await browser.evaluate("document.querySelector('#text').focus()")
        host.showSession(session)
        try await settle()
        XCTAssertTrue(browser.view.window === window)
        XCTAssertTrue(browser.webView.superview === parent)
        XCTAssertTrue(browser.webView.window === window)
        XCTAssertFalse(renderWindow.isVisible)
        let focusedField = try await browser.evaluate("document.activeElement.id") as? String
        XCTAssertEqual(focusedField, "text")
        finish()
        XCTAssertTrue(browser.webView.superview === parent)
    }

    func testOverlappingPagesShareOnePanelAndReleaseItAfterTheLastOperation() async throws {
        let first = try await loadedBrowser()
        first.view.removeFromSuperview()
        window?.orderOut(nil)
        let second = BrowserViewController(
            urlSchemeHandlers: ["threading-capture": FlatColourSchemeHandler(html: Fixture.html)],
            contextKind: .private
        )
        let success = await withCheckedContinuation { continuation in
            second.navigate(to: "threading-capture://fixture/second") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        XCTAssertTrue(success)
        let firstParent = try XCTUnwrap(first.webView.superview)
        let secondParent = try XCTUnwrap(second.webView.superview)
        let finishes = (0..<64).map { _ in first.beginAgentOperation() }
        let finishSecond = second.beginAgentOperation()
        defer {
            finishes.forEach { $0() }
            finishSecond()
        }
        let panel = try XCTUnwrap(first.webView.window)
        XCTAssertTrue(second.webView.window === panel)
        XCTAssertEqual(panel.contentView?.subviews.count, 2)
        try await changeWhileHidden(first)
        let firstReading = await capture(first, green: true)
        let secondReading = await capture(second)
        XCTAssertEqual(firstReading, .rendered)
        XCTAssertEqual(secondReading, .rendered, "Concurrent pages must retain their own pixels")
        finishes.forEach { $0() }
        finishes.forEach { $0() }
        XCTAssertTrue(first.webView.superview === firstParent)
        XCTAssertNil(first.webView.window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(second.webView.window === panel)
        finishSecond()
        XCTAssertTrue(second.webView.superview === secondParent)
        XCTAssertNil(second.webView.window)
        XCTAssertFalse(panel.isVisible)
    }

    func testRenderReadinessTimeoutReleasesThePanel() async throws {
        let browser = try await loadedBrowser()
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            browser.webView.callAsyncJavaScript(
                """
                globalThis.fixtureFrame = requestAnimationFrame;
                globalThis.pendingFrames = [];
                globalThis.requestAnimationFrame = callback => { pendingFrames.push(callback); return 1; };
                return true;
                """,
                arguments: [:], in: nil, in: .defaultClient
            ) { continuation.resume(with: $0.map { _ in () }) }
        }
        browser.view.removeFromSuperview()
        window?.orderOut(nil)
        let parent = try XCTUnwrap(browser.webView.superview)
        do {
            _ = try await browser.agentClick(ref: nil, selector: "#change")
            XCTFail("Missing render callbacks must time out instead of returning empty content")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "WebKit did not resume background rendering"
            ), error.localizedDescription)
        }
        XCTAssertTrue(browser.webView.superview === parent)
        XCTAssertNil(browser.webView.window)
        if #available(macOS 14.0, *) {
            XCTAssertEqual(browser.webView.configuration.preferences.inactiveSchedulingPolicy, .suspend)
        }
        let finish = browser.beginAgentOperation()
        defer { finish() }
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            browser.webView.callAsyncJavaScript(
                "globalThis.requestAnimationFrame = fixtureFrame; return true;",
                arguments: [:], in: nil, in: .defaultClient
            ) { continuation.resume(with: $0.map { _ in () }) }
        }
        finish()
        // A rendering timeout happened before dispatching the click. Ordinary page-owned form
        // submission must not stay blocked by the late-action guard used for real click timeouts.
        _ = try await browser.evaluate("""
            const form = document.createElement('form');
            form.method = 'POST'; form.action = 'threading-capture://fixture/submitted';
            document.body.appendChild(form); form.submit();
            """)
        await browser.settleAfterAgentAction()
        XCTAssertEqual(browser.currentURL?.path, "/submitted")
    }

    func testDOMFocusSurvivesSeparateBackgroundOperations() async throws {
        let browser = try await loadedBrowser()
        browser.view.removeFromSuperview()
        window?.orderOut(nil)
        _ = try await browser.evaluate("document.querySelector('#text').focus()")
        _ = try await browser.evaluate("document.querySelector('#change').focus()")
        let button = try await browser.evaluate("document.activeElement.id") as? String
        XCTAssertEqual(button, "change")
        _ = try await browser.evaluate("document.querySelector('#text').focus()")
        let field = try await browser.evaluate("document.activeElement.id") as? String
        XCTAssertEqual(field, "text")
    }

    func testLoadingBackgroundDocumentCanBeReadAndStoppedBeforeFramesAreReady() async throws {
        let browser = BrowserViewController(
            urlSchemeHandlers: [
                "threading-capture": FlatColourSchemeHandler(html: Fixture.html, finishes: false)
            ],
            contextKind: .private
        )
        self.browser = browser
        let committed = await withCheckedContinuation { continuation in
            browser.navigate(to: "threading-capture://fixture/stream", waitUntil: .commit) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        XCTAssertTrue(committed)
        let started = Date()
        var label: String?
        repeat {
            label = try await browser.evaluate("document.querySelector('#change')?.textContent") as? String
            if label == nil { try await settle(0.05) }
        } while label == nil && Date().timeIntervalSince(started) < 2
        XCTAssertEqual(label, "Change")
        XCTAssertLessThan(Date().timeIntervalSince(started), Fixture.operationLimit)
        XCTAssertTrue(browser.webView.isLoading)
        let stopped = await browser.agentStopLoading(expectedURL: try XCTUnwrap(browser.currentURL))
        XCTAssertTrue(stopped.ok, stopped.message)
        XCTAssertFalse(browser.webView.isLoading)
        let snapshot = try await browser.agentSnapshot()
        XCTAssertTrue(snapshot.agentText.contains("Change"), snapshot.agentText)
        XCTAssertNil(browser.webView.window)
    }

    func testHistoryAndReloadKeepRenderingFreshBackgroundContent() async throws {
        let browser = try await loadedBrowser()
        window?.orderOut(nil)
        let loaded = await withCheckedContinuation { continuation in
            browser.navigate(to: "threading-capture://fixture/second") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        XCTAssertTrue(loaded)
        for action in [BrowserHistoryAction.back, .forward, .reload, .reloadFromOrigin] {
            let target = try XCTUnwrap(browser.historyTarget(for: action))
            let completed = await withCheckedContinuation { continuation in
                browser.navigateHistory(action, expectedTarget: target) { ok, _ in
                    continuation.resume(returning: ok)
                }
            }
            XCTAssertTrue(completed)
            _ = try await browser.evaluate("""
                document.body.style.background = '#FF0000';
                document.querySelector('#change').textContent = 'Change';
                """)
            try await changeWhileHidden(browser)
        }
        XCTAssertFalse(try XCTUnwrap(window).isVisible)
    }

    func testFailedEvaluationRestoresTheDetachedPageAndIdlePolicy() async throws {
        let browser = try await loadedBrowser()
        browser.view.removeFromSuperview()
        window?.orderOut(nil)
        let parent = try XCTUnwrap(browser.webView.superview)
        do {
            _ = try await browser.evaluate("throw new Error('deliberate fixture failure')")
            XCTFail("The evaluation should fail")
        } catch {
            XCTAssertEqual((error as? WKError)?.code, .javaScriptExceptionOccurred)
        }
        XCTAssertTrue(browser.webView.superview === parent)
        XCTAssertNil(browser.webView.window)
        if #available(macOS 14.0, *) {
            XCTAssertEqual(browser.webView.configuration.preferences.inactiveSchedulingPolicy, .suspend)
        }
        let reading = await capture(browser)
        XCTAssertEqual(reading, .rendered, "A failed operation must not poison the next lease")
    }
}

private final class UnconstrainedCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Fixture Scheme

/// Serves one page on a custom scheme. The sibling in `BrowserAgentBridgeTests` is file-private,
/// and one flat page needs none of its request bookkeeping.
private final class FlatColourSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String
    private let finishes: Bool

    init(html: String, finishes: Bool = true) {
        self.html = html
        self.finishes = finishes
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let data = Data(html.utf8)
        task.didReceive(URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: finishes ? data.count : -1,
            textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        if finishes { task.didFinish() }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
