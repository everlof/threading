import AppKit

/// The tab host inside a detached browser window: the same `PaneTab` objects the panel and the
/// drawer hold, in a window of their own.
///
/// **Pinned to one session, and that is the whole difference.** The panel and the drawer follow
/// whatever session is on screen, so every one of their methods resolves a session first. A
/// window is not a pane in the session's workspace — it is a window the user put a page in, and
/// it keeps showing that page while they work on something else. So the session is stored once
/// and the `sessionID` arguments the host contract carries are checked against it rather than
/// used to look anything up.
///
/// **Browsers only**, for v1. `canAdopt` refuses everything else, which is not merely scope:
/// `WindowBackdrop` is one app-wide value describing the main window's terminal palette, and a
/// shell tab dragged here would read it and ink itself for a window it is no longer in. A
/// browser paints its own page and does not ask.
@MainActor
final class DetachedBrowserHostViewController: NSViewController {

    // MARK: - Properties

    /// The session this window belongs to, for its whole life. A detached window outlives the
    /// selection: that is what it is for.
    let sessionID: SessionID
    let windowID: UUID

    private let browserFactory: @MainActor (BrowserContextKind) -> BrowserViewController

    private var tabs = TabListState()
    private weak var installedController: NSViewController?

    /// Anything that changes what should be written back — tabs, order, selection.
    var onLayoutChanged: (() -> Void)?

    /// How many browsers this session already has **across every host**, so the per-session cap
    /// is one number rather than one per pane. Counting locally made the cap meaningless the
    /// moment a browser could move: every detach lowered the panel's count and re-opened
    /// headroom, so eight was really eight *per host*.
    var sessionBrowserCount: (() -> Int)?

    /// The last tab closed. A window with no tabs is not a window; the controller closes it.
    var onEmptied: (() -> Void)?

    /// The active tab changed what it is called, so the window can retitle.
    var onTitleChanged: (() -> Void)?

    /// The window appends "Move to …" here, because where else a tab could live is the window's
    /// knowledge and not this host's — the same seam the panel and drawer expose.
    var transferEntries: ((UUID) -> [ThemedMenuEntry])?

    /// The drag half of the same wiring, in screen points because this gesture crosses windows.
    var dragOutDestination: ((UUID, NSPoint) -> Bool)?
    var performDragOut: ((UUID, NSPoint) -> Void)?
    var dragOutEnded: ((UUID) -> Void)?

    private let strip = ThemedTabStripView(inkSource: .chrome)
    private lazy var newTabButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("New browser tab"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("New Browser Tab")
        button.onPress = { [weak self] in
            guard let self else { return }
            if addBrowserTab() == nil { SystemAlert.refuse() }
        }
        return button
    }()

    private lazy var contentView: NSView = {
        let content = NSView()
        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        return content
    }()

