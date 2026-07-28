import AppKit

/// Hosts the terminal for whichever session is selected in the sidebar.
///
/// Live session controllers are retained by `AgentRuntime`, so switching selection swaps
/// views without restarting agents or losing scrollback.
final class TerminalContainerViewController: NSViewController {

    // MARK: - Properties

    private let placeholderView = SessionPlaceholderView()
    private let appEvents = AppEventObservations()

    /// Shown when a project rather than a session is selected.
    let composerViewController = SessionComposerViewController()

    private var currentChild: AgentSessionViewController?
    private var currentConversation: ConversationViewController?

    /// The one authoritative answer to which session is on screen.
    ///
    /// Runtime attention and window chrome derive from this transition rather than being
    /// updated independently by every surface-changing call site.
    private(set) var currentSessionID: SessionID? {
        didSet {
            guard currentSessionID != oldValue else { return }
            AgentRuntime.shared.setVisibleSession(currentSessionID)
            delegate?.terminalContainer(self, visibleSessionDidChange: currentSessionID)
            updateGitChangeMonitor()
        }
    }

    /// The floating branch-and-changes card, and the watcher feeding it. The monitor follows
    /// `currentSessionID`: it exists only while a session's checkout is on screen.
    private let gitStatusOverlay = GitStatusOverlayView()
    private var gitChangeMonitor: GitChangeMonitor?

    /// Settings is shown as a single page centred in the pane; the page list lives in the
    /// window's sidebar, which the settings sections replace, so there is no second sidebar.
    /// One shell per session, kept alive while the app runs — the process *is* the feature, and
    /// a shell that forgot its directory on every session switch would be worse than useless.
    private var drawers: [SessionID: ShellDrawerViewController] = [:]
    private var openDrawerSessions: Set<SessionID> = []

    private var drawerHost: NSView!
    private var drawerDivider: ShellDrawerDivider!
    private var drawerHeight: NSLayoutConstraint!

    /// In-memory, like the sidebar's branch-group collapse state: a drawer height is a working
    /// preference for a window, not a fact about the session.
    private var drawerHeightValue: CGFloat = ShellDrawerDefaults.defaultHeight

    private var settingsPage: NSViewController?
    private var settingsPageCache: [String: NSViewController] = [:]

    /// Whether settings is the surface currently on screen, so the window can title the pane.
    var isShowingSettings: Bool { settingsPage != nil }

    /// The non-session sidebar destination currently shown. These make the toolbar tab derive
    /// from the same selection as the content pane instead of falling back to a generic title.
    private(set) var currentComposerProjectID: ProjectID?
    private(set) var currentSettingsPageID: String?

    weak var delegate: TerminalContainerViewControllerDelegate?

    /// The pane's header strip. See `setupHeader`.
    private let headerHost = NSView()
    private var headerLeadingConstraint: NSLayoutConstraint?

    /// Where the pane's content begins — below the header rather than below the toolbar.
    private let contentGuide = NSLayoutGuide()

    /// What every surface in this pane pins its top to.
    var contentTopAnchor: NSLayoutYAxisAnchor { contentGuide.topAnchor }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupDrawer()
        setupPlaceholder()
        setupComposer()
        setupGitStatusOverlay()
        showEmptyState()

