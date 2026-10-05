import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserReloadShortcutTests: HostedStoreTestCase {
    private enum Host: CaseIterable { case panel, drawer, detached }

    /// ⌘R belongs to Rename Session in the menu; the browser takes it only while it holds focus.
    func testCommandRReloadsOnlyWhileTheBrowserHasFocus() throws {
        for host in Host.allCases {
            try assertReloadShortcut(in: host, throughApplication: false)
        }
    }

    func testApplicationDispatchReloadsBeforeRenameMenuWithBrowserFocus() throws {
        for host in Host.allCases {
            try assertReloadShortcut(in: host, throughApplication: true)
        }
    }

    private func assertReloadShortcut(in kind: Host, throughApplication: Bool) throws {
        let pages = ReloadCountingPageHandler()
        let browser = BrowserViewController(urlSchemeHandlers: ["threading-reload": pages])
        let sessionID = SessionID()
        let host: NSViewController
        switch kind {
        case .panel:
            let panel = DisplayPaneController(browserFactory: { _, _ in browser })
            _ = panel.view
            panel.showSessionTabs(sessionID)
            XCTAssertTrue(panel.addBrowserTab(for: sessionID) === browser)
            host = panel
        case .drawer:
            let drawer = DrawerHostViewController(
                directoryProvider: { _ in nil },
                browserFactory: { _, _ in browser },
                loadPanel: { _ in nil },
                persistDrawer: { _, _, _, _ in }
            )
            _ = drawer.view
            drawer.showSession(sessionID)
            XCTAssertTrue(drawer.addBrowserTab(for: sessionID) === browser)
            host = drawer
        case .detached:
            let detached = DetachedBrowserHostViewController(
                sessionID: sessionID, browserFactory: { _, _ in browser }
            )
            _ = detached.view
            XCTAssertTrue(detached.addBrowserTab() === browser)
            host = detached
        }
        let origin = throughApplication ? NSPoint(x: 120, y: 120) : NSPoint(x: -10_000, y: -10_000)
        let rect = NSRect(origin: origin, size: NSSize(width: 480, height: 360))
        let window: NSWindow = throughApplication
            ? ReloadShortcutKeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        NSLayoutConstraint.activate([
            host.view.widthAnchor.constraint(equalToConstant: 480),
            host.view.heightAnchor.constraint(equalToConstant: 360)
        ])
        window.setFrameOrigin(origin)
        defer {
            browser.webView.stopLoading()
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentViewController = nil
        }
        if throughApplication {
            window.makeKeyAndOrderFront(nil)
            try XCTSkipUnless(pollUntil { window.isKeyWindow }, "the host cannot grant keyboard focus")
        } else {
            window.orderFront(nil)
        }
        host.view.layoutSubtreeIfNeeded()

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

        let renameTarget = ReloadShortcutRenameTarget()
        let menu = NSMenu()
        let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        let projectMenu = NSMenu(title: "Project")
        let renameItem = NSMenuItem(
            title: "Rename Session", action: #selector(ReloadShortcutRenameTarget.rename), keyEquivalent: "r"
        )
        renameItem.keyEquivalentModifierMask = .command
        renameItem.target = renameTarget
        projectMenu.addItem(renameItem)
        projectItem.submenu = projectMenu
        menu.addItem(projectItem)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }

        XCTAssertTrue(window.makeFirstResponder(nil))
        if throughApplication {
            NSApp.sendEvent(commandR)
            XCTAssertEqual(renameTarget.count, 1, "without browser focus the menu must receive Rename Session")
        } else {
            XCTAssertFalse(window.performKeyEquivalent(with: commandR))
        }

        let tab = try XCTUnwrap(browser.tabShortcutFocusOwner as? ThemedTabItemView)
        XCTAssertFalse(tab.isDescendant(of: browser.view), "the shipping tab is outside browser content")
        host.view.layoutSubtreeIfNeeded()
        browser.view.layoutSubtreeIfNeeded()
        browser.viewDidLayout()
        let pagePoint = browser.webView.convert(NSPoint(
            x: browser.webView.bounds.midX, y: browser.webView.bounds.midY
        ), to: browser.webView.superview)
        let pageContent = try XCTUnwrap(browser.webView.hitTest(pagePoint),
            "\(kind) page bounds \(browser.webView.bounds), frame \(browser.webView.frame), hit point \(pagePoint)")
        let responders: [NSView] = [tab, pageContent, browser.webView, chrome.addressField]
        for (index, responder) in responders.enumerated() {
            XCTAssertTrue(pollUntil { !browser.webView.isLoading })
            XCTAssertTrue(window.makeFirstResponder(responder))
            if throughApplication {
                XCTAssertTrue(window.isKeyWindow)
                NSApp.sendEvent(commandR)
            } else {
                XCTAssertTrue(window.performKeyEquivalent(with: commandR))
            }
            XCTAssertTrue(pollUntil { pages.requestCount == index + 2 },
                          "⌘R with \(type(of: responder)) focus in \(kind) must reload the page")
            XCTAssertEqual(renameTarget.count, throughApplication ? 1 : 0,
                           "focused browser reload must precede the menu binding")
        }
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

private final class ReloadShortcutKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ReloadShortcutRenameTarget: NSObject {
    private(set) var count = 0
    @objc func rename() { count += 1 }
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