    /// What the window calls itself: the page on show, else the session's own name.
    var windowTitle: String {
        tabs.activeTab?.title ?? L10n.string("Browser")
    }

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        windowID: UUID = UUID(),
        browserFactory: @escaping @MainActor (BrowserContextKind) -> BrowserViewController = {
            BrowserViewController(contextKind: $0)
        }
    ) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.browserFactory = browserFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // The window's own ground under the strip band, for the drawer's reason: the strip is
        // inked from the chrome and needs a surface it can be read on. Unlike the drawer this
        // is the whole window's background, so nothing else paints behind the page.
        let backdrop = ThemedSurfaceView()
        backdrop.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        strip.chipMaxWidth = DisplayPaneDefaults.tabChipMaxWidth
        strip.onSelect = { [weak self] id in
            self?.activate(id: id)
        }
        strip.onClose = { [weak self] id in
            self?.close(id: id)
        }
        strip.onReorder = { [weak self] id, index in
            self?.move(id: id, toIndex: index)
        }
        strip.contextEntries = { [weak self] id in
            self?.tabContextEntries(for: id) ?? []
        }
        strip.externalDropTarget = { [weak self] id, windowPoint in
            guard let self, let point = screenPoint(from: windowPoint) else { return false }
            return dragOutDestination?(id, point) ?? false
        }
        strip.onDropOut = { [weak self] id, windowPoint in
            guard let self, let point = screenPoint(from: windowPoint) else { return }
            performDragOut?(id, point)
        }
        strip.onDragEnded = { [weak self] id in
            self?.dragOutEnded?(id)
        }
        view.addSubview(strip)
        view.addSubview(newTabButton)

        let separator = SeparatorView()
        view.addSubview(separator)
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newTabButton.centerYAnchor.constraint(equalTo: strip.contentCenterYAnchor),
            newTabButton.leadingAnchor.constraint(
                equalTo: strip.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            newTabButton.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Design.Spacing.small
            ),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: strip.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        render()
    }

    // MARK: - Public

    /// What a detached window may hold, asked without building one — so the menu offering
    /// "Open in New Window" and the move that follows it cannot disagree about what travels.
    ///
    /// Browsers, and shared ones at that. A private context cannot be restored — it is
    /// ephemeral by definition — and `canAdopt` is bounded by what a host could rebuild after a
    /// relaunch, so admitting one would be admitting a tab the layout later forgets. Shells are
    /// refused for `WindowBackdrop`'s reason, in the type's own note.
    static func canHold(_ tab: PaneTab) -> Bool {
        guard case .browser(let browser) = tab.body else { return false }
        return browser.contextKind == .shared
    }

    @discardableResult
    func addBrowserTab(contextKind: BrowserContextKind = .shared) -> BrowserViewController? {
        let existing = sessionBrowserCount?() ?? tabs.tabs.filter { $0.browser != nil }.count
        guard existing < DisplayPaneDefaults.maximumBrowserTabs else { return nil }

        let controller = makeBrowser(contextKind: contextKind)
        let tab = PaneTab(body: .browser(controller), owningSessionID: sessionID)
        tabs.insert(tab)
        tabs.activate(id: tab.id)
        render()
        onLayoutChanged?()
        return controller
    }

    /// Puts back what was persisted. Separate from `adopt` because a restore is not a transfer:
    /// nothing is being taken from another host, and no layout is written back for it.
    func restore(_ restored: [PaneTab], activeID: UUID?) {
        for tab in restored {
            tab.owningSessionID = sessionID
            if let controller = tab.hostedController, controller.parent !== self {
                addChild(controller)
            }
            tabs.insert(tab)
        }
        if let activeID { tabs.activate(id: activeID) }
        else if let first = tabs.tabs.first { tabs.activate(id: first.id) }
        render()
    }

    /// The browser a restore needs to build, so the window controller does not have to know how
    /// this host makes one.
    func makeRestoredBrowser(url: String?) -> BrowserViewController {
        let controller = makeBrowser(contextKind: .shared)
        controller.restoredURL = url
        return controller
    }

    var persistedTabs: [PersistedTab] {
        tabs.tabs.compactMap { tab in
            guard let browser = tab.browser, browser.contextKind == .shared else { return nil }
            guard let url = browser.currentURL?.absoluteString ?? browser.restoredURL else {
                return nil
            }
            return PersistedTab(
                id: tab.id.uuidString,
                kind: .browser,
                title: tab.title,
                subtitle: "",
                url: url,
                html: nil,
                cacheFile: nil,
                host: PersistedTab.detachedWindowHost(windowID)
            )
        }
    }

    var persistedActiveTabID: String? {
        guard let active = tabs.activeTab,
              persistedTabs.contains(where: { $0.id == active.id.uuidString })
        else { return nil }
        return active.id.uuidString
    }

    var isEmpty: Bool { tabs.tabs.isEmpty }

    var tabCount: Int { tabs.tabs.count }

    // MARK: - Keyboard Commands

    /// ⌘W inside this window. Closing the last tab closes the window, which is what `onEmptied`
    /// already arranges — a window kept open around nothing is not a window.
    @discardableResult
    func closeActiveTab() -> Bool {
        guard let activeID = tabs.activeTab?.id else { return false }
        return close(id: activeID)
    }

    /// ⇧⌘[ and ⇧⌘], wrapping — the main window's own rule for its strips, so one window's tabs
    /// do not cycle differently from another's.
    @discardableResult
    func selectAdjacentTab(offset: Int) -> Bool {
        let all = tabs.tabs
        guard all.count > 1,
              let activeID = tabs.activeTab?.id,
              let index = all.firstIndex(where: { $0.id == activeID })
        else { return false }

        let target = (index + offset % all.count + all.count) % all.count
        return activate(id: all[target].id)
    }

    /// ⌘1–⌘9. Out of range fails rather than clamping: ⌘9 is not a request for the last tab,
    /// it is a miss — again the main window's rule.
    @discardableResult
    func selectTab(atIndex index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        return activate(id: tabs.tabs[index].id)
    }

    func focusActiveTab() {
        guard let controller = tabs.activeTab?.hostedController else { return }
        view.window?.makeFirstResponder(controller.view)
    }

    // MARK: - Private

    private func makeBrowser(contextKind: BrowserContextKind) -> BrowserViewController {
        let controller = browserFactory(contextKind)
        addChild(controller)
        controller.onPageChange = pageHook
        return controller
    }

    /// Installed on every browser this host shows, however it arrived.
    private var pageHook: () -> Void {
        { [weak self] in
            guard let self else { return }
            render()
            onTitleChanged?()
            onLayoutChanged?()
        }
    }

    private func adoptPageHook(_ tab: PaneTab) {
        tab.browser?.onPageChange = pageHook
    }

    @discardableResult
    private func activate(id: UUID) -> Bool {
        guard tabs.activate(id: id) else { return false }
        render()
        onTitleChanged?()
        onLayoutChanged?()
        return true
    }

    @discardableResult
    private func close(id: UUID) -> Bool {
        guard let (removed, _) = tabs.remove(id: id) else { return false }
        if installedController === removed.hostedController { installHosted(nil) }
        removed.hostedController?.view.removeFromSuperview()
        removed.hostedController?.removeFromParent()
        render()
        onTitleChanged?()
        onLayoutChanged?()
        if tabs.tabs.isEmpty { onEmptied?() }
        return true
    }

    @discardableResult
    private func move(id: UUID, toIndex index: Int) -> Bool {
        guard tabs.move(id: id, toIndex: index) else { return false }
        render()
        onLayoutChanged?()
        return true
    }

    private func tabContextEntries(for id: UUID) -> [ThemedMenuEntry] {
        standardTabEntries(for: id, sessionID: sessionID) + (transferEntries?(id) ?? [])
    }

    private func render() {
        guard isViewLoaded else { return }

        strip.update(items: tabs.tabs.map {
            TabStripItem(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isActive: $0.id == tabs.activeTab?.id
            )
        })
        installHosted(tabs.activeTab?.hostedController)
    }

    private func installHosted(_ controller: NSViewController?) {
        guard installedController !== controller else { return }

        installedController?.view.removeFromSuperview()
        installedController = controller

        guard let controller else { return }

        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        // A restored page loads when it is first shown, exactly as the other hosts defer it —
        // and the measurement behind the detached window says this is enough: a window that has
        // been ordered in captures correctly even when it is later hidden, but one that was
        // never shown renders nothing at all. See `BrowserOffScreenCaptureTests`.
        if let browser = controller as? BrowserViewController,
           browser.currentURL == nil, let url = browser.restoredURL {
            browser.restoredURL = nil
            browser.navigate(to: url)
        }
    }
}

