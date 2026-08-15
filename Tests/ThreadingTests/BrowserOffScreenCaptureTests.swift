import AppKit
import WebKit
import XCTest
@testable import Threading

/// What an agent can still see of a browser whose window is not in front of the user.
///
/// This exists because the detached-browser-window plan rests on it. The point of moving the
/// browser to its own window is to put a developer's own app fullscreen on a second display
/// while an agent keeps driving it — and every read the agent performs on that page
/// (`browser_screenshot`, and the remote workspace preview the phone shows) goes through
/// `WKSnapshotConfiguration.afterScreenUpdates = true`, which by its name waits for the
/// *screen* to update. Whether that returns pixels, blank pixels, or nothing at all when the
/// window is miniaturized, occluded or off the visible frame is a platform behaviour, not a
/// decision this codebase gets to make, so it is measured rather than assumed.
///
/// Kept as a test rather than run once and thrown away: it is the tripwire for a macOS update
/// changing the answer under a shipped feature.
///
/// Every case orders a real window on screen, so the whole class is excluded from the fast test
/// plan — WebKit renders nothing offscreen, which is the very property under measurement.
@MainActor
final class BrowserOffScreenCaptureTests: XCTestCase {

    private enum Fixture {
        /// A page that is one flat, unmistakable colour, so "did it render" is one pixel read
        /// rather than an image comparison.
        static let html = "<html><body style='margin:0;background:#FF0000'></body></html>"
        static let expected = (red: 255, green: 0, blue: 0)
        static let size = NSSize(width: 480, height: 320)
        static let loadTimeout: TimeInterval = 10
    }

    private var window: NSWindow?
    private var browser: BrowserViewController?

    override func tearDown() {
        // Ordered out before release. Closing a live WKWebView window synchronously can retire
        // WebKit/AppKit state while XCTest is still draining the case's autorelease pool; the
        // all-plan tripwire owns only one fixture at a time, so it needs no shared host.
        window?.orderOut(nil)
        window = nil
        browser = nil
        super.tearDown()
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
        settle()

        let reading = await capture(browser)
        record("miniaturized", reading)
        XCTAssertNotEqual(
            reading, .blank,
            "a miniaturized window returned a blank capture — an agent would read a white page "
                + "as the page, which is worse than an error it could report"
        )
    }

    func testAWindowMovedOffTheVisibleFrameCapture() async throws {
        let browser = try await loadedBrowser()
        let window = try XCTUnwrap(self.window)

        // Far beyond any attached display, which is what a window on another Space looks like
        // to the compositor as far as this process can arrange one in a test.
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        settle()

        let reading = await capture(browser)
        record("off the visible frame", reading)
        XCTAssertNotEqual(
            reading, .blank,
            "an off-frame window returned a blank capture, so an agent driving a browser the "
                + "user parked on another Space would be told the page is empty"
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
        cover.isOpaque = true
        cover.backgroundColor = .black
        cover.level = .floating
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        settle()

        let reading = await capture(browser)
        record("fully occluded", reading)
        XCTAssertNotEqual(
            reading, .blank,
            "an occluded window returned a blank capture, so anything laid over the browser "
                + "would silently empty what the agent reads"
        )
    }

    // MARK: - Reading

    private enum Reading: Equatable {
        /// The page's own colour came back.
        case rendered
        /// A capture arrived, but not of this page — the failure that cannot be reported,
        /// because an agent cannot tell a white capture from a white page.
        case blank
        /// No capture at all. Honest: the tool reports failure and the agent retries.
        case none
    }

    private func capture(_ browser: BrowserViewController) async -> Reading {
        guard let shot = await browser.screenshot(),
              let bitmap = NSBitmapImageRep(data: shot.data),
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
        let matches = read.red >= 200
            && read.green <= 100
            && read.blue <= 100
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

        let window = NSWindow(
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
        // WebKit will not load or render a view that is in no on-screen window, so this class
        // is the exception the fast plan documents rather than an oversight.
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
        settle(0.3)
        return browser
    }

    /// Lets AppKit and WebKit act on what was just asked of them. A window's miniaturize,
    /// move or occlusion is not observable to the compositor on the same turn of the run loop.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

// MARK: - Fixture Scheme

/// Serves one page on a custom scheme. The sibling in `BrowserAgentBridgeTests` is file-private,
/// and one flat page needs none of its request bookkeeping.
private final class FlatColourSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String

    init(html: String) {
        self.html = html
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
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