        // A theme change repaints the terminal but not the pane behind it, so the seam would
        // return until the next surface swap; re-apply the colour when the theme changes,
        // whether that was the app default or an assignment on this session or its project.
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.themeDidChange() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in
            self?.themeDidChange()
        }
        // The **app** theme change is the one that was missing here, which is why switching to a
        // light style while Settings was open left the pane dark: the sweep repaints recorded
        // surfaces, but the pane fill is set directly by `applyPaneBackground` and follows
        // nothing on its own.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.themeDidChange() }
        appEvents.observe(ExtensionSettingsRegistryDidChange.self) { [weak self] _ in
            self?.settingsCatalogueDidChange()
        }
    }

    /// Repaints the pane behind whatever surface is on screen after a theme change.
    ///
    /// Resolves the colour here rather than reading it off the terminal view, because the
    /// session controller observes the same notification and the order between two observers
    /// is not defined — reading its view could paint the pane the colour it is leaving.
    ///
    /// The early-return this used to have was the bug: it covered only the terminal and the
    /// conversation, so a theme switch while the **composer, settings, or placeholder** was
    /// showing left the pane on the previous theme's colour. Those surfaces are the app's own
    /// chrome, so they take the app theme's ground.
    private func themeDidChange() {
        if currentChild != nil || currentConversation != nil {
            applyPaneBackground(.terminal(ThemeAssignments.theme(for: currentSessionID).background))
        } else {
            applyPaneBackground(.chrome)
        }
    }

    // MARK: - Header

    /// The pane's own header strip: the page tab, the `+`, and the session's actions.
    ///
    /// **These used to be toolbar items**, and moving them here is what stops them drifting away
    /// from the pane they act on. `NSToolbar` positions its items relative to the *window*, so
    /// the tab naming this session sat at a fixed x while the sidebar's divider moved under it —
    /// `NSTrackingSeparatorToolbarItem` had papered over that, and it stopped working the moment
    /// the sidebar became a plain split item. A header owned by the pane cannot drift, because it
    /// *is* the pane: no divider is crossed and there is nothing to track.
    ///
    /// The strip sits under the toolbar rather than in the titlebar. A view in the titlebar strip
    /// is behind AppKit's own titlebar container, which is what this project's earlier hand-rolled
    /// header ran into, and the window keeps a real toolbar for the one control that belongs to
    /// the *window* rather than to either pane — the sidebar toggle.
    private func setupHeader() {
        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        view.addLayoutGuide(contentGuide)

        let headerBottom = headerHost.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor
        )
        // AppKit briefly reports a zero-height safe area while the full-size-content window is
        // being attached. Let the 40pt floor win for that one layout pass; once the toolbar has
        // established its inset, both constraints agree. Keeping this equality just below
        // required avoids a launch-time unsatisfiable-constraints warning without changing the
        // settled geometry.
        headerBottom.priority = .init(999)

        NSLayoutConstraint.activate([
            // **The strip the toolbar reserves is the header's**, top to safe-area bottom, and
            // that is the whole of "one row across the window". Pinned below the safe area
            // instead, the header was a second row under a toolbar holding one button, so the
            // content pane opened with an empty band across the top of it.
            headerHost.topAnchor.constraint(equalTo: view.topAnchor),
            headerBottom,
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // A floor, not the height: the strip is the toolbar's to size, and this only keeps
            // the row sane where there is no window to inset it — a fixture, or a test.
            headerHost.heightAnchor.constraint(
                greaterThanOrEqualToConstant: PaneHeaderDefaults.height
            ),

            // Everything else in the pane hangs off this rather than off the safe area directly,
            // so the header is the only place that knows where the pane's content begins.
            contentGuide.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Puts the window controller's header content into the strip. The controller owns those
    /// views because it owns what they do; the pane owns where they sit.
    func installHeader(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(content)

        let leading = content.leadingAnchor.constraint(
            equalTo: headerHost.leadingAnchor,
            constant: PaneHeaderDefaults.inset
        )
        headerLeadingConstraint = leading

        NSLayoutConstraint.activate([
            leading,
            content.trailingAnchor.constraint(
                equalTo: headerHost.trailingAnchor,
                constant: -PaneHeaderDefaults.inset
            ),
            content.centerYAnchor.constraint(equalTo: headerHost.centerYAnchor)
        ])
    }

    /// How far in the header's first control starts.
    ///
    /// Normally the pane's own inset — but the strip the header sits in is also where the
    /// **window's** controls live, and with the sidebar collapsed the pane reaches the window's
    /// leading edge and the tab lands on top of the traffic lights. This is the "shift itself
    /// sideways to dodge the traffic lights" that a hand-rolled header has to do; the window
    /// controller computes it by measuring, since the lights are AppKit's to size.
    var headerLeadingInset: CGFloat {
        get { headerLeadingConstraint?.constant ?? PaneHeaderDefaults.inset }
        set { headerLeadingConstraint?.constant = newValue }
    }

    /// The composer sits alongside the placeholder, hidden until a project is selected.
    private func setupComposer() {
        addChild(composerViewController)

        let composer = composerViewController.view
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.isHidden = true
        view.addSubview(composer)

        NSLayoutConstraint.activate([
            composer.topAnchor.constraint(equalTo: contentTopAnchor),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// Shows the composer for a project, replacing whatever session was on screen.
    func showComposer(projectID: ProjectID) {
        detachCurrentChild()
        currentComposerProjectID = projectID
        currentSettingsPageID = nil
        currentSessionID = nil

        // A shell belongs to a conversation; neither the composer nor a settings page is one, and
        // a drawer left standing under them draws a terminal through the form on top of it.
        applyDrawer(for: nil)

        placeholderView.isHidden = true
        composerViewController.view.isHidden = false
        applyPaneBackground(.chrome)
        composerViewController.show(projectID: projectID)
    }

    /// Shows a settings page centred in the pane, replacing whatever session or composer was on
    /// screen. The section list lives in the sidebar; this only draws the chosen page.
    ///
    /// The page is pinned straight to the pane — centred, capped at a readable width, floored by
    /// margins — rather than through an intermediate container, which did not size its child.
    func showSettingsPage(id: String) {
        guard let definition = SettingsPages.page(id: id) else { return }

        currentComposerProjectID = nil
        currentSettingsPageID = id

        if settingsPage == nil {
            detachCurrentChild()
            currentSessionID = nil
            placeholderView.isHidden = true
            composerViewController.view.isHidden = true
            applyPaneBackground(.chrome)
            // The session's shell goes with the session — see `showComposer`.
            applyDrawer(for: nil)
        } else if let current = settingsPage {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        let cached = settingsPageCache[id]
        let page = cached ?? {
            let made = definition.make()
            settingsPageCache[id] = made
            return made
        }()

        addChild(page)
        let content = page.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        // A cached page was detached while the theme moved, and the sweep walks windows — so it
        // never reached this tree. Re-resolve it here rather than dropping the cache: rebuilding
        // would cost the page its scroll position and its controls' state to fix colours and
        // fonts that one walk can simply take again.
        if cached != nil { AppThemeRefresh.repaint(content) }

        // The cap is the readable measure plus the glow gutters the page pads itself with,
        // so the cards inside keep the readable width.
        let preferred = content.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.pageWidth)
        preferred.priority = .defaultHigh

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentTopAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            preferred,
            content.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsUIDefaults.pageWidth),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Design.Spacing.large),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Design.Spacing.large)
        ])

        settingsPage = page
    }

    private func settingsCatalogueDidChange() {
        settingsPageCache.removeAll()
        guard settingsPage != nil else { return }
        let requested = currentSettingsPageID ?? SettingsPages.generalID
        showSettingsPage(
            id: SettingsPages.page(id: requested) == nil ? SettingsPages.generalID : requested
        )
    }

    // MARK: - Setup

    // MARK: - Shell Drawer

    /// The drawer lives at the pane's bottom edge and is *always* installed, zero-high when
    /// closed. Every session surface pins its bottom to the drawer's top rather than to the
    /// pane, so opening one is a change of constant rather than a rebuild of the layout.
    private func setupDrawer() {
        drawerHost = NSView()
        drawerHost.wantsLayer = true
        drawerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawerHost)

        drawerDivider = ShellDrawerDivider()
        drawerDivider.translatesAutoresizingMaskIntoConstraints = false
        drawerDivider.isHidden = true
        drawerDivider.onDrag = { [weak self] delta in self?.resizeDrawer(by: delta) }
        view.addSubview(drawerDivider)

        drawerHeight = drawerHost.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            drawerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawerHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            drawerHeight,

            drawerDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawerDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawerDivider.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            drawerDivider.heightAnchor.constraint(equalToConstant: ShellDrawerDefaults.dividerHeight)
        ])
    }

    /// Opens or closes the shell for the session on screen. Sessions keep their own answer, so
    /// a drawer opened for one conversation does not follow you into the next.
    func toggleShellDrawer() {
        guard let sessionID = currentSessionID else { return }

        if openDrawerSessions.contains(sessionID) {
            openDrawerSessions.remove(sessionID)
        } else {
            openDrawerSessions.insert(sessionID)
        }
        applyDrawer(for: sessionID, focusing: openDrawerSessions.contains(sessionID))
    }

    var isShellDrawerOpen: Bool {
        currentSessionID.map { openDrawerSessions.contains($0) } ?? false
    }

    /// Installs the session's own shell and sizes the drawer to match its state.
    private func applyDrawer(for sessionID: SessionID?, focusing: Bool = false) {
        drawerHost.subviews.forEach { $0.removeFromSuperview() }
        children.compactMap { $0 as? ShellDrawerViewController }.forEach { $0.removeFromParent() }

        guard let sessionID, openDrawerSessions.contains(sessionID),
              let drawer = drawer(for: sessionID) else {
            drawerHeight.constant = 0
            drawerDivider.isHidden = true
            return
        }

        addChild(drawer)
        drawer.view.translatesAutoresizingMaskIntoConstraints = false
        drawerHost.addSubview(drawer.view)
        NSLayoutConstraint.activate([
            drawer.view.topAnchor.constraint(equalTo: drawerHost.topAnchor),
            drawer.view.bottomAnchor.constraint(equalTo: drawerHost.bottomAnchor),
            drawer.view.leadingAnchor.constraint(equalTo: drawerHost.leadingAnchor),
            drawer.view.trailingAnchor.constraint(equalTo: drawerHost.trailingAnchor)
        ])

        drawerHeight.constant = clampedDrawerHeight(drawerHeightValue)
        drawerDivider.isHidden = false
        drawer.startIfNeeded()
        if focusing { drawer.focus() }
    }

    /// The session's shell-drawer root process, when it has one. Asked by the info panel, which
    /// attributes a listening port to the shell or to the agent. Deliberately does *not* build a
    /// drawer: a session whose shell was never opened has no second origin to report.
    func shellRootPid(for sessionID: SessionID) -> pid_t? {
        drawers[sessionID]?.shellRootPid
    }

    /// A session's shell, built the first time it is asked for. A session whose project has
    /// gone is not given one — there would be nowhere to run it.
    private func drawer(for sessionID: SessionID) -> ShellDrawerViewController? {
        if let existing = drawers[sessionID] { return existing }

        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return nil }
        let drawer = ShellDrawerViewController(sessionID: sessionID) {
            // Where the agent *is*, asked at the moment the shell starts: a running terminal
            // session reports its directory over OSC 7. A conversation has no PTY to ask, and
            // was launched in the project's folder, which is what the fallback is.
            AgentRuntime.shared.controller(for: sessionID)?.session.effectiveWorkingDirectory()
                ?? URL(fileURLWithPath: project.folderPath)
        }
        drawers[sessionID] = drawer
        return drawer
    }

    private func resizeDrawer(by delta: CGFloat) {
        drawerHeightValue = clampedDrawerHeight(drawerHeight.constant - delta)
        drawerHeight.constant = drawerHeightValue
    }

    private func clampedDrawerHeight(_ height: CGFloat) -> CGFloat {
        let ceiling = max(
            ShellDrawerDefaults.minimumHeight,
            view.bounds.height * ShellDrawerDefaults.maximumHeightFraction
        )
        return min(max(height, ShellDrawerDefaults.minimumHeight), ceiling)
    }

    /// Drops a closed session's shell, so its process does not outlive the thing it belonged to.
    func closeShellDrawer(for sessionID: SessionID) {
        openDrawerSessions.remove(sessionID)
        drawers.removeValue(forKey: sessionID)?.terminate()
    }

    private func setupPlaceholder() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderView)

        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: contentTopAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Public Methods

    /// Shows the given session, launching or resuming it when it has no live terminal.
    ///
    /// Selecting a dormant session is the "reopen" gesture: it resumes the prior
    /// conversation by identifier rather than starting a fresh one.
    func show(sessionID: SessionID?, initialPrompt: String? = nil) {
        guard sessionID != currentSessionID || settingsPage != nil else { return }

        detachCurrentChild()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        applyDrawer(for: sessionID)

        guard let sessionID,
              let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            currentSessionID = nil
            showEmptyState()
            return
        }

        // Sessions Skalman renders itself take a different surface entirely: no PTY, no
        // terminal view, and a conversation drawn from the CLI's structured events. The kind
        // must still support it — a session flagged native for an agent since disabled falls
        // back to the terminal rather than launching a mode it should no longer use.
        if agentSession.usesNativeUI, agentSession.kind.supportsNativeUI,
           let project = ProjectStore.shared.project(forSessionID: sessionID) {
            showConversation(agentSession, in: project, initialPrompt: initialPrompt)
            return
        }

        let isNewTerminal = !AgentRuntime.shared.hasTerminal(sessionID: sessionID)
        let controller = AgentRuntime.shared.makeController(for: agentSession)
        controller.delegate = self

        // Assigned only after the runtime owns the controller, so the authoritative transition
        // can mark the new controller visible as well as the one it replaces invisible.
        currentSessionID = sessionID
        attach(controller)

        if isNewTerminal {
            controller.launch(initialPrompt: initialPrompt)
        }
    }

    /// Relaunches the currently shown session, used by the dormant placeholder's button.
    func resumeCurrentSession() {
        guard let sessionID = currentSessionID else { return }

        // Force a fresh terminal so the resumed conversation starts from a clean screen.
        AgentRuntime.shared.discard(sessionID: sessionID)
        currentSessionID = nil
        show(sessionID: sessionID)
    }

    /// Reopens a session on whichever surface it now uses, when it is the one on screen.
    ///
    /// The surface switch calls this after tearing the old process down: a session that is
    /// *not* showing needs nothing, since it opens on its new surface the next time it is
    /// selected. Clearing `currentSessionID` first is what lets `show` do its work — it
    /// early-returns for the session already on screen, which is exactly this one.
    func reopenIfShowing(sessionID: SessionID) {
        guard sessionID == currentSessionID else { return }

        currentSessionID = nil
        show(sessionID: sessionID)
    }

    /// Drops the session's terminal if it is showing, returning the pane to a placeholder.
    func closeTerminal(for sessionID: SessionID) {
        AgentRuntime.shared.discard(sessionID: sessionID)
        closeShellDrawer(for: sessionID)

        guard sessionID == currentSessionID else { return }
        detachCurrentChild()
        showDormantState(for: sessionID)
    }

    // MARK: - Private Methods

    private func attach(_ controller: AgentSessionViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: gitStatusOverlay)

        // Pinned to the safe area, which the toolbar insets for us.
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        currentChild = controller
        placeholderView.isHidden = true
        composerViewController.view.isHidden = true

        // The terminal is inset below the toolbar, so the strip above it is the pane's own
        // background. Matching it to the terminal's colour keeps that strip — and the window's
        // rounded top corner — from showing the window's default grey against a themed terminal.
        applyPaneBackground(.terminal(controller.paneBackgroundColor))
        refreshGitStatusOverlayRunState()
        controller.focusTerminal()
    }

    /// Installs the native conversation view for a session, launching it on first show.
    private func showConversation(
        _ agentSession: AgentSession,
        in project: Project,
        initialPrompt: String?
    ) {
        let isNew = AgentRuntime.shared.conversation(for: agentSession.id) == nil
        let conversation = AgentRuntime.shared.makeConversation(for: agentSession, in: project)
        conversation.delegate = self

        // See the terminal path above: the runtime must own the surface before visibility is
        // derived from the container's selection.
        currentSessionID = agentSession.id
        attachConversation(conversation)

        guard isNew else { return }

        conversation.launch()

        // The composer's opening message is sent as the first turn rather than passed on the
        // command line: a streaming session has no positional prompt argument.
        if let initialPrompt, !initialPrompt.isEmpty {
            conversation.sendInitialPrompt(initialPrompt)
        }
    }

    private func attachConversation(_ conversation: ConversationViewController) {
        addChild(conversation)
        conversation.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(conversation.view, positioned: .below, relativeTo: gitStatusOverlay)

        NSLayoutConstraint.activate([
            // The conversation draws its own top inset, so it pinned to the pane's own top and
            // ran under the toolbar deliberately. The header is a real strip and cannot be run
            // under, so this is the one place that changes from `view.topAnchor`.
            conversation.view.topAnchor.constraint(equalTo: contentTopAnchor),
            conversation.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            conversation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conversation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        currentConversation = conversation
        placeholderView.isHidden = true
        composerViewController.view.isHidden = true

        // A conversation outlives its time on screen — `AgentRuntime` keeps it for a dormant
        // session — and the theme sweep walks *windows*, so a detached surface is in none. Its
        // layer colours and its labels' fonts both freeze at assignment, so one returning after
        // a theme switch would come back wearing the theme it left under. Re-resolving on attach
        // is the same sweep, scoped to the tree that missed it.
        AppThemeRefresh.repaint(conversation.view)

        // A native conversation has no terminal, but it should read like one: the backdrop is
        // its resolved terminal theme's background, so it — and the sidebar sampling it — match a
        // Claude or shell session rather than the flatter `windowBackgroundColor`, which shows
        // through the sidebar's material as a subtly different tone. This is also the whole
        // extent to which a theme reaches a natively-rendered session: the conversation itself
        // is drawn in system colours, per the design system.
        applyPaneBackground(.terminal(ThemeAssignments.theme(for: currentSessionID).background))
        refreshGitStatusOverlayRunState()
        conversation.focusPrompt()
    }

    /// The one way a view is placed over the pane's backdrop.
    ///
    /// Typed to `BackdropOverlay` for the same reason the toolbar's factory is: this pane is
    /// painted with the *terminal palette's* background, so anything floating on it that colours
    /// itself from `Design.Text` or `Design.Surface` is reading the wrong ground. The type is
    /// what hands it the right ink, and the compiler is what remembers.
    private func addOverlay(_ overlay: BackdropOverlay) {
        view.addSubview(overlay)
    }

    /// Fills the pane behind its content. Only the strip above a toolbar-inset terminal ever
    /// shows it, but leaving a stale colour there is exactly the seam this avoids — so every
    /// surface swap sets it, resetting to the window's own colour for anything but a terminal.
    ///
    /// Takes the typed ground rather than a colour, because the backdrop's *ownership* travels
    /// with it: `WindowBackdrop` tells the divider whether the theme states this ground, and a
    /// bare `NSColor` cannot carry that answer — see `WindowBackdrop.Ground`.
    private func applyPaneBackground(_ ground: WindowBackdrop.Ground) {
        let color: NSColor
        switch ground {
        case .chrome: color = Design.Surface.ground
        case .terminal(let terminal): color = terminal
        }
        view.applyLayerBackground(color)

        // Also paint the window itself, so the terminal's colour is the backdrop the whole
        // right side sits on: it fills the strip beneath the transparent toolbar and runs into
        // the window's rounded corners, instead of a neutral chrome meeting the terminal in a
        // hard edge. The sidebar covers its own column with an opaque ground, so this reaches
        // only the panes that want it — and the split view's divider is the seam between them.
        view.window?.backgroundColor = color

        // And tell whatever is drawn on it. The toolbar sits over this colour rather than over
        // the chrome's ground, so its ink has to come from here — see `WindowBackdrop`.
        WindowBackdrop.set(ground)
    }

    private func detachCurrentChild() {
        if let page = settingsPage {
            page.view.removeFromSuperview()
            page.removeFromParent()
            settingsPage = nil
            settingsPageCache.removeAll()
        }

        if let conversation = currentConversation {
            conversation.view.removeFromSuperview()
            conversation.removeFromParent()
            currentConversation = nil
        }

        guard let child = currentChild else { return }
        child.view.removeFromSuperview()
        child.removeFromParent()
        currentChild = nil
    }

    private func showEmptyState() {
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        composerViewController.view.isHidden = true
        placeholderView.isHidden = false
        applyPaneBackground(.chrome)
        placeholderView.configure(
            symbolName: "terminal",
            title: L10n.string("No Session Selected"),
            detail: L10n.string(
                "Select a session in the sidebar, or start one here."
            ),
            actionTitle: L10n.string("New Session")
        )
        // The one thing an empty pane is for is starting a session, so the pane offers the
        // same route ⌘N takes rather than only describing where else to click.
        placeholderView.onAction = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainerDidRequestNewSession(self)
        }
    }

    private func showDormantState(for sessionID: SessionID) {
        guard let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            showEmptyState()
            return
        }

        composerViewController.view.isHidden = true
        placeholderView.isHidden = false
        applyPaneBackground(.chrome)
        placeholderView.configure(
            symbolName: "arrow.clockwise.circle",
            title: L10n.format("%@ ended", agentSession.title),
            detail: dormantDetail(for: agentSession),
            actionTitle: agentSession.isResumable
                ? L10n.string("Resume Session")
                : L10n.string("Start Again")
        )
        placeholderView.onAction = { [weak self] in
            self?.resumeCurrentSession()
        }
    }

    /// Explains what resuming will do, which differs once a resumable identifier is known.
    private func dormantDetail(for agentSession: AgentSession) -> String {
        if agentSession.isResumable {
            return L10n.string(
                "The conversation is saved and will pick up where it left off."
            )
        }

        if agentSession.kind.supportsResume {
            return L10n.string(
                "No saved conversation was found, so this will start fresh."
            )
        }

        return L10n.string("Starting again opens a new shell.")
    }
}