// MARK: - Drop Band Hosting

extension DetachedBrowserHostViewController: TabDropBandHosting {

    var isDropBandVisible: Bool {
        isViewLoaded && view.window != nil
    }

    func dropBandContains(screenPoint: NSPoint) -> Bool {
        guard isDropBandVisible, let window = view.window else { return false }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard view.bounds.contains(point) else { return false }
        return point.y >= view.bounds.maxY - ThemedTabStripView.bandHeight
    }

    func dropInsertionIndex(screenPoint: NSPoint) -> Int {
        guard isViewLoaded, let window = view.window else { return 0 }
        return strip.insertionIndex(
            forWindowPoint: window.convertPoint(fromScreen: screenPoint)
        )
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isViewLoaded else { return }
        strip.isDropTarget = highlighted
    }

    fileprivate func screenPoint(from windowPoint: NSPoint) -> NSPoint? {
        view.window.map { $0.convertPoint(toScreen: windowPoint) }
    }
}

// MARK: - Tab Hosting

extension DetachedBrowserHostViewController: TabHosting {

    var hostID: TabHostID { .detachedWindow(windowID) }

    /// Every method checks the session rather than resolving one: this host has exactly one, and
    /// a caller naming a different session is asking about tabs that are not here.
    private func owns(_ sessionID: SessionID?) -> Bool {
        sessionID == nil || sessionID == self.sessionID
    }

