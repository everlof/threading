import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserReloadShortcutTests: XCTestCase {
    /// ⌘R belongs to Rename Session in the menu; the browser takes it only while it holds focus.
    func testCommandRReloadsOnlyWhileTheBrowserHasFocus() throws {
        let pages = ReloadCountingPageHandler()
        let browser = BrowserViewController(urlSchemeHandlers: ["threading-reload": pages])
        let origin = NSPoint(x: -10_000, y: -10_000)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 480, height: 360)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setFrameOrigin(origin)
        window.orderFront(nil)
        defer {
            browser.webView.stopLoading()
            window.orderOut(nil)
            window.contentViewController = nil
        }

        let loaded = expectation(description: "page loaded")
        browser.navigate(to: "threading-reload://fixture/page") { success, message in
            XCTAssertTrue(success, message)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(pages.requestCount, 1)
        let chrome = try XCTUnwrap(descendant(BrowserChromeBar.self, in: browser.view))
        // The navigation callback can arrive before WebKit clears `isLoading` and the chrome hears
        // about it. Settle first, so the tooltip is Reload's and ⌘R starts a navigation of its own.
        XCTAssertTrue(
            pollUntil { !browser.webView.isLoading && chrome.reloadButton.toolTip == "Reload (⌘R)" },
            "hovering Reload names its chord once the page has loaded; got \(chrome.reloadButton.toolTip ?? "nil")"
        )

        let commandR = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "r",
            charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ))

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(
            window.performKeyEquivalent(with: commandR),
            "without focus the chord continues to the menu's Rename Session"
        )

        XCTAssertTrue(window.makeFirstResponder(browser.webView))
        XCTAssertTrue(window.performKeyEquivalent(with: commandR))
        XCTAssertTrue(pollUntil { pages.requestCount == 2 }, "⌘R in the focused browser reloads the page")
    }

    private func pollUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

private final class ReloadCountingPageHandler: NSObject, WKURLSchemeHandler {
    private(set) var requestCount = 0

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        requestCount += 1
        let data = Data("<!doctype html><title>Reload</title><p>Reload fixture</p>".utf8)
        task.didReceive(URLResponse(
            url: task.request.url!,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