// MARK: - Git Status Overlay

/// Split from the class body purely for size, like the sidebar's action extension.
private extension TerminalContainerViewController {

    /// Floats at the pane's top-right corner, above every session surface — installed after
    /// the static views, and the surfaces attach `positioned: .below` it, so nothing added
    /// later ever covers it. Clicking is the same gesture as View ▸ Git Review.
    func setupGitStatusOverlay() {
        gitStatusOverlay.onOpen = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainerDidRequestGitReview(self)
        }
        addOverlay(gitStatusOverlay)

        NSLayoutConstraint.activate([
            gitStatusOverlay.topAnchor.constraint(
                equalTo: contentTopAnchor,
                constant: Design.Spacing.inset
            ),
            gitStatusOverlay.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            )
        ])
    }

    /// Follows the selection: the card and its watcher serve the checkout on screen, and a
    /// pane showing no session — composer, settings, nothing — shows no card either.
    func updateGitChangeMonitor() {
        gitChangeMonitor?.stop()
        gitChangeMonitor = nil
        gitStatusOverlay.clear()

        guard let sessionID = currentSessionID,
              let project = ProjectStore.shared.project(forSessionID: sessionID) else { return }

        delegate?.terminalContainer(self, gitStatusLoadingDidChange: true, for: sessionID)

        gitChangeMonitor = GitChangeMonitor(
            root: project.folderURL,
            onChange: { [weak self] reading in
                guard let self, self.currentSessionID == sessionID else { return }
                self.gitStatusOverlay.update(with: reading)
                self.refreshGitStatusOverlayRunState()
            },
            onInitialReadComplete: { [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.delegate?.terminalContainer(
                    self,
                    gitStatusLoadingDidChange: false,
                    for: sessionID
                )
            }
        )

        guard gitChangeMonitor != nil else {
            delegate?.terminalContainer(
                self,
                gitStatusLoadingDidChange: false,
                for: sessionID
            )
            return
        }
        gitChangeMonitor?.start()
        refreshGitStatusOverlayRunState()
    }

    /// The same live checkout reading has two presentations: branch while idle, turn progress
    /// while an agent is working. Structured conversations can add a plan position; terminal
    /// sessions still get the working orb and live diff totals.
    func refreshGitStatusOverlayRunState() {
        guard gitChangeMonitor != nil else { return }

        if let conversation = currentConversation {
            gitStatusOverlay.updateRunState(
                isActive: conversation.isTurnInFlight,
                progress: conversation.runProgress
            )
        } else if let child = currentChild {
            gitStatusOverlay.updateRunState(
                isActive: child.activity == .working,
                progress: nil
            )
        } else {
            gitStatusOverlay.updateRunState(isActive: false, progress: nil)
        }
    }
}