    func tabs(for sessionID: SessionID?) -> [PaneTab] {
        owns(sessionID) ? tabs.tabs : []
    }

    func activeTabID(for sessionID: SessionID?) -> UUID? {
        owns(sessionID) ? tabs.activeTab?.id : nil
    }

    @discardableResult
    func activateTab(id: UUID, for sessionID: SessionID?) -> Bool {
        owns(sessionID) ? activate(id: id) : false
    }

    @discardableResult
    func closeTab(id: UUID, for sessionID: SessionID?) -> Bool {
        owns(sessionID) ? close(id: id) : false
    }

    @discardableResult
    func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID?) -> Bool {
        owns(sessionID) ? move(id: id, toIndex: index) : false
    }

    func canAdopt(_ tab: PaneTab) -> Bool {
        Self.canHold(tab)
    }

    func detachTab(id: UUID, for sessionID: SessionID?) -> PaneTab? {
        guard owns(sessionID), let (removed, _) = tabs.remove(id: id) else { return nil }

        if installedController === removed.hostedController { installHosted(nil) }
        removed.hostedController?.view.removeFromSuperview()
        removed.hostedController?.removeFromParent()

        render()
        onTitleChanged?()
        onLayoutChanged?()
        // Deliberately after the write: a window emptied by a *move* closes exactly as one
        // emptied by a close does, and the layout it wrote is the empty one that drops it.
        if tabs.tabs.isEmpty { onEmptied?() }
        return removed
    }

    func adopt(_ tab: PaneTab, at index: Int?, for sessionID: SessionID?) {
        guard owns(sessionID) else { return }
        if let controller = tab.hostedController { addChild(controller) }
        // The page hook belongs to whoever is showing the page. It was built capturing the host
        // that made the browser, so a moved tab keeps telling its *old* host about navigations —
        // and when that host is a window that has since closed, the closure is dead and nothing
        // retitles, re-renders or persists here again.
        adoptPageHook(tab)
        // The tab is this window's session's now and stays so wherever it goes next — a moved
        // tab that forgot whose it was is how a drag back lands in the wrong session's panel.
        tab.owningSessionID = self.sessionID
        tabs.insert(tab, at: index)
        tabs.activate(id: tab.id)
        render()
        onTitleChanged?()
        onLayoutChanged?()
    }
}

// MARK: - Session Browser Hosting

extension DetachedBrowserHostViewController: SessionBrowserHosting {

    func browserTabs(for sessionID: SessionID) -> [PaneTab] {
        owns(sessionID) ? tabs.tabs.filter { $0.browser != nil } : []
    }

    func preferredBrowserTabID(for sessionID: SessionID) -> UUID? {
        guard owns(sessionID) else { return nil }
        if let active = tabs.activeTab, active.holdsAgentDrivableBrowser { return active.id }
        return tabs.tabs.first(where: \.holdsAgentDrivableBrowser)?.id
    }
}
