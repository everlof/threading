import XCTest

@testable import Threading

/// What a captured pixel actually *is*, asked of WebKit rather than reasoned about.
///
/// Two contracts the whole attribution stack rests on were assumed rather than verified, and both
/// fail silently when wrong: a wrong origin attributes every changed region to whatever sits near
/// the top of the page, and a wrong scale mis-places every box by the zoom factor. Neither shows up
/// at scroll 0 and zoom 1, which is exactly the state anybody testing by hand is in.
///
/// **These need a window on screen.** WKWebView does not render or snapshot offscreen, so the class
/// is in `Threading-Fast.xctestplan`'s skip list beside the other live-WebKit suites.
@MainActor
final class BrowserCaptureGeometryTests: XCTestCase {

    private var window: NSWindow!
    private var browser: BrowserViewController!

    override func setUp() async throws {
        try await super.setUp()
        browser = BrowserViewController(contextKind: .private)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.animationBehavior = .none
        window.orderFront(nil)
        // The web view is sized by the controller's layout pass, and `innerWidth` is 0 until it has
        // run. Without this the probes answer about a zero-sized page, which makes the document
        // -coverage assertion pass vacuously — the exact shape of the bug they exist to catch.
        browser.view.layoutSubtreeIfNeeded()
        _ = await navigate(to: "about:blank")
        // An explicit responsive viewport, for the reason the visual-compare integration test uses
        // one: `layoutWebViews` sizes from the scroll view's visible bounds and bails while those
        // are zero, so a test window alone leaves `innerWidth` at 0. Stating the viewport also
        // makes the numbers below deterministic rather than dependent on the window the CI machine
        // happened to open.
        _ = await browser.agentSetResponsiveViewport(width: 500, height: 300)
        try await settle()
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        browser = nil
        try await super.tearDown()
    }

    // MARK: - Origin

