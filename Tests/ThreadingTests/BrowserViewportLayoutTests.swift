import AppKit
import XCTest

@testable import Threading

final class BrowserViewportLayoutTests: XCTestCase {

    @MainActor
    func testBrowserCreatedBeforeItsHostHasLayoutStartsWithAUsableViewport() {
        let browser = BrowserViewController(contextKind: .private)
        _ = browser.view
        XCTAssertGreaterThan(browser.webView.bounds.width, 0)
        XCTAssertGreaterThan(browser.webView.bounds.height, 0)
        XCTAssertNil(browser.responsiveViewport, "background sizing must not enable device emulation")
    }

    @MainActor
    func testAutomaticViewportRejectsNativeScrollBursts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_BROWSER_VIEWPORT_STRESS"] == "1")
        let (browser, window, scroll) = try browserWindow()
        defer { window.contentViewController = nil }
        // One clip per tab, normally called at gesture frequency. Stress 2,000 native
        // requests per batch; fixture/WebKit creation is deliberately outside the timer.
        for batch in 1...3 {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<1_000 {
                let origin = CGPoint(x: index % 800, y: index % 600)
                scroll.contentView.scroll(to: origin)
                scroll.contentView.setBoundsOrigin(origin)
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
            XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)
            print("Browser canvas batch \(batch): 2,000 native requests in \(milliseconds) ms")
        }
    }

    @MainActor
    func testAutomaticViewportCannotRemainPannedOutsideItsHost() throws {
        let (browser, window, scroll) = try browserWindow()
        defer { window.contentViewController = nil }
        // AppKit can retain a bounds origin independently of the document's frame. In fill
        // mode the page itself owns scrolling; its outer canvas has no valid panning range.
        scroll.contentView.scroll(to: CGPoint(x: 180, y: 80))
        XCTAssertNil(browser.responsiveViewport)
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)

        scroll.contentView.setBoundsOrigin(CGPoint(x: 240, y: 120))
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)
    }

    @MainActor
    func testResponsiveViewportPreservesValidPanningDuringLayout() throws {
        let (browser, window, scroll) = try browserWindow()
        defer { window.contentViewController = nil }
        browser.setResponsiveViewport(width: 1_440, height: 900)
        window.setContentSize(CGSize(width: 760, height: 600))
        browser.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 180, y: 80))
        browser.view.needsLayout = true
        browser.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.responsiveViewport, CGSize(width: 1_440, height: 900))
        XCTAssertEqual(scroll.contentView.bounds.origin, CGPoint(x: 180, y: 80))
    }

    @MainActor
    func testResponsiveViewportConstrainsScrollingWithoutAnotherLayout() throws {
        let (browser, window, scroll) = try browserWindow()
        defer { window.contentViewController = nil }
        browser.setResponsiveViewport(width: 1_440, height: 900)
        browser.view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let canvas = try XCTUnwrap(scroll.documentView)
        clip.scroll(to: CGPoint(x: 2_000, y: 2_000))
        XCTAssertEqual(clip.bounds.maxX, canvas.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.maxY, canvas.frame.maxY, accuracy: 0.5)
        clip.scroll(to: CGPoint(x: -180, y: -80))
        XCTAssertEqual(clip.bounds.origin, .zero)
    }

    @MainActor
    func testAutomaticViewportFollowsItsTabHostAfterReturningToANarrowerWindow() throws {
        let sessionID = SessionID()
        let host = DisplayPaneController(scope: .detachedWindow(UUID(), session: sessionID))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_440, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.contentViewController = host
        defer { window.contentViewController = nil }
        host.showSessionTabs(sessionID)
        let browser = try XCTUnwrap(host.addBrowserTab(for: sessionID, contextKind: .private))
        host.view.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.addBrowserTab(for: sessionID, contextKind: .private))
        window.setContentSize(CGSize(width: 430, height: 600))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.activateTab(index: 0, for: sessionID))
        host.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(browser.webView.frame.size, scroll.contentView.bounds.size)
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)
    }

    @MainActor
    func testAutomaticViewportKeepsItsOriginDuringHostResizes() throws {
        let (browser, window, scroll) = try browserWindow(fixedSize: false)
        defer { window.contentViewController = nil }

        for width: CGFloat in [760, 1_440, 430, 760] {
            window.setContentSize(CGSize(width: width, height: 600))
            browser.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
            XCTAssertEqual(browser.webView.frame.size, scroll.contentView.bounds.size)
            XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)
        }
    }

    @MainActor
    func testReturningFromPannedResponsiveViewportFillsTheHost() throws {
        let (browser, window, scroll) = try browserWindow()
        defer { window.contentViewController = nil }
        browser.setResponsiveViewport(width: 1_440, height: 900)
        window.setContentSize(CGSize(width: 760, height: 600))
        browser.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 600, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        browser.resetResponsiveViewportToHost()
        window.setContentSize(CGSize(width: 760, height: 600))
        browser.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertEqual(browser.webView.frame.size, scroll.contentView.bounds.size)
        XCTAssertEqual(browser.webView.convert(.zero, to: browser.view).x, 0, accuracy: 0.5)
    }

    @MainActor
    private func browserWindow(fixedSize: Bool = true) throws -> (BrowserViewController, NSWindow, NSScrollView) {
        let browser = BrowserViewController(contextKind: .private)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.contentViewController = browser
        if fixedSize {
            // A split pane supplies a measure independently of its child's fitting size.
            // State that same contract on this unshown fixture instead of letting it refit.
            NSLayoutConstraint.activate([
                browser.view.widthAnchor.constraint(equalToConstant: 760),
                browser.view.heightAnchor.constraint(equalToConstant: 600)
            ])
        }
        browser.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? NSScrollView }.first)
        return (browser, window, scroll)
    }

    func testAutomaticViewportFillsItsHost() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: nil
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 760, height: 1_000)
        )
    }

    func testShortResponsiveViewportStartsAtThePageTop() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 760, height: 656)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 760, height: 656),
            "unused vertical canvas belongs below the page, never between it and the address bar"
        )
    }

    func testResponsiveViewportCentresOnlyAcrossTheUnusedWidth() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 390, height: 844)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 185, y: 0, width: 390, height: 844)
        )
    }

    func testOversizedViewportStartsAtItsDocumentOriginAndPans() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 1_440, height: 1_200)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 1_440, height: 1_200))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 1_440, height: 1_200)
        )
    }
}
