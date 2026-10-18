import AppKit

/// A user's browser, with no session, project, agent registration or origin grants.
/// Native window chrome follows the detached browser's containment boundary; the existing
/// browser controller owns all content and themed controls.
@MainActor
final class StandaloneBrowserWindowController: ThemedWindowController, NSWindowDelegate {
    private enum Defaults {
        static let size = NSSize(width: 1_100, height: 800)
        static let minimumSize = NSSize(width: 480, height: 360)
    }

    let browser: BrowserViewController
    var onClose: (() -> Void)?

    convenience init() {
        self.init(browser: BrowserViewController(websiteDataStore: BrowserWebsiteDataStores.standalone))
    }

    init(browser: BrowserViewController) {
        self.browser = browser
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Defaults.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("standalone-browser")
        window.minSize = Defaults.minimumSize
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        super.init(window: window)
        window.delegate = self
        window.setContentSize(Defaults.size)
        window.center()
        window.title = L10n.string("Browser")
        browser.onPageChange = { [weak self] in
            guard let self else { return }
            self.window?.title = self.browser.currentTitle ?? L10n.string("Browser")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if browser.currentURL == nil { browser.focusAddress() }
    }

    func windowWillClose(_ notification: Notification) {
        browser.webView.stopLoading()
        onClose?()
    }
}

/// Retains only open user windows; each requested URL gets a visible destination. Closing a
/// window releases its WebKit tree. A blank launch window is reused for the first incoming URL.
@MainActor
final class StandaloneBrowserWindows {
    private var windows: [UUID: StandaloneBrowserWindowController] = [:]

    var active: StandaloneBrowserWindowController? {
        NSApp.keyWindow?.windowController as? StandaloneBrowserWindowController
    }

    @discardableResult
    func revealVisibleWindow() -> Bool {
        guard let window = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.windowController is StandaloneBrowserWindowController
        }), let controller = window.windowController as? StandaloneBrowserWindowController else {
            return false
        }
        controller.showWindow(nil)
        return true
    }

    @discardableResult
    func open(_ url: URL? = nil) -> StandaloneBrowserWindowController {
        let controller: StandaloneBrowserWindowController
        if let blank = windows.values.first(where: { $0.browser.hasBlankPageAndAddress }) {
            controller = blank
        } else {
            controller = StandaloneBrowserWindowController()
            let id = UUID()
            windows[id] = controller
            controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
            // No strip to add a tab to, so ⌘T's fresh browser is a window of its own.
            controller.browser.openNewTab = { [weak self] in self?.open().browser }
        }
        controller.showWindow(nil)
        if let url { controller.browser.navigate(to: url) }
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }
}
