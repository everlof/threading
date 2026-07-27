import AppKit
import SkalmanExtensionKit

/// The application's single window: a project sidebar beside the active session's terminal.
final class MainWindowController: ThemedWindowController {

    private enum SessionLoadingReason: Hashable {
        case gitStatus
        case gitReview
    }

    // MARK: - Properties

    /// Not private: the toolbar delegate needs the split view for its tracking separator.
    private(set) var splitViewController: SidebarSplitViewController!
    private var sidebarViewController: ProjectSidebarViewController!
    private var containerViewController: TerminalContainerViewController!
    private var extensionHookViewController: ExtensionComponentHookViewController!

    /// Retained so the sidebar can be collapsed and restored directly.
    private var sidebarItem: NSSplitViewItem!

    /// Owns session creation, import, worktree targeting, surface switches, and closing.
    private var sessionCoordinator: SessionCoordinator!

    /// The session that was on screen before Settings opened, restored when it closes.
    private var preSettingsSessionID: SessionID?

    /// The panel agents display content in, and its split item, retained so it can be
    /// revealed when content arrives.
    ///
    /// Not private: the MCP tool handlers put content into it. See `MainWindowMCPTools`.
    private(set) var displayPaneController: DisplayPaneController!
    private var displayItem: NSSplitViewItem!

    /// Owns agent-originated browser, display, storage, and theme requests.
    private(set) var agentToolCoordinator: AgentToolCoordinator!

    /// Suppresses width recording while the panel is being revealed, so the transient
    /// thickness that pass produces is not mistaken for a width the user chose.
    private var isRestoringDisplayPaneWidth = false

    /// Store-change observations, released with the window.
    private let appEvents = AppEventObservations()

    /// The active page, drawn as the selected tab of the window's page strip.
    ///
    /// The *same* class the display pane's strip uses, inked from the backdrop rather than the
    /// chrome because the toolbar floats over the terminal's own palette — which is the only thing
    /// that differs between the two, and now the only thing stated. See `ThemedTabItemView`.
    let pageTabView = ThemedTabItemView(
        title: "",
        symbolName: SessionTitleDefaults.projectSymbolName,
        placement: .horizontal,
        showsClose: true,
        inkSource: .backdrop
    )

    /// Toolbar pill showing the current account's rate-limit usage.
    let accountUsageItemView = AccountUsageItemView()

    /// App-owned toolbar controls, retained so pane visibility is reflected as selected state.
    var sidebarToolbarButton: ThemedIconButton?
    var newSessionButton: ThemedIconButton?
    var shellDrawerToolbarButton: ThemedIconButton?
    var displayPaneToolbarButton: ThemedIconButton?
    var sessionContextToolbarButton: ThemedIconButton?

    /// The toolbar context button's menu, rebuilt each open so the theme checkmarks are live.
    let sessionContextMenu = NSMenu()

    /// Builds the Theme submenu for the context button; retained because the items target it.
    let themeMenuBuilder = ThemeMenuBuilder()

    /// Exposed to the toolbar delegate, which needs the split view for its tracking separator.
    var splitView: NSSplitView { splitViewController.splitView }


    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?

    /// Several independent reads start from one selection. The row stops spinning only once all
    /// of them have landed, so a quick status summary cannot hide a still-rendering branch diff.
    private var sessionLoadingReasons: [SessionID: Set<SessionLoadingReason>] = [:]

    /// The inspect mode, kept here because extensions cannot store it. See `MainWindowInspector`.
    let elementInspector = ElementInspector()

    /// The session currently shown, if any.
    var currentSessionID: SessionID? {
        containerViewController.currentSessionID
    }

    /// The project implied by the visible session or composer. Settings and empty states carry
    /// no project context, so project-scoped extension commands disable there.
    var currentProjectID: ProjectID? {
        if let currentSessionID {
            return ProjectStore.shared.project(forSessionID: currentSessionID)?.id
        }
        return containerViewController.currentComposerProjectID
    }

    // MARK: - Initialization

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init() {
        self.init(window: Self.createWindow())
        setupSplitViewController()
        window?.delegate = self
        applyInitialFrame()
        updateWindowTitle()
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: WindowDefaults.defaultWidth,
            height: WindowDefaults.defaultHeight
        )

        // Full-size content so the sidebar runs the whole height of the window and the
        // traffic lights sit over it, rather than above a separate title bar. Views that
        // must not slide under the toolbar pin to their safe area instead.
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(width: WindowDefaults.minWidth, height: WindowDefaults.minHeight)
        window.titleVisibility = .hidden