// MARK: - AgentSessionViewControllerDelegate

extension TerminalContainerViewController: AgentSessionViewControllerDelegate {

    func agentSession(_ controller: AgentSessionViewController, titleChangedTo title: String) {
        // Agents report progress through the terminal title, so this drives the sidebar
        // name as well as the window subtitle.
        ProjectStore.shared.updateAgentTitle(title, for: controller.sessionID)

        delegate?.terminalContainer(self, sessionTitleChanged: title, for: controller.sessionID)
    }

    func agentSession(_ controller: AgentSessionViewController, didExitWithCode exitCode: Int32?) {
        // The agent exited: close its terminal but keep the sidebar entry so the
        // conversation can be resumed by identifier later.
        let sessionID = controller.sessionID

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            AgentRuntime.shared.discard(sessionID: sessionID)

            if sessionID == self.currentSessionID {
                self.detachCurrentChild()
                self.showDormantState(for: sessionID)
            }

            self.delegate?.terminalContainer(self, sessionDidExit: sessionID, exitCode: exitCode)
        }
    }

    func agentSessionDidChangeState(_ controller: AgentSessionViewController) {
        if controller.sessionID == currentSessionID {
            refreshGitStatusOverlayRunState()
        }
        NotificationCenter.default.post(
            SessionActivityDidChange(sessionID: controller.sessionID)
        )
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }
}

