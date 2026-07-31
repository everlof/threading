import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

/// The application's single window: a project sidebar beside the active session's terminal.
final class MainWindowController: ThemedWindowController, RemoteWorkspaceProviding {

    // MARK: - Properties

    /// Not private: the toolbar delegate needs the split view for its tracking separator.
    private(set) lazy var splitViewController = SidebarSplitViewController()
    private lazy var sidebarViewController = ProjectSidebarViewController()
    private lazy var workspaceSidebarViewController = WorkspaceSidebarContainerViewController(
        nativeController: sidebarViewController,
        routing: ExtensionManager.shared,
        contextProvider: { [weak self] in
            ExtensionCommandContext(
                projectID: self?.currentProjectID?.uuidString.lowercased(),
                sessionID: self?.currentSessionID?.uuidString.lowercased()
            )
        },
        destinationHandler: { [weak self] destination in
            self?.openWorkspaceNavigatorDestination(destination)
                ?? L10n.string("The workspace window is no longer available.")
        }
    )
    private lazy var containerViewController = TerminalContainerViewController()
    private lazy var extensionHookViewController = ExtensionComponentHookViewController(
        target: .init(component: .applicationMainWindow, contractVersion: 1),
        child: splitViewController,
        customSurfaceResolver: { [weak self] surface, extensionIdentifier in
            self?.renderCustomSurface(surface, extensionIdentifier: extensionIdentifier)
        }
    )

    /// Retained so the sidebar can be collapsed and restored directly.
    private lazy var sidebarItem = NSSplitViewItem(viewController: workspaceSidebarViewController)

    /// Owns session creation, import, worktree targeting, surface switches, and closing.
    private lazy var sessionCoordinator = SessionCoordinator(
        sidebar: sidebarViewController,
        container: containerViewController,
        onPresentationChanged: { [weak self] in self?.updateSessionTitleItem() }
    )

    /// The page that was on screen before Settings opened, restored when it closes.
    ///
    /// A *page*, not a session id: a project's composer is as much somewhere to come back to as
    /// a session is, and remembering only sessions dropped the user on the empty state — taking
    /// a half-written prompt off the screen with it.
    private var preSettingsPage: NavigationHistory.Page?

    /// Where the window has been: the selection history behind ⌃⌘← / ⌃⌘→.
    private var history = NavigationHistory()

    /// The page a Back or Forward press is currently presenting, so its arrival is recognised
    /// and not pushed as a fresh visit. A plain flag would not survive the sidebar's deferred
    /// presentation — the delegate callback lands a run-loop turn after `select` returns.
    private var pendingHistoryTarget: NavigationHistory.Page?

    /// The panel agents display content in, and its split item, retained so it can be
    /// revealed when content arrives.
    ///
    /// Not private: the MCP tool handlers put content into it. See `MainWindowMCPTools`.
    private(set) lazy var displayPaneController = DisplayPaneController()
    private lazy var displayItem = NSSplitViewItem(viewController: displayPaneController)

    /// Owns agent-originated browser, display, storage, and theme requests.
    private(set) lazy var agentToolCoordinator = AgentToolCoordinator(
        displayPaneController: displayPaneController,
        visibleSessionID: { [weak self] in self?.currentSessionID },
        setPaneVisible: { [weak self] visible in self?.setDisplayPaneVisible(visible) },
        windowProvider: { [weak self] in self?.window }
    )

    /// Suppresses width recording while the panel is being revealed, so the transient
    /// thickness that pass produces is not mistaken for a width the user chose.
    private var isRestoringDisplayPaneWidth = false

    /// The sidebar's width is not worth recording until the stored one has been put back.
    ///
    /// Launch lays the column out at its default before the restore can run, and the resize that
    /// produces would otherwise overwrite the width being restored — with the default, one turn
    /// of the run loop before it was going to be read.
    private var recordsSidebarWidth = false
    private var pendingWorkspaceNavigatorWidth: CGFloat?

    /// Store-change observations, released with the window.
    private let appEvents = AppEventObservations()

    /// The active page, drawn as the selected tab of the window's page strip.
    ///
    /// Deliberately a *single* chip, not a strip: a page here swaps the whole workspace — the
    /// drawer, the panel, the sidebar's selection — so a row of them would be a second session
    /// switcher wearing tab clothes. The sidebar is the switcher; this names where you are.
    /// The *same* class the pane strips use, inked from the backdrop rather than the chrome
    /// because the header floats over the terminal's own palette — which is the only thing
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

    /// App-owned chrome controls, retained so pane visibility and session state stay reflected.
    var sidebarToolbarButton: ThemedIconButton?
    var navBackToolbarButton: ThemedIconButton?
    var navForwardToolbarButton: ThemedIconButton?
    var newSessionButton: ThemedIconButton?
    var shellDrawerToolbarButton: ThemedIconButton?
    var displayPaneToolbarButton: ThemedIconButton?
    var sessionContextToolbarButton: ThemedIconButton?
    var surfaceToggleToolbarButton: ThemedIconButton?
    var openInToolbarButton: ThemedIconButton?
    var openInMenuToolbarButton: ThemedIconButton?

    /// Holds the "Open in" dropdown while it is up; released from its own dismissal.
    var openInMenuSession: AnyObject?

    /// The toolbar context button's menu, rebuilt each open so all session state is live.
    let sessionContextMenu = NSMenu()

    /// Exposed to the toolbar delegate, which needs the split view for its tracking separator.
    var splitView: NSSplitView { splitViewController.splitView }

    var effectiveWorkspaceNavigatorSelection: WorkspaceNavigatorSelection {
        workspaceSidebarViewController.effectiveSelection
    }


    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?

    /// The inspect mode, kept here because extensions cannot store it. See `MainWindowInspector`.
    let elementInspector = ElementInspector()

    /// The session currently shown, if any.
    var currentSessionID: SessionID? {
        containerViewController.currentSessionID
    }

    var currentTerminalID: TerminalID? {
        containerViewController.currentTerminalID
    }

    /// The project implied by the visible session or composer. Settings and empty states carry
    /// no project context, so project-scoped extension commands disable there.
    var currentProjectID: ProjectID? {
        if let currentSessionID {
            return ProjectStore.shared.project(forSessionID: currentSessionID)?.id
        }
        if let currentTerminalID {
            return ProjectStore.shared.displayProject(forTerminalID: currentTerminalID)?.id
        }
        return containerViewController.currentComposerProjectID
    }