    /// The responsive-test viewport remains part of the real browser surface rather than
    /// floating midway down it.
    ///
    /// The pure geometry tests make the placement rule cheap to exercise in the fast lane. This
    /// on-screen WebKit test proves the shipping controller applies that rule, and leaves a real
    /// browser render behind for the appearance-review lap.
    func testResponsiveViewportStaysAttachedToBrowserChrome() async throws {
        window.setContentSize(NSSize(width: 760, height: 1_000))
        browser.view.layoutSubtreeIfNeeded()

        let resized = await browser.agentSetResponsiveViewport(width: 760, height: 656)
        XCTAssertTrue(resized.ok, resized.message)
        _ = try await browser.evaluate(
            """
            document.documentElement.style.margin = '0';
            document.body.style.margin = '0';
            document.body.style.minHeight = '656px';
            document.body.style.background = 'rgb(246, 241, 232)';
            document.body.innerHTML =
              "<main style='box-sizing:border-box;padding:56px;font:24px -apple-system;color:#14213d'>" +
              "<h1 style='margin:0 0 18px;font-size:42px'>Responsive page</h1>" +
              "<p style='margin:0;max-width:560px;line-height:1.45'>The document starts directly " +
              "below the browser chrome. Spare test canvas belongs after the page.</p></main>";
            """
        )
        try await settle()

        XCTAssertEqual(browser.webView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(browser.webView.frame.height, 656, accuracy: 0.5)

        let representation = try XCTUnwrap(
            browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds)
        )
        browser.view.cacheDisplay(in: browser.view.bounds, to: representation)
        browser.view.cacheDisplay(in: browser.view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !output.isEmpty {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(
                to: directory.appendingPathComponent(
                    "browser-responsive-viewport-top-aligned.png"
                )
            )
        }
    }

    /// A full-page capture starts at the document origin, whatever the page is scrolled to.
    ///
    /// It did not, until this test asked. `WKSnapshotConfiguration.rect` is in the *view's*
    /// coordinates, where (0, 0) is the current scroll position, so a capture taken at scroll 1000
    /// covered document 1000–4000 — the wrong band, running a thousand pixels past the end of the
    /// document — while three consumers read it as starting at the top: the attribution space adds
    /// the scroll back, the overlay anchors at `-scroll`, and `clipped` compares against the
    /// document height. `screenshot(fullPage:)` now scrolls to the top and back.
    ///
    /// The page is banded so the answer is a single pixel: scrolled to the lime band, a
    /// document-origin capture starts red and a view-origin capture starts lime.
    func testAFullPageCaptureStartsAtTheDocumentOrigin() async throws {
        try await layOutBandedDocument()
        _ = try await browser.evaluate("window.scrollTo(0, 1000)")
        try await settle()

        let scrolled = try await browser.captureContext()
        try requireLaidOutPage(scrolled)
        XCTAssertEqual(scrolled.scrollY, 1000, accuracy: 2, "the page did not scroll")

        let capture = try await browser.captureBaseline(kind: .fullPage)
        let pixels = try BrowserVisualComparator.decodeRGBA(capture.pngData)
        let top = Self.colour(of: pixels, x: 10, y: 40)

        XCTAssertTrue(
            top.isRed || top.isLime,
            "expected the capture to start in one of the two bands, got \(top)"
        )
        XCTAssertTrue(
            top.isRed,
            """
            A full-page capture taken while scrolled started at the scroll position, not the \
            document origin. Every consumer of BrowserCaptureSpace.forCapture(.fullPage) assumes \
            the document origin, so regions are misattributed by exactly scrollY.
            """
        )

        // And the reader gets their place back: a capture is not a navigation.
        try await settle()
        let after = try await browser.captureContext()
        XCTAssertEqual(after.scrollY, 1000, accuracy: 2, "the scroll was not restored")
    }

    /// The other half of the same contract: the capture covers the whole document rather than one
    /// viewport, which is what makes `clipped` and the overlay's scroll tracking meaningful.
    func testAFullPageCaptureCoversTheWholeDocument() async throws {
        try await layOutBandedDocument()
        try await settle()
        try requireLaidOutPage(try await browser.captureContext())

        let capture = try await browser.captureBaseline(kind: .fullPage)
        XCTAssertEqual(
            Double(capture.conditions.pixelHeight),
            capture.conditions.documentHeight,
            accuracy: 4,
            "a full-page capture should be as tall as the document it claims to cover"
        )
        XCTAssertFalse(capture.clipped, "a 3000pt document is far under the 16000 cap")
    }

    // MARK: - Scale

    /// One captured pixel is one CSS pixel only at zoom 1, so `BrowserCaptureSpace.scale` is the
    /// page zoom.
    ///
    /// Measured, after the scale was hardcoded to 1: at 200% a captured pixel is exactly two CSS
    /// pixels, because the capture is sized from `webView.bounds` (points) while every box, offset
    /// and scroll attribution reads is in CSS pixels.
    func testACapturedPixelIsACSSPixelScaledByPageZoom() async throws {
        try await layOutBandedDocument()
        try await settle()

        browser.setPageZoom(1)
        try await settle()
        try requireLaidOutPage(try await browser.captureContext())
        let plain = try await browser.captureBaseline(kind: .viewport)
        let plainRatio = Double(plain.conditions.pixelWidth) / plain.conditions.viewportWidth
        XCTAssertEqual(plainRatio, 1, accuracy: 0.02, "at zoom 1 a captured pixel is a CSS pixel")

        browser.setPageZoom(2)
        try await settle()
        let zoomed = try await browser.captureBaseline(kind: .viewport)
        let zoomedRatio = Double(zoomed.conditions.pixelWidth) / zoomed.conditions.viewportWidth
        addTeardownBlock { @MainActor [browser] in browser?.setPageZoom(1) }

        XCTAssertEqual(zoomed.conditions.pageZoom, 2, accuracy: 0.01)
        XCTAssertEqual(
            zoomedRatio,
            2,
            accuracy: 0.05,
            "a captured pixel should be exactly `pageZoom` CSS pixels"
        )

        // Which is precisely what the capture space must apply, or every attributed region is
        // offset by the zoom factor for anybody who has zoomed.
        let space = BrowserCaptureSpace.forCapture(
            zoomed.conditions,
            attributionScrollX: 0,
            attributionScrollY: 0
        )
        XCTAssertEqual(space.scale, zoomedRatio, accuracy: 0.05)
    }

    // MARK: - Helpers

    /// Red across the top 200 CSS pixels, lime across 1000–1200, white between, 3000 tall.
    private func layOutBandedDocument() async throws {
        _ = try await browser.evaluate(
            """
            document.documentElement.style.margin = '0';
            document.body.style.margin = '0';
            document.body.innerHTML =
              "<div style='height:200px;background:rgb(255,0,0)'></div>" +
              "<div style='height:800px;background:rgb(255,255,255)'></div>" +
              "<div style='height:200px;background:rgb(0,255,0)'></div>" +
              "<div style='height:1800px;background:rgb(255,255,255)'></div>";
            """
        )
        try await settle()
    }

    /// Layout and paint after a DOM or viewport change are asynchronous; capturing in the same turn
    /// photographs the page mid-reflow.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    /// Refuses to answer a geometry question about a page that has not laid out.
    ///
    /// Every assertion here is a comparison between two numbers the page reports, and zero compares
    /// equal to zero. A harness that quietly measured nothing would report the contract as sound.
    private func requireLaidOutPage(_ context: BrowserCaptureContext) throws {
        try XCTSkipIf(
            context.viewportWidth < 1 || context.viewportHeight < 1,
            "the web view never laid out, so there is no geometry to ask about"
        )
        XCTAssertGreaterThan(
            context.documentHeight,
            context.viewportHeight,
            "the banded fixture should be taller than the viewport"
        )
    }

    private func navigate(to url: String) async -> Bool {
        await withCheckedContinuation { continuation in
            browser.navigate(to: url) { success, _ in continuation.resume(returning: success) }
        }
    }

    private struct Sample: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var isRed: Bool { r > 180 && g < 80 && b < 80 }
        var isLime: Bool { g > 180 && r < 80 && b < 80 }
        var description: String { "rgb(\(r), \(g), \(b))" }
    }

    private static func colour(
        of pixels: BrowserVisualComparator.Pixels,
        x: Int,
        y: Int
    ) -> Sample {
        let offset = (y * pixels.width + x) * 4
        return Sample(
            r: Int(pixels.bytes[offset]),
            g: Int(pixels.bytes[offset + 1]),
            b: Int(pixels.bytes[offset + 2])
        )
    }
}