// MARK: - TerminalContainerViewControllerDelegate

protocol TerminalContainerViewControllerDelegate: AnyObject {
    func terminalContainer(
        _ container: TerminalContainerViewController,
        visibleSessionDidChange sessionID: SessionID?
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionTitleChanged title: String,
        for sessionID: SessionID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionDidExit sessionID: SessionID,
        exitCode: Int32?
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        sessionStateDidChange sessionID: SessionID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        gitStatusLoadingDidChange isLoading: Bool,
        for sessionID: SessionID
    )
    /// The floating git status card was clicked; the window opens the review tab.
    func terminalContainerDidRequestGitReview(_ container: TerminalContainerViewController)
    /// The empty state's one action: begin a session, the same route ⌘N takes.
    func terminalContainerDidRequestNewSession(_ container: TerminalContainerViewController)
}

// MARK: - ConversationViewControllerDelegate

extension TerminalContainerViewController: ConversationViewControllerDelegate {

    func conversation(_ controller: ConversationViewController, didExitWithCode code: Int32) {
        // Unlike a terminal, the view is kept rather than swapped for the dormant placeholder:
        // the conversation it is showing is the only record of the turn on screen, and the
        // session can be resumed by selecting it again.
        delegate?.terminalContainer(self, sessionDidExit: controller.sessionID, exitCode: code)
    }