    /// The checkout the visible page is about — what "Open in" opens, and what the Finder
    /// reveal in the same menus points at.
    ///
    /// A session's folder is its *project's*, because a worktree is a project here rather than
    /// a mode of one (see `git.md`), so a session in a checkout and the checkout itself answer
    /// the same URL. Settings has no project and therefore no answer, which is what hides the
    /// control rather than leaving it pointed at whatever was open before.
    var currentFolderURL: URL? {
        currentProjectID
            .flatMap { ProjectStore.shared.project(withID: $0) }?
            .folderURL
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
        //
        // `TitlebarActionWindow` rather than a plain `NSWindow` because of what the next two
        // lines cost together: full-size content *and* a transparent titlebar is the one
        // combination in which AppKit stops hit-testing the strip, so a double-click there
        // reaches the content view and the platform's zoom-on-double-click never runs. That
        // class puts the gesture back — see its own note.
        let window = TitlebarActionWindow(
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
        // A floor, not the floor: `updateSidebarMinimumThickness` raises it to clear the window
        // controls floating over the column as soon as they can be measured.
        sidebarItem.minimumThickness = SidebarDefaults.minWidth
        // **No ceiling of its own.** A fixed 400 stopped the divider in open space with the
        // window nowhere near full, which reads as the drag being broken rather than as a
        // decision — and there is nothing at 400 that the column stops being useful past. What
        // the sidebar may take is what the terminal can spare, and the terminal already states
        // that itself (`MainWindowDefaults.minContentWidth`), so the split view enforces one
        // rule instead of two. `SidebarDefaults.maxWidth` remains what the app opens *itself*
        // to, which is a different question from how wide the user may drag.
        sidebarItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        // Pushed past that minimum the column shuts rather than stopping dead, which is the only
        // sensible next size once it can no longer hold its own controls — see
        // `SidebarSplitViewController.shutPaneIfPushedPast`.
        sidebarItem.canCollapse = true
        // The sidebar is the fixed column: a window resize is absorbed by the terminal, which is
        // what the sidebar behaviour arranged for itself and a plain item does not.
        sidebarItem.holdingPriority = SidebarDefaults.holdingPriority
        splitViewController.addSplitViewItem(sidebarItem)
        configureWorkspaceNavigator()

        containerViewController.delegate = self

        containerViewController.composerViewController.delegate = sessionCoordinator
        pageTabView.onClose = { [weak self] in self?.closeActivePageTab() }
        pageTabView.onSelect = { [weak self] in self?.revealActivePageInSidebar() }
        // The header shows exactly one page, and it is always the current one.
        pageTabView.isSelected = true

        let contentItem = NSSplitViewItem(viewController: containerViewController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = MainWindowDefaults.minContentWidth
        splitViewController.addSplitViewItem(contentItem)

        setupDisplayPane()
        setupAgentToolCoordinator()

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
        configureTabTransfer()
        // The first update above can only reach the real NSToolbar button. Initialize the pane
        // controls now that they exist too, especially the surface button whose glyph depends
        // on the restored session and which must disappear when there is no session.
        updateToolbarControlStates()
        splitViewController.sidebarTransitionDidComplete = { [weak self] isCollapsed in
            self?.updateHeaderInset(sidebarIsCollapsed: isCollapsed)
            if !isCollapsed {
                self?.applyPendingWorkspaceNavigatorWidth()
            }
        }

        // The toolbar was installed a moment ago and has not laid its items out yet, so the
        // sidebar's floor is claimed on the next turn of the run loop — before the window is on
        // screen, and well before a divider can be dragged. The stored width follows in the same
        // turn, once there is a floor for it to be clamped against.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateSidebarMinimumThickness()
            self.restoreSidebarWidth()
        }
    }

    private func configureWorkspaceNavigator() {
        workspaceSidebarViewController.activate(AppSettings.shared.workspaceNavigatorSelection)
        workspaceSidebarViewController.synchronizeSelection(
            with: currentWorkspaceNavigatorDestination
        )
        appEvents.observe(ExtensionsDidChange.self) { [weak self] _ in
            guard let self else { return }
            self.workspaceSidebarViewController.refreshAvailability()
            self.workspaceSidebarViewController.synchronizeSelection(
                with: self.currentWorkspaceNavigatorDestination
            )
        }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            guard let self else { return }
            self.workspaceSidebarViewController.activate(
                AppSettings.shared.workspaceNavigatorSelection
            )
            self.workspaceSidebarViewController.synchronizeSelection(
                with: self.currentWorkspaceNavigatorDestination
            )
        }
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.workspaceSidebarViewController.refreshDocument()
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
                ThreadingLogger.extensions.error(
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
        _ = agentToolCoordinator
    }

    /// Adds the panel agents display content in, collapsed until something arrives.
    ///
    /// Appended last, so it takes divider index 1 and leaves the toolbar's tracking separator
    /// — which is bound to divider 0, between sidebar and terminal — undisturbed.
    private func setupDisplayPane() {
        displayPaneController.onClose = { [weak self] in
            self?.setDisplayPaneVisible(false)
        }
        displayPaneController.onShowCurrentTheme = { [weak self] in
            self?.toggleCurrentTheme()
        }
        displayPaneController.onReviewLoadingChange = { [weak self] sessionID, isLoading in
            self?.setSessionLoading(
                isLoading,
                reason: .gitReview,
                for: sessionID
            )
        }
        displayPaneController.onSubagentSelection = { [weak self] sessionID, threadID in
            guard let self, sessionID == self.currentSessionID else { return }
            self.containerViewController.selectSubagent(threadID)
        }
        displayPaneController.onShareSession = { sessionID in
            ShareChatSheet.run(for: sessionID)
        }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            guard let self,
                  self.displayPaneController.isShowingCurrentTheme,
                  !MCPToolCatalog.hasEnabledThemeTools else { return }
            self.setDisplayPaneVisible(false)
        }

        // The shell drawer belongs to the terminal container, on the other side of the split; the
        // window is what can see both, so it is what joins them.
        displayPaneController.shellRootResolver = { [weak self] sessionID in
            self?.containerViewController.shellRootPid(for: sessionID)
        }

        displayItem.canCollapse = true

        // The pane's own chrome, not the width it opens at: a split item's minimum is required,
        // and a required constraint is also the *window's* minimum. See
        // `DisplayPaneDefaults.slimmestWidth` for the measurement. The 200pt the panel opens at
        // is applied as a width when it is revealed, which a window resize may squeeze past.
        displayItem.minimumThickness = DisplayPaneDefaults.slimmestWidth
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

        // A clicked macOS notification lands here. Selecting through the sidebar keeps it on
        // the same path as a local click, exactly like a remote resume.
        appEvents.observe(SessionNotificationOpened.self) { [weak self] event in
            guard let self,
                  ProjectStore.shared.session(withID: event.sessionID) != nil else { return }
            // Settings takes the sidebar over, so arriving from a notification has to leave it
            // the same way Back does — otherwise the pane switches to the session while the
            // sidebar keeps listing settings sections, with no row to show which one arrived.
            self.exitSettingsForNavigation()
            self.sidebarViewController.select(sessionID: event.sessionID)
        }
    }

