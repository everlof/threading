import AppKit

/// The tabbed drawer under the conversation: the third tab host, on the same model as the
/// display panel.
///
/// The drawer used to *be* one shell view controller; now it hosts tabs, of which a shell is
/// the default first — created on first open with the same working-directory rule the lone
/// drawer documented (OSC 7, project folder as fallback). Its strip creates the kinds that are
/// naturally *many* — shells and browsers; the singleton surfaces (review, info, files) keep
/// their one home in the display panel, and movement between hosts is the transfer
/// coordinator's job, not a second creation path.
///
/// Tabs are per-session, exactly as the panel's are: switching sessions swaps which list is
/// shown and tears nothing down, so a shell keeps its process and scrollback across switches
/// — the old drawer's one load-bearing promise, kept. Closing a *tab* ends what it held.
@MainActor
final class DrawerHostViewController: NSViewController {

    // MARK: - Properties

    /// Where a new shell opens for a session — injected by the terminal container, which is
    /// the one place that can ask a running agent over OSC 7.
    private let directoryProvider: (SessionID) -> URL?

    private let browserFactory: @MainActor (BrowserContextKind) -> BrowserViewController

    private var statesBySession: [SessionID: TabListState] = [:]
    private var restoredSessions: Set<SessionID> = []

    /// Sessions whose drawer stands open, restored from the persisted payload on first ask.
    private var openSessions: Set<SessionID> = []

    private(set) var currentSessionID: SessionID?

