import AppKit

/// Hosts whichever chat or standalone terminal is selected in the sidebar.
///
/// Live chat controllers are retained by `AgentRuntime` and standalone terminals by
/// `ProjectTerminalRuntime`, so switching selection swaps views without restarting processes
/// or losing scrollback.
final class TerminalContainerViewController: NSViewController {

    // MARK: - Properties

    private let placeholderView = SessionPlaceholderView()
    private let appEvents = AppEventObservations()

    /// Shown when a project rather than a session is selected.
    let composerViewController = SessionComposerViewController()

    private var currentChild: AgentSessionViewController?
    private var currentConversation: ConversationViewController?
    private var currentProjectTerminal: ProjectTerminalViewController?
    private(set) var currentTerminalID: TerminalID?

    /// The terminal surface currently accepting terminal commands, whether it belongs to a
    /// chat or is a standalone project terminal.
    var activeTerminalSession: TerminalSession? {
        currentProjectTerminal?.session ?? currentChild?.session
    }

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
    /// Transcript reads started after the owning renderer has exited. The hierarchy survives
    /// renderer disposal, so its selected child must remain a working destination too.
    private var retainedSubagentTranscriptLoads = SubagentTranscriptLoadCache()
    private var retainedTranscriptRecheckGeneration: [String: Int] = [:]

    /// Settings is shown as a single page centred in the pane; the page list lives in the
    /// window's sidebar, which the settings sections replace, so there is no second sidebar.
    /// The drawer's tabs, per session, kept alive while the app runs — the process *is* the
    /// feature, and a shell that forgot its directory on every session switch would be worse
    /// than useless. One host controller serves every session; switching swaps which list it
    /// shows, exactly as the display panel does.
    private(set) lazy var drawerHostController = DrawerHostViewController(
        directoryProvider: { sessionID in
            guard let project = ProjectStore.shared.project(forSessionID: sessionID) else {
                return nil
            }
            return AgentRuntime.shared.controller(for: sessionID)?.session
                .effectiveWorkingDirectory()
                ?? URL(fileURLWithPath: project.folderPath)
        }
    )

    private lazy var drawerHost: NSView = {
        let host = NSView()
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }()
    private lazy var drawerDivider: ShellDrawerDivider = {
        let divider = ShellDrawerDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true
        divider.onDrag = { [weak self] delta in self?.resizeDrawer(by: delta) }
        return divider
    }()
    private lazy var drawerHeight = drawerHost.heightAnchor.constraint(equalToConstant: 0)