    /// Supplies the extension runtime broker with the same shell root as the native Info pane.
    ///
    /// The broker receives only a root chosen by Threading for a known session. It never receives
    /// the terminal container or a way to query arbitrary processes.
    func extensionShellRootPid(for sessionID: SessionID) -> pid_t? {
        containerViewController.shellRootPid(for: sessionID)
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        // Fires while a divider is dragged and when a pane collapses, which are the two ways the
        // content pane can arrive at the window's leading edge.
        updateHeaderInset()
        // Cheap and idempotent, and this is the first moment on a cold launch at which the
        // toolbar's controls have a frame to measure.
        updateSidebarMinimumThickness()
        // A pane can also be shut by dragging its divider past it, which never reaches
        // `toggleSidebar` — and left the toolbar's toggle lit for a pane that was gone.
        // Just the two toggles: the full control pass reads the store, and this fires on
        // every tick of a drag.
        updatePaneToggleSelection()
        recordSidebarWidth()

        guard !displayItem.isCollapsed, !isRestoringDisplayPaneWidth else {
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
        guard sidebarIsCollapsed ?? sidebarItem.isCollapsed else {
            containerViewController.headerLeadingInset = PaneHeaderDefaults.inset
            return
        }

        let pane = containerViewController.view
        let paneMinX = pane.convert(pane.bounds, to: nil).minX
        let controlsMaxX = windowControlsTrailingEdge()
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

    /// Where the window's own controls end, in window coordinates.
    ///
    /// The *trailing-most* toolbar control, not a named one: the history group sits right of the
    /// toggle, and clearing only the toggle would leave the pane header — or the sidebar's own
    /// trailing edge — under it. A toolbar item can already exist while its view still has a zero
    /// frame (notably while attaching a hosted test window). That is not a measurement, so the
    /// launch fallback stands until AppKit has actually placed the control.
    private func windowControlsTrailingEdge() -> CGFloat {
        let measured = [sidebarToolbarButton, navBackToolbarButton, navForwardToolbarButton]
            .compactMap { control in
                control.map { $0.convert($0.bounds, to: nil).maxX }
            }
            .max()

        return measured.flatMap {
            $0 > PaneHeaderDefaults.inset ? $0 : nil
        } ?? PaneHeaderDefaults.assumedWindowControlsWidth
    }

    // MARK: - Sidebar Width

    /// Keeps the sidebar wide enough to hold the window controls that float over it.
    ///
    /// The toolbar positions its items against the *window*, so the sidebar toggle and the
    /// history pair sit at a fixed x whatever the divider does — and at
    /// `SidebarDefaults.minWidth` the forward chevron was cut in half by the divider, its
    /// trailing edge hanging over the terminal. A column too narrow to hold its own controls has
    /// no useful sizes left below it: from here the next size down is shut, which dragging past
    /// the minimum already does (`canCollapse`).
    ///
    /// Measured rather than stated, for the same reason `updateHeaderInset` measures: those
    /// controls are AppKit's to place, and an item added to the toolbar has to move this floor
    /// with it. Idempotent — the value only ever changes when the toolbar's contents do.
    private func updateSidebarMinimumThickness() {
        let target = max(
            SidebarDefaults.minWidth,
            windowControlsTrailingEdge() + Design.Spacing.medium
        )
        guard abs(sidebarItem.minimumThickness - target) > 0.5 else { return }

        sidebarItem.minimumThickness = target
    }

    /// Keeps the stored width in step with the divider.
    ///
    /// Not while the column is shut, and not while it is on its way there: a collapse animates
    /// through every width down to zero, and recording those would answer "how wide was it" with
    /// the last frame of it disappearing. The width a shut column reopens at is the one it had.
    private func recordSidebarWidth() {
        guard recordsSidebarWidth, !sidebarItem.isCollapsed else { return }
        SidebarWidth.record(sidebarItem.viewController.view.bounds.width)
    }

    /// Opens the column at the width the user left it at.
    ///
    /// Moved through the divider rather than a width constraint, for the reason
    /// `applyDisplayPaneWidth` records: the split view goes on positioning its items from its own
    /// constraint, so a constraint released after one layout pass is undone by the next.
    /// `setPosition` clamps against the other items' minimums itself, which is also the whole of
    /// the sidebar's ceiling — a width wider than the terminal can spare arrives as the widest
    /// the terminal can spare.
    private func restoreSidebarWidth() {
        defer { recordsSidebarWidth = true }
        guard let width = SidebarWidth.stored, !sidebarItem.isCollapsed else { return }

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(width, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }

    // MARK: - Display Pane

    /// Shows or hides the display panel.
    func setDisplayPaneVisible(_ visible: Bool) {
        if !visible {
            displayPaneController.hideCurrentTheme()
        }
        guard displayItem.isCollapsed == visible else { return }

        guard visible else {
            displayItem.isCollapsed = true
            updateToolbarControlStates()
            return
        }

        // Read *before* uncollapsing. The layout that follows fires resize notifications
        // carrying a transient thickness — the item's minimum — and recording that would
        // overwrite the width about to be restored with that minimum on every first reveal.
        // The window is measured here too, while the panel is still shut and the split view
        // therefore still the full content width.
        let target = DisplayPaneWidth.opening(in: splitView.bounds.width)
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
    /// Moved through the split view's own divider, because the width has to become *its* answer.
    ///
    /// This used to activate a required width constraint on the pane, lay out, and release it.
    /// That holds the frame for exactly as long as the constraint is active: the split view goes
    /// on positioning its items with its own constraint at `holdingPriority`, whose constant is
    /// still the thickness the pane had, so the very next layout pass puts it back. Traced:
    /// asked 372 → with constraint 372 → released 372 → **relaid 48**.
    ///
    /// It was survivable while the item's minimum was 200 — the panel merely opened narrower
    /// than it was left. Lowering the minimum to `slimmestWidth` so the panel would stop raising
    /// the *window's* minimum turned "back" into a 48pt sliver, and `display_image` then opened
    /// a panel too narrow to show an image in. The two changes were each correct and only wrong
    /// together, which is why nothing caught it.
    ///
    /// The note this replaces said `setPosition` is ignored outright by an
    /// `NSSplitViewController`. It is not: dividers are indexed among the *panes*, while a split
    /// view keeps its dividers in `subviews` as well, so a `subviews`-counted index addresses the
    /// wrong divider — with three panes, `subviews.count - 2` is a divider view, not the
    /// panel's. AppKit clamps the position against the other items' minimums, so a width wider
    /// than the window can spare costs the terminal nothing below its own floor.
    private func applyDisplayPaneWidth(_ width: CGFloat) {
        let dividerIndex = splitViewController.splitViewItems.count - 2
        guard dividerIndex >= 0 else { return }

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(
            splitView.bounds.width - width - splitView.dividerThickness,
            ofDividerAt: dividerIndex
        )
        splitView.layoutSubtreeIfNeeded()
    }

    /// Points the panel at whichever session is on screen.
    ///
    /// Content belongs to a session, so switching sessions switches what the panel shows,
    /// and a session with nothing to show closes it rather than leaving the last image up.
    private func syncDisplayPane(to sessionID: SessionID?) {
        displayPaneController.showSession(sessionID)

        // The theme document is app-wide, so changing or temporarily clearing the selected
        // session must not close it. Its agent attribution remains whichever conversation is in
        // the main pane; only the inspector itself is global.
        if displayPaneController.isShowingCurrentTheme {
            setDisplayPaneVisible(true)
            return
        }

        guard let sessionID, displayPaneController.hasContent(for: sessionID) else {
            setDisplayPaneVisible(false)
            return
        }

        setDisplayPaneVisible(true)
    }

    /// Forwards a pane's loading state to the row it belongs to.
    ///
    /// The sidebar keeps the reasons, so this no longer aggregates a second copy of them — one
    /// place answers "why is that row spinning". **Raising** stays gated on the session being on
    /// screen, since these loads describe the pane and only the shown session has one; a
    /// **clear** is always forwarded, because a load that finishes after the user has moved on
    /// is exactly the one whose row would otherwise keep the spinner for good.
    private func setSessionLoading(
        _ isLoading: Bool,
        reason: SessionLoadingState.Reason,
        for sessionID: SessionID
    ) {
        guard !isLoading || sessionID == currentSessionID else { return }
        sidebarViewController.setSessionLoading(isLoading, reason: reason, for: sessionID)
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

    func selectWorkspaceNavigator(_ selection: WorkspaceNavigatorSelection) {
        AppSettings.shared.workspaceNavigatorSelection = selection
        workspaceSidebarViewController.activate(selection)
        workspaceSidebarViewController.synchronizeSelection(
            with: currentWorkspaceNavigatorDestination
        )
        if case .extensionNavigator(let extensionIdentifier, let navigatorID) = selection,
           let width = ExtensionManager.shared.registeredWorkspaceNavigator(
               extensionIdentifier: extensionIdentifier,
               navigatorID: navigatorID
           )?.navigator.preferredWidth {
            requestWorkspaceNavigatorWidth(CGFloat(width))
        }
    }

    /// Applies a contribution's width only when the user explicitly chooses it. The temporary
    /// constraint is released immediately, so subsequent divider movement remains authoritative.
    ///
    /// Bounded by `SidebarDefaults.maxWidth` rather than by the item's own maximum, which is
    /// deliberately unset: how wide the user may *drag* the column is their business, and how
    /// wide an extension may open it is not.
    private func requestWorkspaceNavigatorWidth(_ proposedWidth: CGFloat) {
        pendingWorkspaceNavigatorWidth = min(
            SidebarDefaults.maxWidth,
            max(sidebarItem.minimumThickness, proposedWidth)
        )
        guard !sidebarItem.isCollapsed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingWorkspaceNavigatorWidth()
        }
    }

    private func applyPendingWorkspaceNavigatorWidth() {
        guard !sidebarItem.isCollapsed, let width = pendingWorkspaceNavigatorWidth else {
            return
        }
        pendingWorkspaceNavigatorWidth = nil
        let constraint = workspaceSidebarViewController.view.widthAnchor.constraint(
            equalToConstant: width
        )
        constraint.isActive = true
        workspaceSidebarViewController.view.layoutSubtreeIfNeeded()
        constraint.isActive = false
    }

    private var currentWorkspaceNavigatorDestination:
        ExtensionWorkspaceNavigatorDestination?
    {
        if let sessionID = currentSessionID {
            return .session(
                id: sessionID.uuidString.lowercased(),
                projectID: ProjectStore.shared.project(forSessionID: sessionID)?
                    .id.uuidString.lowercased()
            )
        }
        if currentTerminalID != nil, let projectID = currentProjectID {
            return .project(id: projectID.uuidString.lowercased())
        }
        if let projectID = containerViewController.currentComposerProjectID {
            return .project(id: projectID.uuidString.lowercased())
        }
        return nil
    }

    private func openWorkspaceNavigatorDestination(
        _ destination: ExtensionWorkspaceNavigatorDestination
    ) -> String? {
        switch destination {
        case .project(let rawID):
            guard let projectID = ProjectID(uuidString: rawID),
                  ProjectStore.shared.project(withID: projectID) != nil else {
                return L10n.string("That project is no longer available.")
            }
            exitSettingsForNavigation()
            sidebarViewController.select(projectID: projectID)
            return nil

        case .session(let rawID, let rawProjectID):
            guard let sessionID = SessionID(uuidString: rawID),
                  let session = ProjectStore.shared.session(withID: sessionID),
                  !session.isArchived,
                  let project = ProjectStore.shared.project(forSessionID: sessionID) else {
                return L10n.string("That session is no longer available.")
            }
            if let rawProjectID {
                guard let expectedProjectID = ProjectID(uuidString: rawProjectID),
                      expectedProjectID == project.id else {
                    return L10n.string("That session does not belong to the requested project.")
                }
            }
            exitSettingsForNavigation()
            sidebarViewController.select(sessionID: sessionID)
            return nil
        }
    }

    /// Keeps the header naming whatever is on screen.
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
        } else if let terminalID = containerViewController.currentTerminalID,
                  let terminal = ProjectStore.shared.terminal(withID: terminalID) {
            showPageTab(
                title: terminal.displayTitle,
                symbolName: "terminal",
                identity: terminalID,
                toolTip: terminal.currentDirectory
            )
        } else if let projectID = containerViewController.currentComposerProjectID {
            let project = ProjectStore.shared.project(withID: projectID)
            showPageTab(
                title: project?.name ?? L10n.string("New Session"),
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

    // MARK: - Tab Transfer

    /// Moves tabs between the window's hosts; only the window sees both.
    private lazy var tabTransfer = TabTransferCoordinator(host: { [weak self] hostID in
        guard let self else { return nil }
        switch hostID {
        case .displayPanel: return displayPaneController
        case .drawer: return containerViewController.drawerHostController
        }
    })

    /// Wires movement into both strip panes' context menus, the drag-out gesture, and the
    /// browser resolution's cross-host fallback. Called once, after both panes exist.
    private func configureTabTransfer() {
        displayPaneController.transferEntries = { [weak self] tabID in
            self?.transferMenuEntries(from: .displayPanel, tabID: tabID) ?? []
        }
        containerViewController.drawerHostController.transferEntries = { [weak self] tabID in
            self?.transferMenuEntries(from: .drawer, tabID: tabID) ?? []
        }

        displayPaneController.dragOutDestination = { [weak self] tabID, windowPoint in
            self?.trackDrag(from: .displayPanel, tabID: tabID, at: windowPoint) != nil
        }
        displayPaneController.performDragOut = { [weak self] tabID, windowPoint in
            self?.dropDraggedTab(from: .displayPanel, tabID: tabID, at: windowPoint)
        }
        displayPaneController.dragOutEnded = { [weak self] _ in
            self?.dragDidSettle()
        }
        containerViewController.drawerHostController.dragOutDestination = {
            [weak self] tabID, windowPoint in
            self?.trackDrag(from: .drawer, tabID: tabID, at: windowPoint) != nil
        }
        containerViewController.drawerHostController.performDragOut = {
            [weak self] tabID, windowPoint in
            self?.dropDraggedTab(from: .drawer, tabID: tabID, at: windowPoint)
        }
        containerViewController.drawerHostController.dragOutEnded = { [weak self] _ in
            self?.dragDidSettle()
        }

        displayPaneController.browserFallback = { [weak self] sessionID in
            self?.containerViewController.drawerHostController.browser(for: sessionID)
        }
    }

    /// What a travelling drag arranged for its own benefit: a destination pane sprung open,
    /// remembered so a drag that settles without the drop puts it back.
    private struct DragSpringState {
        var openedDrawer = false
        var revealedPanel = false
        var dropped = false
    }

    private var dragSpring = DragSpringState()

    /// One pointer sample of a travelling chip: springs a closed destination open once the
    /// drag has left its own band, keeps the destination strip's wash in step, and answers
    /// whether a drop right now would land.
    private func trackDrag(
        from sourceID: TabHostID,
        tabID: UUID,
        at windowPoint: NSPoint
    ) -> TabHostID? {
        springDestinationOpen(from: sourceID, tabID: tabID, at: windowPoint)
        let destination = dragDestination(from: sourceID, tabID: tabID, at: windowPoint)
        highlightDropTarget(destination)
        return destination
    }

    /// A drop needs a visible band, so the band makes itself visible: the moment a movable
    /// chip leaves its own strip's row, a closed destination opens — Finder's spring-loaded
    /// folder, for panes. Springing on *leaving* rather than on grabbing is what keeps an
    /// ordinary reorder from flinging the other pane open.
    private func springDestinationOpen(
        from sourceID: TabHostID,
        tabID: UUID,
        at windowPoint: NSPoint
    ) {
        guard let sessionID = currentSessionID else { return }

        let stillOverOwnBand: Bool
        let destinationID: TabHostID
        switch sourceID {
        case .displayPanel:
            stillOverOwnBand = displayPaneController.dropBandContains(windowPoint: windowPoint)
            destinationID = .drawer
        case .drawer:
            stillOverOwnBand = containerViewController.drawerHostController
                .dropBandContains(windowPoint: windowPoint)
            destinationID = .displayPanel
        }

        guard !stillOverOwnBand, tabTransfer.canMove(
            tabID: tabID, from: sourceID, to: destinationID, sessionID: sessionID
        ) else { return }

        switch destinationID {
        case .drawer:
            guard !containerViewController.isShellDrawerOpen else { return }
            dragSpring.openedDrawer = true
            containerViewController.openShellDrawer()
        case .displayPanel:
            guard displayItem.isCollapsed else { return }
            dragSpring.revealedPanel = true
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        }
        updateToolbarControlStates()
    }

    private func highlightDropTarget(_ destinationID: TabHostID?) {
        containerViewController.drawerHostController
            .setDropTargetHighlighted(destinationID == .drawer)
        displayPaneController.setDropTargetHighlighted(destinationID == .displayPanel)
    }

    /// The drag is over, dropped or not: washes clear, and a pane sprung open for a drop
    /// that never came goes back where it was.
    private func dragDidSettle() {
        highlightDropTarget(nil)
        if !dragSpring.dropped {
            if dragSpring.openedDrawer {
                containerViewController.collapseShellDrawer()
            }
            if dragSpring.revealedPanel {
                setDisplayPaneVisible(false)
            }
            updateToolbarControlStates()
        }
        dragSpring = DragSpringState()
    }

    /// The host a tab dragged out of `sourceID` would land in at this pointer position, or nil
    /// while the drop would do nothing. Only a *visible* strip band takes a drop — a closed
    /// drawer or collapsed panel is reached by the context menu, which opens it on landing.
    private func dragDestination(
        from sourceID: TabHostID,
        tabID: UUID,
        at windowPoint: NSPoint
    ) -> TabHostID? {
        guard let sessionID = currentSessionID else { return nil }

        let destinationID: TabHostID
        let bandHit: Bool
        switch sourceID {
        case .displayPanel:
            destinationID = .drawer
            bandHit = containerViewController.isShellDrawerOpen
                && containerViewController.drawerHostController
                    .dropBandContains(windowPoint: windowPoint)
        case .drawer:
            destinationID = .displayPanel
            bandHit = !displayItem.isCollapsed
                && displayPaneController.dropBandContains(windowPoint: windowPoint)
        }

        guard bandHit, tabTransfer.canMove(
            tabID: tabID, from: sourceID, to: destinationID, sessionID: sessionID
        ) else { return nil }
        return destinationID
    }

    private func dropDraggedTab(from sourceID: TabHostID, tabID: UUID, at windowPoint: NSPoint) {
        guard let destinationID = dragDestination(
            from: sourceID, tabID: tabID, at: windowPoint
        ) else { return }
        dragSpring.dropped = true

        // The slot the pointer names, by the destination strip's own midpoint rule — a drop
        // lands where it was aimed, not at the end of the row.
        let index: Int
        switch destinationID {
        case .drawer:
            index = containerViewController.drawerHostController
                .dropInsertionIndex(windowPoint: windowPoint)
        case .displayPanel:
            index = displayPaneController.dropInsertionIndex(windowPoint: windowPoint)
        }
        moveTab(tabID, from: sourceID, to: destinationID, insertionIndex: index)
    }

    /// The "Move to …" items for one tab — offered only where the destination would say yes,
    /// so the menu never advertises a move that would beep.
    private func transferMenuEntries(
        from sourceID: TabHostID,
        tabID: UUID
    ) -> [ThemedMenuEntry] {
        guard let sessionID = currentSessionID else { return [] }

        let destinations: [(TabHostID, String)]
        switch sourceID {
        case .displayPanel:
            destinations = [(.drawer, L10n.string("Move to Shell Drawer"))]
        case .drawer:
            destinations = [(.displayPanel, L10n.string("Move to Display Panel"))]
        }

        return destinations.compactMap { destinationID, title in
            guard tabTransfer.canMove(
                tabID: tabID, from: sourceID, to: destinationID, sessionID: sessionID
            ) else { return nil }
            return .item(ThemedMenuItem(title: title, onChoose: { [weak self] in
                self?.moveTab(tabID, from: sourceID, to: destinationID)
            }))
        }
    }

    /// Moves the tab and brings its destination into view — a move you cannot see landing is
    /// a tab that just vanished.
    func moveTab(
        _ tabID: UUID,
        from sourceID: TabHostID,
        to destinationID: TabHostID,
        insertionIndex: Int? = nil
    ) {
        guard let sessionID = currentSessionID,
              tabTransfer.move(
                  tabID: tabID,
                  from: sourceID,
                  to: destinationID,
                  index: insertionIndex,
                  sessionID: sessionID
              ) else {
            NSSound.beep()
            return
        }

        switch destinationID {
        case .drawer:
            containerViewController.openShellDrawer()
        case .displayPanel:
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        }
    }

    /// ⌘W: the focused strip's tab when keyboard focus is inside the drawer or the panel,
    /// else the page on screen — settings closes back to what it covered, a session or
    /// composer page closes to the empty pane. Closing is never stopping an agent — Close
    /// Session remains its own command, one menu away.
    func closeActiveTab() {
        if displayPaneController.isShowingCurrentTheme, !displayItem.isCollapsed,
           let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: displayPaneController.view) {
            setDisplayPaneVisible(false)
            return
        }

        if let host = focusedTabHost() {
            if let activeID = host.activeTabID(for: currentSessionID),
               host.closeTab(id: activeID, for: currentSessionID) {
                return
            }
            NSSound.beep()
            return
        }

        if containerViewController.isShowingSettings
            || containerViewController.currentComposerProjectID != nil
            || containerViewController.currentSessionID != nil
            || containerViewController.currentTerminalID != nil {
            closeActivePageTab()
        } else {
            NSSound.beep()
        }
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
        } else if let terminalID = containerViewController.currentTerminalID {
            sidebarViewController.reveal(terminalID: terminalID)
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
        recordVisit(.settings(pageID))
    }

    // MARK: - Selection History

    /// ⌃⌘← — retraces the window's page selection, Xcode's Go Back.
    func goBack() {
        guard let page = history.goBack() else {
            NSSound.beep()
            return
        }
        present(page)
        updateNavigationButtons()
    }

    /// ⌃⌘→ — the step back forward.
    func goForward() {
        guard let page = history.goForward() else {
            NSSound.beep()
            return
        }
        present(page)
        updateNavigationButtons()
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// A page actually presented, from any entrance. The one being replayed by Back or Forward
    /// is recognised and not pushed again; everything else is a fresh visit. Cleared on every
    /// arrival either way, so an abandoned replay cannot swallow a later genuine visit.
    private func recordVisit(_ page: NavigationHistory.Page) {
        if pendingHistoryTarget == page {
            pendingHistoryTarget = nil
        } else {
            pendingHistoryTarget = nil
            history.visit(page)
        }
        updateNavigationButtons()
    }

    /// What the pane is showing now, as a page — a session, a project's composer, or nothing.
    /// Settings is not one of the answers: it is what the caller is about to replace.
    private func currentPage() -> NavigationHistory.Page? {
        if let sessionID = containerViewController.currentSessionID {
            return .session(sessionID)
        }
        if let terminalID = containerViewController.currentTerminalID {
            return .terminal(terminalID)
        }
        return containerViewController.currentComposerProjectID.map(NavigationHistory.Page.composer)
    }

    /// Presents a remembered page by replaying its ordinary entrance — the sidebar for
    /// sessions and composers, the settings door for settings — so every side effect of a real
    /// selection happens for a retraced one too.
    private func present(_ page: NavigationHistory.Page) {
        switch page {
        case .session(let sessionID):
            exitSettingsForNavigation()
            pendingHistoryTarget = page
            sidebarViewController.select(sessionID: sessionID)

        case .terminal(let terminalID):
            exitSettingsForNavigation()
            pendingHistoryTarget = page
            sidebarViewController.select(terminalID: terminalID)

        case .composer(let projectID):
            exitSettingsForNavigation()
            pendingHistoryTarget = page
            sidebarViewController.select(projectID: projectID)

        case .settings(let pageID):
            pendingHistoryTarget = page
            showSettingsPage(id: pageID)
        }
    }

    /// Leaving settings *sideways* — Back to a session rather than out through the toggle —
    /// must still restore the sidebar's session list, and must drop the toggle's own memory of
    /// what to restore, which history has now superseded.
    private func exitSettingsForNavigation() {
        guard containerViewController.isShowingSettings else { return }
        sidebarViewController.setSettingsMode(false)
        workspaceSidebarViewController.setSettingsOverride(false)
        preSettingsPage = nil
    }

    private func updateNavigationButtons() {
        navBackToolbarButton?.isEnabled = history.canGoBack
        navForwardToolbarButton?.isEnabled = history.canGoForward
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

    /// Opens the app-wide theme document beside the conversation. Unlike ordinary panel tabs it
    /// survives session selection and joins no persisted layout — the panel's `+` offers it,
    /// behind its own separator, as a way *in* rather than as another of that chat's tabs.
    func toggleCurrentTheme() {
        window?.makeKeyAndOrderFront(nil)
        guard MCPToolCatalog.hasEnabledThemeTools else {
            NSSound.beep()
            return
        }

        if displayPaneController.isShowingCurrentTheme, !displayItem.isCollapsed {
            setDisplayPaneVisible(false)
            return
        }

        // The utility is explicitly for working beside a conversation. If invoked from
        // Settings, restore the page Settings covered before opening the inspector.
        if containerViewController.isShowingSettings {
            toggleSettings()
        }
        displayPaneController.showSession(containerViewController.currentSessionID)
        displayPaneController.showCurrentTheme()
        setDisplayPaneVisible(true)
    }

    var isCurrentThemeVisible: Bool {
        displayPaneController.isShowingCurrentTheme && !displayItem.isCollapsed
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
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    // MARK: - Remote Workspace

    func remoteBrowserTabs(for sessionID: SessionID) -> [RemoteBrowserTabDTO] {
        let target = displayPaneController.browser(for: sessionID)
        return browserTabsAcrossHosts(for: sessionID).compactMap { tab in
            guard let browser = tab.browser else { return nil }
            let isPrivate = browser.contextKind == .private
            let rawURL = browser.currentURL?.absoluteString ?? browser.restoredURL
            return RemoteBrowserTabDTO(
                id: tab.id.uuidString,
                title: isPrivate ? "" : boundedRemoteBrowserTitle(tab.title),
                displayURL: isPrivate ? nil : rawURL.map(BrowserURLRedactor.redact),
                isActive: browser === target,
                isPrivate: isPrivate,
                canPreview: !isPrivate && browser.currentURL != nil
            )
        }
    }

    func remoteBrowserPreview(for sessionID: SessionID, tabID: UUID) async -> Data? {
        guard let browser = browserTabsAcrossHosts(for: sessionID)
            .first(where: { $0.id == tabID })?
            .browser,
              browser.contextKind == .shared,
              browser.currentURL != nil,
              let capture = await browser.screenshot(),
              capture.data.count <= RemoteWorkspaceDefaults.maximumPreviewBytes else {
            return nil
        }
        return capture.data
    }

    private func browserTabsAcrossHosts(for sessionID: SessionID) -> [PaneTab] {
        displayPaneController.tabs(for: sessionID)
            + containerViewController.drawerHostController.tabs(for: sessionID)
    }

    private func boundedRemoteBrowserTitle(_ title: String) -> String {
        let collapsed = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(RemoteWorkspaceDefaults.maximumTitleCharacters))
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

    /// A filled pane button means that pane is actually visible, however it was closed.
    ///
    /// Split out of `updateToolbarControlStates` because the divider drag needs exactly this
    /// much on every tick of the drag, and none of the store reads around it.
    private func updatePaneToggleSelection() {
        sidebarToolbarButton?.isSelected = !sidebarItem.isCollapsed
        displayPaneToolbarButton?.isSelected = !displayItem.isCollapsed
    }

    /// Keeps toolbar controls semantic: a filled pane button means the pane is actually visible,
    /// and controls that need a session leave the key-view loop when no session is selected.
    func updateToolbarControlStates() {
        let session = containerViewController.currentSessionID.flatMap {
            ProjectStore.shared.session(withID: $0)
        }
        let hasSession = session != nil
        updatePaneToggleSelection()
        // **New Session is hidden while Settings is the page.** It creates a session, which a
        // preferences page is not a context for — and beside a closable "Profiles" tab a `+`
        // reads as "add another one of these", which is the one thing it does not do. The
        // design system's own rule: a control offering nothing here hides rather than sitting
        // there dead.
        newSessionButton?.isHidden = containerViewController.isShowingSettings
        updateOpenInControls()
        shellDrawerToolbarButton?.isEnabled = hasSession
        shellDrawerToolbarButton?.isSelected = containerViewController.isShellDrawerOpen
        sessionContextToolbarButton?.isEnabled = hasSession || containerViewController.isShowingSettings

        if let session, session.kind.supportsNativeUI {
            let presentation = SessionSurfaceTogglePresentation(session: session)
            let accessibility = "Show as \(presentation.title)"
            surfaceToggleToolbarButton?.isHidden = false
            surfaceToggleToolbarButton?.isEnabled = true
            surfaceToggleToolbarButton?.setSymbol(
                presentation.symbolName,
                accessibility: accessibility
            )
            surfaceToggleToolbarButton?.toolTip = accessibility
        } else {
            surfaceToggleToolbarButton?.isHidden = true
            surfaceToggleToolbarButton?.isEnabled = false
        }
    }

    /// Populates the pane-header menu through the row's action builder. The two entrances
    /// therefore share not just their labels but their targets, enablement, and extensions.
    @discardableResult
    func populateVisibleSessionActions(_ menu: NSMenu) -> Bool {
        guard let sessionID = currentSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return false }

        sidebarViewController.actionSessionID = sessionID
        sidebarViewController.populateSessionActions(menu, for: session)
        return true
    }

    /// The dedicated header button always points to the surface not currently on screen.
    /// The coordinator owns the actual switch so this path keeps the same running-agent
    /// confirmation and relaunch behavior as the Interface menu.
    func toggleCurrentSessionSurface() {
        guard let sessionID = currentSessionID,
              let session = ProjectStore.shared.session(withID: sessionID),
              session.kind.supportsNativeUI else {
            NSSound.beep()
            return
        }

        let presentation = SessionSurfaceTogglePresentation(session: session)
        sessionCoordinator.setUsesNativeUI(
            presentation.targetUsesNativeUI,
            for: sessionID
        )
    }

    func showReview(mode: GitReviewMode? = nil) {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        let review = displayPaneController.activateReview(for: sessionID)
        if let mode { review?.show(mode: mode) }
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    /// Opens who can reach the chat on screen, and who is looking at it right now.
    func showSharing() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateSharing(for: sessionID)
        displayPaneController.showSessionTabs(sessionID)
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
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    func showFilesTab() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateFiles(for: sessionID)
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    // MARK: - Tab Cycling

    /// The tab host keyboard focus is inside, or nil when focus is with the page itself —
    /// the distinction ⌘W runs on, because closing "the tab" must never reach past what the
    /// user is looking at into a strip they are not.
    private func focusedTabHost() -> TabHosting? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        let drawerHost = containerViewController.drawerHostController
        if containerViewController.isShellDrawerOpen,
           responder.isDescendant(of: drawerHost.view) {
            return drawerHost
        }
        if displayPaneController.isViewLoaded,
           !displayItem.isCollapsed,
           responder.isDescendant(of: displayPaneController.view) {
            return displayPaneController
        }
        return nil
    }

    /// The tab host the traversal commands act on: the one keyboard focus is inside, else the
    /// display panel — the window's standing strip now that pages are not tabs. The commands'
    /// meaning never changes — only the answer.
    func activeTabHost() -> TabHosting? {
        focusedTabHost() ?? displayPaneController
    }

    /// ⇧⌘[ / ⇧⌘]: the neighbouring tab in the focused host's strip, wrapping at the ends the
    /// way every tabbed mac app does.
    func selectAdjacentTab(offset: Int) {
        guard let host = activeTabHost() else {
            NSSound.beep()
            return
        }
        let sessionID = currentSessionID
        let tabs = host.tabs(for: sessionID)
        guard tabs.count > 1,
              let activeID = host.activeTabID(for: sessionID),
              let index = tabs.firstIndex(where: { $0.id == activeID }) else {
            NSSound.beep()
            return
        }

        let target = (index + offset % tabs.count + tabs.count) % tabs.count
        host.activateTab(id: tabs[target].id, for: sessionID)
        revealActiveTabHost()
    }

    /// ⌘1–⌘9: the tab at that place in the focused host's strip. Out-of-range digits beep
    /// rather than clamp — ⌘9 is not a request for the last tab, it is a miss.
    func selectTab(atIndex index: Int) {
        guard let host = activeTabHost() else {
            NSSound.beep()
            return
        }
        let sessionID = currentSessionID
        let tabs = host.tabs(for: sessionID)
        guard tabs.indices.contains(index) else {
            NSSound.beep()
            return
        }

        host.activateTab(id: tabs[index].id, for: sessionID)
        revealActiveTabHost()
    }

    /// Selecting a tab by keyboard means wanting to see it: a collapsed panel would take the
    /// command and show nothing for it.
    private func revealActiveTabHost() {
        guard activeTabHost() === displayPaneController else { return }
        setDisplayPaneVisible(true)
    }

    func showInfo() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        displayPaneController.activateInfo(for: sessionID)
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    func showAttachments() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        showAttachments(for: sessionID)
    }

    private func showAttachments(for sessionID: SessionID) {
        displayPaneController.activateAttachments(for: sessionID)
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    /// Opens Settings in the content pane, or closes it and returns to what was on screen. The
    /// sidebar itself swaps to the section list rather than a second sidebar appearing.
    func toggleSettings() {
        if containerViewController.isShowingSettings {
            sidebarViewController.setSettingsMode(false)
            workspaceSidebarViewController.setSettingsOverride(false)

            switch preSettingsPage {
            case .session(let sessionID):
                containerViewController.show(sessionID: sessionID)
                syncDisplayPane(to: sessionID)
                recordVisit(.session(sessionID))

            case .terminal(let terminalID):
                containerViewController.show(terminalID: terminalID)
                syncDisplayPane(to: nil)
                recordVisit(.terminal(terminalID))

            case .composer(let projectID):
                // Restored rather than re-shown: the composer is put back as it was left,
                // choices, attachments and half-written prompt included. Settings is a detour,
                // not a change of project, so nothing about it should reset the decision the
                // user was in the middle of making.
                containerViewController.restoreComposer(projectID: projectID)
                syncDisplayPane(to: nil)
                recordVisit(.composer(projectID))

            case .settings, .none:
                containerViewController.show(sessionID: nil)
            }
            preSettingsPage = nil
        } else {
            preSettingsPage = currentPage()
            workspaceSidebarViewController.setSettingsOverride(true)
            sidebarViewController.setSettingsMode(true)
            containerViewController.showSettingsPage(id: SettingsPages.generalID)
            syncDisplayPane(to: nil)
            recordVisit(.settings(SettingsPages.generalID))
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
        containerViewController.activeTerminalSession?.increaseFontSize()
    }

    func decreaseFontSize() {
        containerViewController.activeTerminalSession?.decreaseFontSize()
    }

    // MARK: - Find

    func showFind() {
        if !displayItem.isCollapsed,
           let browser = displayPaneController.currentBrowser {
            browser.showFind()
            return
        }

        guard let contentView = window?.contentView,
              let terminalView = containerViewController.activeTerminalSession?.terminalView
        else { return }

        if findBar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.onClose = { [weak self] in self?.hideFindBar() }

            contentView.addSubview(bar)

            let topConstraint = bar.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: -FindBarDefaults.height
            )
            findBarTopConstraint = topConstraint

            NSLayoutConstraint.activate([
                topConstraint,
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
            Task { @MainActor [weak self] in
                self?.findBar?.removeFromSuperview()
                self?.findBar = nil
                if let terminalID = self?.containerViewController.currentTerminalID,
                   let controller = ProjectTerminalRuntime.shared.controller(for: terminalID) {
                    controller.focus()
                } else {
                    self?.currentAgentController()?.focusTerminal()
                }
            }
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
        window?.representedURL = currentFolderURL
    }
}

// MARK: - ProjectSidebarViewControllerDelegate

extension MainWindowController: ProjectSidebarViewControllerDelegate {

    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSession sessionID: SessionID) {
        // Taken rather than read: an opening prompt belongs to the launch that follows it,
        // not to every later selection of the same session.
        let prompt = sessionCoordinator.takePendingPrompt()
        let previousSessionID = containerViewController.currentSessionID
        let previousTerminalID = containerViewController.currentTerminalID

        containerViewController.show(sessionID: sessionID, initialPrompt: prompt)
        syncDisplayPane(to: sessionID)
        recordVisit(.session(sessionID))
        workspaceSidebarViewController.synchronizeSelection(
            with: currentWorkspaceNavigatorDestination
        )

        // Visibility can change the attention state of the row leaving and entering the pane.
        // Those are the only two rows affected; rebuilding the entire outline made selection
        // cost proportional to the number of sessions.
        if let previousSessionID, previousSessionID != sessionID {
            sidebar.refreshRow(sessionID: previousSessionID)
        }
        if let previousTerminalID {
            sidebar.refreshRow(terminalID: previousTerminalID)
        }
        sidebar.refreshRow(sessionID: sessionID)
    }

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        didSelectTerminal terminalID: TerminalID
    ) {
        let previousSessionID = containerViewController.currentSessionID
        let previousTerminalID = containerViewController.currentTerminalID

        containerViewController.show(terminalID: terminalID)
        syncDisplayPane(to: nil)
        recordVisit(.terminal(terminalID))
        workspaceSidebarViewController.synchronizeSelection(
            with: currentWorkspaceNavigatorDestination
        )
        updateSessionTitleItem()
        updateWindowTitle()

        if let previousSessionID {
            sidebar.refreshRow(sessionID: previousSessionID)
        }
        if let previousTerminalID, previousTerminalID != terminalID {
            sidebar.refreshRow(terminalID: previousTerminalID)
        }
        sidebar.refreshRow(terminalID: terminalID)
    }

    /// A project has no terminal of its own, so selecting one offers the composer: the
    /// choices that are only made when a session starts.
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: ProjectID) {
        let previousSessionID = containerViewController.currentSessionID
        let previousTerminalID = containerViewController.currentTerminalID
        containerViewController.showComposer(projectID: projectID)
        syncDisplayPane(to: nil)
        recordVisit(.composer(projectID))
        workspaceSidebarViewController.synchronizeSelection(
            with: currentWorkspaceNavigatorDestination
        )
        if let previousSessionID {
            sidebar.refreshRow(sessionID: previousSessionID)
        }
        if let previousTerminalID {
            sidebar.refreshRow(terminalID: previousTerminalID)
        }
    }

    /// A folder dropped on the sidebar lands in its composer, like one added from the panel:
    /// a project's first session is still a session, and still worth choosing.
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didAddProject project: Project) {
        sidebar.select(projectID: project.id)
    }

    /// Archiving and closing are lifecycle decisions, so both route through the coordinator,
    /// which stops a running agent first and may ask before doing so.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setArchived archived: Bool,
        for sessionID: SessionID
    ) {
        sessionCoordinator.setArchived(archived, for: sessionID)
    }

    func projectSidebar(_ sidebar: ProjectSidebarViewController, closeSession sessionID: SessionID) {
        sessionCoordinator.closeSession(sessionID)
    }

    /// Naming is a decision about the session record, so it routes through the coordinator with
    /// the rest of them rather than the sidebar reaching for the running agent itself.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        askAgentToRename sessionID: SessionID
    ) {
        sessionCoordinator.askAgentToRename(sessionID)
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

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        showAttachmentsFor sessionID: SessionID
    ) {
        if currentSessionID != sessionID {
            sidebar.select(sessionID: sessionID)
            // Selection deliberately presents on the next main-loop turn so its spinner can
            // paint first. Queue the tab behind that presentation rather than briefly showing
            // one session's attachments beside another session's conversation.
            DispatchQueue.main.async { [weak self] in
                guard self?.currentSessionID == sessionID else { return }
                self?.showAttachments(for: sessionID)
            }
            return
        }
        showAttachments(for: sessionID)
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

    /// Starts a new provider-native conversation from a frozen, MCP-readable snapshot. The
    /// source stays as its own resumable session; this is lineage, not a transcript move.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        continueSession sessionID: SessionID,
        withAccount account: AgentAccount
    ) {
        sessionCoordinator.continueSession(sessionID, with: account)
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
        if let currentTerminalID, ProjectStore.shared.terminal(withID: currentTerminalID) == nil {
            containerViewController.closeTerminal(for: currentTerminalID)
        }

        // A deleted session must not keep its image in memory, nor leave a live MCP endpoint
        // addressing a session that no longer exists.
        let liveSessionIDs = Set(ProjectStore.shared.projects.flatMap { $0.sessions.map(\.id) })
        let liveTerminalIDs = Set(ProjectStore.shared.projects.flatMap { $0.terminals.map(\.id) })
        displayPaneController.retainOnly(sessionIDs: liveSessionIDs)
        containerViewController.retainDrawerSessions(liveSessionIDs)
        MCPSessionRegistry.retainOnly(sessionIDs: liveSessionIDs)
        GitTurnBaselineStore.shared.retainOnly(sessionIDs: liveSessionIDs)
        AgentRuntime.shared.retainOnly(sessionIDs: liveSessionIDs)

        // Nor stay reachable through Back: a retraced page must exist to be presented.
        history.prune { page in
            switch page {
            case .session(let sessionID):
                return liveSessionIDs.contains(sessionID)
            case .terminal(let terminalID):
                return liveTerminalIDs.contains(terminalID)
            case .composer(let projectID):
                return ProjectStore.shared.project(withID: projectID) != nil
            case .settings:
                return true
            }
        }
        updateNavigationButtons()

        syncDisplayPane(to: containerViewController.currentSessionID)
    }

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        didCloseTerminal terminalID: TerminalID
    ) {
        containerViewController.closeTerminal(for: terminalID)
        history.prune { page in
            if case .terminal(let candidate) = page { return candidate != terminalID }
            return true
        }
        updateNavigationButtons()
        updateSessionTitleItem()
        updateWindowTitle()
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
        recordVisit(.settings(pageID))
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

    func terminalContainerDidRequestSharing(_ container: TerminalContainerViewController) {
        showSharing()
    }

    func terminalContainerDidRequestTurnDiff(_ container: TerminalContainerViewController) {
        showReview(mode: .lastTurn)
    }

    func terminalContainerDidRequestNewSession(_ container: TerminalContainerViewController) {
        newSession()
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

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didSelectSubagent agent: SubagentTimeline.Agent,
        for sessionID: SessionID
    ) {
        guard sessionID == currentSessionID else { return }
        let state = AgentRuntime.shared.subagentState(for: sessionID)
        displayPaneController.activateSubagents(
            state.timeline,
            selectedThreadID: agent.descriptor.threadID,
            for: sessionID
        )
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent,
        for sessionID: SessionID
    ) {
        let state = AgentRuntime.shared.subagentState(for: sessionID)
        displayPaneController.updateSubagents(
            state.timeline,
            selectedThreadID: agent.descriptor.threadID,
            for: sessionID
        )
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        subagentsDidChange timeline: SubagentTimeline,
        for sessionID: SessionID
    ) {
        let selectedThreadID = AgentRuntime.shared
            .subagentState(for: sessionID)
            .selectedThreadID
        displayPaneController.updateSubagents(
            timeline,
            selectedThreadID: selectedThreadID,
            for: sessionID
        )
    }

}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        AgentRuntime.shared.terminateAll()
        ProjectTerminalRuntime.shared.terminateAll()
    }
}