        // Transparent so the toolbar draws no material bar of its own. Without it, that bar sits
        // between the window's rounded top corner and the content, and the window's lighter
        // default background shows in the gap as a pale sliver at the corner. Transparent, the
        // sidebar's material and the terminal's colour run cleanly up to the rounded corner.
        // (Wrongly blamed once for a mono-colour bug that was actually a missing COLORTERM.)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        return window
    }

    /// Sizes the window once its content is installed.
    ///
    /// Assigning a `contentViewController` resizes the window to that controller's fitting
    /// size, so any earlier frame is discarded. The intended size is therefore applied here,
    /// after setup, restoring the user's own size when one was saved.
    private func applyInitialFrame() {
        guard let window else { return }

        if !window.setFrameUsingName(MainWindowDefaults.frameAutosaveName) {
            window.setContentSize(NSSize(
                width: WindowDefaults.defaultWidth,
                height: WindowDefaults.defaultHeight
            ))
            window.center()
        }

        window.setFrameAutosaveName(MainWindowDefaults.frameAutosaveName)
    }

    // MARK: - Setup

    private func setupSplitViewController() {
        splitViewController = SidebarSplitViewController()

        sidebarViewController = ProjectSidebarViewController()
        sidebarViewController.delegate = self

        // A **plain** item, not `sidebarWithViewController:`, and that is the whole of the
        // sidebar's new silhouette.
        //
        // On macOS 26 the sidebar behaviour draws the pane as a floating inset panel: rounded,
        // held off the window's edges by a margin, with the content pane visible around it.
        // That is the platform's own look and there is no property to decline it —
        // `allowsFullHeightLayout` and `titlebarSeparatorStyle` both leave the inset in place.
        // It is also the wrong shape for this window, whose sidebar is a *structural column*
        // beside a terminal rather than a panel over a document: the margin left the tabs and
        // toolbar controls beside it reading as loose parts, and the terminal's own colour ran
        // underneath the sidebar it is supposed to sit next to.
        //
        // So the pane is ours: flush to the window's edges, full height under the transparent
        // titlebar, its own opaque ground (`ProjectSidebarViewController.applySidebarSurface`),
        // and the split view's hairline as the only seam. What the behaviour gave that has to
        // be replaced by hand is exactly two things — the material, and the collapse animation
        // (`SidebarSplitViewController.toggleSidebar`) — and the app already owned the second.
        sidebarItem = NSSplitViewItem(viewController: sidebarViewController)
        sidebarItem.minimumThickness = SidebarDefaults.minWidth
        sidebarItem.maximumThickness = SidebarDefaults.maxWidth
        sidebarItem.canCollapse = true
        // The sidebar is the fixed column: a window resize is absorbed by the terminal, which is
        // what the sidebar behaviour arranged for itself and a plain item does not.
        sidebarItem.holdingPriority = SidebarDefaults.holdingPriority
        splitViewController.addSplitViewItem(sidebarItem)

        containerViewController = TerminalContainerViewController()
        containerViewController.delegate = self

        sessionCoordinator = SessionCoordinator(
            sidebar: sidebarViewController,
            container: containerViewController,
            onPresentationChanged: { [weak self] in self?.updateSessionTitleItem() }
        )
        containerViewController.composerViewController.delegate = sessionCoordinator
        pageTabView.onClose = { [weak self] in self?.closeActivePageTab() }
        pageTabView.onSelect = { [weak self] in self?.revealActivePageInSidebar() }
        // The toolbar shows exactly one page, and it is always the current one.
        pageTabView.isSelected = true

        let contentItem = NSSplitViewItem(viewController: containerViewController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = MainWindowDefaults.minContentWidth
        splitViewController.addSplitViewItem(contentItem)

        setupDisplayPane()
        setupAgentToolCoordinator()

        extensionHookViewController = ExtensionComponentHookViewController(
            target: .init(
                component: .applicationMainWindow,
                contractVersion: 1
            ),
            child: splitViewController,
            customSurfaceResolver: { [weak self] surface, extensionIdentifier in
                self?.renderCustomSurface(
                    surface,
                    extensionIdentifier: extensionIdentifier
                )
            }
        )
        window?.contentViewController = extensionHookViewController

        // Installed after the split view exists: the tracking separator item needs it.
        window?.toolbar = makeToolbar()
        updateToolbarControlStates()

        // Compact, not `.unified`: the large style reserves a title-scale toolbar row, which
        // dwarfs the deliberately quiet session tab and its compact app-owned actions.
        window?.toolbarStyle = .unifiedCompact

        // The pane's own header, built here because the window controller owns what these
        // controls do, and installed there because the pane owns where they sit.
        containerViewController.installHeader(makePaneHeaderView())
        splitViewController.sidebarTransitionDidComplete = { [weak self] isCollapsed in
            self?.updateHeaderInset(sidebarIsCollapsed: isCollapsed)
        }
    }

    private func renderCustomSurface(
        _ surface: ExtensionCustomSurface,
        extensionIdentifier: String
    ) -> NSView? {
        switch surface {
        case .metal(let specification):
            guard let resourceURL = ExtensionManager.shared.customSurfaceResourceURL(
                relativePath: specification.shaderResource,
                extensionIdentifier: extensionIdentifier
            ), let source = try? String(contentsOf: resourceURL, encoding: .utf8) else {
                return nil
            }
            do {
                return try ExtensionMetalSurfaceView(
                    specification: specification,
                    source: source,
                    signalProvider: { [weak self] signal in
                        self?.extensionHostSignal(signal)
                    }
                )
            } catch {
                SkalmanLogger.extensions.error(
                    "Could not render Metal surface from \(extensionIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    private func extensionHostSignal(_ signal: ExtensionHostSignal) -> Double? {
        switch signal {
        case .activeAccountUsageRemaining:
            guard let account = accountUsageItemView.account,
                  let used = AccountUsageService.shared
                    .usage(for: account)?
                    .peakWindow()?
                    .fraction else {
                return nil
            }
            return 1 - min(max(used, 0), 1)
        default:
            return nil
        }
    }

    private func setupAgentToolCoordinator() {
        agentToolCoordinator = AgentToolCoordinator(
            displayPaneController: displayPaneController,
            visibleSessionID: { [weak self] in self?.currentSessionID },
            setPaneVisible: { [weak self] visible in self?.setDisplayPaneVisible(visible) },
            windowProvider: { [weak self] in self?.window }
        )
    }

    /// Adds the panel agents display content in, collapsed until something arrives.
    ///
    /// Appended last, so it takes divider index 1 and leaves the toolbar's tracking separator
    /// — which is bound to divider 0, between sidebar and terminal — undisturbed.
    private func setupDisplayPane() {
        displayPaneController = DisplayPaneController()
        displayPaneController.onClose = { [weak self] in
            self?.setDisplayPaneVisible(false)
        }
        displayPaneController.onReviewLoadingChange = { [weak self] sessionID, isLoading in
            self?.setSessionLoading(
                isLoading,
                reason: .gitReview,
                for: sessionID
            )
        }

        // The shell drawer belongs to the terminal container, on the other side of the split; the
        // window is what can see both, so it is what joins them.
        displayPaneController.shellRootResolver = { [weak self] sessionID in
            self?.containerViewController.shellRootPid(for: sessionID)
        }

        displayItem = NSSplitViewItem(viewController: displayPaneController)
        displayItem.canCollapse = true
        displayItem.minimumThickness = DisplayPaneDefaults.minWidth
        // The divider's position is the user's answer, and it outranks what the pane's own
        // content would prefer — see `DisplayPaneDefaults.holdingPriority`.
        displayItem.holdingPriority = DisplayPaneDefaults.holdingPriority
        displayItem.isCollapsed = true
        splitViewController.addSplitViewItem(displayItem)

        // Records the width whenever the divider moves, so a width the user chose survives
        // a restart. The window's own frame is autosaved for the same reason.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )

        // The toolbar names whatever is on screen, and a session can be renamed from
        // somewhere that never touches the terminal — the row's `⋯` menu, or another
        // window. Only the *agent's* own title reached here before, through
        // `sessionTitleChanged`, so a rename left the tab holding the old name until the
        // pane next changed.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.updateSessionTitleItem()
        }
    }

    /// Supplies the extension runtime broker with the same shell root as the native Info pane.
    ///
    /// The broker receives only a root chosen by Skalman for a known session. It never receives
    /// the terminal container or a way to query arbitrary processes.
    func extensionShellRootPid(for sessionID: SessionID) -> pid_t? {
        containerViewController?.shellRootPid(for: sessionID)
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        // Fires while a divider is dragged and when a pane collapses, which are the two ways the
        // content pane can arrive at the window's leading edge.
        updateHeaderInset()

        guard let displayItem, !displayItem.isCollapsed, !isRestoringDisplayPaneWidth else {
            return
        }

        let width = displayItem.viewController.view.bounds.width
        guard width > 0 else { return }

        DisplayPaneWidth.stored = width
    }

    // MARK: - Header Inset

    /// Keeps the pane header's first control clear of the window's own controls.
    ///
    /// The header shares its strip with the traffic lights and the sidebar toggle, which is fine
    /// while the sidebar is there: the pane begins past them. **Collapsed, the pane begins at the
    /// window's leading edge and the tab lands on top of the lights** — the one thing a
    /// pane-owned header has to know about the window, and the reason this project's earlier
    /// hand-rolled header was abandoned.
    ///
    /// Measured, not assumed: the lights and the toggle are AppKit's to size, and the answer is
    /// simply where the toggle ends. One value per collapse, not a feedback loop — the strip's
    /// contents do not move while the sidebar is out.
    private func updateHeaderInset(sidebarIsCollapsed: Bool? = nil) {
        guard let sidebarItem, let containerViewController else { return }

        guard sidebarIsCollapsed ?? sidebarItem.isCollapsed else {
            containerViewController.headerLeadingInset = PaneHeaderDefaults.inset
            return
        }

        let pane = containerViewController.view
        let paneMinX = pane.convert(pane.bounds, to: nil).minX
        let measuredControlsMaxX = sidebarToolbarButton.map {
            $0.convert($0.bounds, to: nil).maxX
        }
        // A toolbar item can already exist while its view still has a zero frame (notably while
        // attaching a hosted test window). That is not a measurement. Keep the launch fallback
        // until AppKit has actually placed the control, then replace it with the real edge.
        let controlsMaxX = measuredControlsMaxX.flatMap {
            $0 > PaneHeaderDefaults.inset ? $0 : nil
        } ?? PaneHeaderDefaults.assumedWindowControlsWidth
        let measuredClearance = controlsMaxX - paneMinX + Design.Spacing.medium
        // A collapsed split item can retain its pre-animation model frame even after the
        // presentation has reached the window edge. In that state subtracting `paneMinX` makes
        // the controls appear safely outside the pane although they are visually over it. Use
        // the same launch fallback until the pane's model frame catches up.
        let clearance = paneMinX > PaneHeaderDefaults.inset
            ? PaneHeaderDefaults.assumedWindowControlsWidth + Design.Spacing.medium
            : measuredClearance

        containerViewController.headerLeadingInset = max(
            PaneHeaderDefaults.inset,
            clearance
        )
    }

    // MARK: - Display Pane

    /// Shows or hides the display panel.
    func setDisplayPaneVisible(_ visible: Bool) {
        guard displayItem.isCollapsed == visible else { return }

        guard visible else {
            displayItem.isCollapsed = true
            updateToolbarControlStates()
            return
        }

        // Read *before* uncollapsing. The layout that follows fires resize notifications
        // carrying a transient thickness — the item's minimum — and recording that would
        // overwrite the width about to be restored with that minimum on every first reveal.
        let target = DisplayPaneWidth.stored
        isRestoringDisplayPaneWidth = true
        displayItem.isCollapsed = false
        updateToolbarControlStates()

        // Deferred by one turn of the run loop. Uncollapsing does not lay the item out
        // synchronously, so a width applied here lands on the previous layout and is lost.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyDisplayPaneWidth(target)

            // Cleared a turn later, once the layout that produced has drained and the
            // notifications it raised have been ignored.
            DispatchQueue.main.async { self.isRestoringDisplayPaneWidth = false }
        }
    }

    /// Opens the panel at the width it was last left at.
    ///
    /// Applied on every reveal rather than only the first, which is what carries a dragged
    /// width across restarts. It reads as no snap-back because the width being restored is
    /// the one the user themselves chose.
    ///
    /// Done with a constraint rather than `NSSplitView.setPosition`, which this window's
    /// `NSSplitViewController` ignores outright — it lays its items out with Auto Layout, and
    /// a `setPosition(915, ofDividerAt: 1)` measurably left the pane at its 260pt minimum.
    /// The constraint is released as soon as it has been honoured, so the divider stays
    /// draggable instead of being pinned to the width just restored.
    private func applyDisplayPaneWidth(_ width: CGFloat) {
        let paneView = displayItem.viewController.view

        let constraint = paneView.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        paneView.layoutSubtreeIfNeeded()
        constraint.isActive = false
    }

    /// Points the panel at whichever session is on screen.
    ///
    /// Content belongs to a session, so switching sessions switches what the panel shows,
    /// and a session with nothing to show closes it rather than leaving the last image up.
    private func syncDisplayPane(to sessionID: SessionID?) {
        displayPaneController.showSession(sessionID)

        guard let sessionID, displayPaneController.hasContent(for: sessionID) else {
            setDisplayPaneVisible(false)
            return
        }

        setDisplayPaneVisible(true)
    }

    private func setSessionLoading(
        _ isLoading: Bool,
        reason: SessionLoadingReason,
        for sessionID: SessionID
    ) {
        var reasons = sessionLoadingReasons[sessionID] ?? []
        if isLoading {
            reasons.insert(reason)
            sessionLoadingReasons[sessionID] = reasons
        } else {
            reasons.remove(reason)
            if reasons.isEmpty {
                sessionLoadingReasons.removeValue(forKey: sessionID)
            } else {
                sessionLoadingReasons[sessionID] = reasons
            }
        }
        if sessionID == currentSessionID {
            sidebarViewController.setSessionLoading(!reasons.isEmpty, for: sessionID)
        }
    }

    // MARK: - Public Methods

    /// Restores the session that was selected when the app last quit.
    func restoreSelectedSession() {
        guard AppSettings.shared.restoresLastSession,
              let sessionID = ProjectStore.shared.selectedSessionID,
              ProjectStore.shared.session(withID: sessionID) != nil else { return }

        sidebarViewController.select(sessionID: sessionID)
    }

    /// Selects through the same sidebar path as a local click, so loading state, persistence,
    /// display-pane routing, and surface launch cannot drift for a remote resume. Selection is
    /// intentionally background-only; remote activity must not make the app key.
    func resumeRemoteSession(_ sessionID: SessionID) {
        // AppKit does not emit a selection-change callback when the requested row is already
        // selected. That is exactly the shape of a visible dormant placeholder, so resume it
        // directly instead of waiting on a delegate callback that will never arrive.
        if containerViewController.currentSessionID == sessionID {
            containerViewController.resumeCurrentSession()
            return
        }
        sidebarViewController.select(sessionID: sessionID)
    }

    @discardableResult
    func startRemoteSession(
        in projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        usesNativeUI: Bool,
        prompt: String
    ) -> AgentSession? {
        sessionCoordinator.startRemoteSession(
            in: projectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            usesNativeUI: usesNativeUI,
            prompt: prompt
        )
    }

    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool) {
        if archived, sessionID == currentSessionID {
            containerViewController.show(sessionID: nil)
        }
        sidebarViewController.reload()
    }

    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID) {
        containerViewController.reopenIfShowing(sessionID: sessionID)
        sidebarViewController.reload()
        updateSessionTitleItem()
    }

    /// Shows or hides the sidebar. Shared by the View menu and the themed toolbar action.
    func toggleSidebar() {
        let targetIsCollapsed = !sidebarItem.isCollapsed
        splitViewController.toggleSidebar(nil)
        // Move clear of the window controls at the start of a collapse. AppKit may withhold both
        // the final resize notification and the animation completion while a hosted window is
        // off screen; subsequent layout callbacks refine this fallback with measured geometry.
        updateHeaderInset(sidebarIsCollapsed: targetIsCollapsed)
        updateToolbarControlStates()
    }

    /// Keeps the toolbar naming whatever is on screen.
    ///
    /// Each branch hands the tab an **identity** as well as a title, which is what lets a rename
    /// morph while a change of page lands directly — see `ThemedTabItemView.update`.
    func updateSessionTitleItem() {
        if let pageID = containerViewController.currentSettingsPageID,
           let page = SettingsPages.page(id: pageID) {
            showPageTab(title: page.title, symbolName: page.symbol, identity: pageID)
            updateAccountUsageItem(session: nil)
            updateToolbarControlStates()
            return
        }

        let sessionID = containerViewController.currentSessionID
        let session = sessionID.flatMap { ProjectStore.shared.session(withID: $0) }

        if let sessionID, let session {
            let project = ProjectStore.shared.project(forSessionID: sessionID)
            showPageTab(
                title: session.displayTitle,
                symbolName: SessionTitleDefaults.projectSymbolName,
                identity: session.id,
                // The agent's own mark rather than a symbol, which is what the sidebar row beside
                // it shows for the same session.
                icon: session.kind.icon,
                toolTip: project.map { "\($0.name) — \(session.displayTitle)" }
            )
        } else if let projectID = containerViewController.currentComposerProjectID {
            let project = ProjectStore.shared.project(withID: projectID)
            showPageTab(
                title: project?.name ?? "New Session",
                symbolName: SessionTitleDefaults.projectSymbolName,
                identity: projectID,
                toolTip: project?.name
            )
        } else {
            pageTabView.isHidden = true
        }
        updateAccountUsageItem(session: session)
        updateToolbarControlStates()
    }

    private func showPageTab(
        title: String,
        symbolName: String,
        identity: AnyHashable,
        icon: NSImage? = nil,
        toolTip: String? = nil
    ) {
        pageTabView.isHidden = false
        pageTabView.update(
            title: title,
            symbolName: symbolName,
            showsClose: true,
            identity: identity
        )
        if let icon {
            pageTabView.setIcon(icon)
        }
        pageTabView.toolTip = toolTip ?? title
    }

    /// Clicking the active page tab shows *where* it is, by selecting and scrolling to its row in
    /// the sidebar.
    ///
    /// The tab is always the selected one — the toolbar shows exactly one page — so "select it"
    /// has nothing left to do in the pane. What it can still answer is the question a page tab
    /// raises when the sidebar has scrolled somewhere else or the row is nested under a collapsed
    /// group: *which of these is the thing I am looking at*.
    func revealActivePageInSidebar() {
        if let sessionID = containerViewController.currentSessionID {
            sidebarViewController.reveal(sessionID: sessionID)
        } else if let projectID = containerViewController.currentComposerProjectID {
            sidebarViewController.reveal(projectID: projectID)
        }
    }

    /// Closes the active page without killing the persisted session or its running agent.
    ///
    /// The sidebar remains the durable collection. Its page tab is transient: selecting the
    /// row opens it, and × returns the content pane to its empty state. Settings is a temporary
    /// mode and closes back to the page it replaced.
    private func closeActivePageTab() {
        if containerViewController.isShowingSettings {
            toggleSettings()
            return
        }

        sidebarViewController.clearSelection()
        containerViewController.show(sessionID: nil)
        syncDisplayPane(to: nil)
        updateSessionTitleItem()
        updateWindowTitle()
    }

    /// Points the usage pill at the shown session's account *and model*, or clears it.
    ///
    /// The model travels with the account because a model-scoped limit only binds a session
    /// running that model. It is the effective one — the session's own choice, else what the
    /// account is configured to use — since that is what the next turn will actually spend.
    private func updateAccountUsageItem(session: AgentSession?) {
        guard let session else {
            if accountUsageItemView.account != nil {
                accountUsageItemView.configure(account: nil)
            }
            return
        }

        let accountID = AccountID(provider: session.kind, handle: session.accountHandle)
        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        let model = session.model
            ?? AgentModels.defaultModel(for: session.kind, account: account)

        // Re-configured when either half changes: switching model inside a session moves which
        // limit binds it, without the account moving at all.
        guard accountUsageItemView.account?.id != accountID
            || accountUsageItemView.model != model else { return }

        accountUsageItemView.configure(account: account, model: model)
    }

    /// Opens Settings, or does nothing if already open. What a *door* to a page needs — see
    /// `showSettingsPage`, which then names the page to land on.
    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        guard !containerViewController.isShowingSettings else { return }
        toggleSettings()
    }

    /// What ⌘, does: opens Settings, and closes it again if it is already the page.
    ///
    /// The platform's Preferences chord only ever *opens*, because on macOS preferences are a
    /// separate window and ⌘W closes them. Here Settings is a **page in this window**, sharing
    /// the pane with the session it replaced — so the chord that put it there is the obvious
    /// thing to press to get the session back, and there is no second window for ⌘W to mean.
    func toggleSettingsFromCommand() {
        window?.makeKeyAndOrderFront(nil)
        toggleSettings()
    }

    /// Opens Settings directly on a named page — the door "Edit Themes…" walks through.
    func showSettingsPage(title: String) {
        guard let pageID = SettingsPages.id(ofTitle: title) else { return }
        showSettingsPage(id: pageID)
    }

    func showSettingsPage(id pageID: String) {
        guard SettingsPages.page(id: pageID) != nil else { return }
        showSettings()
        sidebarViewController.selectSettingsPage(id: pageID)
        containerViewController.showSettingsPage(id: pageID)
        updateSessionTitleItem()
    }

    /// Opens the display panel on the current session's tabs, or closes it.
    ///
    /// The toolbar button's job: the panel otherwise opens only when content arrives or a
    /// View-menu surface asks for it, which left no way to just look. An empty panel shows
    /// its placeholder, which is honest.
    func toggleDisplayPane() {
        if displayItem.isCollapsed {
            displayPaneController.showSession(containerViewController.currentSessionID)
            setDisplayPaneVisible(true)
        } else {
            setDisplayPaneVisible(false)
        }
        updateToolbarControlStates()
    }

    /// Opens the browser as a tab in the selected session's display panel, beside the terminal.
    ///
    /// The browser is per-session — it is one of that session's display tabs, so the agent
    /// running there and the user drive the same page. With no session selected there is nowhere
    /// for it to live, so the gesture just beeps.
    func showBrowser() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateBrowser(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    /// Opens the git review as a tab in the selected session's display panel — the same
    /// per-session shape as the browser, and the same beep when no session is selected.
    /// Opens or closes the shell under the session on screen. A session is required — the shell
    /// belongs to a conversation, which is the whole point of the change that put it here.
    func toggleShellDrawer() {
        window?.makeKeyAndOrderFront(nil)

        guard containerViewController.currentSessionID != nil else {
            NSSound.beep()
            return
        }
        containerViewController.toggleShellDrawer()
        updateToolbarControlStates()
    }

    /// Keeps toolbar controls semantic: a filled pane button means the pane is actually visible,
    /// and controls that need a session leave the key-view loop when no session is selected.
    func updateToolbarControlStates() {
        let hasSession = containerViewController.currentSessionID != nil
        sidebarToolbarButton?.isSelected = !sidebarItem.isCollapsed
        // **New Session is hidden while Settings is the page.** It creates a session, which a
        // preferences page is not a context for — and beside a closable "Profiles" tab a `+`
        // reads as "add another one of these", which is the one thing it does not do. The
        // design system's own rule: a control offering nothing here hides rather than sitting
        // there dead.
        newSessionButton?.isHidden = containerViewController.isShowingSettings
        shellDrawerToolbarButton?.isEnabled = hasSession
        shellDrawerToolbarButton?.isSelected = containerViewController.isShellDrawerOpen
        displayPaneToolbarButton?.isSelected = !displayItem.isCollapsed
        sessionContextToolbarButton?.isEnabled = hasSession || containerViewController.isShowingSettings
    }

    func showReview() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateReview(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    /// Opens a shell in the display pane. Unlike the others this *adds* one every time, which is
    /// the point — the browser and the review answer a question with one answer, while a second
    /// shell is a thing people actually want.
    func showTerminalTab() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.addTerminalTab(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    func showFilesTab() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateFiles(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    func showInfo() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateInfo(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    func showAttachments() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateAttachments(for: sessionID)
        displayPaneController.showSession(sessionID)
        setDisplayPaneVisible(true)
    }

    /// Opens Settings in the content pane, or closes it and returns to what was on screen. The
    /// sidebar itself swaps to the section list rather than a second sidebar appearing.
    func toggleSettings() {
        if containerViewController.isShowingSettings {
            sidebarViewController.setSettingsMode(false)

            if let sessionID = preSettingsSessionID {
                containerViewController.show(sessionID: sessionID)
                syncDisplayPane(to: sessionID)
            } else {
                containerViewController.show(sessionID: nil)
            }
            preSettingsSessionID = nil
        } else {
            preSettingsSessionID = containerViewController.currentSessionID
            sidebarViewController.setSettingsMode(true)
            containerViewController.showSettingsPage(id: SettingsPages.generalID)
            syncDisplayPane(to: nil)
        }

        updateSessionTitleItem()
    }

    /// Opens the composer for the project owning the current selection, or the first project.
    ///
    /// It does not create anything. A session carries four decisions — agent, account, model
    /// and which checkout it runs in — and the paths that created one outright answered all
    /// four with defaults the user never saw. The composer is now the only way in, so every
    /// session starts from a choice.
    func newSession() {
        sessionCoordinator.newSession()
    }

    func addProject() {
        sessionCoordinator.addProject()
    }

    func newProject() {
        sessionCoordinator.newProject()
    }

    /// Closes the current session's terminal, leaving it dormant and resumable.
    func closeCurrentSession() {
        sessionCoordinator.closeCurrentSession()
    }

    func increaseFontSize() {
        currentAgentController()?.session.increaseFontSize()
    }

    func decreaseFontSize() {
        currentAgentController()?.session.decreaseFontSize()
    }

    // MARK: - Find

    func showFind() {
        guard let contentView = window?.contentView,
              let terminalView = currentAgentController()?.session.terminalView else { return }

        if findBar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.onClose = { [weak self] in self?.hideFindBar() }

            contentView.addSubview(bar)

            findBarTopConstraint = bar.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: -FindBarDefaults.height
            )

            NSLayoutConstraint.activate([
                findBarTopConstraint!,
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])

            findBar = bar
        }

        findBar?.terminalView = terminalView

        findBarTopConstraint?.constant = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            contentView.layoutSubtreeIfNeeded()
        }

        findBar?.focus()
    }

    func hideFindBar() {
        guard let contentView = window?.contentView, findBar != nil else { return }

        findBarTopConstraint?.constant = -FindBarDefaults.height
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.standard
            contentView.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.findBar?.removeFromSuperview()
            self?.findBar = nil
            self?.currentAgentController()?.focusTerminal()
        })
    }

    // MARK: - Private Methods

    private func currentAgentController() -> AgentSessionViewController? {
        guard let currentSessionID else { return nil }
        return AgentRuntime.shared.controller(for: currentSessionID)
    }

    /// Keeps the window named after the app.
    ///
    /// The title bar is hidden, so this text only appears where macOS refers to the window
    /// by name — Mission Control, the Window menu, the app switcher — and the app's own name
    /// identifies it better there than whichever project happens to be selected. The current
    /// project and session are shown in the sidebar instead.
    private func updateWindowTitle() {
        window?.title = MainWindowDefaults.defaultTitle
        window?.subtitle = ""

        // Still tracked: it drives the proxy icon and path menu if the title bar is shown.
        window?.representedURL = currentSessionID
            .flatMap { ProjectStore.shared.project(forSessionID: $0) }?
            .folderURL
    }
}

