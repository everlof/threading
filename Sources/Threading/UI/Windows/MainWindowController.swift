import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

/// Coarse owners inside `MainWindowController` construction for the opt-in Release startup run.
///
/// These are deliberately one timestamp per semantic phase, never per view or row. The App Launch
/// sampler runs at 5 ms and can distinguish native window creation from split setup, but not the
/// several independently removable pieces inside that setup. The startup metric prints this value
/// beside the aggregate so a harness or OS shift cannot be mistaken for product work.
struct MainWindowStartupPerformance: Sendable {
    var createWindowNanoseconds: UInt64 = 0
    var baseInitializationNanoseconds: UInt64 = 0
    var splitTotalNanoseconds: UInt64 = 0
    var splitSidebarNanoseconds: UInt64 = 0
    var splitContentNanoseconds: UInt64 = 0
    var splitDisplayAndToolsNanoseconds: UInt64 = 0
    var splitContentInstallNanoseconds: UInt64 = 0
    var splitToolbarNanoseconds: UInt64 = 0
    var splitToolbarConstructionNanoseconds: UInt64 = 0
    var splitToolbarAttachmentNanoseconds: UInt64 = 0
    var splitToolbarItemNanoseconds: UInt64 = 0
    var splitToolbarStyleNanoseconds: UInt64 = 0
    var splitHeaderNanoseconds: UInt64 = 0
    var splitFinalizeNanoseconds: UInt64 = 0
    var chromeCoordinatorNanoseconds: UInt64 = 0
    var initialFrameNanoseconds: UInt64 = 0
    var initialTitleNanoseconds: UInt64 = 0
}

/// The application's single window: a project sidebar beside the active session's terminal.
final class MainWindowController: ThemedWindowController, RemoteWorkspaceProviding {

#if DEBUG
    struct DisplayPaneRequestPhaseDurations {
        var preparationNanoseconds: UInt64 = 0
        var collapseNanoseconds: UInt64 = 0
        var toolbarNanoseconds: UInt64 = 0
    }
#endif

    private(set) var startupPerformance = MainWindowStartupPerformance()
    private var isMeasuringStartupToolbarItems = false
    private let environment: AppEnvironment

    /// Installed by the application composition root. Sheets inject this further into their
    /// submission closures, so neither UI surface reaches into account or diagnostic state.
    var issueReportSubmitter: MacIssueReportSubmitter?
    private var isSendingCrashReport = false

    // MARK: - Properties

    /// Not private: the toolbar delegate needs the split view for its tracking separator.
    private(set) lazy var splitViewController = SidebarSplitViewController()
    private lazy var sidebarViewController = ProjectSidebarViewController(
        projectStore: environment.projectStore,
        canAskAgentToRename: { [weak self] sessionID in
            guard let self else { return false }
            return SessionCoordinator.canAskAgentToRename(
                sessionID,
                agentRuntime: environment.agentRuntime
            )
        },
        canAskForReportBack: { [weak self] sessionID in
            guard let self else { return false }
            return SessionCoordinator.canAskForReportBack(
                sessionID,
                projectStore: environment.projectStore,
                agentRuntime: environment.agentRuntime
            )
        },
        defersInitialTreeMount: true
    )
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

    /// The window's permanent content root: the app-drawn chrome, collapsed to nothing in
    /// native dress, around the extension hook and the workspace inside it.
    private lazy var chromeHostViewController = WindowChromeHostViewController(
        workspace: extensionHookViewController,
        initialTakeoverActive: window?.styleMask.contains(.titled) == false
    )

    /// Retained so the sidebar can be collapsed and restored directly.
    private lazy var sidebarItem = NSSplitViewItem(viewController: workspaceSidebarViewController)

    /// Owns session creation, import, worktree targeting, surface switches, and closing.
    private lazy var sessionCoordinator = SessionCoordinator(
        sidebar: sidebarViewController,
        container: containerViewController,
        environment: environment,
        onPresentationChanged: { [weak self] in self?.updateSessionTitleItem() }
    )

    /// Selection history, replay identity, and the page hidden behind Settings.
    private let navigation = WindowNavigationCoordinator()

    /// The panel agents display content in, and its split item, retained so it can be
    /// revealed when content arrives.
    ///
    /// Not private: the MCP tool handlers put content into it. See `MainWindowMCPTools`.
    private(set) lazy var displayPaneController = DisplayPaneController()
    private lazy var displayItem = NSSplitViewItem(viewController: displayPaneController)

    /// Where a session's browser is, across every pane that can hold one. Window-owned for the
    /// same reason `tabTransfer` is: only the window sees all the hosts. Panel first — it is
    /// where a browser is built and where a session with none gets one.
    private lazy var browserResolver = SessionBrowserResolver(hosts: { [weak self] in
        guard let self else { return [] }
        // Detached windows last, so a browser the user is looking at *in a pane* still answers
        // first. A window they parked on another display is the session's browser only when no
        // pane holds one — which is exactly the case the feature is for.
        return [
            (.displayPanel, displayPaneController),
            (.drawer, containerViewController.drawerHostController)
        ] + orderedDetachedWindows.map { (.detachedWindow($0.windowID), $0.host) }
    })

    /// The session's detached browser windows, by their own id. Window-owned like every other
    /// host: only this controller can see all of them at once.
    private var detachedBrowserWindows: [UUID: DetachedBrowserWindowController] = [:]

    /// The same windows in a **stable** order. `Dictionary.values` reorders itself as the
    /// dictionary mutates, so with two windows for one session the resolver's answer could flip
    /// — and a lease then fails with "a different browser tab became active" because an
    /// unrelated window happened to open. Creation order is arbitrary but it does not move.
    private var detachedWindowOrder: [UUID] = []

    private var orderedDetachedWindows: [DetachedBrowserWindowController] {
        detachedWindowOrder.compactMap { detachedBrowserWindows[$0] }
    }

    /// Owns agent-originated browser, display, storage, and theme requests.
    private(set) lazy var agentToolCoordinator = AgentToolCoordinator(
        displayPaneController: displayPaneController,
        browserResolver: browserResolver,
        visibleSessionID: { [weak self] in self?.currentSessionID },
        setPaneVisible: { [weak self] visible in self?.setDisplayPaneVisible(visible) },
        revealBrowserHost: { [weak self] hostID in
            guard let self else { return }
            switch hostID {
            case .displayPanel: setDisplayPaneVisible(true)
            case .drawer: containerViewController.openShellDrawer()
            case .detachedWindow(let id):
                // Ordered front, never made key: an agent acting on a page must not take the
                // keyboard out from under whatever the user is typing into. `showWindow` is
                // what the *user's* own "Focus" does.
                detachedBrowserWindows[id]?.window?.orderFront(nil)
            }
        },
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
    private var lastBlockedInputToastAt = Date.distantPast
#if DEBUG
    private(set) var lastDisplayPaneRequestPhaseDurations = DisplayPaneRequestPhaseDurations()
#endif

    /// Paces the startup relaunch of the sessions that were running at the last quit.
    /// Retained for the stagger's duration; it retires its own timer when the plan is spent.
    private var startupRelauncher: StartupSessionRelauncher?

    /// How closing the window asks the application to quit. See `windowShouldClose`.
    ///
    /// Injectable because the real request ends the process: a hosted test that exercised the
    /// close would take the test host down with it, which reads as an unrelated later test
    /// crashing rather than as this one.
    var requestsApplicationQuit: () -> Void = { NSApp.terminate(nil) }

    /// Exchanges the window's frame with a takeover theme's own chrome and back. Optional
    /// because it needs the real window; every consumer asks with `?.` and reads nil as
    /// "native frame", which is also what it means.
    private(set) var chromeCoordinator: WindowChromeCoordinator?

    /// The active workspace page, named at the head of the pane's header.
    ///
    /// Deliberately *one* name, and deliberately not a tab: a page here swaps the whole
    /// workspace — the drawer, the panel, the sidebar's selection — so a row of tabs would be a
    /// second session switcher, and a single tab drawn on its own promises the rest of that row
    /// exists somewhere. The sidebar is the switcher; this says where you are and carries the
    /// menu of what can be done to it. See `PageTitleView` for what the tab's plate, × and `+`
    /// each claimed that the window does not do.
    ///
    /// Settings is not one of these pages: it is a temporary window mode with its own static
    /// label and Done action, because presenting a changing category as a page implies that
    /// several settings documents can coexist when they cannot.
    ///
    /// Inked from the backdrop rather than the chrome, because the header floats over the
    /// terminal's own palette.
    var materializedPageTitleView: PageTitleView?
    var pageTitleView: PageTitleView {
        if let materializedPageTitleView { return materializedPageTitleView }

        let title = PageTitleView(
            symbolName: SessionTitleDefaults.projectSymbolName,
            inkSource: .backdrop
        )
        title.onReveal = { [weak self] in self?.revealActivePageInSidebar() }
        title.onActions = { [weak self] button in self?.showSessionContextMenu(from: button) }
        title.isHidden = containerViewController.isShowingSettings
        title.maxWidth = SessionTitleDefaults.maxWidth
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(lessThanOrEqualToConstant: SessionTitleDefaults.maxWidth)
        ])
        sessionContextToolbarButton = title.actionsAnchor