    private let strip = ThemedTabStripView(inkSource: .chrome)
    private lazy var newTabButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("New drawer tab"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("New Drawer Tab")
        button.presentsMenu = true
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            presentNewTabMenu(from: button)
        }
        return button
    }()
    private lazy var contentView: NSView = {
        let content = NSView()
        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        return content
    }()
    private weak var installedController: NSViewController?
    private var newTabMenuSession: AnyObject?

    /// Extra context-menu entries for a tab — the window appends "Move to …" here, because
    /// where else a tab could live is the window's knowledge, not this host's.
    var transferEntries: ((UUID) -> [ThemedMenuEntry])?

    /// The drag half of the same wiring: whether a window point is over another pane that
    /// would adopt the tab, the move itself when the drop lands there, and the drag's end —
    /// dropped or not — so the window can settle what it arranged for the gesture. The
    /// context menu stays the gesture's pointerless twin.
    var dragOutDestination: ((UUID, NSPoint) -> Bool)?
    var performDragOut: ((UUID, NSPoint) -> Void)?
    var dragOutEnded: ((UUID) -> Void)?

    /// Whether a window point lands where a dropped tab would join this host — the strip
    /// band, full width, since an emptier strip is narrower than the drop it invites.
    func dropBandContains(windowPoint: NSPoint) -> Bool {
        guard isViewLoaded, view.window != nil else { return false }
        let point = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(point) else { return false }
        return point.y >= view.bounds.maxY - ThemedTabStripView.bandHeight
    }

    /// The wash on this host's strip while another pane's chip would land here.
    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isViewLoaded else { return }
        strip.isDropTarget = highlighted
    }

    /// The slot a drop at this window point takes, by the strip's own midpoint rule.
    func dropInsertionIndex(windowPoint: NSPoint) -> Int {
        guard isViewLoaded else { return 0 }
        return strip.insertionIndex(forWindowPoint: windowPoint)
    }

    // MARK: - Initialization

    /// Test seams for persistence, defaulting to the shared store. Injected because the store
    /// writes through `StateManager.shared` — the user's real database, which a behaviour test
    /// must never leave fixture rows in.
    typealias LoadPanel = @MainActor (SessionID) -> PersistedPanel?
    typealias PersistDrawer = @MainActor ([PersistedTab], String?, Bool?, SessionID) -> Void

    private let loadPanel: LoadPanel
    private let persistDrawer: PersistDrawer

    init(
        directoryProvider: @escaping (SessionID) -> URL?,
        browserFactory: @escaping @MainActor (BrowserContextKind) -> BrowserViewController = {
            BrowserViewController(contextKind: $0)
        },
        loadPanel: @escaping LoadPanel = { DisplayPaneStore.shared.loadLayout(for: $0) },
        persistDrawer: @escaping PersistDrawer = { tabs, activeID, open, sessionID in
            DisplayPaneStore.shared.saveDrawerLayout(
                tabs: tabs, activeID: activeID, open: open, for: sessionID
            )
        }
    ) {
        self.directoryProvider = directoryProvider
        self.browserFactory = browserFactory
        self.loadPanel = loadPanel
        self.persistDrawer = persistDrawer
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

        // The pane's own ground, in the chrome's colour — the display panel's reasoning
        // exactly (`DisplayPaneController.setupBackdrop`): this band sits on the window's
        // backdrop, which the terminal paints with a palette the chrome-inked strip cannot
        // read on. The shell below the strip paints itself with the session's theme, so what
        // this actually grounds is the strip band and any gap the content leaves.
        let backdrop = ThemedSurfaceView()
        backdrop.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        strip.chipMaxWidth = DisplayPaneDefaults.tabChipMaxWidth
        strip.onSelect = { [weak self] id in
            guard let self, let sessionID = currentSessionID else { return }
            activateTab(id: id, for: sessionID)
        }
        strip.onClose = { [weak self] id in
            guard let self, let sessionID = currentSessionID else { return }
            closeTab(id: id, for: sessionID)
        }
        strip.onReorder = { [weak self] id, index in
            guard let self, let sessionID = currentSessionID else { return }
            moveTab(id: id, toIndex: index, for: sessionID)
        }
        strip.contextEntries = { [weak self] id in
            self?.tabContextEntries(for: id) ?? []
        }
        strip.externalDropTarget = { [weak self] id, windowPoint in
            self?.dragOutDestination?(id, windowPoint) ?? false
        }
        strip.onDropOut = { [weak self] id, windowPoint in
            self?.performDragOut?(id, windowPoint)
        }
        strip.onDragEnded = { [weak self] id in
            self?.dragOutEnded?(id)
        }
        view.addSubview(strip)

        view.addSubview(newTabButton)

        // The pane's own fold under the strip, edge to edge like every pane header's.
        let separator = SeparatorView()
        view.addSubview(separator)

        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.heightAnchor.constraint(equalToConstant: ThemedTabStripView.bandHeight),

            newTabButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
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
    }

    // MARK: - Session Lifecycle

    /// Switches the drawer to a session's tabs. Nothing is torn down — a background session's
    /// shells keep running, exactly as its panel tabs keep their state.
    func showSession(_ sessionID: SessionID?) {
        currentSessionID = sessionID
        if let sessionID { restoreIfNeeded(sessionID) }
        render()
    }

    /// The drawer's open state, per session, surviving relaunch with the tabs themselves.
    func isOpen(for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        return openSessions.contains(sessionID)
    }

    func setOpen(_ open: Bool, for sessionID: SessionID) {
        restoreIfNeeded(sessionID)
        if open {
            openSessions.insert(sessionID)
        } else {
            openSessions.remove(sessionID)
        }
        persist(sessionID)
    }

    /// The default first tab: a session whose drawer opens with nothing gets its shell, which
    /// is what the drawer is *for*.
    func ensureDefaultShellTab(for sessionID: SessionID) {
        restoreIfNeeded(sessionID)
        guard statesBySession[sessionID, default: TabListState()].tabs.isEmpty else { return }
        addTerminalTab(for: sessionID)
    }

    /// Ends every live surface the session's drawer holds. The tab list itself stays persisted
    /// — a closed session's shells die with it, but its drawer comes back as it was, unstarted.
    func closeSession(_ sessionID: SessionID) {
        openSessions.remove(sessionID)
        guard let state = statesBySession[sessionID] else { return }
        state.tabs.forEach { teardownHosted($0) }
        statesBySession.removeValue(forKey: sessionID)
        restoredSessions.remove(sessionID)
        if currentSessionID == sessionID { render() }
    }

    /// Drops every session not in the given set — deletion, not closing, so nothing of theirs
    /// may stay alive. The persisted payloads are swept by `DisplayPaneStore.retainOnly`.
    func retainOnly(sessionIDs: Set<SessionID>) {
        for (sessionID, state) in statesBySession where !sessionIDs.contains(sessionID) {
            state.tabs.forEach { teardownHosted($0) }
            statesBySession.removeValue(forKey: sessionID)
            restoredSessions.remove(sessionID)
            openSessions.remove(sessionID)
        }
        if let currentSessionID, !sessionIDs.contains(currentSessionID) {
            self.currentSessionID = nil
            render()
        }
    }

    /// The session's first shell's root process — the info panel's attribution question,
    /// answered the way the lone drawer answered it.
    func shellRootPid(for sessionID: SessionID) -> pid_t? {
        statesBySession[sessionID]?.tabs
            .compactMap { $0.terminal?.shellRootPid }
            .first
    }

    /// The drawer's answer to "which browser is the session's": the active tab if it is one,
    /// else the first. Consulted by the panel's resolution as a fallback, so `browser_*` tools
    /// keep finding a browser the user moved down here.
    func browser(for sessionID: SessionID) -> BrowserViewController? {
        restoreIfNeeded(sessionID)
        guard let state = statesBySession[sessionID] else { return nil }
        if let active = state.activeTab?.browser { return active }
        return state.tabs.first(where: { $0.browser != nil })?.browser
    }

    func focusActiveTab() {
        guard let sessionID = currentSessionID,
              let active = statesBySession[sessionID]?.activeTab else { return }
        if let terminal = active.terminal {
            terminal.focus()
        } else if let controller = active.hostedController {
            view.window?.makeFirstResponder(controller.view)
        }
    }

    // MARK: - Tab Creation

    @discardableResult
    func addTerminalTab(for sessionID: SessionID) -> ShellDrawerViewController? {
        restoreIfNeeded(sessionID)
        guard let controller = makeTerminal(for: sessionID) else { return nil }

        var state = statesBySession[sessionID] ?? TabListState()
        let tab = PaneTab(body: .terminal(controller))
        state.insert(tab)
        state.activate(id: tab.id)
        statesBySession[sessionID] = state
        persist(sessionID)
        if sessionID == currentSessionID { render() }
        return controller
    }

    @discardableResult
    func addBrowserTab(
        for sessionID: SessionID,
        contextKind: BrowserContextKind = .shared
    ) -> BrowserViewController {
        restoreIfNeeded(sessionID)
        let controller = makeBrowser(for: sessionID, contextKind: contextKind)

        var state = statesBySession[sessionID] ?? TabListState()
        let tab = PaneTab(body: .browser(controller))
        state.insert(tab)
        state.activate(id: tab.id)
        statesBySession[sessionID] = state
        persist(sessionID)
        if sessionID == currentSessionID { render() }
        return controller
    }

    private func makeTerminal(for sessionID: SessionID) -> ShellDrawerViewController? {
        guard directoryProvider(sessionID) != nil else { return nil }
        let controller = ShellDrawerViewController(sessionID: sessionID) { [directoryProvider] in
            // Asked at the moment the shell starts, not when the tab was made — the agent
            // above may have moved by then. The provider's own fallback is the project folder.
            directoryProvider(sessionID) ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        addChild(controller)
        return controller
    }

    private func makeBrowser(
        for sessionID: SessionID,
        contextKind: BrowserContextKind = .shared
    ) -> BrowserViewController {
        let controller = browserFactory(contextKind)
        addChild(controller)
        controller.onPageChange = { [weak self] in
            guard let self else { return }
            persist(sessionID)
            if sessionID == self.currentSessionID { render() }
        }
        return controller
    }

    private func presentNewTabMenu(from source: NSView) {
        guard let sessionID = currentSessionID else { return }
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Terminal"),
                image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
                onChoose: { [weak self] in _ = self?.addTerminalTab(for: sessionID) }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Browser"),
                image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
                onChoose: { [weak self] in _ = self?.addBrowserTab(for: sessionID) }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Private Browser"),
                image: NSImage(
                    systemSymbolName: "hand.raised.fill",
                    accessibilityDescription: nil
                ),
                onChoose: { [weak self] in
                    _ = self?.addBrowserTab(for: sessionID, contextKind: .private)
                }
            ))
        ]
        newTabMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: DisplayPaneDefaults.newTabMenuMinimumWidth),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.newTabMenuSession = nil }
        )
    }

    // MARK: - Tab Operations

    @discardableResult
    func activateTab(id: UUID, for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        var state = statesBySession[sessionID] ?? TabListState()
        guard state.activate(id: id) else { return false }
        statesBySession[sessionID] = state
        persist(sessionID)
        if sessionID == currentSessionID { render() }
        return true
    }

    @discardableResult
    func closeTab(id: UUID, for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        var state = statesBySession[sessionID] ?? TabListState()
        guard let (removed, _) = state.remove(id: id) else { return false }
        teardownHosted(removed)
        statesBySession[sessionID] = state
        persist(sessionID)
        if sessionID == currentSessionID { render() }
        return true
    }

    @discardableResult
    func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        var state = statesBySession[sessionID] ?? TabListState()
        guard state.move(id: id, toIndex: index) else { return false }
        statesBySession[sessionID] = state
        persist(sessionID)
        if sessionID == currentSessionID { render() }
        return true
    }

    func tabs(for sessionID: SessionID) -> [PaneTab] {
        restoreIfNeeded(sessionID)
        return statesBySession[sessionID]?.tabs ?? []
    }

    func activeTabID(for sessionID: SessionID) -> UUID? {
        restoreIfNeeded(sessionID)
        return statesBySession[sessionID]?.activeTab?.id
    }

    private func tabContextEntries(for id: UUID) -> [ThemedMenuEntry] {
        guard let sessionID = currentSessionID else { return [] }
        var entries = standardTabEntries(for: id, sessionID: sessionID)
        guard !entries.isEmpty else { return [] }
        if let transfers = transferEntries?(id), !transfers.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: transfers)
        }
        return entries
    }

    /// A terminal is the one kind holding something a detach does not release: closing its tab
    /// has to kill the shell — the panel's rule, restated because the consequence is a process.
    private func teardownHosted(_ tab: PaneTab) {
        tab.terminal?.terminate()

        guard let controller = tab.hostedController else { return }
        if installedController === controller { installHosted(nil) }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }

        let state = currentSessionID.flatMap { statesBySession[$0] } ?? TabListState()
        strip.update(items: state.tabs.map {
            TabStripItem(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isActive: $0.id == state.activeTab?.id
            )
        })
        newTabButton.isHidden = currentSessionID == nil

        let active = state.activeTab
        installHosted(active?.hostedController)

        // Deferred exactly like the panel's terminal tabs: no process until the tab is shown
        // — and "shown" means on screen, so an unwindowed fixture never spawns a shell.
        if view.window != nil {
            active?.terminal?.startIfNeeded()
        }
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

        // A restored browser's page loads the moment it is first shown, not before.
        if let browser = controller as? BrowserViewController,
           browser.currentURL == nil, let url = browser.restoredURL {
            browser.restoredURL = nil
            browser.navigate(to: url)
        }
    }

    // MARK: - Persistence

    private func restoreIfNeeded(_ sessionID: SessionID) {
        guard !restoredSessions.contains(sessionID) else { return }
        restoredSessions.insert(sessionID)

        guard let panel = loadPanel(sessionID) else {
            statesBySession[sessionID] = TabListState()
            return
        }

        var tabs: [PaneTab] = []
        for persisted in panel.drawerTabs {
            let id = UUID(uuidString: persisted.id) ?? UUID()
            switch persisted.kind {
            case .terminal:
                // The tab comes back, the process does not — a shell's state was never on disk.
                guard let controller = makeTerminal(for: sessionID) else { continue }
                tabs.append(PaneTab(id: id, body: .terminal(controller)))

            case .browser:
                let controller = makeBrowser(for: sessionID)
                controller.restoredURL = persisted.url
                tabs.append(PaneTab(id: id, body: .browser(controller)))

            default:
                // Kinds the drawer cannot rebuild yet keep their place in the payload; they
                // are simply not shown until the host that can build them exists here.
                continue
            }
        }

        var state = TabListState(tabs: tabs)
        if let activeString = panel.drawerActiveTabID,
           let activeID = UUID(uuidString: activeString) {
            state.activate(id: activeID)
        } else if let last = tabs.last {
            state.activate(id: last.id)
        }
        statesBySession[sessionID] = state

        if panel.drawerOpen == true {
            openSessions.insert(sessionID)
        }
    }

    private func persist(_ sessionID: SessionID) {
        let state = statesBySession[sessionID] ?? TabListState()
        let persistedTabs = state.tabs.compactMap(persisted)
        let active = state.activeTab?.id.uuidString
        persistDrawer(persistedTabs, active, openSessions.contains(sessionID), sessionID)
    }

    private func persisted(_ tab: PaneTab) -> PersistedTab? {
        if tab.terminal != nil {
            return PersistedTab(
                id: tab.id.uuidString, kind: .terminal, title: tab.title,
                subtitle: "", url: nil, html: nil, cacheFile: nil,
                host: PersistedTab.drawerHost
            )
        }

        if let browser = tab.browser {
            guard browser.contextKind == .shared else { return nil }
            guard let url = browser.currentURL?.absoluteString ?? browser.restoredURL else {
                return nil
            }
            return PersistedTab(
                id: tab.id.uuidString, kind: .browser, title: tab.title,
                subtitle: "", url: url, html: nil, cacheFile: nil,
                host: PersistedTab.drawerHost
            )
        }

        return nil
    }
}