// MARK: - ProjectSidebarViewControllerDelegate

extension MainWindowController: ProjectSidebarViewControllerDelegate {

    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSession sessionID: SessionID) {
        // Taken rather than read: an opening prompt belongs to the launch that follows it,
        // not to every later selection of the same session.
        let prompt = sessionCoordinator.takePendingPrompt()
        let previousSessionID = containerViewController.currentSessionID

        containerViewController.show(sessionID: sessionID, initialPrompt: prompt)
        syncDisplayPane(to: sessionID)

        // Visibility can change the attention state of the row leaving and entering the pane.
        // Those are the only two rows affected; rebuilding the entire outline made selection
        // cost proportional to the number of sessions.
        if let previousSessionID, previousSessionID != sessionID {
            sidebar.refreshRow(sessionID: previousSessionID)
        }
        sidebar.refreshRow(sessionID: sessionID)
    }

    /// A project has no terminal of its own, so selecting one offers the composer: the
    /// choices that are only made when a session starts.
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: ProjectID) {
        let previousSessionID = containerViewController.currentSessionID
        containerViewController.showComposer(projectID: projectID)
        syncDisplayPane(to: nil)
        if let previousSessionID {
            sidebar.refreshRow(sessionID: previousSessionID)
        }
    }

    /// A folder dropped on the sidebar lands in its composer, like one added from the panel:
    /// a project's first session is still a session, and still worth choosing.
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didAddProject project: Project) {
        sidebar.select(projectID: project.id)
    }

    /// Archives or restores a session, and clears the pane if the archived one was showing.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setArchived archived: Bool,
        for sessionID: SessionID
    ) {
        ProjectStore.shared.setArchived(archived, for: sessionID)

        if archived, sessionID == currentSessionID {
            containerViewController.show(sessionID: nil)
        }

        sidebar.reload()
    }

    /// Switches a session between the terminal and the native conversation, and reopens it
    /// there.
    ///
    /// This is a relaunch, not a new conversation: both surfaces resume the CLI by the
    /// session's own id and append to the same transcript, so the agent picks up where it
    /// left off under the other interface. The old process is discarded *first* and
    /// deliberately — two live processes sharing one id would interleave their writes into
    /// that single transcript.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setUsesNativeUI usesNative: Bool,
        for sessionID: SessionID
    ) {
        sessionCoordinator.setUsesNativeUI(usesNative, for: sessionID)
    }

    /// Moves a conversation to another account of the same agent and reopens it there.
    ///
    /// A move copies the transcript into the target account's config directory, so the resumed
    /// conversation arrives with its full context; what it cannot keep is the process, which
    /// belonged to the account it is leaving.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        moveSession sessionID: SessionID,
        toAccount account: AgentAccount
    ) {
        sessionCoordinator.moveSession(sessionID, to: account)
    }

    /// Forks a session into a side chat and opens it.
    ///
    /// Nothing here stops the parent: a fork writes its own transcript, which is exactly what
    /// lets the side chat run *beside* a live session instead of queueing behind it — the one
    /// constraint the surface switch has and this does not.
    ///
    /// An opening question travels the same one-shot coordinator route as the composer's,
    /// so "Ask on the Side…" needs no launch path of its own.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        createSideChatOf sessionID: SessionID,
        prompt: String?
    ) {
        sessionCoordinator.createSideChat(of: sessionID, prompt: prompt)
    }

    func projectSidebarDidRemoveSessions(_ sidebar: ProjectSidebarViewController) {
        // The shown session may have just been deleted; fall back to an empty pane.
        if let currentSessionID, ProjectStore.shared.session(withID: currentSessionID) == nil {
            containerViewController.show(sessionID: nil)
        }

        // A deleted session must not keep its image in memory, nor leave a live MCP endpoint
        // addressing a session that no longer exists.
        let liveSessionIDs = Set(ProjectStore.shared.projects.flatMap { $0.sessions.map(\.id) })
        displayPaneController.retainOnly(sessionIDs: liveSessionIDs)
        MCPSessionRegistry.retainOnly(sessionIDs: liveSessionIDs)
        GitTurnBaselineStore.shared.retainOnly(sessionIDs: liveSessionIDs)

        syncDisplayPane(to: containerViewController.currentSessionID)
    }

    func projectSidebarDidToggleSettings(_ sidebar: ProjectSidebarViewController) {
        toggleSettings()
    }

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        didSelectSettingsPage pageID: String
    ) {
        containerViewController.showSettingsPage(id: pageID)
        updateSessionTitleItem()
    }
}

