import AppKit

/// A session's browser in a window of its own.
///
/// The point of the feature, stated once: a developer puts their own app on a second display at
/// real size — fullscreen if they want — while an agent keeps driving it and the main window
/// keeps the conversation. So this window is **pinned to one session** and outlives the
/// selection, unlike the panel and drawer it can take tabs from.
///
/// **Native chrome, deliberately.** `window-chrome.md` scopes the theme takeover to the main
/// window and keeps the Component Gallery and Onboarding windows native under every theme; this
/// follows that precedent. Takeover here would need a `TitlebarActionWindow` and a whole
/// app-drawn content root (band, drag handle, close button, overlay hosting), which is a
/// separate piece of work rather than a detail of this one.
@MainActor
final class DetachedBrowserWindowController: ThemedWindowController {

    private enum Defaults {
        static let size = NSSize(width: 1_100, height: 800)
        static let minimumSize = NSSize(width: 480, height: 360)
        /// Offset from the main window, so a detached window does not land exactly on top of
        /// the thing it was detached from.
        static let cascade = NSPoint(x: 42, y: -42)

        /// How far into the new window's top-left corner the pointer sits when a torn-off tab
        /// lands. Roughly where the chip was held, so the window arrives under the hand.
        static let grabInset: CGFloat = 60

        /// How long a burst of frame changes is gathered before it is written.
        static let persistCoalescing: TimeInterval = 0.4
    }

    let host: DetachedBrowserHostViewController

    var sessionID: SessionID { host.sessionID }
    var windowID: UUID { host.windowID }

    /// The window closed — by its own button, or because its last tab left. The owner forgets
    /// it and stops persisting for it.
    var onClose: ((UUID) -> Void)?

    /// Anything worth writing back: the tabs, the selection, the frame, fullscreen.
    var onPersist: ((DetachedBrowserWindowController) -> Void)?

    private var isClosing = false

    /// The frame the window had before it went fullscreen, which is the one worth restoring.
    private var lastWindowedFrame: String?

    private var isPersistScheduled = false

    // MARK: - Initialization

    init(
        host: DetachedBrowserHostViewController,
        restoredFrame: NSRect?,
        droppedAt screenPoint: NSPoint? = nil
    ) {
        self.host = host

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Defaults.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = Defaults.minimumSize
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        // The strip is the window's own chrome, so the titlebar draws no bar of its own above
        // it — the main window's reasoning, for the same seam between rounded corner and
        // content. The strip pins to the safe area, which is what keeps it clear of the
        // traffic lights.
        window.titlebarAppearsTransparent = true
        // A window whose whole purpose is showing a page at real size must be able to take the
        // whole screen. Primary rather than auxiliary: it gets its own Space, which is exactly
        // the "my app on the second display" case.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = host

        super.init(window: window)

        window.delegate = self
        applyFrame(restoredFrame, droppedAt: screenPoint)
        retitle()

        host.onTitleChanged = { [weak self] in self?.retitle() }
        host.onLayoutChanged = { [weak self] in self?.persist() }
        host.onEmptied = { [weak self] in
            // A window with no tabs is not a window. Closed on the next turn of the run loop
            // because this arrives *during* the close or move that emptied it, and tearing the
            // window down inside that call unparents the very view AppKit is working through.
            DispatchQueue.main.async { self?.close() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        host.focusActiveTab()
    }

    /// The state to write back, assembled here because the frame is the window's own knowledge
    /// and the tabs are the host's.
    var persistedWindow: PersistedDetachedWindow {
        // Not while fullscreen: the frame is then the whole screen, and a window restored into
        // that has no earlier size to come back to when the user leaves fullscreen. The last
        // windowed frame stays the stored one.
        let windowedFrame = window.flatMap { window -> String? in
            window.styleMask.contains(.fullScreen) ? lastWindowedFrame : NSStringFromRect(window.frame)
        } ?? lastWindowedFrame
        return PersistedDetachedWindow(
            id: windowID.uuidString,
            frame: windowedFrame,
            activeTabID: host.persistedActiveTabID,
            isFullScreen: window?.styleMask.contains(.fullScreen) == true ? true : nil
        )
    }

    // MARK: - Private

    private func applyFrame(_ restored: NSRect?, droppedAt screenPoint: NSPoint?) {
        guard let window else { return }

        // Installing a content controller resizes the window to its fitting size, so the
        // intended frame is applied after — the main window's own ordering, for its reason.
        if let restored, restored.width >= Defaults.minimumSize.width,
           restored.height >= Defaults.minimumSize.height,
           NSScreen.screens.contains(where: { $0.frame.intersects(restored) }) {
            window.setFrame(restored, display: false)
            return
        }

        window.setContentSize(Defaults.size)

        // Carried here by hand: the window's strip lands under the pointer that dropped it, so
        // the chip the user was holding is where they let go rather than somewhere the app
        // chose. Clamped to the screen the drop happened on, because a window whose titlebar is
        // off the top of a display cannot be moved back.
        if let screenPoint {
            let size = window.frame.size
            var origin = NSPoint(
                x: screenPoint.x - Defaults.grabInset,
                y: screenPoint.y - size.height + Defaults.grabInset
            )
            if let visible = NSScreen.screens.first(where: {
                $0.frame.contains(screenPoint)
            })?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            }
            window.setFrameOrigin(origin)
            return
        }

        if let main = NSApp.mainWindow, main !== window {
            window.setFrameOrigin(NSPoint(
                x: main.frame.minX + Defaults.cascade.x,
                y: main.frame.minY + Defaults.cascade.y
            ))
        } else {
            window.center()
        }
    }

    private func retitle() {
        window?.title = host.windowTitle
    }

    private func persist() {
        guard !isClosing else { return }
        onPersist?(self)
    }

    /// Coalesced, because `windowDidMove` and `windowDidResize` fire continuously through a drag
    /// and each write decodes and re-encodes the session's whole layout document. The same
    /// reasoning as `ProjectStore.scheduleSave`, which exists for exactly this shape of write.
    private func schedulePersist() {
        guard !isClosing, !isPersistScheduled else { return }
        isPersistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Defaults.persistCoalescing) { [weak self] in
            guard let self else { return }
            isPersistScheduled = false
            persist()
        }
    }
}