    func conversationDidChangeActivity(_ controller: ConversationViewController) {
        if controller.sessionID == currentSessionID {
            refreshGitStatusOverlayRunState()
        }
        // Same channel a terminal session's activity uses, so the sidebar refreshes its row
        // and its attention dot the one way it already knows.
        NotificationCenter.default.post(
            SessionActivityDidChange(sessionID: controller.sessionID)
        )
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }
}

// MARK: - Pane Header Defaults

/// The strip at the top of the content pane, holding what used to be toolbar items.
enum PaneHeaderDefaults {
    /// Deep enough for the tab and the icon buttons beside it, with air above and below.
    /// Read from `PaneHeaderView` so this strip and the sidebar's header band keep one
    /// silhouette: their hairlines land on the same line across the split.
    static let height: CGFloat = PaneHeaderView.bandHeight

    /// From the pane's own edges. The leading one is what makes the tab start where the sidebar
    /// ends, which is the whole reason the header lives in the pane.
    static let inset: CGFloat = Design.Spacing.medium

    /// Stands in for the window controls' width until they have been laid out and can be
    /// measured. Only ever used on the first pass of a launch that starts collapsed — the
    /// measurement replaces it as soon as there is something to measure.
    static let assumedWindowControlsWidth: CGFloat = 112
}