// MARK: - Main Window Defaults

enum MainWindowDefaults {
    static let defaultTitle = "Threading"
    static let frameAutosaveName = "ThreadingMainWindow"
    static let toolbarIdentifier = NSToolbar.Identifier("ThreadingMainToolbar")
    static let minContentWidth: CGFloat = 320

}

// MARK: - Sidebar Width

/// Remembers how wide the user left the sidebar, across launches.
///
/// The window's own frame is autosaved, so a restart used to bring back the window the user
/// arranged with the column inside it reset to 240. Same reasoning as `DisplayPaneWidth`, and
/// the same store: this is a choice made with a divider, and a hosted test must not write it
/// into the developer's own preferences.
enum SidebarWidth {
    private static let key = "ThreadingSidebarWidth"

    /// The width to open at, or nil if the divider has never been moved.
    ///
    /// Narrower than the list's own floor is not a width anyone chose — it is a transient
    /// caught mid-collapse — and restoring one would open the column at a size it cannot hold
    /// its rows at.
    static var stored: CGFloat? {
        let saved = PreferenceStore.shared.double(forKey: key)
        guard saved >= SidebarDefaults.minWidth else { return nil }
        return CGFloat(saved)
    }

    static func record(_ width: CGFloat) {
        guard width >= SidebarDefaults.minWidth else { return }
        PreferenceStore.shared.set(Double(width), forKey: key)
    }
}

