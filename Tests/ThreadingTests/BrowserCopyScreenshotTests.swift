import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserCopyScreenshotTests: XCTestCase {

    /// Copy Screenshot puts the visible page on the pasteboard as one item carrying both PNG and
    /// TIFF — into a private pasteboard here, never the developer's clipboard.
    func testCopyScreenshotPutsTheVisiblePageOnThePasteboard() throws {
        let browser = BrowserViewController(
            urlSchemeHandlers: ["threading-copy": CopyScreenshotPageHandler()],
            websiteDataStore: .nonPersistent()
        )
        // Parked and borderless: a real window for WebKit to draw into, on no display.
        let rect = NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: NSSize(width: 480, height: 360))
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        NSLayoutConstraint.activate([
            browser.view.widthAnchor.constraint(equalToConstant: rect.width),
            browser.view.heightAnchor.constraint(equalToConstant: rect.height)
        ])
        window.setFrameOrigin(rect.origin)
        defer {
            browser.webView.stopLoading()
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.orderFront(nil)
        browser.view.layoutSubtreeIfNeeded()

        let loaded = expectation(description: "page loaded")
        browser.navigate(to: "threading-copy://fixture/page") { success, message in
            XCTAssertTrue(success, message)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        XCTAssertTrue(pollUntil { !browser.webView.isLoading })

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        browser.copyVisiblePageScreenshot(to: pasteboard)

        XCTAssertTrue(pollUntil { pasteboard.data(forType: .png) != nil }, "the copy must reach the pasteboard")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1, "one image, offered in two encodings")
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pasteboard.data(forType: .png))))
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pasteboard.data(forType: .tiff))))
        XCTAssertGreaterThanOrEqual(png.pixelsWide, Int(browser.webView.bounds.width),
                                    "the PNG is the whole visible page, not a fragment of it")
        XCTAssertEqual(png.pixelsWide, tiff.pixelsWide)
        XCTAssertEqual(png.pixelsHigh, tiff.pixelsHigh)
    }

    private func pollUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class CopyScreenshotPageHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let data = Data("<!doctype html><title>Copy</title><body style=\"background:#3a6\"><p>Copy fixture</p>".utf8)
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