        materializedPageTitleView = title
        paneHeaderStackView?.insertArrangedSubview(title, at: 0)
        return title
    }
    var pageTitleViewIsMaterialized: Bool { materializedPageTitleView != nil }

    /// Settings replaces the workspace temporarily rather than opening a document. Its header
    /// therefore states the mode and the way back rather than borrowing the shape of
    /// `pageTitleView`, whose `⋯` acts on a session Settings does not have.
    ///
    /// **The two halves sit at the two ends of the row.** The label takes the leading slot the
    /// page's name would have had, because that is where this row says what you are looking at.
    /// Done goes to the trailing edge with the rest of what acts on the surface on screen. Held
    /// beside the label it was the only bordered button in the chrome, floating in the middle of
    /// an otherwise empty strip with nothing on either side of it to belong to — a dialog's
    /// commit button left behind in a header, and read as one.
    let settingsModeLabel = NSTextField(labelWithString: L10n.string("Settings"))
    let settingsDoneButton = ThemedButton(title: L10n.string("Done"), target: nil, action: nil)
    private(set) lazy var settingsModeHeaderView: NSStackView = {
        settingsModeLabel.applyFont(.control)
        settingsModeLabel.textColor = Design.Text.label
        settingsModeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [settingsModeLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.medium
        header.isHidden = true
        return header
    }()

    /// The way out of the mode, built once and parked at the trailing end of the pane header.
    /// Hidden with `settingsModeHeaderView`; the two are only ever shown or hidden together, by
    /// `setSettingsModeChrome(visible:)`.
    private(set) lazy var settingsModeDoneButton: ThemedButton = {
        settingsDoneButton.target = self
        settingsDoneButton.action = #selector(settingsDoneClicked(_:))
        settingsDoneButton.toolTip = L10n.string("Close Settings")
        settingsDoneButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsDoneButton.isHidden = true
        return settingsDoneButton
    }()

    /// Shows or hides both ends of the mode's chrome. They are one state wearing two views, and
    /// a caller that set only the one it remembered would leave the other stranded over a
    /// session — which is exactly what a header with a Done button and a session's name says.
    func setSettingsModeChrome(visible: Bool) {
        settingsModeHeaderView.isHidden = !visible
        settingsModeDoneButton.isHidden = !visible
    }

    /// Toolbar pill showing the current account's rate-limit usage.
    ///
    /// A composer or empty launch has no account to meter. Building the pill anyway used to
    /// install its event observation and repeating refresh timer before the first frame, then
    /// leave the view hidden. Keep the source-compatible accessor for callers that genuinely
    /// need the pill, but do not materialize it until a session supplies an account.
    var materializedAccountUsageItemView: AccountUsageItemView?
    weak var paneHeaderStackView: NSStackView?
    var accountUsageItemView: AccountUsageItemView {
        if let materializedAccountUsageItemView { return materializedAccountUsageItemView }

        let item = AccountUsageItemView()
        materializedAccountUsageItemView = item
        if let paneHeaderStackView {
            // Anchored on the control it belongs in front of rather than counted back from the
            // end: the row's trailing items have changed twice, and an offset that has to be
            // re-derived every time is how the pill ends up inside the session's action group.
            let anchor = openInSplitControl
                .flatMap { paneHeaderStackView.arrangedSubviews.firstIndex(of: $0) }
                ?? paneHeaderStackView.arrangedSubviews.count
            paneHeaderStackView.insertArrangedSubview(item, at: anchor)
        }
        return item
    }
    var accountUsageItemIsMaterialized: Bool {
        materializedAccountUsageItemView != nil
    }

    /// App-owned chrome controls, retained so pane visibility and session state stay reflected.
    var sidebarToolbarButton: ThemedIconButton?
    var navBackToolbarButton: ThemedIconButton?
    var navForwardToolbarButton: ThemedIconButton?
    var shellDrawerToolbarButton: ThemedIconButton?
    var displayPaneToolbarButton: ThemedIconButton?
    var statusCardToolbarButton: ThemedIconButton?
    /// The pane's surface group, held because the panel's toggle *leaves* it for the panel's own
    /// corner and has to be put back — see `updatePaneToggleSelection`.
    var sessionActionsGroup: ToolbarButtonGroupView?
    /// The `⋯` beside the page's name. Owned by `PageTitleView`; held here because the same
    /// state pass that enables the rest of the header's controls decides whether it has a
    /// session to act on.
    var sessionContextToolbarButton: ThemedIconButton?
    var surfaceToggleToolbarButton: ThemedIconButton?
    var openInToolbarButton: ThemedIconButton?
    var openInMenuToolbarButton: ThemedIconButton?
    /// The plate those two are halves of, retained because what hides with no checkout is the
    /// whole control rather than either half of it.
    var openInSplitControl: SplitIconButtonView?

    /// Holds the "Open in" dropdown while it is up; released from its own dismissal.
    var openInMenuSession: AnyObject?

    /// Holds the toolbar context button's menu while it is up, rebuilt each open so all
    /// session state is live; released from its own dismissal.
    var sessionContextMenuSession: AnyObject?

    /// Exposed to the toolbar delegate, which needs the split view for its tracking separator.
    var splitView: NSSplitView { splitViewController.splitView }

    var effectiveWorkspaceNavigatorSelection: WorkspaceNavigatorSelection {
        workspaceSidebarViewController.effectiveSelection
    }

    /// The startup lifecycle seam, exposed beside the sidebar's other aggregate test state so
    /// a regression cannot silently move viewport construction back ahead of divider restore.
    var initialSidebarTreeIsMounted: Bool {
        sidebarViewController.initialTreeIsMounted
    }

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

    /// The checkout repository commands belong to. A managed session points at its execution
    /// worktree rather than its logical Project; a standalone terminal follows its live cwd;
    /// the composer follows the selected project. Settings deliberately carries no checkout.
    var currentExecutionDirectoryURL: URL? {
        if let currentSessionID,
           let path = ProjectStore.shared.workingDirectory(forSessionID: currentSessionID) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let currentTerminalID,
           let terminal = ProjectStore.shared.terminal(withID: currentTerminalID) {
            return URL(fileURLWithPath: terminal.currentDirectory, isDirectory: true)
        }
        return containerViewController.currentComposerProjectID
            .flatMap { ProjectStore.shared.project(withID: $0) }?
            .folderURL
    }

    // MARK: - Initialization

    override init(window: NSWindow?) {
        environment = .live
        super.init(window: window)
    }

    private init(window: NSWindow?, environment: AppEnvironment) {
        self.environment = environment
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init() {
        self.init(environment: .live)
    }

    convenience init(environment: AppEnvironment) {
        let constructionStarted = DispatchTime.now().uptimeNanoseconds
        let createdWindow = Self.createWindow()
        let windowCreated = DispatchTime.now().uptimeNanoseconds
        self.init(window: createdWindow, environment: environment)
        let baseInitialized = DispatchTime.now().uptimeNanoseconds
        startupPerformance.createWindowNanoseconds = windowCreated - constructionStarted
        startupPerformance.baseInitializationNanoseconds = baseInitialized - windowCreated

        let splitStarted = DispatchTime.now().uptimeNanoseconds
        setupSplitViewController()
        startupPerformance.splitTotalNanoseconds = DispatchTime.now().uptimeNanoseconds
            - splitStarted

        let chromeStarted = DispatchTime.now().uptimeNanoseconds
        setupChromeCoordinator()
        startupPerformance.chromeCoordinatorNanoseconds = DispatchTime.now().uptimeNanoseconds
            - chromeStarted
        window?.delegate = self

        let frameStarted = DispatchTime.now().uptimeNanoseconds
        applyInitialFrame()
        startupPerformance.initialFrameNanoseconds = DispatchTime.now().uptimeNanoseconds
            - frameStarted

        let titleStarted = DispatchTime.now().uptimeNanoseconds
        updateWindowTitle()
        startupPerformance.initialTitleNanoseconds = DispatchTime.now().uptimeNanoseconds
            - titleStarted
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: WindowDefaults.defaultWidth,
            height: WindowDefaults.defaultHeight
        )

        // A theme that takes the chrome over must be honoured at creation, never by flipping
        // a just-made titled window: `AppThemeLibrary.restore()` runs before this controller
        // exists (`AppDelegate`), so the current theme is already the right one to ask.
        let takeover = WindowChromeCoordinator.takeoverRequested

        // Full-size content so the sidebar runs the whole height of the window and the
        // traffic lights sit over it, rather than above a separate title bar. Views that
        // must not slide under the toolbar pin to their safe area instead.
        //
        // `TitlebarActionWindow` rather than a plain `NSWindow` because of what the next two
        // lines cost together: full-size content *and* a transparent titlebar is the one
        // combination in which AppKit stops hit-testing the strip, so a double-click there
        // reaches the content view and the platform's zoom-on-double-click never runs. That
        // class puts the gesture back — see its own note. (Under a chrome takeover the class
        // is inert by geometry; see its `canBecomeKey` note.)
        let window = TitlebarActionWindow(
            contentRect: contentRect,
            styleMask: takeover
                ? WindowChromeCoordinator.takeoverMask
                : WindowChromeCoordinator.nativeMask,
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(width: WindowDefaults.minWidth, height: WindowDefaults.minHeight)

        if takeover {
            // A frameless window is not fullscreen-capable on its own; the coordinator makes
            // the same statement when it flips a live window.
            window.collectionBehavior.insert(.fullScreenPrimary)
        } else {
            window.titleVisibility = .hidden

            // Transparent so the toolbar draws no material bar of its own. Without it, that
            // bar sits between the window's rounded top corner and the content, and the
            // window's lighter default background shows in the gap as a pale sliver at the
            // corner. Transparent, the sidebar's material and the terminal's colour run
            // cleanly up to the rounded corner. (Wrongly blamed once for a mono-colour bug
            // that was actually a missing COLORTERM.)
            window.titlebarAppearsTransparent = true
        }
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

#if DEBUG
        if let scenarioSize = MainWindowUIScenarioSize.requested() {
            window.setContentSize(scenarioSize)
            window.center()
            return
        }
#endif

        if window.setFrameUsingName(MainWindowDefaults.frameAutosaveName) {
            holdRestoredFrameOnScreen(window)
        } else {
            window.setContentSize(NSSize(
                width: WindowDefaults.defaultWidth,
                height: WindowDefaults.defaultHeight
            ))
            window.center()
        }

        window.setFrameAutosaveName(MainWindowDefaults.frameAutosaveName)
    }

    /// A restored frame that no longer fits the screen, brought back to it.
    ///
    /// `setFrameUsingName` is the one door into a window's frame that AppKit does not police —
    /// measured, it calls `constrainFrameRect(_:to:)` not at all — so whatever was saved is what
    /// the window wears, however large and wherever it lands. That is survivable for a titled
    /// window, which the next thing to constrain it puts back; under a chrome-takeover theme the
    /// window is frameless and nothing ever constrains it again. It shipped as a window 3386
    /// points tall on a 1084-point screen, restored to exactly that on every launch, with the
    /// composer two thousand points below the bottom of the display and no edge left to drag.
    private func holdRestoredFrameOnScreen(_ window: NSWindow) {
        guard let bounds = MainWindowFrame.bounds(for: window) else { return }

        let held = MainWindowFrame.held(window.frame, within: bounds)
        guard held != window.frame else { return }

        window.setFrame(held, display: false)
    }

    // MARK: - Setup

    private func setupSplitViewController() {
        let sidebarStarted = DispatchTime.now().uptimeNanoseconds
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
        startupPerformance.splitSidebarNanoseconds = DispatchTime.now().uptimeNanoseconds
            - sidebarStarted

        let contentStarted = DispatchTime.now().uptimeNanoseconds
        containerViewController.delegate = self

        containerViewController.composerDelegate = sessionCoordinator
        let contentItem = NSSplitViewItem(viewController: containerViewController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = MainWindowDefaults.minContentWidth
        splitViewController.addSplitViewItem(contentItem)
        startupPerformance.splitContentNanoseconds = DispatchTime.now().uptimeNanoseconds
            - contentStarted

        let displayAndToolsStarted = DispatchTime.now().uptimeNanoseconds
        setupDisplayPane()
        setupAgentToolCoordinator()
        startupPerformance.splitDisplayAndToolsNanoseconds = DispatchTime.now().uptimeNanoseconds
            - displayAndToolsStarted

        let contentInstallStarted = DispatchTime.now().uptimeNanoseconds
        window?.contentViewController = chromeHostViewController
        startupPerformance.splitContentInstallNanoseconds = DispatchTime.now().uptimeNanoseconds
            - contentInstallStarted

        let toolbarStarted = DispatchTime.now().uptimeNanoseconds
        // A frameless window has nowhere to mount a toolbar — under a takeover theme the
        // coordinator reinstalls it the moment the native frame returns.
        if window?.styleMask.contains(.titled) == true {
            // Installed after the split view exists: the tracking separator item needs it.
            let toolbarConstructionStarted = DispatchTime.now().uptimeNanoseconds
            let toolbar = makeToolbar()
            startupPerformance.splitToolbarConstructionNanoseconds =
                DispatchTime.now().uptimeNanoseconds - toolbarConstructionStarted

            let toolbarAttachmentStarted = DispatchTime.now().uptimeNanoseconds
            isMeasuringStartupToolbarItems = true
            window?.toolbar = toolbar
            isMeasuringStartupToolbarItems = false
            startupPerformance.splitToolbarAttachmentNanoseconds =
                DispatchTime.now().uptimeNanoseconds - toolbarAttachmentStarted

            // Compact, not `.unified`: the large style reserves a title-scale toolbar row,
            // which dwarfs the deliberately quiet session tab and its compact app-owned
            // actions.
            let toolbarStyleStarted = DispatchTime.now().uptimeNanoseconds
            window?.toolbarStyle = .unifiedCompact
            startupPerformance.splitToolbarStyleNanoseconds =
                DispatchTime.now().uptimeNanoseconds - toolbarStyleStarted
        }
        startupPerformance.splitToolbarNanoseconds = DispatchTime.now().uptimeNanoseconds
            - toolbarStarted

        let headerStarted = DispatchTime.now().uptimeNanoseconds
        // The pane's own header, built here because the window controller owns what these
        // controls do, and installed there because the pane owns where they sit.
        containerViewController.installHeader(makePaneHeaderView())
        configureTabTransfer()
        // Both sets of controls now exist. Initialize them once, especially the surface button
        // whose glyph depends on the restored session and which must disappear when there is no
        // session. Updating after the toolbar and then again here repeated the same main-thread
        // state walk during every launch.
        updateToolbarControlStates()
        startupPerformance.splitHeaderNanoseconds = DispatchTime.now().uptimeNanoseconds
            - headerStarted

        let finalizeStarted = DispatchTime.now().uptimeNanoseconds
        splitViewController.paneCollapseStateDidChange = { [weak self] item, collapsed in
            guard let self else { return }
            self.updatePaneToggleSelection()
            // A panel dragged shut leaves by the same door as one closed from its own ✕:
            // the app-wide theme document is put away with the pane that was showing it.
            if item === self.displayItem, collapsed {
                self.displayPaneController.hideCurrentTheme()
            }
        }
        splitViewController.paneTransitionDidComplete = { [weak self] item, collapsed in
            // The report that matters here is the *sidebar's* — it moves the pane header out
            // from under the window controls; the panel's completions carry their own work.
            guard let self, item === self.sidebarItem else { return }
            self.updateHeaderInset(sidebarIsCollapsed: collapsed)
            if !collapsed {
                self.applyPendingWorkspaceNavigatorWidth()
            }
        }

        // The toolbar was installed a moment ago and has not laid its items out yet, so the
        // sidebar's floor is claimed on the next turn of the run loop — before the first display
        // cycle, and well before a divider can be dragged. The stored width follows in the same
        // turn, once there is a floor for it to be clamped against. Only then can the sidebar
        // mount its persisted tree: doing that after the window frame but before this width
        // restoration laid out every visible row at the default divider and immediately laid it
        // out again at the user's divider.
        // Snapshot the user's divider before yielding. The test host can have older window
        // controllers draining resize notifications on the same main queue; more importantly,
        // the value being restored is launch input, not mutable state to re-read after default
        // layout has had a chance to report itself.
        let initialSidebarWidth = SidebarWidth.stored
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateSidebarMinimumThickness()
            self.restoreSidebarWidth(initialSidebarWidth)
            self.sidebarViewController.mountInitialTreeIfNeeded()
        }
        startupPerformance.splitFinalizeNanoseconds = DispatchTime.now().uptimeNanoseconds
            - finalizeStarted
    }

    /// Attributes only the delegate work nested inside the initial `NSWindow.setToolbar` call.
    /// Theme reinstalls and later AppKit requests are deliberately excluded from the launch
    /// metric, so the sub-phase remains comparable with `splitToolbarAttachmentNanoseconds`.
    func recordStartupToolbarItemConstruction(_ elapsedNanoseconds: UInt64) {
        guard isMeasuringStartupToolbarItems else { return }
        startupPerformance.splitToolbarItemNanoseconds += elapsedNanoseconds
    }

    /// Wires the frame exchange up once the window and split view exist.
    ///
    /// The coordinator observes theme changes itself; the controller only lends it the three
    /// operations that are genuinely the controller's — the toolbar's lifecycle and the
    /// measurements that assume one frame or the other.
    private func setupChromeCoordinator() {
        guard let window = window as? TitlebarActionWindow else { return }
        chromeCoordinator = WindowChromeCoordinator(
            window: window,
            callbacks: .init(
                removeToolbar: { [weak self] in
                    self?.window?.toolbar = nil
                },
                reinstallToolbar: { [weak self] in
                    self?.reinstallNativeToolbar()
                },
                takeoverDidChange: { [weak self] active in
                    self?.windowChromeTakeoverDidChange(active)
                }
            )
        )

        // A window created straight into takeover never flips, so the content-side chrome is
        // brought in line here rather than by the callback nothing will fire.
        if chromeCoordinator?.isTakeoverActive == true {
            windowChromeTakeoverDidChange(true)
        }
    }

    private func reinstallNativeToolbar() {
        window?.toolbar = makeToolbar()
        updateToolbarControlStates()
        window?.toolbarStyle = .unifiedCompact
    }

    /// The frame changed hands: the chrome host dresses or undresses, the window's own
    /// controls move between the toolbar and the app-drawn command band, and the measurements that assumed the
    /// other frame answer again — now, for everything that reads them this turn, and once
    /// more a turn later because a reinstalled toolbar's items have no real frames yet (the
    /// rule `setupSplitViewController` already follows).
    private func windowChromeTakeoverDidChange(_ active: Bool) {
        chromeHostViewController.setTakeoverActive(active)
        if active {
            installTakeoverControls()
        } else {
            // The toolbar reinstall has already re-created its buttons and re-pointed the
            // weak references at them; the command band only has to let go of its copies.
            chromeHostViewController.commandBandView.setLeadingControls([])
        }

        updateHeaderInset()
        updateSidebarMinimumThickness()
        DispatchQueue.main.async { [weak self] in
            self?.updateHeaderInset()
            self?.updateSidebarMinimumThickness()
        }
    }

    /// The toolbar residents, rebuilt for the command band with ordinary chrome ink. Fresh
    /// instances rather than the toolbar's: an `NSToolbarItem`'s view belongs to the item,
    /// and the weak references exist precisely so `updateToolbarControlStates` reaches
    /// whichever copies are live.
    private func installTakeoverControls() {
        let sidebar = ThemedIconButton(
            symbolName: "sidebar.leading",
            accessibility: L10n.string("Show or hide sidebar"),
            inkSource: .chrome
        )
        sidebar.toolTip = L10n.string("Show or Hide the Sidebar (⌃⌘S)")
        sidebar.onPress = { [weak self] in self?.toggleSidebar() }
        sidebarToolbarButton = sidebar

        let back = ThemedIconButton(
            symbolName: "chevron.left",
            accessibility: L10n.string("Go back"),
            inkSource: .chrome
        )
        back.toolTip = L10n.string("Go Back (⌃⌘←)")
        back.onPress = { [weak self] in self?.goBack() }
        back.isEnabled = false
        navBackToolbarButton = back

        let forward = ThemedIconButton(
            symbolName: "chevron.right",
            accessibility: L10n.string("Go forward"),
            inkSource: .chrome
        )
        forward.toolTip = L10n.string("Go Forward (⌃⌘→)")
        forward.onPress = { [weak self] in self?.goForward() }
        forward.isEnabled = false
        navForwardToolbarButton = forward

        chromeHostViewController.commandBandView.setLeadingControls([sidebar, back, forward])
        updateToolbarControlStates()
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
            guard let source = ExtensionManager.shared.customSurfaceSource(
                relativePath: specification.shaderResource,
                extensionIdentifier: extensionIdentifier
            ) else {
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
                    "Could not render Metal surface from \(extensionIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                return nil
            }
        }
    }

    private func extensionHostSignal(_ signal: ExtensionHostSignal) -> Double? {
        switch signal {
        case .activeAccountUsageRemaining:
            guard let account = materializedAccountUsageItemView?.account,
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

        // Where a page went, answered in the pane it left. Built here because which windows
        // exist is the window's knowledge, and the panel is deliberately not told how to make
        // one — only what to draw and what the two answers do.
        displayPaneController.sessionBrowserCount = { [weak self] sessionID in
            self?.browserResolver.locations(for: sessionID).count ?? 0
        }

        displayPaneController.detachedWindowProxies = { [weak self] sessionID in
            guard let self else { return [] }
            return orderedDetachedWindows
                .filter { $0.sessionID == sessionID }
                .map { controller in
                    DisplayPaneController.DetachedWindowProxy(
                        windowID: controller.windowID,
                        title: controller.host.windowTitle,
                        onFocus: { [weak controller] in controller?.showWindow(nil) },
                        onBringBack: { [weak self, weak controller] in
                            guard let self, let controller else { return }
                            bringDetachedWindowBack(controller)
                        }
                    )
                }
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
            self?.refreshProjectScriptContext()
        }

        // A clicked macOS notification lands here. The sidebar owns the chat selection; the
        // destination is then resolved against the session's current durable/live surfaces.
        appEvents.observe(SessionNotificationOpened.self) { [weak self] event in
            guard let self,
                  ProjectStore.shared.session(withID: event.sessionID) != nil else { return }
            // Settings takes the sidebar over, so arriving from a notification has to leave it
            // the same way Back does — otherwise the pane switches to the session while the
            // sidebar keeps listing settings sections, with no row to show which one arrived.
            self.exitSettingsForNavigation()
            self.sidebarViewController.select(sessionID: event.sessionID)
            DispatchQueue.main.async { [weak self] in
                self?.openNotificationDestination(event.destination, for: event.sessionID)
            }
        }
        appEvents.observe(SessionLocalInputBlocked.self) { [weak self] event in
            guard let self, self.currentSessionID == event.sessionID,
                  Date().timeIntervalSince(self.lastBlockedInputToastAt) > 2 else { return }
            self.lastBlockedInputToastAt = Date()
            let control = RemoteSessionMirrorRegistry.shared.ownerInputControlState(
                for: event.sessionID
            )
            let controller = control.controllerDisplayName ?? L10n.string("Another participant")
            self.sidebarViewController.presentToast(ToastRequest(
                message: L10n.format("%@ is controlling this chat", controller),
                detail: L10n.string("Your input was not sent."),
                actionTitle: L10n.string("Reclaim"),
                action: {
                    RemoteSessionMirrorRegistry.shared.setInputControlFromOwner(
                        .reclaim,
                        sessionID: event.sessionID
                    )
                },
                dwell: ToastDefaults.unattendedDwell,
                identifier: "remote.input.blocked"
            ))
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
        // Under a takeover theme there is nothing to clear: the traffic lights are gone and
        // the window's own controls live inside the title band, above the panes, so the
        // header begins at its plain inset in both sidebar states.
        guard chromeCoordinator?.isTakeoverActive != true else {
            containerViewController.headerLeadingInset = PaneHeaderDefaults.inset
            return
        }
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
        // A takeover window floats no controls over the panes at all — no traffic lights, no
        // toolbar — so nothing ends anywhere: the sidebar's floor falls back to its own
        // minimum and the header to its plain inset.
        guard chromeCoordinator?.isTakeoverActive != true else { return 0 }

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
    private func restoreSidebarWidth(_ width: CGFloat?) {
        defer { recordsSidebarWidth = true }
        guard let width, !sidebarItem.isCollapsed else { return }

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(width, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }

    // MARK: - Display Pane

    /// Shows or hides the display panel, through the same animated route as the sidebar.
    ///
    /// Animated by default because showing and hiding this panel are *gestures* — the toolbar
    /// toggle, the pane's own ✕, a surface command. A session switch passes `animated: false`:
    /// it swaps the whole workspace, and a panel sliding during the swap would animate a change
    /// of subject as if it were a change of state.
    func setDisplayPaneVisible(
        _ visible: Bool,
        animated: Bool = true
    ) {
#if DEBUG
        let requestStarted = DispatchTime.now().uptimeNanoseconds
#endif
        if !visible {
            displayPaneController.hideCurrentTheme()
        }
        guard displayItem.isCollapsed == visible else {
            return
        }

        // AppKit's implicit split animation synchronously commits the window's whole backing
        // layer tree before its first frame. Beside a live TUI that means repainting SwiftTerm,
        // laying out every intermediate width, and provoking SIGWINCH-driven Codex/Claude
        // redraws for motion whose only useful result is the final divider position. Measured
        // cold on the CLI fixture: ~297 ms animated versus ~111 ms at one stable width. Native
        // conversation surfaces keep the standard pane motion; a terminal commits once.
        let activeTerminal = containerViewController.activeTerminalSession?.terminalView
        let animatesGeometry = animated && activeTerminal == nil

        guard visible else {
#if DEBUG
            let collapseStarted = DispatchTime.now().uptimeNanoseconds
#endif
            splitViewController.setCollapsed(
                true,
                on: displayItem,
                animated: animatesGeometry,
                completion: nil
            )
#if DEBUG
            let collapseEnded = DispatchTime.now().uptimeNanoseconds
#endif
            updateToolbarControlStates()
#if DEBUG
            let toolbarEnded = DispatchTime.now().uptimeNanoseconds
            lastDisplayPaneRequestPhaseDurations = DisplayPaneRequestPhaseDurations(
                preparationNanoseconds: collapseStarted - requestStarted,
                collapseNanoseconds: collapseEnded - collapseStarted,
                toolbarNanoseconds: toolbarEnded - collapseEnded
            )
#endif
            return
        }

        // Read *before* uncollapsing. The layout that follows fires resize notifications
        // carrying a transient thickness — the item's minimum — and recording that would
        // overwrite the width about to be restored with that minimum on every first reveal.
        // The window is measured here too, while the panel is still shut and the split view
        // therefore still the full content width.
        let target = DisplayPaneWidth.opening(in: splitView.bounds.width)
        isRestoringDisplayPaneWidth = true
#if DEBUG
        let collapseStarted = DispatchTime.now().uptimeNanoseconds
#endif
        splitViewController.setCollapsed(
            false,
            on: displayItem,
            animated: animatesGeometry,
            geometryChanges: { [weak self] in
                self?.applyDisplayPaneWidth(target)
            }
        ) { [weak self] in
            guard let self else { return }
            guard !self.displayItem.isCollapsed else {
                // Closed again mid-reveal: there is no width to restore, and the flag must not
                // outlive the reveal it was guarding or no width is ever recorded again.
                self.isRestoringDisplayPaneWidth = false
                return
            }

            // The remembered divider position was installed inside the uncollapse's animation
            // group, so there is one motion from shut to target rather than a reveal to the
            // chrome floor followed by a second 200 ms width restoration.
            self.isRestoringDisplayPaneWidth = false
        }
#if DEBUG
        let collapseEnded = DispatchTime.now().uptimeNanoseconds
#endif
        updateToolbarControlStates()
#if DEBUG
        let toolbarEnded = DispatchTime.now().uptimeNanoseconds
        lastDisplayPaneRequestPhaseDurations = DisplayPaneRequestPhaseDurations(
            preparationNanoseconds: collapseStarted - requestStarted,
            collapseNanoseconds: collapseEnded - collapseStarted,
            toolbarNanoseconds: toolbarEnded - collapseEnded
        )
#endif
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
    /// Unanimated throughout: a switch swaps the whole workspace at once, and the panel
    /// sliding beside an instant page change would single it out as the one thing "moving".
    private func syncDisplayPane(to sessionID: SessionID?) {
        displayPaneController.showSession(sessionID)

        // A session's detached windows come back when the session does. The panes restore on
        // their first *ask* and that is invisible because a pane is not on screen until its
        // session is either — but nothing ever asks a window into existence, so this is the
        // ask. Existing windows stay exactly where they are: a window is not a pane, and
        // switching sessions must not sweep another session's browser off the screen.
        if let sessionID {
            restoreDetachedBrowserWindows(for: sessionID)
        }

        // The theme document is app-wide, so changing or temporarily clearing the selected
        // session must not close it. Its agent attribution remains whichever conversation is in
        // the main pane; only the inspector itself is global.
        if displayPaneController.isShowingCurrentTheme {
            setDisplayPaneVisible(true, animated: false)
            return
        }

        guard let sessionID, displayPaneController.hasContent(for: sessionID) else {
            setDisplayPaneVisible(false, animated: false)
            return
        }

        setDisplayPaneVisible(true, animated: false)
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

    /// Says that the previous launch died, and offers back the workspace this one held.
    ///
    /// **A band in the pane, never an alert.** A launch that stops to ask a question asks it
    /// before the user has asked the app for anything, and what it would be asking about is the
    /// *previous* launch — nothing is waiting on the answer. So the report sits above the
    /// content where the pane's other chrome does, waits as long as it takes to be read, and
    /// leaves when it is answered or dismissed.
    ///
    /// The report is *revealed* rather than opened: an `.ips` opens in Console, and what someone
    /// filing a bug needs is the file, in the Finder, ready to attach.
    ///
    /// Two answers carry the band's weight — take my workspace back, and tell the developer —
    /// and the Finder reveal trails them as the technical footnote it is. Neither of the two is
    /// primary: a band that appears unasked has no claim on the screen's one primary action.
    ///
    /// The escalated wording is the only thing a crash *loop* changes here. It says the app has
    /// died more than once and stops: what to do about it is Recovery Mode's to offer, and a band
    /// that hinted at a mode the build does not have would be worse than one that says nothing.
    func presentUncleanExitNotice(
        crashReport: URL?,
        escalation: UncleanExitEscalation = .none,
        restore: @escaping () -> Void
    ) {
        MacRemoteDiagnostics.record(.uncleanExitDetected, level: .warning, fields: [
            .result: crashReport == nil ? "withoutSystemReport" : "withSystemReport",
            .reason: escalation == .none ? "singleExit" : "repeatedExit",
        ])
        var actions: [PaneNoticeAction] = [
            PaneNoticeAction(title: L10n.string("Restore")) { [weak self] in
                self?.containerViewController.dismissNotice()
                restore()
            }
        ]
        if let submitter = issueReportSubmitter {
            actions.append(
                PaneNoticeAction(
                    // The band's second answer, at the band's second weight. The report is the
                    // only thing this band asks *for* — a crash nobody sends is a crash nobody
                    // can fix — and as a tertiary label behind the Finder reveal it read as a
                    // footnote to the one action that only helps the developer if it is pressed.
                    title: L10n.string("Send to Developer"),
                    emphasis: .secondary
                ) { [weak self] in
                    guard let self, !isSendingCrashReport else { return }
                    isSendingCrashReport = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { isSendingCrashReport = false }
                        let draft = DeveloperIssueReportDraft(
                            kind: .problem,
                            title: L10n.string("Previous launch ended unexpectedly"),
                            details: Self.uncleanExitMessage(escalation: escalation)
                        )
                        let outcome = await submitter.submit(
                            trigger: "postCrash",
                            draft: draft
                        )
                        showCrashReportSubmissionOutcome(outcome)
                    }
                }
            )
        }
        // Last, and quiet: revealing the `.ips` is for the person who wants to read it or attach
        // it themselves, which is the rarer of the two things to do with a crash report.
        if let crashReport {
            actions.append(
                PaneNoticeAction(
                    title: L10n.string("Show Crash Report"),
                    emphasis: .tertiary
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([crashReport])
                }
            )
        }

        let notice = PaneNoticeView(
            tone: .attention,
            message: Self.uncleanExitMessage(escalation: escalation),
            actions: actions,
            onDismiss: { [weak self] in self?.containerViewController.dismissNotice() }
        )
        containerViewController.showNotice(notice)
    }

    private func showCrashReportSubmissionOutcome(
        _ outcome: DeveloperIssueReportSubmission
    ) {
        let alert = ThemedAlert()
        switch outcome {
        case .delivered(let reference):
            alert.messageText = L10n.string("Report received")
            alert.informativeText = L10n.format(
                "Threading’s developer inbox received the crash summary. Reference: %@",
                reference
            )
        case .queued:
            alert.messageText = L10n.string("Report saved")
            alert.informativeText = L10n.string(
                "The crash summary is saved securely and will retry when Threading is active."
            )
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Couldn’t send report")
            alert.informativeText = message
        }
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }

    /// Puts the recovery surface in the pane, with a standing band above it.
    ///
    /// **A band with no dismissal.** `PaneNoticeView` already draws a standing condition the pane
    /// found on its own, and this is the most standing one there is: the only thing that ends it
    /// is a relaunch. Without it the surface would be a screen the user could navigate away from
    /// and never get back, because every route that used to reach the pane now shows something
    /// else.
    ///
    /// The actions are handed in rather than built here, so the screen can be exercised without
    /// relaunching the app or moving anybody's data.
    func presentRecoveryMode(
        reason: LaunchModeReason,
        checkpoint: StartupCheckpoint?,
        crashReport: URL?,
        extensionsDisabledNextLaunch: Bool,
        actions: RecoveryModeActions
    ) {
        installRecoverySurface(
            reason: reason,
            checkpoint: checkpoint,
            crashReport: crashReport,
            extensionsDisabledNextLaunch: extensionsDisabledNextLaunch,
            actions: actions
        )

        let notice = PaneNoticeView(
            tone: .attention,
            message: RecoveryModeDefaults.bandMessage,
            actions: [
                PaneNoticeAction(title: RecoveryModeDefaults.bandAction) { [weak self] in
                    self?.containerViewController.showRecoverySurface()
                }
            ]
        )
        containerViewController.showNotice(notice)
    }

    /// Builds the surface and hands it to the pane. Called again when something on it changed
    /// state — the extensions button's title is the one such thing, and a button that does not
    /// answer a press reads as broken.
    func installRecoverySurface(
        reason: LaunchModeReason,
        checkpoint: StartupCheckpoint?,
        crashReport: URL?,
        extensionsDisabledNextLaunch: Bool,
        actions: RecoveryModeActions
    ) {
        containerViewController.installRecoverySurface(
            RecoveryModeSurface.make(
                reason: reason,
                checkpoint: checkpoint,
                hasCrashReport: crashReport != nil,
                extensionsDisabledNextLaunch: extensionsDisabledNextLaunch,
                actions: actions
            )
        )
    }

    /// Takes the surface off the pane, leaving the band. "Continue in Recovery Mode": the app
    /// stays exactly as it is, and the pane goes back to what a recovery selection shows.
    func dismissRecoverySurface() {
        containerViewController.dismissRecoverySurface()
    }

    /// Says that a normal launch deliberately came up without extensions.
    func presentExtensionsHeldBackNotice() {
        let notice = PaneNoticeView(
            tone: .informational,
            message: L10n.string(
                "Extensions did not start this launch. They start again the next time Threading opens."
            ),
            actions: [
                PaneNoticeAction(title: L10n.string("Open Extensions Settings")) { [weak self] in
                    self?.containerViewController.dismissNotice()
                    self?.showSettingsPage(id: SettingsPages.extensionsID)
                }
            ],
            onDismiss: { [weak self] in self?.containerViewController.dismissNotice() }
        )
        containerViewController.showNotice(notice)
    }

    /// Built apart from being shown, so a test can hold the wording without a window.
    static func uncleanExitMessage(escalation: UncleanExitEscalation) -> String {
        switch escalation {
        case .none:
            return L10n.string(
                "Threading quit unexpectedly last time. Its open session and browser windows were not reopened."
            )
        case .repeatedUnexpectedExits:
            return L10n.string(
                "Threading has quit unexpectedly more than once, so its open session and browser windows were not reopened."
            )
        }
    }

    /// Relaunches, without selecting them, the sessions that were running at the last quit.
    ///
    /// The record is consumed before the setting is consulted, so a list written under one
    /// choice cannot fire under a later one. The selected session is left out when
    /// `restoreSelectedSession` is already bringing it back through the sidebar — its launch
    /// is a run-loop turn away, which `hasTerminal` alone would race.
    func relaunchSessionsFromLastQuit() {
        // Consumed whatever the policy is, and before the policy is consulted: a list written
        // under one choice must not be able to fire under a later one.
        let recorded = StateManager.shared.consumeRunningSessionIDs()
        let settings = AppSettings.shared
        let policy = settings.sessionRestorePolicy

        let plan = StartupSessionRelaunch.plan(
            policy: policy,
            recorded: recorded,
            sessions: ProjectStore.shared.projects.flatMap(\.sessions),
            windowDays: settings.sessionRestoreWindowDays,
            limit: settings.sessionRestoreLimit,
            excluding: settings.restoresLastSession
                ? ProjectStore.shared.selectedSessionID
                : nil
        )
        // Recorded before the plan is allowed to be empty, and recorded for every policy: the
        // hover card on a dormant row explains this decision, and "nothing came back" is the
        // answer a user is most likely to be asking about.
        SessionRestorationLedger.shared.record(plan)

        // Both counts, before the plan is allowed to be empty: "recorded 1, relaunching 0" is
        // the ordinary answer when the only session running at the quit was the selected one,
        // which `plan` leaves to `restoreSelectedSession`. Logging only the launches made that
        // case look exactly like a record that was never written.
        EventLog.shared.record(.session, "Relaunching sessions from last quit", [
            "policy": policy.rawValue,
            "recorded": String(recorded.count),
            "relaunching": String(plan.sessionIDs.count)
        ])

        guard !plan.sessionIDs.isEmpty else { return }

        let relauncher = StartupSessionRelauncher(
            sessionIDs: plan.sessionIDs
        ) { [weak self] sessionID in
            self?.containerViewController.launchInBackground(sessionID: sessionID)
        }
        startupRelauncher = relauncher
        relauncher.start()
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
        fastMode: Bool?,
        permissionMode: AgentPermissionMode?,
        usesNativeUI: Bool,
        prompt: String
    ) -> AgentSession? {
        sessionCoordinator.startRemoteSession(
            in: projectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            permissionMode: permissionMode,
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
    /// Each workspace branch hands the header an **identity** as well as a title, which is what
    /// lets a rename morph while a change of page lands directly — see `PageTitleView.update`.
    /// Settings instead shows one stable mode label: the selected category is already named by
    /// its sidebar row and page heading, and changing it does not create a new document.
    func updateSessionTitleItem() {
        if containerViewController.isShowingSettings {
            materializedPageTitleView?.isHidden = true
            setSettingsModeChrome(visible: true)
            updateAccountUsageItem(session: nil)
            updateToolbarControlStates()
            return
        }

        setSettingsModeChrome(visible: false)

        let sessionID = containerViewController.currentSessionID
        let session = sessionID.flatMap { ProjectStore.shared.session(withID: $0) }

        if let sessionID, let session {
            let project = ProjectStore.shared.project(forSessionID: sessionID)
            showPageTitle(
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
            showPageTitle(
                title: ProjectTerminalTitle.displayTitle(for: terminal),
                symbolName: "terminal",
                identity: terminalID,
                toolTip: terminal.currentDirectory
            )
        } else if let projectID = containerViewController.currentComposerProjectID {
            let project = ProjectStore.shared.project(withID: projectID)
            showPageTitle(
                title: project?.name ?? L10n.string("New Session"),
                symbolName: SessionTitleDefaults.projectSymbolName,
                identity: projectID,
                toolTip: project?.name
            )
        } else {
            materializedPageTitleView?.isHidden = true
        }
        updateAccountUsageItem(session: session)
        updateToolbarControlStates()
    }

    private func showPageTitle(
        title: String,
        symbolName: String,
        identity: AnyHashable,
        icon: NSImage? = nil,
        toolTip: String? = nil
    ) {
        setSettingsModeChrome(visible: false)
        let pageTitleView = pageTitleView
        pageTitleView.isHidden = false
        pageTitleView.update(
            title: title,
            symbolName: symbolName,
            identity: identity
        )
        if let icon {
            pageTitleView.setIcon(icon)
        }
        pageTitleView.toolTip = toolTip ?? title
    }

    @objc private func settingsDoneClicked(_ sender: ThemedButton) {
        guard containerViewController.isShowingSettings else { return }
        toggleSettings()
    }

    // MARK: - Tab Transfer

    /// Moves tabs between the window's hosts; only the window sees them all.
    private lazy var tabTransfer = TabTransferCoordinator(host: { [weak self] hostID in
        guard let self else { return nil }
        switch hostID {
        case .displayPanel: return displayPaneController
        case .drawer: return containerViewController.drawerHostController
        case .detachedWindow(let id): return detachedBrowserWindows[id]?.host
        }
    })

    // MARK: - Detached Browser Windows

    /// Moves a tab into a window of its own, and shows it.
    ///
    /// The window is built empty and the tab moved into it through the same transfer path every
    /// other move uses — detach without teardown, adopt — so the browser keeps its page, its
    /// history and its signed-in state, exactly as it does travelling between the two panes.
    @discardableResult
    func detachTabIntoWindow(
        _ tabID: UUID,
        from sourceID: TabHostID,
        droppedAt screenPoint: NSPoint? = nil
    ) -> Bool {
        guard let source = tabTransfer.resolve(sourceID),
              let tab = source.tabs(for: nil).first(where: { $0.id == tabID })
                ?? currentSessionID.flatMap({ session in
                    source.tabs(for: session).first { $0.id == tabID }
                }),
              let sessionID = tab.owningSessionID ?? currentSessionID
        else {
            NSSound.beep()
            return false
        }

        let controller = makeDetachedBrowserWindow(
            for: sessionID,
            droppedAt: screenPoint
        )
        guard tabTransfer.move(
            tabID: tabID,
            from: sourceID,
            to: TabHostID.detachedWindow(controller.windowID),
            sessionID: sessionID
        ) else {
            // Nothing moved, so nothing should have been built.
            forgetDetachedWindow(controller.windowID)
            controller.close()
            NSSound.beep()
            return false
        }

        controller.showWindow(nil)
        persistDetachedWindow(controller)
        return true
    }

    private func makeDetachedBrowserWindow(
        for sessionID: SessionID,
        windowID: UUID = UUID(),
        restoredFrame: NSRect? = nil,
        droppedAt screenPoint: NSPoint? = nil
    ) -> DetachedBrowserWindowController {
        let host = DetachedBrowserHostViewController(sessionID: sessionID, windowID: windowID)
        let controller = DetachedBrowserWindowController(
            host: host,
            restoredFrame: restoredFrame,
            droppedAt: screenPoint
        )

        host.sessionBrowserCount = { [weak self] in
            self?.browserResolver.locations(for: sessionID).count ?? 0
        }
        host.transferEntries = { [weak self, weak controller] tabID in
            guard let self, let controller else { return [] }
            return transferMenuEntries(
                from: TabHostID.detachedWindow(controller.windowID),
                tabID: tabID
            )
        }
        // The window's strip drags by the same rules the panes' do, already in screen space.
        host.dragOutDestination = { [weak self, weak controller] tabID, screenPoint in
            guard let self, let controller else { return false }
            return trackDrag(
                from: .detachedWindow(controller.windowID),
                tabID: tabID,
                at: screenPoint
            ) != nil
        }
        host.performDragOut = { [weak self, weak controller] tabID, screenPoint in
            guard let self, let controller else { return }
            dropDraggedTab(
                from: .detachedWindow(controller.windowID),
                tabID: tabID,
                at: screenPoint
            )
        }
        host.dragOutEnded = { [weak self] _ in
            self?.dragDidSettle()
        }
        controller.onPersist = { [weak self] controller in
            guard let self else { return }
            persistDetachedWindow(controller)
            // The chip carries the page's own title, so it follows the page.
            refreshDetachedWindowProxies()
        }
        controller.onClose = { [weak self] windowID in
            self?.forgetDetachedWindow(windowID)
        }

        detachedBrowserWindows[windowID] = controller
        detachedWindowOrder.append(windowID)
        refreshDetachedWindowProxies()
        return controller
    }

    /// The proxy chips are drawn from `detachedBrowserWindows`, so the panel is asked to redraw
    /// whenever that set changes — a window opening, closing, or renaming itself.
    private func refreshDetachedWindowProxies() {
        // A redraw, not a re-point. `showSessionTabs` also dismisses the app-theme document —
        // right for a keystroke, catastrophic here, where this fires on every window move,
        // resize and page change: dragging a detached window would have closed a document the
        // user was reading.
        displayPaneController.refreshDetachedWindowProxies()
    }

    private func persistDetachedWindow(_ controller: DetachedBrowserWindowController) {
        DisplayPaneStore.shared.saveDetachedWindowLayout(
            controller.persistedWindow,
            tabs: controller.host.persistedTabs,
            for: controller.sessionID
        )
    }

    /// Closes the detached windows of sessions that no longer exist.
    ///
    /// Without this an orphan window stays on screen and keeps persisting — and
    /// `saveDetachedWindowLayout` rebuilds a `panel_layout` row from nothing, so the deleted
    /// session's document comes *back* moments after the sweep that removed it.
    func closeDetachedWindows(forSessionsOutside liveSessionIDs: Set<SessionID>) {
        for controller in orderedDetachedWindows
        where !liveSessionIDs.contains(controller.sessionID) {
            forgetDetachedWindow(controller.windowID)
            controller.close()
        }
    }

    /// Closes one deleted session's detached windows without rewriting its soon-to-be-deleted
    /// panel document once per window.
    func closeDetachedWindows(forSession sessionID: SessionID) {
        let controllers = orderedDetachedWindows.filter { $0.sessionID == sessionID }
        guard !controllers.isEmpty else { return }
        for controller in controllers {
            detachedBrowserWindows.removeValue(forKey: controller.windowID)
            detachedWindowOrder.removeAll { $0 == controller.windowID }
            controller.onPersist = nil
            controller.onClose = nil
            controller.close()
        }
        refreshDetachedWindowProxies()
    }

    /// Moves every page in a detached window back into the panel. The window empties as its
    /// last tab leaves and closes itself, which is the same path a drag back takes — nothing
    /// here knows how to close a window, and nothing needs to.
    private func bringDetachedWindowBack(_ controller: DetachedBrowserWindowController) {
        let sessionID = controller.sessionID
        for tab in controller.host.tabs(for: sessionID) {
            moveTab(tab.id, from: .detachedWindow(controller.windowID), to: .displayPanel)
        }
    }

    private func forgetDetachedWindow(_ windowID: UUID) {
        guard let controller = detachedBrowserWindows.removeValue(forKey: windowID) else { return }
        detachedWindowOrder.removeAll { $0 == windowID }
        refreshDetachedWindowProxies()
        // A window closed with tabs still in it ends what they held, exactly as closing a tab
        // does; one emptied by a move has nothing left to forget and already wrote that.
        if !controller.host.isEmpty {
            DisplayPaneStore.shared.removeDetachedWindow(windowID, for: controller.sessionID)
        }
    }

    /// Brings back every session's detached windows at launch.
    ///
    /// **Eager, and it has to be.** Both panes restore on their first *ask*, which is invisible
    /// because a pane is not on screen until its session is either — but nothing ever asks a
    /// window into existence. Hanging this on session selection instead, as an earlier pass did,
    /// means the headline case does not come back at all: `relaunchSessionsFromLastQuit`
    /// relaunches without *selecting*, so a fullscreen browser on a second display would wait
    /// until the user happened to click that session.
    ///
    /// The scan is over `panel_layout` rows, not conversations: a session's layout is a small
    /// JSON document in its own table, deliberately not foreign-keyed to `session`, and building
    /// a browser needs a session id and nothing else. Gated on the same switches that decide how
    /// much of the workspace comes back at all.
    func restoreDetachedBrowserWindowsAtLaunch() {
        guard AppSettings.shared.restoresLastSession
            || AppSettings.shared.restoresSessionsAtLaunch else { return }

        for session in ProjectStore.shared.projects.flatMap(\.sessions) where !session.isArchived {
            restoreDetachedBrowserWindows(for: session.id)
        }
    }

    /// Brings back the detached windows a session left behind.
    ///
    /// Eager, and it has to be: every pane restores on first *ask* — selecting the session asks
    /// — but nothing ever asks a window into existence. Ordered on screen for a second reason
    /// the measurement found: WebKit renders nothing for a view in a window that was never
    /// shown, so a window restored but never ordered in would hand an agent blank captures
    /// forever (`BrowserOffScreenCaptureTests`).
    func restoreDetachedBrowserWindows(for sessionID: SessionID) {
        guard let panel = DisplayPaneStore.shared.loadLayout(for: sessionID) else { return }

        for window in panel.detachedWindows {
            guard let windowID = UUID(uuidString: window.id),
                  detachedBrowserWindows[windowID] == nil
            else { continue }

            let persistedTabs = panel.tabs(inDetachedWindow: windowID)
            guard !persistedTabs.isEmpty else { continue }

            let controller = makeDetachedBrowserWindow(
                for: sessionID,
                windowID: windowID,
                restoredFrame: window.frame.map(NSRectFromString)
            )
            let tabs = persistedTabs.map { persisted in
                PaneTab(
                    id: UUID(uuidString: persisted.id) ?? UUID(),
                    body: .browser(controller.host.makeRestoredBrowser(url: persisted.url)),
                    owningSessionID: sessionID
                )
            }
            controller.host.restore(
                tabs,
                activeID: window.activeTabID.flatMap(UUID.init(uuidString:))
            )
            // Ordered in, never made key: selecting a session in the sidebar is not a request
            // to type into a browser, and with several windows each would have grabbed the
            // keyboard in turn. Being ordered in at all is still required — WebKit renders
            // nothing for a view in a window that was never shown.
            controller.window?.orderFront(nil)
            if window.isFullScreen == true, controller.window?.styleMask.contains(.fullScreen) != true {
                controller.window?.toggleFullScreen(nil)
            }
        }
    }

    /// Wires movement into both strip panes' context menus and the drag-out gesture. Called
    /// once, after both panes exist. Finding a browser across those panes is
    /// `browserResolver`'s job, not a hook installed here.
    private func configureTabTransfer() {
        displayPaneController.transferEntries = { [weak self] tabID in
            self?.transferMenuEntries(from: .displayPanel, tabID: tabID) ?? []
        }
        containerViewController.drawerHostController.transferEntries = { [weak self] tabID in
            self?.transferMenuEntries(from: .drawer, tabID: tabID) ?? []
        }

        displayPaneController.dragOutDestination = { [weak self] tabID, windowPoint in
            guard let self, let point = screenPoint(windowPoint, in: displayPaneController.view)
            else { return false }
            return trackDrag(from: .displayPanel, tabID: tabID, at: point) != nil
        }
        displayPaneController.performDragOut = { [weak self] tabID, windowPoint in
            guard let self, let point = screenPoint(windowPoint, in: displayPaneController.view)
            else { return }
            dropDraggedTab(from: .displayPanel, tabID: tabID, at: point)
        }
        displayPaneController.dragOutEnded = { [weak self] _ in
            self?.dragDidSettle()
        }
        containerViewController.drawerHostController.dragOutDestination = {
            [weak self] tabID, windowPoint in
            guard let self, let point = screenPoint(
                windowPoint,
                in: containerViewController.drawerHostController.view
            ) else { return false }
            return trackDrag(from: .drawer, tabID: tabID, at: point) != nil
        }
        containerViewController.drawerHostController.performDragOut = {
            [weak self] tabID, windowPoint in
            guard let self, let point = screenPoint(
                windowPoint,
                in: containerViewController.drawerHostController.view
            ) else { return }
            dropDraggedTab(from: .drawer, tabID: tabID, at: point)
        }
        containerViewController.drawerHostController.dragOutEnded = { [weak self] _ in
            self?.dragDidSettle()
        }
    }

    /// What a travelling drag arranged for its own benefit: a destination pane sprung open,
    /// remembered so a drag that settles without the drop puts it back.
    private struct DragSpringState {
        var openedDrawer = false
        var revealedPanel = false
        var dropped = false
        /// The session the panel was showing before a spring re-pointed it at the travelling
        /// tab's own. Left behind, the pane keeps showing another session's tabs — and
        /// `tabSession`'s fallback then resolves the wrong session for the next gesture.
        var paneSessionBeforeSpring: SessionID??
    }

    private var dragSpring = DragSpringState()

    /// The strip reports its own window's coordinates; every question after this is asked in
    /// screen space, because the drag can now end in another window entirely.
    private func screenPoint(_ windowPoint: NSPoint, in view: NSView) -> NSPoint? {
        view.window.map { $0.convertPoint(toScreen: windowPoint) }
    }

    /// Every host that can take a dropped chip, with its id. Enumerated rather than paired: the
    /// drag used to map each source to *the* other pane, which stops being a rule the moment
    /// there are three hosts and stops being expressible the moment there are many.
    /// Whether a host's window can actually receive a drop *now*.
    ///
    /// Asked here rather than inside `isDropBandVisible` because the hosts answer a geometry
    /// question that a built-but-never-shown fixture window must still be able to answer. The
    /// earlier reasoning — that screen coordinates make visibility redundant — was wrong for the
    /// windows this feature adds: a miniaturized window, one on another Space, and a fully
    /// occluded one all keep their frame, so their bands do contain live screen points. A
    /// fullscreen browser on Space 2 owns the top strip of the whole screen, and a drag near the
    /// top of Space 1 would have landed the tab in a window nobody can see.
    private func isWindowUsableForDrop(_ host: TabDropBandHosting) -> Bool {
        guard let window = (host as? NSViewController)?.view.window else { return false }
        return window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    private var dropBandHosts: [(TabHostID, TabDropBandHosting)] {
        [
            (.displayPanel, displayPaneController),
            (.drawer, containerViewController.drawerHostController)
        ] + detachedBrowserWindows.values.map { (.detachedWindow($0.windowID), $0.host) }
    }

    /// One pointer sample of a travelling chip: springs a closed destination open once the drag
    /// has left its own band, keeps the destination strip's wash in step, and answers whether a
    /// drop right now would land.
    private func trackDrag(
        from sourceID: TabHostID,
        tabID: UUID,
        at screenPoint: NSPoint
    ) -> DragLanding? {
        springDestinationOpen(from: sourceID, tabID: tabID, at: screenPoint)
        let landing = dragDestination(from: sourceID, tabID: tabID, at: screenPoint)
        highlightDropTarget(landing?.hostID)
        return landing
    }

    /// Where a travelling chip would land. A tear-off is not a host, which is the whole reason
    /// this is not simply a `TabHostID?`.
    private enum DragLanding {
        case host(TabHostID)
        /// Outside every window: let go and the tab gets one of its own.
        case newWindow

        var hostID: TabHostID? {
            if case .host(let id) = self { return id }
            return nil
        }
    }

    /// A drop needs a visible band, so the band makes itself visible: the moment a movable chip
    /// leaves its own strip's row, a closed *pane* opens — Finder's spring-loaded folder, for
    /// panes. Springing on leaving rather than on grabbing is what keeps an ordinary reorder
    /// from flinging the other pane open.
    ///
    /// Only the two panes spring. A detached window is not a pane the window can open on the
    /// user's behalf — it is either on screen or it is not, and one summoned by a drag passing
    /// over where it used to be would be a window appearing from nowhere.
    private func springDestinationOpen(
        from sourceID: TabHostID,
        tabID: UUID,
        at screenPoint: NSPoint
    ) {
        guard let sessionID = tabSession(of: tabID, in: sourceID) else { return }
        guard !isOverOwnBand(sourceID, screenPoint) else { return }

        if displayItem.isCollapsed, tabTransfer.canMove(
            tabID: tabID, from: sourceID, to: .displayPanel, sessionID: sessionID
        ) {
            dragSpring.revealedPanel = true
            if dragSpring.paneSessionBeforeSpring == nil {
                dragSpring.paneSessionBeforeSpring = .some(displayPaneController.currentSessionID)
            }
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        }
        if !containerViewController.isShellDrawerOpen, tabTransfer.canMove(
            tabID: tabID, from: sourceID, to: .drawer, sessionID: sessionID
        ) {
            dragSpring.openedDrawer = true
            containerViewController.openShellDrawer()
        }
        updateToolbarControlStates()
    }

    private func isOverOwnBand(_ hostID: TabHostID, _ screenPoint: NSPoint) -> Bool {
        dropBandHosts
            .first { $0.0 == hostID }?.1
            .dropBandContains(screenPoint: screenPoint) ?? false
    }

    private func highlightDropTarget(_ destinationID: TabHostID?) {
        for (hostID, host) in dropBandHosts {
            host.setDropTargetHighlighted(hostID == destinationID)
        }
    }

    /// The drag is over, dropped or not: washes clear, and a pane sprung open for a drop that
    /// never came goes back where it was.
    private func dragDidSettle() {
        highlightDropTarget(nil)
        if !dragSpring.dropped {
            if dragSpring.openedDrawer {
                containerViewController.collapseShellDrawer()
            }
            if dragSpring.revealedPanel {
                setDisplayPaneVisible(false)
            }
            if case .some(let previous) = dragSpring.paneSessionBeforeSpring {
                displayPaneController.showSessionTabs(previous)
            }
            updateToolbarControlStates()
        }
        dragSpring = DragSpringState()
    }

    /// The host a tab dragged out of `sourceID` would land in at this screen position, or nil
    /// while the drop would do nothing. Only a *visible* band takes a drop — a collapsed pane or
    /// an unshown window is reached by the menu, which opens it on landing.
    private func dragDestination(
        from sourceID: TabHostID,
        tabID: UUID,
        at screenPoint: NSPoint
    ) -> DragLanding? {
        guard let sessionID = tabSession(of: tabID, in: sourceID) else { return nil }

        for (hostID, host) in dropBandHosts where hostID != sourceID {
            // The drawer is furniture under the session on screen, so a tab belonging to another
            // one cannot land there: `moveTab` would adopt it into its own session's drawer while
            // `openShellDrawer` opened the visible session's, and the tab would be in no drawer
            // anyone can see. The chip menu already refuses this; the drag has to agree.
            if hostID == .drawer, sessionID != currentSessionID { continue }
            guard host.isDropBandVisible,
                  isWindowUsableForDrop(host),
                  host.dropBandContains(screenPoint: screenPoint),
                  tabTransfer.canMove(
                      tabID: tabID, from: sourceID, to: hostID, sessionID: sessionID
                  )
            else { continue }
            return .host(hostID)
        }

        return wouldTearOff(sourceID, tabID: tabID, at: screenPoint) ? .newWindow : nil
    }

    /// **Carried out of the window, not merely off a band.** The looser rule — anywhere no host
    /// would take it — would make a window out of every drag that overshot the strip by a few
    /// points, and an unwanted window is far more expensive to undo than a chip that springs
    /// back. Leaving the window the tab lives in is a thing a hand does on purpose.
    private func wouldTearOff(
        _ sourceID: TabHostID,
        tabID: UUID,
        at screenPoint: NSPoint
    ) -> Bool {
        guard canDetachTabIntoWindow(tabID, from: sourceID) else { return false }

        // A window's only tab has nowhere to go: the source would close as the destination
        // opened, which is an expensive way to move a window.
        if case .detachedWindow(let id) = sourceID,
           detachedBrowserWindows[id]?.host.tabCount ?? 0 <= 1 {
            return false
        }

        guard let source = dropBandHosts.first(where: { $0.0 == sourceID })?.1,
              let frame = (source as? NSViewController)?.view.window?.frame
        else { return false }
        return !frame.contains(screenPoint)
    }

    private func dropDraggedTab(from sourceID: TabHostID, tabID: UUID, at screenPoint: NSPoint) {
        guard let landing = dragDestination(
            from: sourceID, tabID: tabID, at: screenPoint
        ) else { return }
        dragSpring.dropped = true

        switch landing {
        case .host(let destinationID):
            // The slot the pointer names, by the destination strip's own midpoint rule — a drop
            // lands where it was aimed, not at the end of the row.
            let index = dropBandHosts
                .first { $0.0 == destinationID }?.1
                .dropInsertionIndex(screenPoint: screenPoint)
            moveTab(tabID, from: sourceID, to: destinationID, insertionIndex: index)

        case .newWindow:
            // Placed so the page appears under the hand that carried it there, rather than
            // cascading off the main window as the menu's own "Open in New Window" does — the
            // pointer already said where this belongs.
            detachTabIntoWindow(tabID, from: sourceID, droppedAt: screenPoint)
        }
    }

    /// The "Move to …" items for one tab — offered only where the destination would say yes,
    /// so the menu never advertises a move that would beep.
    private func transferMenuEntries(
        from sourceID: TabHostID,
        tabID: UUID
    ) -> [ThemedMenuEntry] {
        guard let sessionID = tabSession(of: tabID, in: sourceID) else { return [] }

        var destinations: [(TabHostID, String)] = []
        switch sourceID {
        case .displayPanel:
            destinations = [(.drawer, L10n.string("Move to Shell Drawer"))]
        case .drawer:
            destinations = [(.displayPanel, L10n.string("Move to Display Panel"))]
        case .detachedWindow:
            // A window's tab goes back to the panel; the drawer is furniture under a session on
            // screen, and offering it from a window pinned to a session the user may not be
            // looking at would land the tab somewhere they are not.
            destinations = [(.displayPanel, L10n.string("Move to Main Window"))]
        }

        var entries: [ThemedMenuEntry] = destinations.compactMap { destinationID, title in
            guard tabTransfer.canMove(
                tabID: tabID, from: sourceID, to: destinationID, sessionID: sessionID
            ) else { return nil }
            return .item(ThemedMenuItem(
                title: title,
                image: ThemedMenuIcon.symbol(Self.transferSymbol(to: destinationID)),
                onChoose: { [weak self] in
                    self?.moveTab(tabID, from: sourceID, to: destinationID)
                }
            ))
        }

        // Offered from the panes only: a tab already in a window of its own has nowhere new to
        // go, and moving it to a second empty window is not what the item means.
        if case .detachedWindow = sourceID {} else if canDetachTabIntoWindow(
            tabID,
            from: sourceID
        ) {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Open in New Window"),
                image: ThemedMenuIcon.symbol("macwindow.on.rectangle"),
                onChoose: { [weak self] in
                    self?.detachTabIntoWindow(tabID, from: sourceID)
                }
            )))
        }
        return entries
    }

    /// The mark a "move this tab there" row wears: the destination's own glyph, which is the
    /// same one its toggle wears in the header — so the row is read by where it sends the tab
    /// rather than by the three words the three destinations share.
    private static func transferSymbol(to destinationID: TabHostID) -> String {
        switch destinationID {
        case .displayPanel: return DisplayPanelToggle.symbolName
        case .drawer: return "rectangle.bottomthird.inset.filled"
        case .detachedWindow: return "macwindow"
        }
    }

    /// Whether a tab could live in a window of its own — asked of a *prospective* detached host
    /// rather than guessed at, so the menu and the move cannot disagree about what travels.
    private func canDetachTabIntoWindow(_ tabID: UUID, from sourceID: TabHostID) -> Bool {
        guard let source = tabTransfer.resolve(sourceID),
              let sessionID = tabSession(of: tabID, in: sourceID),
              let tab = source.tabs(for: sessionID).first(where: { $0.id == tabID })
        else { return false }
        return DetachedBrowserHostViewController.canHold(tab)
    }

    /// Which session a tab belongs to. Its own answer first: a detached window is pinned to a
    /// session that may not be the one on screen, so reading the *selection* would move its tab
    /// into a different session's panel and take the page with it.
    private func tabSession(of tabID: UUID, in hostID: TabHostID) -> SessionID? {
        guard let host = tabTransfer.resolve(hostID) else { return currentSessionID }
        if let owned = host.tabs(for: nil).first(where: { $0.id == tabID })?.owningSessionID {
            return owned
        }
        return currentSessionID
    }

    /// Moves the tab and brings its destination into view — a move you cannot see landing is
    /// a tab that just vanished.
    func moveTab(
        _ tabID: UUID,
        from sourceID: TabHostID,
        to destinationID: TabHostID,
        insertionIndex: Int? = nil
    ) {
        // The tab's own session, not the selection. Both panes follow what is on screen, so the
        // two agreed until a host could be *pinned*: dragging a tab back from a window bound to
        // session A while the main window showed B put it in B's panel and took the page with
        // it — a move that lands somewhere the user was not looking is the same as losing it.
        guard let sessionID = tabSession(of: tabID, in: sourceID),
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
            // Landing in a session that is not on screen would be invisible, so the move brings
            // that session forward — the pane's own rule, applied to the session as well.
            if sessionID != currentSessionID {
                sidebarViewController.select(sessionID: sessionID)
            }
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        case .detachedWindow(let id):
            detachedBrowserWindows[id]?.showWindow(nil)
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

    /// The same live answer `closeActiveTab` uses, exposed as a semantic capability so command
    /// frontends can disable honestly instead of calling the implementation just to hear a beep.
    var canCloseActiveTab: Bool {
        if displayPaneController.isShowingCurrentTheme, !displayItem.isCollapsed,
           let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: displayPaneController.view) {
            return true
        }
        if let host = focusedTabHost() {
            return host.activeTabID(for: currentSessionID) != nil
        }
        return containerViewController.isShowingSettings
            || containerViewController.currentComposerProjectID != nil
            || containerViewController.currentSessionID != nil
            || containerViewController.currentTerminalID != nil
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
            if materializedAccountUsageItemView?.account != nil {
                materializedAccountUsageItemView?.configure(account: nil)
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

        guard let account else {
            if materializedAccountUsageItemView?.account != nil {
                materializedAccountUsageItemView?.configure(account: nil)
            }
            return
        }

        let usageItem = accountUsageItemView

        // Re-configured when either half changes: switching model inside a session moves which
        // limit binds it, without the account moving at all.
        guard usageItem.account?.id != accountID || usageItem.model != model else { return }

        usageItem.configure(account: account, model: model)
    }

    /// Opens Settings, or does nothing if already open. What a *door* to a page needs — see
    /// `showSettingsPage`, which then names the page to land on.
    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        guard !containerViewController.isShowingSettings else { return }
        toggleSettings()
    }

    /// What ⌘, does: opens Settings, and closes it again if the mode is already active.
    ///
    /// The platform's Preferences chord only ever *opens*, because on macOS preferences are a
    /// separate window and ⌘W closes them. Here Settings is a **mode in this window**, sharing
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

    /// `revealing` names a row on the page — a search result's anchor — for the pane to
    /// scroll to and mark once the page is up.
    func showSettingsPage(id pageID: String, revealing anchorTitle: String? = nil) {
        guard SettingsPages.page(id: pageID) != nil else { return }
        showSettings()
        sidebarViewController.selectSettingsPage(id: pageID)
        containerViewController.showSettingsPage(id: pageID, revealing: anchorTitle)
        updateSessionTitleItem()
        recordVisit(.settings(pageID))
    }

    // MARK: - Selection History

    /// ⌃⌘← — retraces the window's page selection, Xcode's Go Back.
    func goBack() {
        guard let page = navigation.goBack() else {
            NSSound.beep()
            return
        }
        present(page)
        updateNavigationButtons()
    }

    /// ⌃⌘↑/↓ and ⌥⌘↑/↓ — the same retracing gesture one level in, over a conversation's own
    /// exchanges and the tool calls inside them.
    func moveConversation(byTurn forward: Bool) {
        guard containerViewController.moveConversation(byTurn: forward) else {
            NSSound.beep()
            return
        }
    }

    func moveConversation(byStep forward: Bool) {
        guard containerViewController.moveConversation(byStep: forward) else {
            NSSound.beep()
            return
        }
    }

    var isShowingConversation: Bool { containerViewController.isShowingConversation }

    /// ⌃⌘→ — the step back forward.
    func goForward() {
        guard let page = navigation.goForward() else {
            NSSound.beep()
            return
        }
        present(page)
        updateNavigationButtons()
    }

    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    /// A page actually presented, from any entrance. The one being replayed by Back or Forward
    /// is recognised and not pushed again; everything else is a fresh visit. Cleared on every
    /// arrival either way, so an abandoned replay cannot swallow a later genuine visit.
    private func recordVisit(_ page: NavigationHistory.Page) {
        navigation.recordVisit(page)
        updateNavigationButtons()
        refreshProjectScriptContext()
    }

    private func refreshProjectScriptContext() {
        ProjectScriptService.shared.activate(
            executionDirectory: currentExecutionDirectoryURL
        )
    }

    /// Creates and selects a durable project terminal before sending a repository command.
    /// The receipt means the validated command reached that visible PTY; completion remains a
    /// fact printed by the terminal's host-owned exit-status suffix, not guessed here.
    func runProjectScript(
        _ invocation: ProjectScriptInvocation
    ) -> ProjectScriptExecutionReceipt? {
        guard !RecoveryMode.isActive,
              let projectID = currentProjectID,
              ProjectScriptService.shared.activeCatalog?.repositoryRoot
                == invocation.repositoryRoot else { return nil }

        guard let terminal = ProjectStore.shared.addTerminal(
            to: projectID,
            currentDirectory: invocation.workingDirectory.path
        ) else { return nil }
        ProjectStore.shared.renameTerminal(
            id: terminal.id,
            to: L10n.format("Script: %@", invocation.script.name)
        )

        sidebarViewController.select(terminalID: terminal.id)
        guard let controller = ProjectTerminalRuntime.shared.controller(for: terminal.id),
              let receipt = controller.runProjectScript(invocation) else {
            ProjectStore.shared.removeTerminal(id: terminal.id)
            return nil
        }
        return receipt
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
            sidebarViewController.select(sessionID: sessionID)

        case .terminal(let terminalID):
            exitSettingsForNavigation()
            sidebarViewController.select(terminalID: terminalID)

        case .composer(let projectID):
            exitSettingsForNavigation()
            sidebarViewController.select(projectID: projectID)

        case .settings(let pageID):
            showSettingsPage(id: pageID)

        case .settingsAISearch:
            showSettingsAISearchSurface()
        }
    }

    /// Shows the AI settings search holding whatever it last answered, without starting a
    /// run — the Back path into suggestions the user navigated away from.
    private func showSettingsAISearchSurface() {
        showSettings()
        containerViewController.reshowSettingsAISearch()
        updateSessionTitleItem()
        recordVisit(.settingsAISearch)
    }

    /// Leaving settings *sideways* — Back to a session rather than out through the toggle —
    /// must still restore the sidebar's session list, and must drop the toggle's own memory of
    /// what to restore, which history has now superseded.
    private func exitSettingsForNavigation() {
        guard containerViewController.isShowingSettings else { return }
        sidebarViewController.setSettingsMode(false)
        workspaceSidebarViewController.setSettingsOverride(false)
        navigation.abandonSettingsDetour()
    }

    private func updateNavigationButtons() {
        navBackToolbarButton?.isEnabled = navigation.canGoBack
        navForwardToolbarButton?.isEnabled = navigation.canGoForward
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

    /// Brings the selected session's browser forward, wherever the user keeps it.
    ///
    /// The browser is per-session — the agent running there and the user drive the same page —
    /// so this shows *that* browser rather than the panel's. Reaching straight for the panel
    /// built a second browser beside one the user had moved to the drawer and showed that
    /// instead, which is `browser_navigate`'s bug in the shape of a keystroke; both now resolve
    /// through `browserResolver`. The panel is still where a session with no browser gets one.
    /// With no session selected there is nowhere for it to live, so the gesture just beeps.
    func showBrowser() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        if let location = browserResolver.location(for: sessionID) {
            browserResolver.activate(location, for: sessionID)
            revealBrowserHost(location.hostID, for: sessionID)
            return
        }

        displayPaneController.activateBrowser(for: sessionID)
        revealBrowserHost(.displayPanel, for: sessionID)
    }

    /// Opens the pane that holds a browser — the window's half of the same rule the agent's
    /// tools follow through `revealBrowserPane`.
    private func revealBrowserHost(_ hostID: TabHostID, for sessionID: SessionID) {
        switch hostID {
        case .displayPanel:
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        case .drawer:
            containerViewController.openShellDrawer()
        case .detachedWindow(let id):
            // The user's own gesture, so this one does take the keyboard — unlike the agent's
            // reveal, which only orders the window forward.
            detachedBrowserWindows[id]?.showWindow(nil)
        }
    }

    // MARK: - Remote Workspace

    /// Enumerated through `browserResolver`, not by adding the hosts up here. A hand-rolled
    /// `panel + drawer` compiles unchanged when a host is added, so the mirror would have
    /// quietly stopped showing a browser the user moved — while the invalidation pulses that
    /// tell the phone to refetch are host-neutral and would have kept firing at nothing.
    func remoteBrowserTabs(for sessionID: SessionID) -> [RemoteBrowserTabDTO] {
        let target = browserResolver.browser(for: sessionID)
        return browserResolver.locations(for: sessionID).map { location in
            let browser = location.browser
            let isPrivate = browser.contextKind == .private
            let rawURL = browser.currentURL?.absoluteString ?? browser.restoredURL
            return RemoteBrowserTabDTO(
                id: location.tabID.uuidString,
                title: isPrivate ? "" : boundedRemoteBrowserTitle(location.tab.title),
                displayURL: isPrivate ? nil : rawURL.map(BrowserURLRedactor.redact),
                isActive: browser === target,
                isPrivate: isPrivate,
                canPreview: !isPrivate && browser.currentURL != nil
            )
        }
    }

    func remoteBrowserPreview(for sessionID: SessionID, tabID: UUID) async -> Data? {
        guard let browser = browserResolver.locations(for: sessionID)
            .first(where: { $0.tabID == tabID })?
            .browser,
              browser.contextKind == .shared,
              browser.currentURL != nil,
              let capture = await browser.screenshot(),
              capture.data.count <= RemoteWorkspaceDefaults.maximumPreviewBytes else {
            return nil
        }
        return capture.data
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

    /// Shows or hides the session pane's floating corner card.
    ///
    /// No session check, unlike the shell: this is a standing preference about a surface rather
    /// than an action on the conversation, and it is as legitimate to switch the card off from
    /// a pane that has none as it is to switch it on before opening one.
    func toggleStatusCard() {
        containerViewController.toggleGitStatusOverlay()
        updateToolbarControlStates()
    }

    /// A filled pane button means that pane is actually visible, however it was closed.
    ///
    /// Split out of `updateToolbarControlStates` because the divider drag needs exactly this
    /// much on every tick of the drag, and none of the store reads around it.
    private func updatePaneToggleSelection() {
        sidebarToolbarButton?.isSelected = !sidebarItem.isCollapsed
        displayPaneToolbarButton?.isSelected = !displayItem.isCollapsed

        // **The panel's toggle moves to the open panel's corner — it is one view, not two.**
        // The corner is where the control lives while the panel is open: the same glyph the same
        // distance from the window's trailing edge, so the pane arrives underneath a button that
        // never moved. Left in the header as well it would offer the same switch twice, a pane's
        // width apart. Run on every tick of a divider drag, alongside the fill above, because
        // dragging the panel shut is one of the ways it comes back; both moves are no-ops when
        // the toggle is already home. See `DisplayPanelToggle`.
        //
        // **It was two views that hid each other, and that cost the gesture.** AppKit sends every
        // click after the first of a *chain* — the run of clicks a person makes without moving
        // the pointer far enough to break it — to the view that took the first one. A control
        // that removes itself as part of its own press therefore throws away every press that
        // follows: measured, click 1 arrived and clicks 2…n were delivered to nobody at all, not
        // even to the view standing in the same place. What the user saw was a toggle that
        // answered the pointer, worked once, and then did nothing until they moved the pointer
        // off it — which is all it takes to end a chain. One view that moves keeps taking the
        // clicks it started, wherever the swap has put it.
        guard let toggle = displayPaneToolbarButton else { return }
        if displayItem.isCollapsed {
            // Back on the header's ground, so it reads the terminal's palette again.
            toggle.hostGround = nil
            sessionActionsGroup?.readopt(toggle)
        } else {
            displayPaneController.adoptPanelToggle(toggle)
        }
    }

    /// Keeps toolbar controls semantic: a filled pane button means the pane is actually visible,
    /// and controls that need a session leave the key-view loop when no session is selected.
    func updateToolbarControlStates() {
        let session = containerViewController.currentSessionID.flatMap {
            ProjectStore.shared.session(withID: $0)
        }
        let hasSession = session != nil
        updatePaneToggleSelection()
        updateOpenInControls()
        shellDrawerToolbarButton?.isEnabled = hasSession
        shellDrawerToolbarButton?.isSelected = containerViewController.isShellDrawerOpen
        // The panel holds a *session's* tabs, which is why `view.displayPanel` is declared
        // session-scoped and the View menu already refuses without one. This toggle was the one
        // route that did not ask: pressed on a page with no session — the start page under a
        // project — it revealed a panel whose placeholder is the only thing it can ever show and
        // whose `+` does nothing, and which `syncDisplayPane` then shuts again on the very next
        // selection. An **open** panel can always be shut, whatever page is on screen, because
        // the app-wide theme document deliberately keeps one open with no session selected.
        displayPaneToolbarButton?.isEnabled = hasSession || !displayItem.isCollapsed
        // The standing choice, not whether a card is on screen right now: a pane too narrow to
        // carry one withdraws it without the user having decided anything, and a button that
        // unfilled itself on a divider drag would report a switch nobody threw.
        statusCardToolbarButton?.isSelected = containerViewController.isGitStatusOverlayEnabled
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

    /// The pane-header menu, built through the row's action builder. The two entrances
    /// therefore share not just their labels but their handlers, enablement, and extensions.
    /// Nil when no session is on screen — Settings, say — so the caller can offer its own.
    func visibleSessionActionEntries() -> [ThemedMenuEntry]? {
        guard let sessionID = currentSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return nil }

        sidebarViewController.actionSessionID = sessionID
        return sidebarViewController.sessionActionEntries(for: session)
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

    func showReview(
        mode: GitReviewMode? = nil,
        checkpointID: GitTurnCheckpointID? = nil
    ) {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID else {
            NSSound.beep()
            return
        }

        let review = displayPaneController.activateReview(for: sessionID)
        if let mode { review?.show(mode: mode, checkpointID: checkpointID) }
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

    var canSelectAdjacentTab: Bool {
        (activeTabHost()?.tabs(for: currentSessionID).count ?? 0) > 1
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

    func canSelectTab(atIndex index: Int) -> Bool {
        activeTabHost()?.tabs(for: currentSessionID).indices.contains(index) == true
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

    /// Save as Baseline, from the View menu or whatever chord the user bound to it.
    ///
    /// It captures the browser the user is *looking at*, not the one an agent last drove: this is
    /// the user's judgment about a page, and the page they mean is the one on screen. A session
    /// whose visible tab is not a browser gets a beep rather than a surprising capture of a browser
    /// hidden behind an image tab.
    func saveVisibleBrowserBaseline() {
        window?.makeKeyAndOrderFront(nil)

        guard let sessionID = containerViewController.currentSessionID,
              let browser = visibleBrowser(for: sessionID) else {
            NSSound.beep()
            return
        }
        BrowserBaselineUI.captureBaseline(from: browser, sessionID: sessionID)
    }

    var canSaveVisibleBrowserBaseline: Bool {
        guard let sessionID = containerViewController.currentSessionID else { return false }
        return visibleBrowser(for: sessionID) != nil
    }

    /// The panel's own visible browser first, then whichever browser the session has.
    ///
    /// The visible one answers first because a browser on screen is the one the user means by
    /// "this page"; the session's own is the fallback for a command sent while another tab is up.
    private func visibleBrowser(for sessionID: SessionID) -> BrowserViewController? {
        displayPaneController.currentBrowser ?? displayPaneController.browser(for: sessionID)
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

    /// Resolves a notification's thin route only after its chat has become current. Durable
    /// content is looked up by attachment identity; live content is looked up in the host that
    /// owns it now, so moving a browser tab does not stale a notification.
    private func openNotificationDestination(
        _ destination: RemoteNotificationDestinationDTO,
        for sessionID: SessionID
    ) {
        window?.makeKeyAndOrderFront(nil)

        switch destination.kind {
        case .session:
            return

        case .attachment:
            guard let attachmentID = destination.attachmentID,
                  let attachment = SessionAttachmentStore.shared.attachment(
                    for: sessionID,
                    id: attachmentID
                  ),
                  let controller = displayPaneController.activateAttachments(for: sessionID)
            else { return }
            controller.showAttachment(at: attachment.url)
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)

        case .browserTab:
            guard let rawTabID = destination.browserTabID,
                  let tabID = UUID(uuidString: rawTabID),
                  let location = browserResolver.locations(for: sessionID).first(where: {
                    $0.tabID == tabID
                  }) else { return }
            browserResolver.activate(location, for: sessionID)
            revealBrowserHost(location.hostID, for: sessionID)

        case .extensionPanel:
            guard let extensionIdentifier = destination.extensionIdentifier,
                  let panelID = destination.extensionPanelID,
                  let item = ExtensionManager.shared.registeredPanel(
                    extensionIdentifier: extensionIdentifier,
                    panelID: panelID
                  ) else { return }
            displayPaneController.activateExtensionPanel(
                extensionIdentifier: extensionIdentifier,
                panelID: panelID,
                title: item.panel.title,
                for: sessionID
            )
            displayPaneController.showSessionTabs(sessionID)
            setDisplayPaneVisible(true)
        }
    }

    /// Opens Settings in the content pane, or closes it and returns to what was on screen. The
    /// sidebar itself swaps to the section list rather than a second sidebar appearing.
    func toggleSettings() {
        if containerViewController.isShowingSettings {
            sidebarViewController.setSettingsMode(false)
            workspaceSidebarViewController.setSettingsOverride(false)

            switch navigation.takeSettingsReturnTarget() {
            case .session(let sessionID):
                containerViewController.show(sessionID: sessionID)
                syncDisplayPane(to: sessionID)
                recordVisit(.session(sessionID))

            case .terminal(let terminalID):
                containerViewController.show(terminalID: terminalID)
                syncDisplayPane(to: nil)
                recordVisit(.terminal(terminalID))

            case .composer(let projectID):
                // Put back as it was left, choices, attachments and half-written prompt
                // included: showing the composer the project it already holds is a return to
                // it. Settings is a detour, not a change of project, so nothing about it
                // should reset the decision the user was in the middle of making.
                containerViewController.showComposer(projectID: projectID)
                syncDisplayPane(to: nil)
                recordVisit(.composer(projectID))

            case .settings, .settingsAISearch, .none:
                containerViewController.show(sessionID: nil)
            }
        } else {
            navigation.beginSettingsDetour(from: currentPage())
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
        // The three ways to start work all land back on the surface in recovery. The menu items
        // are already refused by `RecoveryModeCommandPolicy`, so what reaches here is a route
        // that did not go through the menu — the sidebar's `+`, a drop, a key equivalent
        // validated a moment early — and doing nothing at all would read as a broken button.
        guard !showRecoverySurfaceIfActive() else { return }
        sessionCoordinator.newSession()
    }

#if DEBUG
    /// Opens the chat a development build's report is sent to. Lives here rather than in
    /// `MainWindowInspector`, which raises the sheets, because `sessionCoordinator` is private
    /// to this file — and the fallback project is this window's own answer to "what am I
    /// looking at", which only this file can give.
    func startDeveloperReportChat(
        _ request: DeveloperReportChatRequest
    ) -> DeveloperReportChatOutcome {
        sessionCoordinator.startDeveloperReportChat(
            request,
            fallbackProjectID: currentProjectID
        )
    }
#endif

    func addProject() {
        guard !showRecoverySurfaceIfActive() else { return }
        sessionCoordinator.addProject()
    }

    func newProject() {
        guard !showRecoverySurfaceIfActive() else { return }
        sessionCoordinator.newProject()
    }

    /// Puts the recovery surface back in the pane, and says whether it did.
    @discardableResult
    func showRecoverySurfaceIfActive() -> Bool {
        guard RecoveryMode.isActive else { return false }
        containerViewController.showRecoverySurface()
        return true
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

    var canAdjustTerminalText: Bool {
        containerViewController.activeTerminalSession != nil
    }

    // MARK: - Find

    func showFind() {
        guard !displayItem.isCollapsed else { return }
        if let browser = displayPaneController.currentBrowser {
            browser.showFind()
        } else if let review = displayPaneController.currentReview, review.canShowFind {
            review.showFind()
        }
    }

    var canShowFind: Bool {
        guard !displayItem.isCollapsed else { return false }
        if displayPaneController.currentBrowser != nil { return true }
        return displayPaneController.currentReview?.canShowFind == true
    }

    func showReviewFileJump() {
        guard !displayItem.isCollapsed else { return }
        displayPaneController.currentReview?.showJumpToFile()
    }

    var canJumpToReviewFile: Bool {
        !displayItem.isCollapsed
            && displayPaneController.currentReview?.canJumpToFile == true
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
        // The band shows the same name the window carries; pushed rather than observed —
        // see `WindowTitleBandView.setTitle`.
        chromeHostViewController.setTitle(MainWindowDefaults.defaultTitle)

        // Still tracked: it drives the proxy icon and path menu if the title bar is shown.
        window?.representedURL = currentFolderURL
    }
}

#if DEBUG
/// Debug-only launch input used by the out-of-process UI runner.
///
/// Requiring the isolated scenario-home marker keeps ordinary debug launches and a developer's
/// saved window frame entirely untouched. Both dimensions must be present and valid; a partial
/// contract is rejected instead of producing a misleading compact-layout test.
private enum MainWindowUIScenarioSize {
    private static let markerName = ".threading-ui-scenario-home"
    private static let widthKey = "THREADING_UI_WINDOW_WIDTH"
    private static let heightKey = "THREADING_UI_WINDOW_HEIGHT"

    static func requested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> NSSize? {
        let widthValue = environment[widthKey]
        let heightValue = environment[heightKey]
        guard widthValue != nil || heightValue != nil else { return nil }

        guard let scenarioHome = environment["THREADING_UI_SCENARIO_HOME"],
              environment["HOME"] == scenarioHome,
              environment["CFFIXED_USER_HOME"] == scenarioHome,
              fileManager.fileExists(
                atPath: URL(fileURLWithPath: scenarioHome, isDirectory: true)
                    .appendingPathComponent(markerName)
                    .path
              ),
              let widthValue,
              let heightValue,
              let width = Double(widthValue),
              let height = Double(heightValue),
              width.isFinite,
              height.isFinite,
              width >= Double(WindowDefaults.minWidth),
              height >= Double(WindowDefaults.minHeight),
              width <= 10_000,
              height <= 10_000 else {
            assertionFailure("Invalid Threading UI scenario window contract")
            return nil
        }
        return NSSize(width: width, height: height)
    }
}
#endif

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
        updateSessionTitleItem()
        updateWindowTitle()
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

    /// Report-back is a lifecycle decision like the rename request: one line into the side
    /// chat, asking its agent to send the conclusion to the session it was forked from.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        sendResultToParentOf sessionID: SessionID
    ) {
        sessionCoordinator.askAgentToReportBack(sessionID)
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

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        didRemoveSession sessionID: SessionID
    ) {
        let span = PerformanceRecorder.shared.begin(
            "sidebar.session-remove.cleanup",
            category: "sidebar"
        )
        defer { span.end() }

        closeDetachedWindows(forSession: sessionID)

        if currentSessionID == sessionID {
            containerViewController.show(sessionID: nil)
        }

        // Release live surfaces first. The one persisted panel document belongs to both panel
        // hosts and is deleted only after neither host can write it back during teardown.
        displayPaneController.removeSession(sessionID)
        containerViewController.removeDrawerSession(sessionID)
        SessionAttachmentStore.shared.removeSession(sessionID)
        DisplayPaneStore.shared.removeSession(sessionID)
        MCPSessionRegistry.remove(sessionID: sessionID)
        GitTurnBaselineStore.shared.remove(sessionID: sessionID)
        BrowserAutoCaptureRing.shared.clear(for: sessionID)

        // `discardDeletedSession` already removed the live controller and subagent state at the
        // durable mutation boundary. Prune only pages naming this chat from window history.
        navigation.prune { page in
            guard case .session(let candidate) = page else { return true }
            return candidate != sessionID
        }
        updateNavigationButtons()
        syncDisplayPane(to: containerViewController.currentSessionID)
    }

    func projectSidebarDidRemoveSessions(_ sidebar: ProjectSidebarViewController) {
        // A window pinned to a session that no longer exists goes with it — before the store
        // sweep, or its own persistence writes the deleted session's document back.
        closeDetachedWindows(
            forSessionsOutside: Set(ProjectStore.shared.projects.flatMap(\.sessions).map(\.id))
        )

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
        // The before-shot ring is per session and in memory, so a deleted chat's pixels go with it.
        BrowserAutoCaptureRing.shared.retainOnly(sessionIDs: liveSessionIDs)
        AgentRuntime.shared.retainOnly(sessionIDs: liveSessionIDs)
        // Visual baselines are the project's, not the session's, so this sweep is by project: a
        // deleted chat leaves the library alone, and a removed project takes its own with it. The
        // removal confirmation says so.
        BrowserBaselineStore.shared.retainOnly(
            projectIDs: Set(ProjectStore.shared.projects.map(\.id))
        )

        // Nor stay reachable through Back: a retraced page must exist to be presented.
        navigation.prune { page in
            switch page {
            case .session(let sessionID):
                return liveSessionIDs.contains(sessionID)
            case .terminal(let terminalID):
                return liveTerminalIDs.contains(terminalID)
            case .composer(let projectID):
                return ProjectStore.shared.project(withID: projectID) != nil
            case .settings, .settingsAISearch:
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
        navigation.prune { page in
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

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        didSelectSettingsPage pageID: String,
        revealing anchorTitle: String
    ) {
        containerViewController.showSettingsPage(id: pageID, revealing: anchorTitle)
        updateSessionTitleItem()
        recordVisit(.settings(pageID))
    }

    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        askAIAboutSettings query: String
    ) {
        let controller = containerViewController.showSettingsAISearch(query: query)
        controller.onOpen = { [weak self] pageID, anchorTitle in
            self?.showSettingsPage(id: pageID, revealing: anchorTitle)
        }
        updateSessionTitleItem()
        // A page in history, so opening a suggestion leaves the answer one Back away
        // rather than gone.
        recordVisit(.settingsAISearch)
    }

}

// MARK: - TerminalContainerViewControllerDelegate

extension MainWindowController: TerminalContainerViewControllerDelegate {

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestSettingsPage pageID: String
    ) {
        showSettingsPage(id: pageID)
    }

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

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestAttachments attachmentID: String?
    ) {
        guard let sessionID = container.currentSessionID else {
            NSSound.beep()
            return
        }
        guard let controller = displayPaneController.activateAttachments(for: sessionID) else {
            NSSound.beep()
            return
        }
        if let attachmentID,
           let attachment = SessionAttachmentStore.shared.attachment(
            for: sessionID,
            id: attachmentID
           ) {
            controller.showAttachment(at: attachment.url)
        }
        displayPaneController.showSessionTabs(sessionID)
        setDisplayPaneVisible(true)
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestTurnDiff checkpointID: GitTurnCheckpointID
    ) {
        showReview(mode: .lastTurn, checkpointID: checkpointID)
    }

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestOpenSession sessionID: SessionID
    ) {
        guard ProjectStore.shared.session(withID: sessionID) != nil else {
            NSSound.beep()
            return
        }
        sidebarViewController.select(sessionID: sessionID)
    }

    func terminalContainerDidRequestNewSession(_ container: TerminalContainerViewController) {
        newSession()
    }

    func terminalContainerDidChangeShellDrawer(_ container: TerminalContainerViewController) {
        updateToolbarControlStates()
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
            sessionID: sessionID,
            hasAuthoritativeReporting: AgentRuntime.shared.reportsOwnTurns(sessionID: sessionID)
        )

        if AgentRuntime.shared.activity(sessionID: sessionID) == .working {
            displayPaneController.noteSessionStartedWorking(sessionID)
        }

        // An agent that just stopped working may have switched branches on the way.
        if AgentRuntime.shared.activity(sessionID: sessionID) != .working {
            // The hook-less half of observed-work capture. A reporting session already caught up
            // on its `turnFinished` hook; this edge is inferred from output, so it is later and
            // vaguer, but it is the only "something happened" a session without lifecycle hooks
            // has. The pass costs a file-size comparison when nothing was written.
            AgentWorkHydration.hydrate(sessionID: sessionID)

            sidebarViewController.refreshProjectRow(forSessionID: sessionID)

            // The session's own branch record follows the same moment; a change regroups
            // the sidebar through the store's change notification.
            ProjectStore.shared.refreshBranch(forSessionID: sessionID)

            // So does the agent's name for the conversation, which lives in the transcript.
            // This is the only way a *native* session's title arrives — no PTY, no OSC.
            SessionNaming.refreshAgentTitle(forSessionID: sessionID)

            // And the project's code count: a session that just stopped working is a project
            // whose code most likely just changed.
            ProjectStatsService.shared.refreshProject(forSessionID: sessionID)

            // The tree probably changed too; an on-screen review tab refreshes itself.
            displayPaneController.noteSessionStoppedWorking(sessionID)

            // It also just spent tokens, so the finish is the moment the pill is most
            // likely stale. The service's spacing keeps a chatty session polite.
            if sessionID == currentSessionID,
               let account = materializedAccountUsageItemView?.account {
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

    /// Closing the only window *is* quitting — `applicationShouldTerminateAfterLastWindowClosed`
    /// answers true — so the close asks the application to quit and closes nothing itself.
    ///
    /// The order was the bug. Closing first ran `windowWillClose`, which terminated every agent
    /// and emptied `AgentRuntime`; the quit that followed a moment later therefore saw nothing
    /// running, so it neither warned that agents were mid-turn nor recorded anything for
    /// `relaunchSessionsFromLastQuit` to bring back — the setting was on, the record was empty,
    /// and the next launch came up with the same empty sidebar as before the feature existed.
    /// Routed this way there is one quit, and it reads the live runtime before anything has
    /// touched it.
    ///
    /// Returning false is what keeps the declined quit harmless: both close affordances — the
    /// chrome button and the window menu's Close — ask this first and close only on true, so a
    /// cancelled confirmation leaves the window exactly as it was.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestsApplicationQuit()
        return false
    }

    /// The teardown for a window that closes without going through the quit — code calling
    /// `close()` directly, which never consults `windowShouldClose`. On the ordinary quit this
    /// runs after `applicationShouldTerminate` has already recorded and terminated, and both
    /// calls are no-ops on an empty runtime.
    func windowWillClose(_ notification: Notification) {
        AgentRuntime.shared.terminateAll()
        ProjectTerminalRuntime.shared.terminateAll()
    }

    /// A theme change that arrived while the window was fullscreen parked its frame exchange
    /// (`WindowChromeCoordinator.applyCurrentTheme`); this is where the parked change runs.
    func windowDidExitFullScreen(_ notification: Notification) {
        chromeCoordinator?.windowDidExitFullScreen()
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

    /// Forgets the width, so the column opens at its default again. The key stays private and
    /// the clearing lives with it — see `WindowLayoutReset`, which is what calls this.
    static func reset() {
        PreferenceStore.shared.removeObject(forKey: key)
    }
}

// MARK: - Status Card Visibility

/// Whether the session pane carries its floating corner card.
///
/// Through `PreferenceStore` rather than `.standard`, for the same reason `DisplayPaneWidth`
/// is: it records a **choice the user made with a control**, and the test bundle is hosted in
/// the app, so a test that switches the card off would otherwise decide what the developer's
/// own next launch opens into.
///
/// Kept out of `AppSettings` too, which holds behaviour set deliberately on a settings page.
/// This is a surface toggled from the header, and it belongs with the panes toggled beside it.
enum StatusCardVisibility {
    private static let key = "ThreadingShowsStatusCard"

    /// On unless the user turned it off.
    ///
    /// Read as an *optional* rather than through `bool(forKey:)`, because absent has to mean on
    /// and `bool(forKey:)` cannot say the difference between "switched off" and "never asked".
    /// Registering a default would answer it too, but only for a process that has run the
    /// registration — and this is read from the pane's first layout pass.
    static var isEnabled: Bool {
        get { PreferenceStore.shared.object(forKey: key) as? Bool ?? true }
        set { PreferenceStore.shared.set(newValue, forKey: key) }
    }

    /// Back to on, by forgetting rather than by writing: absent is what "never asked" means here,
    /// and a reset that wrote `true` would be a choice nobody made.
    static func reset() {
        PreferenceStore.shared.removeObject(forKey: key)
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

    /// Forgets the width, so a reveal opens at its share of the window again.
    static func reset() {
        PreferenceStore.shared.removeObject(forKey: key)
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
