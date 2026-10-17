import AppKit
import XCTest
@testable import Threading

@MainActor
final class StandaloneBrowserWindowTests: XCTestCase {
    func testRendersBrowserWithoutAProjectOrSession() async throws {
        let previousTheme = AppThemePalette.current
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(previousTheme) }
        // Avoid reading the user's persistent website profile in a render fixture.
        // Construct under the capture appearance too: existing browser surfaces resolve some
        // layer colors at construction, before a window can provide its effective appearance.
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var built: StandaloneBrowserWindowController?
        appearance.performAsCurrentDrawingAppearance {
            let controller = StandaloneBrowserWindowController(browser: BrowserViewController())
            controller.window?.appearance = appearance
            controller.window?.animationBehavior = .none
            controller.window?.setContentSize(NSSize(width: 900, height: 600))
            controller.window?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            controller.window?.orderFront(nil)
            built = controller
        }
        let controller = try XCTUnwrap(built)
        let browser = controller.browser
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.close() }
        XCTAssertNil(browser.annotationSessionID)
        XCTAssertNil(browser.baselineSessionID)
        XCTAssertNil(browser.currentURL)
        XCTAssertTrue(window.contentViewController === browser)

        try await Task.sleep(for: .milliseconds(300))
        AppThemeRefresh.repaint(browser.view)
        browser.view.layoutSubtreeIfNeeded()
        let chrome = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? BrowserChromeBar }.first)
        XCTAssertFalse(chrome.addressField.isHidden)
        XCTAssertGreaterThan(chrome.addressField.frame.width, 100)
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: browser.view).isEmpty)
        XCTAssertTrue(browser.hasBlankPageAndAddress)
        chrome.addressField.stringValue = "unfinished destination"
        XCTAssertFalse(browser.hasBlankPageAndAddress, "An external link must preserve an address draft")
        chrome.addressField.stringValue = ""

        if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            let bitmap = try XCTUnwrap(browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds))
            window.appearance?.performAsCurrentDrawingAppearance {
                browser.view.cacheDisplay(in: browser.view.bounds, to: bitmap)
            }
            let output = URL(fileURLWithPath: directory).appendingPathComponent("standalone-browser.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        }
    }
}