// MARK: - TerminalContainerViewControllerDelegate

extension MainWindowController: TerminalContainerViewControllerDelegate {

    func terminalContainer(
        _ container: TerminalContainerViewController,
        visibleSessionDidChange sessionID: SessionID?
    ) {
        updateSessionTitleItem()
        updateWindowTitle()
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionTitleChanged title: String,
        for sessionID: SessionID
    ) {
        // The sidebar row carries the session name; the window stays named after the app.
        sidebarViewController.refreshRow(sessionID: sessionID)

        if sessionID == currentSessionID {
            updateSessionTitleItem()
        }
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionDidExit sessionID: SessionID,
        exitCode: Int32?
    ) {
        sidebarViewController.refreshRows()
        NotificationCenter.default.post(TerminalSessionDidEnd(sessionID: sessionID))
    }

    func terminalContainerDidRequestGitReview(_ container: TerminalContainerViewController) {
        showReview()
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionStateDidChange sessionID: SessionID
    ) {
        // Only the affected row, so a working session does not rebuild the whole list.
        sidebarViewController.refreshRow(sessionID: sessionID)

        // The review's Last Turn baseline is captured on the entering-working edge; the store
        // watches every change and finds that edge itself.
        GitTurnBaselineStore.shared.noteActivity(
            AgentRuntime.shared.activity(sessionID: sessionID),
            sessionID: sessionID
        )

        // An agent that just stopped working may have switched branches on the way.
        if AgentRuntime.shared.activity(sessionID: sessionID) != .working {
            sidebarViewController.refreshProjectRow(forSessionID: sessionID)

            // The session's own branch record follows the same moment; a change regroups
            // the sidebar through the store's change notification.
            ProjectStore.shared.refreshBranch(forSessionID: sessionID)

            // So does the agent's name for the conversation, which lives in the transcript.
            // This is the only way a *native* session's title arrives — no PTY, no OSC.
            SessionNaming.refreshAgentTitle(forSessionID: sessionID)

            // And the project's code count: a session that just stopped working is a project
            // whose code most likely just changed.
            CodeStatsService.shared.refreshProject(forSessionID: sessionID)

            // The tree probably changed too; an on-screen review tab refreshes itself.
            displayPaneController.noteSessionStoppedWorking(sessionID)

            // It also just spent tokens, so the finish is the moment the pill is most
            // likely stale. The service's spacing keeps a chatty session polite.
            if sessionID == currentSessionID, let account = accountUsageItemView.account {
                AccountUsageService.shared.refresh(account, force: true)
            }
        }
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        gitStatusLoadingDidChange isLoading: Bool,
        for sessionID: SessionID
    ) {
        setSessionLoading(isLoading, reason: .gitStatus, for: sessionID)
    }

}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        AgentRuntime.shared.terminateAll()
    }
}

// MARK: - Main Window Defaults

enum MainWindowDefaults {
    static let defaultTitle = "Skalman"
    static let frameAutosaveName = "SkalmanMainWindow"
    static let toolbarIdentifier = NSToolbar.Identifier("SkalmanMainToolbar")
    static let minContentWidth: CGFloat = 320

}

// MARK: - Display Pane Width

/// Remembers how wide the user left the display panel.
///
/// Kept out of `AppSettings`, which holds behavioural preferences the user sets deliberately.
/// This is window geometry, and belongs with the frame autosave rather than beside them.
enum DisplayPaneWidth {
    private static let key = "SkalmanDisplayPaneWidth"

    static var stored: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: key)
            // Absent, or narrower than the panel is allowed to be, means "never set".
            guard saved >= DisplayPaneDefaults.minWidth else {
                return DisplayPaneDefaults.defaultWidth
            }
            return CGFloat(saved)
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: key)
        }
    }
}

// MARK: - Find Bar Defaults

enum FindBarDefaults {
    static let height: CGFloat = 32
}
