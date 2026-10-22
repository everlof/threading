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

    /// ⌘T belongs to Terminal in the menu; with browser focus it opens another browser in the
    /// same host and hands the keyboard to its address field, up to the session's cap.
    func testCommandTOpensABrowserTabOnlyWhileTheBrowserHasFocus() throws {
        for host in Host.allCases {
            try assertNewTabShortcut(in: host)
        }
    }

    private enum NewTabFocus: CaseIterable { case address, page, tab }

    private func assertNewTabShortcut(in kind: Host) throws {
        let factory: @MainActor (BrowserContextKind, ProjectID?) -> BrowserViewController = { context, _ in
            BrowserViewController(contextKind: context, websiteDataStore: .nonPersistent())
        }
        let sessionID = SessionID()
        let host: NSViewController & TabHosting
        let fillToCap: () -> Void
        switch kind {
        case .panel:
            let panel = DisplayPaneController(browserFactory: factory)
            _ = panel.view
            panel.showSessionTabs(sessionID)
            XCTAssertNotNil(panel.addBrowserTab(for: sessionID))
            fillToCap = { panel.sessionBrowserCount = { _ in DisplayPaneDefaults.maximumBrowserTabs } }
            host = panel
        case .drawer:
            let drawer = DrawerHostViewController(
                directoryProvider: { _ in nil },
                browserFactory: factory,
                loadPanel: { _ in nil },
                persistDrawer: { _, _, _, _ in }
            )
            _ = drawer.view
            drawer.showSession(sessionID)
            XCTAssertNotNil(drawer.addBrowserTab(for: sessionID))
            fillToCap = { drawer.sessionBrowserCount = { _ in DisplayPaneDefaults.maximumBrowserTabs } }
            host = drawer
        case .detached:
            let detached = DisplayPaneController(
                scope: .detachedWindow(UUID(), session: sessionID), browserFactory: factory
            )
            _ = detached.view
            detached.showSessionTabs(sessionID)
            XCTAssertNotNil(detached.addBrowserTab(for: sessionID))
            fillToCap = { detached.sessionBrowserCount = { _ in DisplayPaneDefaults.maximumBrowserTabs } }
            host = detached
        }
        let browsers = { host.tabs(for: sessionID).compactMap(\.browser) }
        let rect = NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: NSSize(width: 480, height: 360))
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        NSLayoutConstraint.activate([
            host.view.widthAnchor.constraint(equalToConstant: 480),
            host.view.heightAnchor.constraint(equalToConstant: 360)
        ])
        window.setFrameOrigin(rect.origin)
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.orderFront(nil)
        host.view.layoutSubtreeIfNeeded()

        let commandT = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "t",
            charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17
        ))

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(window.performKeyEquivalent(with: commandT),
                       "without browser focus ⌘T must reach the menu's Terminal command in \(kind)")
        XCTAssertEqual(browsers().count, 1)

        for focus in NewTabFocus.allCases {
            let active = try XCTUnwrap(browsers().last)
            let address = try XCTUnwrap(descendant(BrowserChromeBar.self, in: active.view)).addressField
            let responder: NSView
            switch focus {
            case .address: responder = address
            case .page: responder = active.webView
            case .tab: responder = try XCTUnwrap(active.tabShortcutFocusOwner)
            }
            XCTAssertTrue(window.makeFirstResponder(responder))
            let before = browsers().count

            XCTAssertTrue(window.performKeyEquivalent(with: commandT), "⌘T with \(focus) focus in \(kind)")

            let opened = try XCTUnwrap(browsers().last)
            XCTAssertEqual(browsers().count, before + 1, "⌘T with \(focus) focus in \(kind) opens one browser")
            XCTAssertFalse(opened === active)
            XCTAssertTrue(opened.view.window === window, "the new browser is shown in the same \(kind)")
            let openedAddress = try XCTUnwrap(descendant(BrowserChromeBar.self, in: opened.view)).addressField
            let focused = ((window.firstResponder as? NSText)?.delegate as? NSView) ?? window.firstResponder as? NSView
            XCTAssertTrue(focused?.isDescendant(of: openedAddress) == true,
                          "the new tab in \(kind) takes the keyboard at its address field")
        }

        fillToCap()
        let atCap = browsers().count
        let last = try XCTUnwrap(browsers().last)
        XCTAssertTrue(window.makeFirstResponder(last.webView))
        XCTAssertTrue(window.performKeyEquivalent(with: commandT), "at the cap ⌘T is still the browser's")
        XCTAssertEqual(browsers().count, atCap, "at the cap \(kind) refuses rather than evicting a browser")
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
            let detached = DisplayPaneController(
                scope: .detachedWindow(UUID(), session: sessionID), browserFactory: { _, _ in browser }
            )
            _ = detached.view
            detached.showSessionTabs(sessionID)
            XCTAssertTrue(detached.addBrowserTab(for: sessionID) === browser)
            host = detached
        }
        let origin = throughApplication ? NSPoint(x: 120, y: 120) : NSPoint(x: -10_000, y: -10_000)
        let rect = NSRect(origin: origin, size: NSSize(width: 480, height: 360))
        let window: NSWindow = throughApplication
            ? ReloadShortcutKeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
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
