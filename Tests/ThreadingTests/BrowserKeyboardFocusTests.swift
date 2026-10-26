import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserKeyboardFocusTests: XCTestCase {
    func testShippingWindowsRefuseAgentFocusBeforeTheEditorResigns() {
        for window in [makeWindow(), makeWindow(main: true)] {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            let page = WKWebView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
            window.contentView?.addSubview(editor)
            window.contentView?.addSubview(page)
            XCTAssertTrue(window.makeFirstResponder(editor))

            let finishOuter = BrowserKeyboardFocus.beginAgentOperation(on: page)
            let finishInner = BrowserKeyboardFocus.beginAgentOperation(on: page)
            XCTAssertFalse(window.makeFirstResponder(page))
            XCTAssertTrue(window.firstResponder === editor)
            finishOuter()
            finishOuter()
            XCTAssertFalse(window.makeFirstResponder(page), "The remaining scope still protects input")
            XCTAssertTrue(window.firstResponder === editor)
            finishInner()
            XCTAssertTrue(window.makeFirstResponder(page), "Focus is available after the last operation")
            _ = window.makeFirstResponder(nil)
        }
    }

    func testUserInputAndPasswordHandoffCanFocusThePageDuringAgentWork() {
        let window = makeWindow()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let page = WKWebView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(page)
        let finish = BrowserKeyboardFocus.beginAgentOperation(on: page)
        defer { finish(); _ = window.makeFirstResponder(nil) }

        for event in [NSEvent.EventType.leftMouseDown, .keyDown] {
            XCTAssertTrue(window.makeFirstResponder(editor))
            let accepted = ApplicationEventDispatchContext.withEvent(type: event, window: window) {
                window.makeFirstResponder(page)
            }
            XCTAssertTrue(accepted)
            XCTAssertTrue(window.firstResponder === page)
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(BrowserKeyboardFocus.withUserFocus { window.makeFirstResponder(page) })
        XCTAssertTrue(window.firstResponder === page)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(window.makeFirstResponder(page), "A completed user handoff grants no later agent focus")
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testOverlappingPagesRetireTheirFocusProtectionIndependently() {
        let window = makeWindow()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let first = WKWebView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        let second = WKWebView(frame: NSRect(x: 200, y: 0, width: 100, height: 100))
        let views: [NSView] = [editor, first, second]
        for view in views { window.contentView?.addSubview(view) }
        XCTAssertTrue(window.makeFirstResponder(editor))
        let finishFirst = BrowserKeyboardFocus.beginAgentOperation(on: first)
        XCTAssertTrue(window.makeFirstResponder(second), "An idle page is not restricted")
        XCTAssertTrue(window.makeFirstResponder(editor))
        let finishSecond = BrowserKeyboardFocus.beginAgentOperation(on: second)
        finishFirst()
        XCTAssertFalse(window.makeFirstResponder(second))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(window.makeFirstResponder(first))
        finishSecond()
        XCTAssertTrue(window.makeFirstResponder(second))
        _ = window.makeFirstResponder(nil)
    }

    private func makeWindow(main: Bool = false) -> BrowserHostingWindow {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = main
            ? TitlebarActionWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            : BrowserHostingWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