// MARK: - Menu Commands

/// The tab commands, answered here whenever this window is key.
///
/// This works *because* the menu items are nil-target. `AppDelegate` states that every command
/// routes through the main window controller deliberately, and that was right while there was
/// one window: an untargeted item walks the key window's responder chain first — first
/// responder, the window, its delegate, this controller — and only reaches the application
/// delegate if nothing along the way answered. So a second window does not need the routing
/// rewritten; it needs to be *in* the chain and to implement the four actions it should own.
///
/// The alternative was worse than it looks. `MainWindowController.closeActiveTab` resolves its
/// target from the main window's `firstResponder`, which a window keeps while it is **not** key
/// — so with this window in front, ⌘W did not fail, it closed a tab in the window behind,
/// silently and in the wrong place. Cycling and ⌘1–9 did the same. That is the class of failure
/// the exhaustive `TabHostID` switches cannot catch, because nothing about it is a type error.
extension DetachedBrowserWindowController {

    @objc func closeActiveTab() {
        if !host.closeActiveTab() { SystemAlert.refuse() }
    }

    @objc func selectPreviousTab() {
        if !host.selectAdjacentTab(offset: -1) { SystemAlert.refuse() }
    }

    @objc func selectNextTab() {
        if !host.selectAdjacentTab(offset: 1) { SystemAlert.refuse() }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        if !host.selectTab(atIndex: sender.tag - 1) { SystemAlert.refuse() }
    }
}

extension DetachedBrowserWindowController: NSMenuItemValidation {

    /// Asked only about items this object would receive, so the panes' own commands still
    /// validate against the main window exactly as before.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeActiveTab):
            return !host.isEmpty
        case #selector(selectPreviousTab), #selector(selectNextTab):
            return host.tabCount > 1
        case #selector(selectTabByNumber(_:)):
            // Written as two comparisons, not `1...host.tabCount`: an empty window makes that
            // `1...0`, which is not an empty range but a trap. Menu validation runs on every
            // menu open, so it would have crashed the app the first time someone opened the
            // View menu over a window whose last tab had just gone.
            return menuItem.tag >= 1 && menuItem.tag <= host.tabCount
        default:
            return true
        }
    }
}

// MARK: - Window Delegate

extension DetachedBrowserWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        onClose?(windowID)
    }

    /// The frame is the only thing that brings the window back where it was — there is no
    /// `NSWindowRestoration` anywhere in this app, and `setFrameAutosaveName` would need a
    /// unique name per window and would still know nothing about which session it belonged to.
    func windowDidMove(_ notification: Notification) {
        rememberWindowedFrame()
        schedulePersist()
    }

    func windowDidResize(_ notification: Notification) {
        rememberWindowedFrame()
        schedulePersist()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        persist()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        rememberWindowedFrame()
        persist()
    }

    /// The last frame the window had while *not* fullscreen — what a restore should come back to.
    private func rememberWindowedFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        lastWindowedFrame = NSStringFromRect(window.frame)
    }
}