// MARK: - Display Pane Width

/// Remembers how wide the user left the display panel.
///
/// Kept out of `AppSettings`, which holds behavioural preferences the user sets deliberately.
/// This is window geometry, and belongs with the frame autosave rather than beside them.
///
/// Through `PreferenceStore`, not `.standard`: this records a **choice the user made with the
/// divider**, and the test bundle is hosted in the app, so a test that opens the panel writes
/// whatever width its fixture window happened to give it into the developer's own preferences.
/// That is how a real machine came to have 48 saved here — the panel's chrome floor, measured
/// in an unshown fixture window by a test about something else entirely, and then read back by
/// the app the developer was running.
enum DisplayPaneWidth {
    private static let key = "ThreadingDisplayPaneWidth"

    static var stored: CGFloat {
        get { chosen ?? DisplayPaneDefaults.defaultWidth }
        set { PreferenceStore.shared.set(Double(newValue), forKey: key) }
    }

    /// The width the user left the divider at, or nil if they never moved it. Absent, or
    /// narrower than the panel is allowed to be, means "never set" — a sliver recorded by a
    /// layout nobody asked for is not a choice to restore.
    private static var chosen: CGFloat? {
        let saved = PreferenceStore.shared.double(forKey: key)
        guard saved >= DisplayPaneDefaults.minWidth else { return nil }
        return CGFloat(saved)
    }

    /// The width a reveal opens at: the one the user chose, or a share of the window the first
    /// time — see `DisplayPaneDefaults.openingFraction`.
    static func opening(in splitWidth: CGFloat) -> CGFloat {
        if let chosen { return chosen }
        guard splitWidth > 0 else { return DisplayPaneDefaults.defaultWidth }
        return min(
            max(DisplayPaneDefaults.defaultWidth, splitWidth * DisplayPaneDefaults.openingFraction),
            DisplayPaneDefaults.widestOpening
        )
    }
}

// MARK: - Find Bar Defaults

enum FindBarDefaults {
    static let height: CGFloat = 32
}