// MARK: - Tab Hosting

/// The drawer through the host-neutral contract, so the cycling commands act on it when focus
/// is inside it and transfers can reach it without knowing which pane they touched.
extension DrawerHostViewController: TabHosting {

    var hostID: TabHostID { .drawer }

    private func resolvedSession(_ sessionID: SessionID?) -> SessionID? {
        sessionID ?? currentSessionID
    }

    func tabs(for sessionID: SessionID?) -> [PaneTab] {
        resolvedSession(sessionID).map { tabs(for: $0) } ?? []
    }

    func activeTabID(for sessionID: SessionID?) -> UUID? {
        resolvedSession(sessionID).flatMap { activeTabID(for: $0) }
    }

    @discardableResult
    func activateTab(id: UUID, for sessionID: SessionID?) -> Bool {
        guard let session = resolvedSession(sessionID) else { return false }
        return activateTab(id: id, for: session)
    }

    @discardableResult
    func closeTab(id: UUID, for sessionID: SessionID?) -> Bool {
        guard let session = resolvedSession(sessionID) else { return false }
        return closeTab(id: id, for: session)
    }

    @discardableResult
    func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID?) -> Bool {
        guard let session = resolvedSession(sessionID) else { return false }
        return moveTab(id: id, toIndex: index, for: session)
    }

    /// The drawer shows what it can build — and therefore *restore*: shells and browsers. A
    /// session page can never live in a strip under a session; the singleton surfaces keep
    /// their one home in the panel; and a kind this host could not rebuild after a relaunch
    /// would be a tab the layout later forgets, which is worse than refusing the move.
    func canAdopt(_ tab: PaneTab) -> Bool {
        tab.terminal != nil || tab.browser != nil
    }

    func detachTab(id: UUID, for sessionID: SessionID?) -> PaneTab? {
        guard let session = resolvedSession(sessionID) else { return nil }
        restoreIfNeeded(session)
        var state = statesBySession[session] ?? TabListState()
        guard let (removed, _) = state.remove(id: id) else { return nil }

        // Unparent without ending: the shell keeps its process for whichever host adopts it.
        if let controller = removed.hostedController {
            if installedController === controller { installHosted(nil) }
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }

        statesBySession[session] = state
        persist(session)
        if session == currentSessionID { render() }
        return removed
    }

    func adopt(_ tab: PaneTab, at index: Int?, for sessionID: SessionID?) {
        guard let session = resolvedSession(sessionID) else { return }
        restoreIfNeeded(session)
        if let controller = tab.hostedController {
            addChild(controller)
        }
        var state = statesBySession[session] ?? TabListState()
        state.insert(tab, at: index)
        state.activate(id: tab.id)
        statesBySession[session] = state
        persist(session)
        if session == currentSessionID { render() }
    }
}