    /// Window geometry, like the display panel's width: a drawer height is a working
    /// preference for a window, not a fact about the session — so it persists app-wide.
    private var drawerHeightValue: CGFloat = ShellDrawerHeight.stored

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
        // The card's agent line reads the *stored* session, and this event fires for content edits
        // as well as structural ones. Without it a model chosen for the session on screen sat
        // stale on the card until the selection moved away and came back. Cheap to repeat: the
        // status-line coverage behind it answers from cache once the account's command is known.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.refreshGitStatusOverlayModel()
        }
        // Who is watching moves on its own clock — a phone picked up, a browser tab closed —
        // and only the chat on screen is worth redrawing for.
        appEvents.observe(SessionFollowersDidChange.self) { [weak self] event in
            guard event.sessionID == self?.currentSessionID else { return }
            self?.refreshGitStatusOverlayAudience()
        }
        appEvents.observe(SessionSharingDidChange.self) { [weak self] _ in
            self?.refreshGitStatusOverlayAudience()
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
        if let currentTerminalID {
            applyPaneBackground(.terminal(
                ThemeAssignments.theme(forTerminal: currentTerminalID).background
            ))
        } else if currentChild != nil || currentConversation != nil {
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

    /// Shows the composer for a project — or for none, the choose-a-project mode a store with
    /// no projects opens onto — replacing whatever session was on screen.
    func showComposer(projectID: ProjectID?) {
        detachCurrentChild()
        currentComposerProjectID = projectID
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = nil

        // A shell belongs to a conversation; neither the composer nor a settings page is one, and
        // a drawer left standing under them draws a terminal through the form on top of it.
        applyDrawer(for: nil)

        placeholderView.isHidden = true
        composerViewController.view.isHidden = false
        applyPaneBackground(.chrome)
        composerViewController.show(projectID: projectID)
        composerViewController.focusPrompt()
    }

    /// Puts a composer back on screen **without resetting it**, for a detour that never changed
    /// which project is selected — Settings opening over it and closing again.
    ///
    /// `showComposer` configures the composer for a project, which is right when the project is
    /// what changed: the choices reset and the prompt is re-read from `DraftStore`. Coming back
    /// from Settings nothing changed, and re-configuring would drop what is not in the draft —
    /// the agent, account, model and checkout just chosen, and any attached images, which are
    /// deliberately not drafted. The composer is still here, still holding all of it; it only
    /// needs to be visible again.
    ///
    /// Falls back to a full show if the composer has since moved on to another project, so the
    /// caller cannot use this to put a stale project's composer on screen.
    func restoreComposer(projectID: ProjectID) {
        guard composerViewController.projectID == projectID else {
            showComposer(projectID: projectID)
            return
        }

        detachCurrentChild()
        currentComposerProjectID = projectID
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = nil
        applyDrawer(for: nil)

        placeholderView.isHidden = true
        composerViewController.view.isHidden = false
        applyPaneBackground(.chrome)
        composerViewController.refreshDerivedState()
        composerViewController.focusPrompt()
    }

    /// Shows a settings page centred in the pane, replacing whatever session or composer was on
    /// screen. The section list lives in the sidebar; this only draws the chosen page.
    ///
    /// The page is pinned straight to the pane — centred, capped at a readable width, floored by
    /// margins — rather than through an intermediate container, which did not size its child.
    func showSettingsPage(id: String) {
        guard let definition = SettingsPages.page(id: id) else { return }

        currentSettingsPageID = id

        let cached = settingsPageCache[id]
        let page = cached ?? {
            let made = definition.make()
            settingsPageCache[id] = made
            return made
        }()

        install(settings: page, repaint: cached != nil)
    }

    /// Puts a settings-shaped child in the pane: centred, capped at a readable width, floored by
    /// margins — pinned straight to the pane rather than through an intermediate container,
    /// which did not size its child.
    private func install(settings page: NSViewController, repaint: Bool) {
        currentComposerProjectID = nil

        if settingsPage == nil {
            detachCurrentChild()
            currentTerminalID = nil
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

        addChild(page)
        let content = page.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        // A cached page was detached while the theme moved, and the sweep walks windows — so it
        // never reached this tree. Re-resolve it here rather than dropping the cache: rebuilding
        // would cost the page its scroll position and its controls' state to fix colours and
        // fonts that one walk can simply take again.
        if repaint { AppThemeRefresh.repaint(content) }

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
        view.addSubview(drawerHost)

        view.addSubview(drawerDivider)

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

        // Installed once and never re-parented: the zero-high band hides it when closed, and a
        // session switch swaps which tab list it shows rather than which child sits here —
        // detaching per switch is what used to separate shells from their scrollback views.
        addChild(drawerHostController)
        drawerHostController.view.translatesAutoresizingMaskIntoConstraints = false
        drawerHost.addSubview(drawerHostController.view)
        NSLayoutConstraint.activate([
            drawerHostController.view.topAnchor.constraint(equalTo: drawerHost.topAnchor),
            drawerHostController.view.bottomAnchor.constraint(equalTo: drawerHost.bottomAnchor),
            drawerHostController.view.leadingAnchor.constraint(equalTo: drawerHost.leadingAnchor),
            drawerHostController.view.trailingAnchor.constraint(equalTo: drawerHost.trailingAnchor)
        ])
    }

    /// Opens or closes the drawer for the session on screen. Sessions keep their own answer, so
    /// a drawer opened for one conversation does not follow you into the next.
    func toggleShellDrawer() {
        guard let sessionID = currentSessionID else { return }

        let open = !drawerHostController.isOpen(for: sessionID)
        drawerHostController.setOpen(open, for: sessionID)
        applyDrawer(for: sessionID, focusing: open)
    }

    var isShellDrawerOpen: Bool {
        currentSessionID.map { drawerHostController.isOpen(for: $0) } ?? false
    }

    /// Points the drawer host at the session and sizes the band to its open state. The host's
    /// children stay parented across every switch — only the visible list changes.
    private func applyDrawer(for sessionID: SessionID?, focusing: Bool = false) {
        guard let sessionID, drawerHostController.isOpen(for: sessionID) else {
            drawerHostController.showSession(nil)
            drawerHeight.constant = 0
            drawerDivider.isHidden = true
            return
        }

        // The default first tab: an opened drawer with nothing in it gets the session's shell.
        drawerHostController.ensureDefaultShellTab(for: sessionID)
        drawerHostController.showSession(sessionID)

        drawerHeight.constant = clampedDrawerHeight(drawerHeightValue)
        drawerDivider.isHidden = false
        if focusing { drawerHostController.focusActiveTab() }
    }

    /// The session's shell-drawer root process, when it has one. Asked by the info panel, which
    /// attributes a listening port to the shell or to the agent. Deliberately does *not* build a
    /// drawer: a session whose shell was never opened has no second origin to report.
    func shellRootPid(for sessionID: SessionID) -> pid_t? {
        drawerHostController.shellRootPid(for: sessionID)
    }

    private func resizeDrawer(by delta: CGFloat) {
        drawerHeightValue = clampedDrawerHeight(drawerHeight.constant - delta)
        drawerHeight.constant = drawerHeightValue
        ShellDrawerHeight.stored = drawerHeightValue
    }

    private func clampedDrawerHeight(_ height: CGFloat) -> CGFloat {
        // The strip band rides on top of the shell, so the floor grows by exactly the band:
        // the *content* below it keeps the old minimum's one honest line of output.
        let floor = ShellDrawerDefaults.minimumHeight + ThemedTabStripView.bandHeight
        let ceiling = max(floor, view.bounds.height * ShellDrawerDefaults.maximumHeightFraction)
        return min(max(height, floor), ceiling)
    }

    /// Ends a closed session's drawer surfaces, so no shell outlives the thing it belonged to.
    func closeShellDrawer(for sessionID: SessionID) {
        drawerHostController.closeSession(sessionID)
    }

    /// Opens the drawer without toggling — where a moved-in tab just landed must come into
    /// view, whatever state the drawer was in.
    func openShellDrawer() {
        guard let sessionID = currentSessionID else { return }
        drawerHostController.setOpen(true, for: sessionID)
        applyDrawer(for: sessionID)
    }

    /// The opposite, for the drag spring's restore: a drawer opened for a drop that never
    /// came goes back where it was — tabs and their processes untouched.
    func collapseShellDrawer() {
        guard let sessionID = currentSessionID else { return }
        drawerHostController.setOpen(false, for: sessionID)
        applyDrawer(for: sessionID)
    }

    /// Deletion sweep — forwarded here because the drawer host is this pane's child.
    func retainDrawerSessions(_ sessionIDs: Set<SessionID>) {
        drawerHostController.retainOnly(sessionIDs: sessionIDs)
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
        guard sessionID != currentSessionID || settingsPage != nil || currentTerminalID != nil
        else { return }

        detachCurrentChild()
        currentTerminalID = nil
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        applyDrawer(for: sessionID)

        guard let sessionID,
              let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            currentSessionID = nil
            showEmptyState()
            return
        }

        // A continuation's bootstrap is model-derived rather than stored as a free-form draft.
        // Regenerating it here means an app quit between creation and first launch cannot strand
        // a destination that has a snapshot but was never told to read it.
        let effectiveInitialPrompt = initialPrompt
            ?? ConversationContinuation.openingPrompt(for: agentSession)

        // Sessions Threading renders itself take a different surface entirely: no PTY, no
        // terminal view, and a conversation drawn from the CLI's structured events. The kind
        // must still support it — a session flagged native for an agent since disabled falls
        // back to the terminal rather than launching a mode it should no longer use.
        if agentSession.usesNativeUI, agentSession.kind.supportsNativeUI,
           let project = ProjectStore.shared.project(forSessionID: sessionID) {
            showConversation(
                agentSession,
                in: project,
                initialPrompt: effectiveInitialPrompt
            )
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
            controller.launch(initialPrompt: effectiveInitialPrompt)
        }
    }

    /// Shows a first-class project terminal, starting a fresh shell only when no process is
    /// currently retained for it.
    func show(terminalID: TerminalID) {
        guard terminalID != currentTerminalID || settingsPage != nil else { return }

        detachCurrentChild()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        currentSessionID = nil
        applyDrawer(for: nil)

        guard let terminal = ProjectStore.shared.terminal(withID: terminalID) else {
            currentTerminalID = nil
            showEmptyState()
            return
        }

        let controller = ProjectTerminalRuntime.shared.makeController(for: terminal)
        controller.delegate = self
        currentTerminalID = terminalID
        attachProjectTerminal(controller)
        controller.startIfNeeded()
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

    func closeTerminal(for terminalID: TerminalID) {
        ProjectTerminalRuntime.shared.discard(terminalID: terminalID)
        guard terminalID == currentTerminalID else { return }
        detachCurrentChild()
        currentTerminalID = nil
        showEmptyState()
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
        refreshGitStatusOverlaySubagents()
        controller.focusTerminal()
    }

    private func attachProjectTerminal(_ controller: ProjectTerminalViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: gitStatusOverlay)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        currentProjectTerminal = controller
        placeholderView.isHidden = true
        composerViewController.view.isHidden = true
        applyPaneBackground(.terminal(controller.paneBackgroundColor))
        controller.focus()
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
        // a theme switch would come back wearing the theme it left under. The refresh generation
        // keeps that repair while making an ordinary hot switch O(1) instead of walking every
        // retained row again.
        AppThemeRefresh.repaintIfNeeded(conversation.view)

        // A native conversation has no terminal, but it should read like one: the backdrop is
        // its resolved terminal theme's background, so it — and the sidebar sampling it — match a
        // Claude or shell session rather than the flatter `windowBackgroundColor`, which shows
        // through the sidebar's material as a subtly different tone. This is also the whole
        // extent to which a theme reaches a natively-rendered session: the conversation itself
        // is drawn in system colours, per the design system.
        applyPaneBackground(.terminal(ThemeAssignments.theme(for: currentSessionID).background))
        refreshGitStatusOverlayRunState()
        refreshGitStatusOverlaySubagents()
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

        if let terminal = currentProjectTerminal {
            terminal.view.removeFromSuperview()
            terminal.removeFromParent()
            currentProjectTerminal = nil
        }

        guard let child = currentChild else { return }
        child.view.removeFromSuperview()
        child.removeFromParent()
        currentChild = nil
    }

    private func showEmptyState() {
        // With no projects at all, the empty pane *is* the way in: the composer in its
        // choose-a-project mode, not a placeholder describing where else to click.
        guard !ProjectStore.shared.projects.isEmpty else {
            showComposer(projectID: nil)
            return
        }

        currentComposerProjectID = nil
        currentSettingsPageID = nil
        currentTerminalID = nil
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

    private func showDormantTerminalState(for terminalID: TerminalID) {
        guard let terminal = ProjectStore.shared.terminal(withID: terminalID) else {
            showEmptyState()
            return
        }

        composerViewController.view.isHidden = true
        placeholderView.isHidden = false
        applyPaneBackground(.chrome)
        placeholderView.configure(
            symbolName: "terminal",
            title: L10n.format("%@ ended", ProjectTerminalTitle.displayTitle(for: terminal)),
            detail: L10n.string("Start a fresh shell in its last working directory."),
            actionTitle: L10n.string("Start Again")
        )
        placeholderView.onAction = { [weak self] in
            self?.resumeCurrentTerminal()
        }
    }

    private func resumeCurrentTerminal() {
        guard let terminalID = currentTerminalID,
              let terminal = ProjectStore.shared.terminal(withID: terminalID) else { return }
        detachCurrentChild()
        let controller = ProjectTerminalRuntime.shared.makeController(for: terminal)
        controller.delegate = self
        attachProjectTerminal(controller)
        controller.startIfNeeded()
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
    /// later ever covers it. Git opens Review; the child-agent segment opens Subagents.
    func setupGitStatusOverlay() {
        gitStatusOverlay.onOpen = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainerDidRequestGitReview(self)
        }
        gitStatusOverlay.onOpenSubagents = { [weak self] in
            self?.openSubagents()
        }
        gitStatusOverlay.onOpenSharing = { [weak self] in
            self?.openSharing()
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
        gitStatusOverlay.showSession(currentSessionID?.uuidString.lowercased())
        refreshGitStatusOverlaySubagents()
        refreshGitStatusOverlayModel()
        refreshGitStatusOverlayAudience()

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
    /// while a turn is in flight.
    ///
    /// **Only a native conversation promotes the card.** A terminal session's CLI already draws
    /// its own spinner and working word a few lines under this corner, so the orb and "Working…"
    /// here said the same thing twice in the same view. The card keeps saying what the terminal
    /// does not — branch and live `+N −M` — for the whole run.
    func refreshGitStatusOverlayRunState() {
        guard gitChangeMonitor != nil else { return }

        gitStatusOverlay.updateRunState(
            isActive: currentConversation?.isTurnInFlight ?? false,
            progress: currentConversation?.runProgress
        )
    }

    /// Says whether anyone outside this Mac can see the chat on screen, and how many are looking.
    ///
    /// Both halves are cheap main-actor reads — a dictionary of live sockets and a dictionary of
    /// shares — so this is called from every event that could move either rather than polled.
    func refreshGitStatusOverlayAudience() {
        guard let sessionID = currentSessionID, AppSettings.shared.remoteAccessEnabled else {
            gitStatusOverlay.updateAudience(GitStatusOverlayView.AudienceReading())
            return
        }
        gitStatusOverlay.updateAudience(GitStatusOverlayView.AudienceReading(
            following: RemoteSessionMirrorRegistry.shared.followers(of: sessionID).count,
            isShared: RemoteAccessCoordinator.shared.hasSessionShares(sessionID)
        ))
    }

    /// Projects the provider-neutral hierarchy into the compact receipt beside Git status.
    func refreshGitStatusOverlaySubagents() {
        let timeline = currentConversation?.subagents
            ?? currentChild?.subagents
            ?? currentSessionID.map {
                AgentRuntime.shared.subagentState(for: $0).timeline
            }
        gitStatusOverlay.updateSubagents(
            workingCount: timeline?.workingCount ?? 0,
            doneCount: timeline?.doneCount ?? 0
        )
    }

    /// Feeds the card the agent facts *this pane* is responsible for showing.
    ///
    /// **A native conversation shows its own.** Its status row already carries model, effort and
    /// speed as chips directly above the composer, so the card would be saying them a second time
    /// in the same view — the rule the run spinner already follows.
    ///
    /// **A terminal session shows what its CLI does not.** Claude draws a status line in its TUI,
    /// and for three of four logins on the machine this was written against that line is usage and
    /// nothing else — no model. `ClaudeStatusLineCoverage` runs the account's own command and
    /// reports which facts it prints; whatever is left is what the card owes the user. The card is
    /// only told the answer, so a Claude-specific rule stays out of a Git-shaped view.
    ///
    /// Two facts are deliberately withheld rather than guessed. Fast mode is a reading only where
    /// Threading sets it: `appendCodexConversationOverrides` is Codex-only, and Claude's own
    /// fast-mode state belongs to its print transport (`AgentModels.defaultFastMode` returns nil
    /// for Claude and says why), so a Claude *terminal* session has no honest speed to report.
    /// Effort for a Claude terminal session is the account's configured value — what the CLI will
    /// inherit, which is the best answer available and goes stale the moment the user types
    /// `/effort`. When their status line prints effort we hide ours, which is also the case where
    /// staleness would have shown.
    func refreshGitStatusOverlayModel() {
        guard let sessionID = currentSessionID,
              let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID),
              currentConversation == nil
        else {
            gitStatusOverlay.updateModel(nil)
            return
        }

        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        let model = session.model ?? AgentModels.defaultModel(
            for: session.kind,
            account: account
        )
        let effort = AgentModels.effectiveEffort(for: session, model: model, account: account)
        let isFast = session.kind == .codex
            && (
                session.fastMode
                    ?? AgentModels.defaultFastMode(
                        for: session.kind,
                        model: model,
                        account: account
                    )
                    ?? false
            )

        let reading = GitStatusOverlayView.ModelReading(
            name: model.map { ModelName.display(for: $0) },
            effort: effort.map {
                AgentReasoningLevel(effort: $0, description: "").displayName
            },
            isFast: isFast
        )

        // Only Claude runs a status line, so a Codex terminal has nothing to complement — and
        // a suppressed one prints nothing by construction, so there is no line to defer to
        // and the card owes every fact. Skipping the probe also skips its cached answer,
        // which describes a line the user is no longer shown.
        guard session.kind == .claude, !AppSettings.shared.suppressesClaudeStatusLine else {
            gitStatusOverlay.updateModel(reading)
            return
        }

        var facts = ClaudeStatusLineCoverage.Facts(
            workingDirectory: project.folderURL.path,
            projectDirectory: project.folderURL.path
        )
        facts.modelIdentifier = model
        facts.modelDisplayName = reading.name
        facts.effort = effort
        facts.sessionID = session.resumeState.transcriptID?.rawValue
        facts.branch = session.branch

        // Set inside the completion rather than before it: `resolve` answers immediately when the
        // account has no status line or the command is already known, and the row appearing with
        // every fact and then dropping the covered ones would be a visible flinch on first paint.
        ClaudeStatusLineCoverage.resolve(account: account, facts: facts) { [weak self] coverage in
            guard let self, self.currentSessionID == sessionID else { return }

            var filtered = reading
            if coverage.model { filtered.name = nil }
            if coverage.effort { filtered.effort = nil }
            if coverage.fastMode { filtered.isFast = false }
            self.gitStatusOverlay.updateModel(filtered)
        }
    }

    /// Opens the most relevant child, after which the display pane owns navigation among all
    /// children. The persisted selection wins; otherwise prefer live work, then the newest row.
    private func openSubagents() {
        guard let sessionID = currentSessionID else { return }
        let state = AgentRuntime.shared.subagentState(for: sessionID)
        let timeline = currentConversation?.subagents
            ?? currentChild?.subagents
            ?? state.timeline
        let selectedID = currentConversation?.selectedSubagentThreadID
            ?? currentChild?.selectedSubagentThreadID
            ?? state.selectedThreadID
        let candidate = selectedID.flatMap { selectedID in
            timeline.agents.first {
                $0.descriptor.threadID == selectedID
            }
        } ?? timeline.agents.last(where: \.status.isWorking)
            ?? timeline.agents.last
        guard let candidate else { return }
        selectSubagent(candidate.descriptor.threadID)
    }

    private func openSharing() {
        delegate?.terminalContainerDidRequestSharing(self)
    }

}

extension TerminalContainerViewController {
    /// Routes selection from the Subagents side pane back to the renderer that owns transcript
    /// loading, without reintroducing a navigator above the chat or terminal. When that renderer
    /// has exited, the runtime's retained hierarchy remains the owner and the descriptor-backed
    /// loader can still rebuild the selected transcript.
    func selectSubagent(_ threadID: String) {
        if let currentConversation {
            currentConversation.selectSubagent(threadID)
            return
        }
        if let currentChild {
            currentChild.selectSubagent(threadID)
            return
        }

        guard let sessionID = currentSessionID else { return }
        let state = AgentRuntime.shared.subagentState(for: sessionID)
        guard let selected = state.timeline.agents.first(where: {
            $0.descriptor.threadID == threadID
        }) else { return }

        state.select(threadID: threadID)
        delegate?.terminalContainer(
            self,
            didSelectSubagent: selected,
            for: sessionID
        )
        loadRetainedSubagentTranscriptIfNeeded(
            selected,
            state: state,
            sessionID: sessionID
        )
    }

    private func loadRetainedSubagentTranscriptIfNeeded(
        _ agent: SubagentTimeline.Agent,
        state: SubagentSessionState,
        sessionID: SessionID
    ) {
        let threadID = agent.descriptor.threadID
        let cacheID = "\(sessionID.uuidString.lowercased()):\(threadID)"
        guard agent.status.isDone,
              let kind = ProjectStore.shared.session(withID: sessionID)?.kind,
              let signature = SubagentTranscriptLoader.signature(for: agent.descriptor),
              retainedSubagentTranscriptLoads.begin(
                  threadID: cacheID,
                  signature: signature
              ) else { return }

        SubagentTranscriptLoader.load(
            descriptor: agent.descriptor,
            kind: kind
        ) { [weak self, weak state] events, isTruncated in
            guard let self, let state else { return }
            switch self.retainedSubagentTranscriptLoads.finish(
                threadID: cacheID,
                signature: signature,
                eventCount: events.count
            ) {
            case .retryAfter(let delay):
                self.scheduleRetainedTranscriptRecheck(
                    state: state,
                    sessionID: sessionID,
                    threadID: threadID,
                    after: delay
                )
                return
            case .unavailable:
                return
            case .loaded:
                state.replaceConversation(threadID: threadID, events: events)
            }

            if isTruncated {
                state.apply(.activity(
                    threadID: threadID,
                    text: ClaudeSubagentHistoryDefaults.truncatedActivity
                ))
            }
            self.delegate?.terminalContainer(
                self,
                subagentsDidChange: state.timeline,
                for: sessionID
            )
        }
    }

    private func scheduleRetainedTranscriptRecheck(
        state: SubagentSessionState,
        sessionID: SessionID,
        threadID: String,
        after delay: TimeInterval
    ) {
        let cacheID = "\(sessionID.uuidString.lowercased()):\(threadID)"
        let generation = (retainedTranscriptRecheckGeneration[cacheID] ?? 0) + 1
        retainedTranscriptRecheckGeneration[cacheID] = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  self.retainedTranscriptRecheckGeneration[cacheID] == generation,
                  let agent = state.timeline.agents.first(where: {
                      $0.descriptor.threadID == threadID
                  }) else { return }
            self.loadRetainedSubagentTranscriptIfNeeded(
                agent,
                state: state,
                sessionID: sessionID
            )
        }
    }
}

// MARK: - ProjectTerminalViewControllerDelegate

extension TerminalContainerViewController: ProjectTerminalViewControllerDelegate {
    func projectTerminalDidChangeRunningState(_ controller: ProjectTerminalViewController) {
        guard controller.terminalID == currentTerminalID, !controller.isRunning else { return }

        // SwiftTerm reports process termination inside its delegate stack. Swap surfaces on the
        // next turn so the terminal finishes unwinding before its view leaves the hierarchy.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller,
                  controller.terminalID == self.currentTerminalID,
                  !controller.isRunning else { return }
            self.detachCurrentChild()
            self.showDormantTerminalState(for: controller.terminalID)
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

    func agentSessionSubagentsDidChange(_ controller: AgentSessionViewController) {
        guard controller.sessionID == currentSessionID else { return }
        refreshGitStatusOverlaySubagents()
        delegate?.terminalContainer(
            self,
            subagentsDidChange: controller.subagents,
            for: controller.sessionID
        )
    }

    func agentSession(
        _ controller: AgentSessionViewController,
        didSelectSubagent agent: SubagentTimeline.Agent
    ) {
        delegate?.terminalContainer(
            self,
            didSelectSubagent: agent,
            for: controller.sessionID
        )
    }

    func agentSession(
        _ controller: AgentSessionViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent
    ) {
        delegate?.terminalContainer(
            self,
            didUpdateSelectedSubagent: agent,
            for: controller.sessionID
        )
    }
}

// MARK: - TerminalContainerViewControllerDelegate

@MainActor
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
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didSelectSubagent agent: SubagentTimeline.Agent,
        for sessionID: SessionID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent,
        for sessionID: SessionID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        subagentsDidChange timeline: SubagentTimeline,
        for sessionID: SessionID
    )
    /// The Git portion of the floating session status card was clicked.
    func terminalContainerDidRequestGitReview(_ container: TerminalContainerViewController)
    /// Its audience row was clicked: open who can reach this chat and who is on it.
    func terminalContainerDidRequestSharing(_ container: TerminalContainerViewController)
    /// A turn's changed-files card asked for its diff; the window opens the review tab on
    /// the Last Turn scope.
    func terminalContainerDidRequestTurnDiff(_ container: TerminalContainerViewController)
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

    func conversationDidRequestTurnDiff(_ controller: ConversationViewController) {
        delegate?.terminalContainerDidRequestTurnDiff(self)
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

    func conversationSubagentsDidChange(_ controller: ConversationViewController) {
        guard controller.sessionID == currentSessionID else { return }
        refreshGitStatusOverlaySubagents()
        delegate?.terminalContainer(
            self,
            subagentsDidChange: controller.subagents,
            for: controller.sessionID
        )
    }

    func conversation(
        _ controller: ConversationViewController,
        didSelectSubagent agent: SubagentTimeline.Agent
    ) {
        delegate?.terminalContainer(
            self,
            didSelectSubagent: agent,
            for: controller.sessionID
        )
    }

    func conversation(
        _ controller: ConversationViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent
    ) {
        delegate?.terminalContainer(
            self,
            didUpdateSelectedSubagent: agent,
            for: controller.sessionID
        )
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
    /// measured. Only ever used on the first pass of a launch — the measurement replaces it as
    /// soon as there is something to measure. Covers the traffic lights, the sidebar toggle, and
    /// the history pair beside it (two more `Design.Size.toolbarButtonWidth` buttons and their
    /// spacing).
    ///
    /// It was 180, which was an under-measurement: read off the running window's accessibility
    /// frames, the forward chevron ends at 198pt from the window's leading edge. Undersized it is
    /// not merely imprecise — `MainWindowController.updateSidebarMinimumThickness` uses the same
    /// answer to decide how narrow the sidebar may be, and a floor below these controls puts the
    /// divider through them.
    static let assumedWindowControlsWidth: CGFloat = 200
}
