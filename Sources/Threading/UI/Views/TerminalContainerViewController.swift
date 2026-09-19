import AppKit
import ThreadingPTYHostKit

private enum StatusCardRemoteDefaults {
    /// Checkout notifications arrive in bursts while an agent writes. Local/provider discovery
    /// starts only after that burst settles, and the provider read below is cached separately.
    static let checkoutDebounce: TimeInterval = 0.5
    static let remoteRefreshInterval: TimeInterval = 15
    static let pendingChecksPollInterval: TimeInterval = 30
}

/// Hosts whichever chat or standalone terminal is selected in the sidebar.
///
/// Live chat controllers are retained by `AgentRuntime` and standalone terminals by
/// `ProjectTerminalRuntime`, so switching selection swaps views without restarting processes
/// or losing scrollback.
final class TerminalContainerViewController: NSViewController {
    // MARK: - Properties

    typealias SessionComposerFactory = @MainActor () -> SessionComposerViewController

    private let placeholderView = SessionPlaceholderView()

    /// The pane a failed launch gets instead of the dormant placeholder. Built lazily: most
    /// sessions never fail to start, and the well inside it owns a text network.
    private lazy var launchFailureView = LaunchFailureView()
    private var isLaunchFailureViewInstalled = false
    private var scheduledPlaceholderView: ScheduledSessionPlaceholderView?
    private let appEvents = AppEventObservations()

    /// Whether this pane opens nothing.
    ///
    /// Taken at construction rather than read from `RecoveryMode` at each site, so a test drives
    /// the pane's recovery behaviour by building one rather than by moving a process-wide answer
    /// out from under whatever else is running.
    private let isRecovery: Bool

    /// The recovery surface, built once and shown wherever the pane would otherwise be empty or
    /// would otherwise open something.
    private var recoveryView: RecoveryModeView?

    /// Shown when a project rather than a session is selected.
    ///
    /// A launch with stored projects opens on the placeholder and then restores its selected
    /// session. The composer owns chips, a prompt surface and footer controls, so constructing
    /// that whole hidden form here made it part of every launch even when no composer route was
    /// visited. Keep the factory and the delegate intent; materialize the controller only when
    /// `showComposer` (or a focused test) asks for it.
    private let sessionComposerFactory: SessionComposerFactory
    private var storedComposerViewController: SessionComposerViewController?
    var composerViewController: SessionComposerViewController {
        if let storedComposerViewController {
            installComposerIfNeeded(storedComposerViewController)
            return storedComposerViewController
        }

        let controller = sessionComposerFactory()
        controller.delegate = composerDelegate
        storedComposerViewController = controller
        installComposerIfNeeded(controller)
        return controller
    }

    weak var composerDelegate: SessionComposerViewControllerDelegate? {
        didSet { storedComposerViewController?.delegate = composerDelegate }
    }

    private var currentChild: AgentSessionViewController?
    private var currentConversation: ConversationViewController?
    private var currentSearchConversationWindow: ConversationSearchWindowViewController?
    private var currentProjectTextSearchPreview: ProjectTextSearchPreviewViewController?
    private(set) var currentSearchFileRelativePath: String?
    private var currentProjectTerminal: ProjectTerminalViewController?
    private(set) var currentTerminalID: TerminalID? {
        didSet {
            guard currentTerminalID != oldValue else { return }
            refreshTerminalTextVisibilityNotice()
        }
    }

    /// The terminal surface currently accepting terminal commands, whether it belongs to a
    /// chat or is a standalone project terminal.
    var activeTerminalSession: TerminalSession? {
        currentProjectTerminal?.session ?? currentChild?.session
    }

    /// Whether a natively rendered conversation is on screen, which is what the turn and step
    /// commands need in order to validate themselves on or off.
    var isShowingConversation: Bool {
        currentConversation != nil || currentSearchConversationWindow != nil
    }

    var isShowingProjectTextSearchPreview: Bool { currentProjectTextSearchPreview != nil }

    /// Moves the showing conversation by one exchange, or by one tool call inside one.
    ///
    /// A narrow forwarding pair rather than an exposed controller: the menu needs to move the
    /// conversation, not to hold it, and everything else that reaches through here has gone the
    /// same way.
    @discardableResult
    func moveConversation(byTurn forward: Bool) -> Bool {
        currentConversation?.goToAdjacentTurn(forward: forward) ?? false
    }

    @discardableResult
    func moveConversation(byStep forward: Bool) -> Bool {
        currentConversation?.goToAdjacentStep(forward: forward) ?? false
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
            refreshTerminalTextVisibilityNotice()
        }
    }

    /// The session whose next attach is the composer's own, and the animator that spends it.
    ///
    /// `SessionCoordinator` leaves the mark at the point a composer start succeeds, because the
    /// composer is the only surface that can hand a box over: a resume, a sidebar click and a
    /// remote start all arrive at the same `show(sessionID:)` with nothing on screen to move.
    private var pendingComposerHandoffSessionID: SessionID?
    private let composerHandoff = ComposerHandoffAnimator()

    /// The floating branch-and-changes card, and the watcher feeding it. The monitor follows
    /// `currentSessionID`: it exists only while a session's checkout is on screen.
    private let gitStatusOverlay = GitStatusOverlayView()
    private var gitChangeMonitor: GitChangeMonitor?
    private lazy var changeRequestProviders = ChangeRequestProviderRegistry.live()
    private var changeRequestTask: Task<Void, Never>?
    private var changeRequestGeneration = 0
    private var changeRequestDebounceWork: DispatchWorkItem?
    private var changeRequestPollWork: DispatchWorkItem?
    private var lastChangeRequestRead: (signature: String, date: Date)?
    private var lastChangeRequestReading: GitStatusOverlayView.ChangeRequestReading?
    /// The session whose row is spinning for the monitor's first read, so tearing the monitor
    /// down can lower a raise whose completion will now never fire.
    private var gitStatusLoadingSessionID: SessionID?
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
            guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else {
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
        divider.onDrag = { [weak self] delta in self?.drawerDividerDragged(by: delta) }
        divider.onDragEnded = { [weak self] in self?.drawerDividerDragEnded() }
        return divider
    }()

    private lazy var drawerHeight = drawerHost.heightAnchor.constraint(equalToConstant: 0)

    /// Window geometry, like the display panel's width: a drawer height is a working
    /// preference for a window, not a fact about the session — so it persists app-wide.
    private var drawerHeightValue: CGFloat = ShellDrawerHeight.stored

    /// The unclamped height the pointer is asking for during a divider drag, nil between
    /// drags. The constraint stops at the floor while the hand keeps going, and this running
    /// total is the only record of how far past it the drag went — the drawer's copy of the
    /// split divider's overshoot problem, kept here because the divider reports only deltas.
    private var drawerDragTargetHeight: CGFloat?

    /// Which drawer transition is current, so a close's completion — which hides the band —
    /// cannot fire after something reopened it mid-slide.
    private var drawerTransitionGeneration = 0

    private var settingsPage: NSViewController?
    private var settingsPageCache: [String: NSViewController] = [:]
    private var settingsAISearch: SettingsAISearchViewController?
    private var triggerCenter: TriggerCenterViewController?

    /// Whether settings is the surface currently on screen, so the window can title the pane.
    var isShowingSettings: Bool { settingsPage != nil }
    var isShowingTriggers: Bool { triggerCenter?.view.superview != nil }

    /// The non-session sidebar destination currently shown. These make the toolbar tab derive
    /// from the same selection as the content pane instead of falling back to a generic title.
    private(set) var currentComposerProjectID: ProjectID?
    private(set) var currentSettingsPageID: String?

    weak var delegate: TerminalContainerViewControllerDelegate?

    /// The pane's header strip. See `setupHeader`.
    private let headerHost = PaneHeaderView(margin: .paneEdge)
    private var headerLeadingConstraint: NSLayoutConstraint?

    /// Where the pane's content begins — below the header rather than below the toolbar.
    private let contentGuide = NSLayoutGuide()

    /// What every surface in this pane pins its top to.
    var contentTopAnchor: NSLayoutYAxisAnchor { contentGuide.topAnchor }

    /// What the content guide currently hangs from — the header, or a notice band under it.
    private var contentTopConstraint: NSLayoutConstraint?

    /// The band standing between the header and the content, when there is one. Readable so a
    /// test can ask whether the pane is carrying a notice rather than search its subviews.
    private(set) var noticeView: NSView?

    private enum NoticeOwner: Equatable {
        case external
        case terminalTextVisibility(signature: String)
    }

    /// Recovery/crash notices outrank a terminal diagnostic. The issue remains pending while one
    /// of those stands, then takes the band only after that higher-priority notice leaves.
    private var noticeOwner: NoticeOwner?
    private var terminalTextVisibilityIssues: [
        TerminalInstanceIdentity: TerminalTextVisibilityIssue
    ] = [:]

    // MARK: - Lifecycle

    init(
        recovery: Bool = RecoveryMode.isActive,
        sessionComposerFactory: @escaping SessionComposerFactory = {
            SessionComposerViewController()
        }
    ) {
        isRecovery = recovery
        self.sessionComposerFactory = sessionComposerFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupDrawer()
        setupPlaceholder()
        setupGitStatusOverlay()
        if let storedComposerViewController {
            installComposerIfNeeded(storedComposerViewController)
        }
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
        // refresh reads memory, and the two transcript revalidations behind it are gated on the
        // file having grown and answer off the main thread.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.refreshGitStatusOverlayModel()
            // The workspace row rides the same event because every managed state change is a
            // store write: provisioning, the finish handshake's merge, a refusal. There is no
            // separate notification to observe, and this read is one dictionary lookup.
            self?.refreshGitStatusOverlayWorkspace()
            self?.refreshScheduledStateIfShowing()
        }
        appEvents.observe(ScheduledMessagesDidChange.self) { [weak self] _ in
            self?.refreshScheduledStateIfShowing()
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
        appEvents.observe(SessionInputControlDidChange.self) { [weak self] event in
            guard event.sessionID == self?.currentSessionID else { return }
            self?.refreshGitStatusOverlayAudience()
        }
        appEvents.observe(SessionAttachmentsDidChange.self) { [weak self] event in
            guard event.sessionID == self?.currentSessionID else { return }
            self?.refreshGitStatusOverlayAttachments()
        }
        appEvents.observe(SessionUsageDidChange.self) { [weak self] event in
            guard event.sessionID == self?.currentSessionID else { return }
            self?.refreshGitStatusOverlayUsage()
            self?.refreshGitStatusOverlaySubagents()
        }
        appEvents.observe(TerminalTextVisibilityIssueDetected.self) { [weak self] event in
            self?.terminalTextVisibilityIssueDetected(event.issue)
        }
        appEvents.observe(TerminalTextVisibilityIssuesInvalidated.self) { [weak self] event in
            self?.terminalTextVisibilityIssues.removeValue(forKey: event.identity)
            self?.refreshTerminalTextVisibilityNotice()
        }
    }

    /// The one place the corner card's room is re-measured.
    ///
    /// Both sides of that question move here and nowhere else: the pane's width, on a divider
    /// drag or a window resize, and the card's own width, when a branch name or a set of rows
    /// changes underneath it. A layout pass is what they have in common — the card is a subview
    /// with constraints, so its own resize brings the pane through here too.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateGitStatusOverlayVisibility(animated: true)
    }

    /// Shows or hides the corner card, and remembers the answer.
    ///
    /// The pane owns the toggle rather than the card, because the card is not the only thing
    /// that decides: a pane too narrow to carry it overrules the switch, and both answers have
    /// to be re-asked together or the card comes back the moment the window is resized.
    func toggleGitStatusOverlay() {
        StatusCardVisibility.isEnabled.toggle()
        if StatusCardVisibility.isEnabled,
           let sessionID = currentSessionID,
           let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
        {
            refreshGitStatusOverlayChangeRequest(
                for: sessionID,
                root: project.folderURL,
                forceRemote: false
            )
        } else if !StatusCardVisibility.isEnabled {
            stopGitStatusOverlayChangeRequest()
        }
        updateGitStatusOverlayVisibility(animated: true)
    }

    /// Whether the *user* has the card switched on — not whether it is on screen. The toolbar
    /// button reflects the standing choice, so a card withdrawn for width still reads as on:
    /// the button is what the press will do next, and a press on a narrow pane cannot be
    /// answered by showing a card there is no room for.
    var isGitStatusOverlayEnabled: Bool { StatusCardVisibility.isEnabled }

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
        // being attached. Let the header's own floor win for that one layout pass; once the
        // toolbar has established its inset, both constraints agree. Keeping this equality just
        // below required avoids a launch-time unsatisfiable-constraints warning without changing
        // the settled geometry.
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
            contentGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Everything else in the pane hangs off this rather than off the safe area directly, so
        // the header is the only place that knows where the pane's content begins — and, when a
        // notice band is standing between the two, the only place that knows it moved.
        pinContentTop(to: headerHost.bottomAnchor)
    }

    // MARK: - Notice Band

    /// Puts a band across the pane between the header and the content.
    ///
    /// It **pushes** rather than covers: the content guide is re-pinned under the band, so every
    /// surface in the pane moves down with it and nothing the notice says is said over something
    /// being read. One band at a time — a second replaces the first, because two stacked strips
    /// about different things read as chrome rather than as news.
    func showNotice(_ notice: NSView) {
        installNotice(notice, owner: .external)
    }

    /// Takes the band away and hands the pane's top edge back to the header.
    func dismissNotice() {
        removeInstalledNotice()
        refreshTerminalTextVisibilityNotice()
    }

    private func installNotice(_ notice: NSView, owner: NoticeOwner) {
        removeInstalledNotice()

        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        noticeView = notice
        noticeOwner = owner
        pinContentTop(to: notice.bottomAnchor)
    }

    private func removeInstalledNotice() {
        guard let noticeView else { return }
        noticeView.removeFromSuperview()
        self.noticeView = nil
        noticeOwner = nil
        pinContentTop(to: headerHost.bottomAnchor)
    }

    private func terminalTextVisibilityIssueDetected(_ issue: TerminalTextVisibilityIssue) {
        guard !TerminalTextVisibilityDismissals.shared.contains(issue) else { return }
        if terminalTextVisibilityIssues.count >= 32,
           terminalTextVisibilityIssues[issue.identity] == nil,
           let expired = terminalTextVisibilityIssues.keys.first
        {
            terminalTextVisibilityIssues.removeValue(forKey: expired)
        }
        terminalTextVisibilityIssues[issue.identity] = issue
        refreshTerminalTextVisibilityNotice()
    }

    private func refreshTerminalTextVisibilityNotice() {
        guard isViewLoaded else { return }
        // A launch/recovery notice has the band until its own action or dismissal releases it.
        if noticeOwner == .external { return }

        guard let issue = visibleTerminalTextVisibilityIssue(),
              !TerminalTextVisibilityDismissals.shared.contains(issue)
        else {
            if case .terminalTextVisibility? = noticeOwner { removeInstalledNotice() }
            return
        }

        if noticeOwner == .terminalTextVisibility(signature: issue.signature) { return }

        let notice = PaneNoticeView(
            tone: .attention,
            title: issue.title,
            message: issue.detail,
            // The pair as it was rendered, beside the sentence that spells it out in hex. Two
            // values four steps apart read as two colours in words and as one field on screen,
            // and the field is what the user was looking at when the text went missing.
            accessory: ColorPairSpecimenView(
                ink: issue.foregroundColor,
                ground: issue.backgroundColor,
                caption: L10n.string("As drawn"),
                accessibilityLabel: issue.specimenLabel
            ),
            actions: [
                PaneNoticeAction(title: L10n.string("Change Theme…")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.terminalContainer(
                        self,
                        didRequestSettingsPage: SettingsPages.themesID
                    )
                },
            ],
            onDismiss: { [weak self] in
                self?.dismissTerminalTextVisibilityIssue(issue)
            }
        )
        installNotice(notice, owner: .terminalTextVisibility(signature: issue.signature))
    }

    private func visibleTerminalTextVisibilityIssue() -> TerminalTextVisibilityIssue? {
        if let terminalID = currentTerminalID {
            return terminalTextVisibilityIssues[.projectTerminal(terminalID)]
        }
        guard let sessionID = currentSessionID else { return nil }
        if drawerHostController.isOpen(for: sessionID),
           let shellIssue = terminalTextVisibilityIssues[.sessionShell(sessionID)]
        {
            return shellIssue
        }
        guard currentChild?.sessionID == sessionID else { return nil }
        return terminalTextVisibilityIssues[.agentSession(sessionID)]
    }

    private func dismissTerminalTextVisibilityIssue(_ issue: TerminalTextVisibilityIssue) {
        TerminalTextVisibilityDismissals.shared.dismiss(issue)
        terminalTextVisibilityIssues = terminalTextVisibilityIssues.filter {
            $0.value.signature != issue.signature
        }
        removeInstalledNotice()
        refreshTerminalTextVisibilityNotice()
    }

    private func pinContentTop(to anchor: NSLayoutYAxisAnchor) {
        contentTopConstraint?.isActive = false
        let constraint = contentGuide.topAnchor.constraint(equalTo: anchor)
        constraint.isActive = true
        contentTopConstraint = constraint
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
            content.centerYAnchor.constraint(equalTo: headerHost.contentCenterYAnchor),
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

    /// Installs a composer that has actually been requested. Merely hiding or replacing a pane
    /// never crosses this boundary, which is what keeps a session-restoring launch from building
    /// an unused form.
    private func installComposerIfNeeded(_ controller: SessionComposerViewController) {
        guard isViewLoaded, controller.parent == nil else { return }

        addChild(controller)
        let composer = controller.view
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.isHidden = true
        // This matches the original eager hierarchy: the composer sits above the static pane
        // surfaces but below the status overlay, even when it materializes much later.
        view.addSubview(composer, positioned: .below, relativeTo: gitStatusOverlay)

        NSLayoutConstraint.activate([
            composer.topAnchor.constraint(equalTo: contentTopAnchor),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func hideComposerIfLoaded() {
        guard let controller = storedComposerViewController, controller.isViewLoaded else { return }
        controller.view.isHidden = true
    }

    /// Shows the composer for a project — or for none, the choose-a-project mode a store with
    /// no projects opens onto — replacing whatever session was on screen.
    ///
    /// Putting it back for the project it is already pointed at keeps it exactly as it was left:
    /// the agent, account, model and checkout just chosen, the half-written prompt and any
    /// attached images. Settings opening over the composer and a session looked at in between
    /// are both detours rather than a change of project, and neither should reset a decision
    /// the user is in the middle of making. The rule lives in `SessionComposerViewController`,
    /// which is what every route here goes through.
    func showComposer(projectID: ProjectID?) {
        // The composer is a form whose one button starts a session, so in recovery it is the
        // surface that gets shown instead — a form that cannot submit is a worse answer than the
        // screen saying why.
        if isRecovery {
            currentSessionID = nil
            currentTerminalID = nil
            showRecoverySurface()
            return
        }

        consumeComposerHandoff(for: nil)
        detachCurrentChild()
        currentComposerProjectID = projectID
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = nil

        // A shell belongs to a conversation; neither the composer nor a settings page is one, and
        // a drawer left standing under them draws a terminal through the form on top of it.
        applyDrawer(for: nil)

        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        let composerViewController = composerViewController
        composerViewController.view.isHidden = false
        applyPaneBackground(.chrome)
        composerViewController.show(projectID: projectID)
        composerViewController.focusPrompt()
    }

    func showManagerComposer(projectID: ProjectID) {
        showComposer(projectID: projectID)
        composerViewController.presetManagerRole()
    }

    /// Shows the authority-bearing trigger workspace as a first-class content destination.
    /// Unlike Settings it uses the full pane width and leaves the project sidebar in place.
    func showTriggers() {
        consumeComposerHandoff(for: nil)
        detachCurrentChild()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = nil
        applyDrawer(for: nil)
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()
        applyPaneBackground(.chrome)

        let controller = triggerCenter ?? TriggerCenterViewController()
        triggerCenter = controller
        addChild(controller)
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentTopAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Shows a settings page centred in the pane, replacing whatever session or composer was on
    /// screen. The section list lives in the sidebar; this only draws the chosen page.
    ///
    /// The page is pinned straight to the pane — centred, capped at the shared Settings width,
    /// and floored by margins — rather than through an intermediate container, which did not
    /// size its child.
    func showSettingsPage(id: String, revealing anchorTitle: String? = nil) {
        guard let definition = SettingsPages.page(id: id) else { return }

        currentSettingsPageID = id

        let cached = settingsPageCache[id]
        let page = cached ?? {
            let made = definition.make()
            settingsPageCache[id] = made
            return made
        }()

        install(settings: page, repaint: cached != nil)

        // After the pane's own layout pass, so the row the reveal scrolls to has a frame. A
        // page that cannot answer for the anchor — table-backed, or rebuilt by an extension —
        // just stays open, which is everything the click promised before reveals existed.
        if let anchorTitle {
            DispatchQueue.main.async { [weak page] in
                guard let page, page.isViewLoaded else { return }
                SettingsRowReveal.reveal(title: anchorTitle, in: page.view)
            }
        }
    }

    /// Shows the AI settings search surface and starts a run for the query.
    ///
    /// Kept as one controller across asks, like the page cache above, so a second question
    /// replaces the first's content rather than the whole surface. It is deliberately not in
    /// `settingsPageCache`: it has no page ID, and `currentSettingsPageID` goes nil so the
    /// toolbar does not claim a destination the sidebar cannot select.
    @discardableResult
    func showSettingsAISearch(query: String) -> SettingsAISearchViewController {
        let cached = settingsAISearch
        let controller = cached ?? SettingsAISearchViewController()
        settingsAISearch = controller

        currentSettingsPageID = nil
        install(settings: controller, repaint: cached != nil)
        controller.begin(query: query)
        return controller
    }

    /// Re-shows the AI search surface with whatever it last held, without starting a run —
    /// the Back path into suggestions the user navigated away from.
    func reshowSettingsAISearch() {
        guard let controller = settingsAISearch else { return }
        currentSettingsPageID = nil
        install(settings: controller, repaint: true)
    }

    /// Puts a settings-shaped child in the pane: centred, capped at the shared Settings width,
    /// floored by margins — pinned straight to the pane rather than through an intermediate
    /// container, which did not size its child.
    private func install(
        settings page: NSViewController,
        repaint: Bool
    ) {
        consumeComposerHandoff(for: nil)
        currentComposerProjectID = nil

        if settingsPage == nil {
            detachCurrentChild()
            currentTerminalID = nil
            currentSessionID = nil
            placeholderView.isHidden = true
            hideLaunchFailureIfNeeded()
            hideComposerIfLoaded()
            applyPaneBackground(.chrome)
            // The session's shell goes with the session — see `showComposer`.
            applyDrawer(for: nil)
        } else if let current = settingsPage {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        addChild(page)
        let content = page.view

        // A cached page was detached while the theme moved, and the sweep walks windows — so it
        // never reached this tree. Re-resolve it here rather than dropping the cache: rebuilding
        // would cost the page its scroll position and its controls' state to fix colours and
        // fonts that one walk can simply take again.
        if repaint { AppThemeRefresh.repaint(content) }

        // The shared canvas, stated once in `SettingsUI.install(page:in:top:)` so a page fixture
        // is under the same constraints as the pane it will ship in. Read that function before
        // changing anything here: the priorities in it are the fix for a page that came out at
        // its own fitting width inside a wider pane.
        SettingsUI.install(page: content, in: view, top: contentTopAnchor)

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
            drawerDivider.heightAnchor.constraint(equalToConstant: ShellDrawerDefaults.dividerHeight),
        ])

        // Installed once and never re-parented: the zero-high band hides it when closed, and a
        // session switch swaps which tab list it shows rather than which child sits here —
        // detaching per switch is what used to separate shells from their scrollback views.
        addChild(drawerHostController)
        drawerHostController.view.translatesAutoresizingMaskIntoConstraints = false
        drawerHost.addSubview(drawerHostController.view)
        let drawerContentBottom = drawerHostController.view.bottomAnchor.constraint(
            equalTo: drawerHost.bottomAnchor
        )
        // Closed means the host is exactly zero high, while the reusable controller retains a
        // real theme-dependent tab-strip constraint. Let the clipped child keep that intrinsic
        // floor for the closed pass instead of asking Auto Layout to break a required constraint.
        // The equality becomes satisfiable—and therefore exact—the moment the drawer opens.
        drawerContentBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            drawerHostController.view.topAnchor.constraint(equalTo: drawerHost.topAnchor),
            drawerContentBottom,
            drawerHostController.view.leadingAnchor.constraint(equalTo: drawerHost.leadingAnchor),
            drawerHostController.view.trailingAnchor.constraint(equalTo: drawerHost.trailingAnchor),
        ])
    }

    /// Opens or closes the drawer for the session on screen. Sessions keep their own answer, so
    /// a drawer opened for one conversation does not follow you into the next.
    func toggleShellDrawer() {
        guard let sessionID = currentSessionID else { return }

        let open = !drawerHostController.isOpen(for: sessionID)
        drawerHostController.setOpen(open, for: sessionID)
        applyDrawer(for: sessionID, focusing: open, animated: true)
    }

    var isShellDrawerOpen: Bool {
        currentSessionID.map { drawerHostController.isOpen(for: $0) } ?? false
    }

    /// Points the drawer host at the session and sizes the band to its open state. The host's
    /// children stay parented across every switch — only the visible list changes.
    ///
    /// `animated` is passed by the gestures — the toggle, a drag-shut, the drag spring — and
    /// left false by a session switch: the switch swaps the whole workspace at once, and the
    /// drawer sliding beside an instant page change would animate a change of subject as if it
    /// were a change of state. The motion itself is `PaneTransition`'s, the same one the
    /// window's split panes run.
    private func applyDrawer(
        for sessionID: SessionID?,
        focusing: Bool = false,
        animated: Bool = false
    ) {
        drawerTransitionGeneration += 1
        let generation = drawerTransitionGeneration

        guard let sessionID, drawerHostController.isOpen(for: sessionID) else {
            guard animated, !drawerHost.isHidden else {
                drawerHostController.showSession(nil)
                drawerHeight.constant = 0
                drawerDivider.isHidden = true
                drawerHost.isHidden = true
                refreshTerminalTextVisibilityNotice()
                return
            }

            // The tabs stay up while the band slides away; what the drawer shows is swapped
            // out only once there is no band left to see it in — and only if nothing has
            // reopened the drawer while the slide ran.
            PaneTransition.run(in: view) {
                drawerHeight.constant = 0
            } completion: { [weak self] in
                guard let self, self.drawerTransitionGeneration == generation else { return }
                self.drawerHostController.showSession(nil)
                self.drawerDivider.isHidden = true
                self.drawerHost.isHidden = true
            }
            refreshTerminalTextVisibilityNotice()
            return
        }

        // The default first tab: an opened drawer with nothing in it gets the session's shell.
        drawerHostController.ensureDefaultShellTab(for: sessionID)
        drawerHostController.showSession(sessionID)

        drawerHost.isHidden = false
        drawerDivider.isHidden = false
        let target = clampedDrawerHeight(drawerHeightValue)
        if animated, drawerHeight.constant != target {
            PaneTransition.run(in: view) {
                drawerHeight.constant = target
            }
        } else {
            drawerHeight.constant = target
        }
        if focusing { drawerHostController.focusActiveTab() }
        refreshTerminalTextVisibilityNotice()
    }

    /// The session's shell-drawer root process, when it has one. Asked by the info panel, which
    /// attributes a listening port to the shell or to the agent. Deliberately does *not* build a
    /// drawer: a session whose shell was never opened has no second origin to report.
    func shellRootPid(for sessionID: SessionID) -> pid_t? {
        drawerHostController.shellRootPid(for: sessionID)
    }

    /// Internal rather than private: the drag-shut tests drive the divider's two callbacks
    /// through these seams, because a synthesized `NSEvent` cannot carry the `deltaY` the real
    /// divider reports.
    func drawerDividerDragged(by delta: CGFloat) {
        // The pointer's own height, unclamped, so the release knows about travel the
        // constraint refused — then the constraint takes the clamped copy, exactly as before.
        let target = (drawerDragTargetHeight ?? drawerHeight.constant) - delta
        drawerDragTargetHeight = target
        drawerHeightValue = clampedDrawerHeight(target)
        drawerHeight.constant = drawerHeightValue
        ShellDrawerHeight.stored = drawerHeightValue
    }

    /// The drawer's copy of `SidebarSplitViewController.shutPaneIfPushedPast`: a release with
    /// the pointer pushed past the floor shuts the band, by the same rule and the same motion.
    /// The height the drawer reopens at is the one it had — the floor, recorded when the drag
    /// reached it — not the overshoot, which was never a height at all.
    func drawerDividerDragEnded() {
        defer { drawerDragTargetHeight = nil }
        guard let target = drawerDragTargetHeight,
              let sessionID = currentSessionID,
              drawerHostController.isOpen(for: sessionID),
              PaneTransition.dragShutsPane(thickness: target, floor: drawerFloor) else { return }

        drawerHostController.setOpen(false, for: sessionID)
        applyDrawer(for: sessionID, animated: true)
        // A drawer shut at its divider never reaches the window's toggle, so the window is
        // told — the split panes get this for free from their resize notifications.
        delegate?.terminalContainerDidChangeShellDrawer(self)
    }

    /// The least the drawer can be: its content's one honest line of output plus the strip
    /// band that rides on top of it.
    private var drawerFloor: CGFloat {
        ShellDrawerDefaults.minimumHeight + ThemedTabStripView.bandHeight
    }

    private func clampedDrawerHeight(_ height: CGFloat) -> CGFloat {
        let floor = drawerFloor
        let ceiling = max(floor, view.bounds.height * ShellDrawerDefaults.maximumHeightFraction)
        return min(max(height, floor), ceiling)
    }

    /// Test seam: the drawer's gestures need a session on screen, and the real route —
    /// `show(sessionID:)` — launches that session's agent, which a hosted test must never do.
    /// States the pane's subject without attaching any surface.
    func setCurrentSessionForTesting(_ sessionID: SessionID?) {
        currentSessionID = sessionID
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
        applyDrawer(for: sessionID, animated: true)
    }

    /// The opposite, for the drag spring's restore: a drawer opened for a drop that never
    /// came goes back where it was — tabs and their processes untouched.
    func collapseShellDrawer() {
        guard let sessionID = currentSessionID else { return }
        drawerHostController.setOpen(false, for: sessionID)
        applyDrawer(for: sessionID, animated: true)
    }

    /// Deletion sweep — forwarded here because the drawer host is this pane's child.
    func retainDrawerSessions(_ sessionIDs: Set<SessionID>) {
        drawerHostController.retainOnly(sessionIDs: sessionIDs)
    }

    func removeDrawerSession(_ sessionID: SessionID) {
        drawerHostController.removeSession(sessionID)
    }

    func removeDrawerSessions(_ sessionIDs: Set<SessionID>) {
        drawerHostController.removeSessions(sessionIDs)
    }

    /// Puts the failure surface in the pane the first time one is needed, in the placeholder's
    /// own frame so the two occupy exactly the same space and never both show.
    private func installLaunchFailureViewIfNeeded() {
        guard !isLaunchFailureViewInstalled else { return }
        isLaunchFailureViewInstalled = true

        view.addSubview(launchFailureView, positioned: .below, relativeTo: gitStatusOverlay)
        NSLayoutConstraint.activate([
            launchFailureView.topAnchor.constraint(equalTo: contentTopAnchor),
            launchFailureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            launchFailureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launchFailureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Takes the failure surface off the pane. Cheap and idempotent, so every route that shows
    /// something else can call it without asking whether a failure was on screen.
    private func hideLaunchFailureIfNeeded() {
        guard isLaunchFailureViewInstalled else { return }
        launchFailureView.isHidden = true
    }

    private func setupPlaceholder() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderView)

        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: contentTopAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public Methods

    /// Shows the given session, launching or resuming it when it has no live terminal.
    ///
    /// Selecting a dormant session is the "reopen" gesture: it resumes the prior
    /// conversation by identifier rather than starting a fresh one.
    func show(sessionID: SessionID?, initialPrompt: String? = nil) {
        // Recovery lists and selects but opens nothing: the sidebar is the evidence somebody in a
        // crash loop came for, and a row that could not be clicked would be a list pretending to
        // be a picture. The pane says so in words instead. This is the *visible* refusal; the
        // load-bearing one is at each surface's own `launch`, which every other route crosses.
        if isRecovery {
            currentSessionID = sessionID
            showRecoveryState(for: sessionID)
            return
        }

        // Spent before the early return as well, so a selection that changes nothing on screen
        // cannot leave a mark standing for some later attach to animate.
        let handsOverTheBox = consumeComposerHandoff(for: sessionID)

        guard sessionID != currentSessionID || settingsPage != nil || currentTerminalID != nil
            || currentSearchConversationWindow != nil
        else { return }

        // Read while the composer is still the visible surface: its frame and its picture are
        // both gone the moment the conversation takes the pane.
        let handoff = handsOverTheBox ? composerHandoffSnapshot() : nil

        detachCurrentChild()
        currentTerminalID = nil
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        applyDrawer(for: sessionID)

        guard let sessionID,
              let agentSession = ProjectStore.shared.session(withID: sessionID)
        else {
            currentSessionID = nil
            showEmptyState()
            return
        }

        if let scheduled = ScheduledMessageStore.shared.scheduledStart(for: sessionID) {
            applyDrawer(for: nil)
            showScheduledState(scheduled, session: agentSession)
            return
        }

        // **Looking at a failed session does not retry it.** Selecting a dormant row is the
        // reopen gesture, so without this a session whose resume the runtime refuses re-runs the
        // same doomed command on every click — each attempt spending a launch, a process and a
        // second of the user's attention to reproduce a failure they have already read. The
        // retry is a button on the surface below instead, which is a decision rather than a
        // side effect of navigating.
        if let failure = agentSession.lastLaunchFailure,
           !AgentRuntime.shared.hasTerminal(sessionID: sessionID)
        {
            applyDrawer(for: nil)
            showLaunchFailureState(failure, session: agentSession)
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
           let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
        {
            showConversation(
                agentSession,
                in: project,
                initialPrompt: effectiveInitialPrompt,
                handoff: handoff
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
        if isRecovery {
            currentTerminalID = terminalID
            showRecoveryState(for: nil)
            return
        }

        consumeComposerHandoff(for: nil)
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

    /// Launches a session's agent without putting it on screen, for the startup relaunch.
    ///
    /// The surface is built exactly as `show` would build it — same runtime cache, same
    /// delegate, so the sidebar's dot and the exit handling work unchanged — but it is never
    /// attached, and the pane keeps whatever it is showing. Selecting the session later takes
    /// the ordinary `show` path, which finds the terminal in the cache and only attaches.
    ///
    /// Laying the view out *before* the launch is load-bearing on the terminal path: SwiftTerm
    /// clamps an unlaid-out grid to its 2×1 minimum rather than zero, so the deferred-launch
    /// gate would pass and `forkpty` would take that as the winsize — the agent's TUI boots
    /// into a two-column window and renders garbage until something resizes it. The frame is
    /// this pane's own bounds where possible, so the eventual attach is not even a resize.
    /// `initialPrompt` is a message the caller wants this launch to carry — a scheduled send
    /// waking a session that had gone dormant. It takes precedence over the session's own
    /// continuation opening, which is the only prompt a relaunch used to have.
    ///
    /// **What it does with it differs by surface, and the difference is not cosmetic.** A native
    /// conversation is handed it over the stream, where an unready transport parks it in the
    /// visible outbox and sends it when the turn opens. A terminal is handed it as a launch
    /// argument, which only works for a session that has never run: `AgentLauncher` deliberately
    /// omits the prompt on `--resume`, and the alternative — typing into the TUI after it boots
    /// — is how a scheduled message ends up answering Claude's "summarise or read in full"
    /// question instead of being sent. `SessionCoordinator` is what decides a resumed terminal
    /// never gets one; this method simply cannot deliver it safely and does not pretend to.
    @discardableResult
    func launchInBackground(sessionID: SessionID, initialPrompt: String? = nil) -> Bool {
        guard !isRecovery else {
            RecoveryMode.refuse("a background session launch")
            return false
        }
        guard let agentSession = ProjectStore.shared.session(withID: sessionID),
              !agentSession.isArchived,
              !AgentRuntime.shared.hasTerminal(sessionID: sessionID) else { return false }

        let frame = NSRect(origin: .zero, size: backgroundLaunchSize)
        let openingPrompt = initialPrompt
            ?? ConversationContinuation.openingPrompt(for: agentSession)

        if agentSession.usesNativeUI,
           let project = ProjectStore.shared.executionProject(forSessionID: sessionID),
           let conversation = AgentRuntime.shared.makeConversation(
               for: agentSession,
               in: project
           )
        {
            conversation.delegate = self
            conversation.view.frame = frame
            conversation.view.layoutSubtreeIfNeeded()
            conversation.launch()
            if let openingPrompt, !openingPrompt.isEmpty {
                conversation.sendInitialPrompt(openingPrompt)
            }
            return true
        }

        let controller = AgentRuntime.shared.makeController(for: agentSession)
        controller.delegate = self
        controller.view.frame = frame
        controller.view.layoutSubtreeIfNeeded()
        // Nobody is looking: the resume's boot repaint must not read as a finished turn and
        // mark every restored session unread. See the tracker for what ends the grace.
        controller.activityTracker.noteUnattendedLaunch()
        controller.launch(initialPrompt: openingPrompt)
        return true
    }

    /// Reconnects a terminal to an agent `threading-ptyd` has been running since the last quit.
    ///
    /// The sibling of `launchInBackground` and built the same way — same runtime cache, same
    /// delegate, never attached — with one difference that is the whole point: **nothing is
    /// launched**. There is no plan, no `--resume`, and no boot. The agent has been working the
    /// whole time; this builds the surface that can show it again.
    ///
    /// The pane's own bounds are still the frame, for the reason `launchInBackground` gives, but
    /// the *grid* is the daemon's rather than this one's: an attach never resizes, so the replay
    /// is rendered at the size it was written at and only a genuinely different window sends a
    /// resize afterwards. A native conversation's child can be host-backed too, but it is never
    /// *reattached*: `PTYHostReattach` ends it and resumes the conversation from its transcript,
    /// because a request/response transport cannot be rejoined half-way through a turn. The guard
    /// stays here as well, so a summary that reached this call by another route is refused rather
    /// than silently given a terminal.
    @discardableResult
    func reattachInBackground(summary: PTYHostSessionSummary, socketPath: String) -> Bool {
        guard !isRecovery else {
            RecoveryMode.refuse("taking a session back from the PTY host")
            return false
        }
        guard let sessionID = summary.sessionID,
              let agentSession = ProjectStore.shared.session(withID: sessionID),
              !agentSession.isArchived,
              !agentSession.usesNativeUI else { return false }

        let controller = AgentRuntime.shared.makeController(for: agentSession)
        // A cached surface may be waiting for launch or displaying a previous refusal.
        // Allocation is not ownership. Reuse it, and leave an already attached child alone.
        if controller.isRunning { return controller.isHostBacked }
        controller.delegate = self
        controller.view.frame = NSRect(origin: .zero, size: backgroundLaunchSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller.reattachToBackgroundHost(
            socketPath: socketPath,
            grid: summary.grid
        )
    }

    /// The size a background-launched surface is laid out at before its process starts:
    /// this pane's, unless the launch outran the window's first real layout.
    private var backgroundLaunchSize: NSSize {
        let bounds = view.bounds.size
        guard bounds.width >= StartupRelaunchDefaults.minimumPaneDimension,
              bounds.height >= StartupRelaunchDefaults.minimumPaneDimension
        else {
            return StartupRelaunchDefaults.fallbackSize
        }
        return bounds
    }

    /// Relaunches the currently shown session, used by the dormant placeholder's button.
    func resumeCurrentSession() {
        guard let sessionID = currentSessionID else { return }

        // Force a fresh terminal so the resumed conversation starts from a clean screen.
        AgentRuntime.shared.discardForRelaunch(sessionID: sessionID)
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
        // Below the *divider*, not merely below the overlay: the surface's bottom edge and the
        // divider occupy the same 5pt band, so a surface inserted above it covers the drawer's
        // seam and takes its drags. The divider precedes the overlay, so this keeps both above.
        view.addSubview(controller.view, positioned: .below, relativeTo: drawerDivider)

        // Pinned to the safe area, which the toolbar insets for us.
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        currentChild = controller
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()

        // The terminal is inset below the toolbar, so the strip above it is the pane's own
        // background. Matching it to the terminal's colour keeps that strip — and the window's
        // rounded top corner — from showing the window's default grey against a themed terminal.
        applyPaneBackground(.terminal(controller.paneBackgroundColor))
        refreshGitStatusOverlayRunState()
        refreshGitStatusOverlaySubagents()
        refreshTerminalTextVisibilityNotice()
        controller.focusTerminal()
    }

    private func attachProjectTerminal(_ controller: ProjectTerminalViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // Same slot as `attach`: under the pane's own chrome, divider included.
        view.addSubview(controller.view, positioned: .below, relativeTo: drawerDivider)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        currentProjectTerminal = controller
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()
        applyPaneBackground(.terminal(controller.paneBackgroundColor))
        refreshTerminalTextVisibilityNotice()
        controller.focus()
    }

    // MARK: - Composer Handoff

    /// Marks the next attach of this session as the composer's own.
    ///
    /// Called before the sidebar selection that performs that attach. The coordinator knows a
    /// start came from the composer; the pane is what knows whether the surface arriving has a
    /// box to take the handoff, and whether the composer is still the thing on screen.
    func prepareComposerHandoff(for sessionID: SessionID) {
        pendingComposerHandoffSessionID = sessionID
    }

    /// Spends the mark: true only for the session it was left for, and only while the composer
    /// is still the visible surface.
    ///
    /// **Every** call clears it, which is the cancellation rule — a mark that survived one
    /// attach would animate some later conversation out of a composer nobody had typed in.
    @discardableResult
    func consumeComposerHandoff(for sessionID: SessionID?) -> Bool {
        guard let pending = pendingComposerHandoffSessionID else { return false }
        pendingComposerHandoffSessionID = nil
        guard pending == sessionID else { return false }
        guard let controller = storedComposerViewController, controller.isViewLoaded else {
            return false
        }
        return !controller.view.isHidden
    }

    private func composerHandoffSnapshot() -> ComposerHandoffAnimator.Snapshot? {
        guard let controller = storedComposerViewController, controller.isViewLoaded else {
            return nil
        }
        let composer = controller.view
        view.layoutSubtreeIfNeeded()
        return ComposerHandoffAnimator.snapshot(
            composer: composer,
            box: controller.promptHandoffView,
            in: view
        )
    }

    /// The box the user typed in travels to where the conversation replies from, and the rest
    /// of the composer leaves as a picture of itself.
    ///
    /// The destination frame does not exist until the pane has laid the conversation out, which
    /// is why this follows the attach rather than being arranged around it.
    private func runComposerHandoff(
        _ snapshot: ComposerHandoffAnimator.Snapshot?,
        into conversation: ConversationViewController
    ) {
        guard let snapshot else { return }

        view.layoutSubtreeIfNeeded()
        composerHandoff.run(
            snapshot,
            in: view,
            below: gitStatusOverlay,
            into: conversation.promptHandoffView,
            revealing: [conversation.scrollView]
        )
    }

    /// Installs the native conversation view for a session, launching it on first show.
    private func showConversation(
        _ agentSession: AgentSession,
        in project: Project,
        initialPrompt: String?,
        handoff: ComposerHandoffAnimator.Snapshot? = nil
    ) {
        let isNew = AgentRuntime.shared.conversation(for: agentSession.id) == nil
        guard let conversation = AgentRuntime.shared.makeConversation(
            for: agentSession,
            in: project
        ) else {
            ThreadingLogger.agent.error(
                "Refused native conversation for unsupported runtime \(agentSession.kind.rawValue, privacy: .public)"
            )
            return
        }
        conversation.delegate = self

        // See the terminal path above: the runtime must own the surface before visibility is
        // derived from the container's selection.
        currentSessionID = agentSession.id
        attachConversation(conversation)
        runComposerHandoff(handoff, into: conversation)

        guard isNew else { return }

        conversation.launch()

        // The composer's opening message is sent as the first turn rather than passed on the
        // command line: a streaming session has no positional prompt argument.
        if let initialPrompt, !initialPrompt.isEmpty {
            conversation.sendInitialPrompt(initialPrompt)
        }
    }

    /// Internal rather than private, like the divider's drag seams: the seam-visibility test
    /// attaches a real conversation through the production insertion without launching its
    /// agent, which the public route — `show(sessionID:)` — always does.
    func attachConversation(_ conversation: ConversationViewController) {
        addChild(conversation)
        conversation.view.translatesAutoresizingMaskIntoConstraints = false
        // Below the *divider*, not merely below the overlay — see `attach`. This shipped the
        // other way: every surface covered the drawer's seam, which made the one rule between
        // a conversation and its shell invisible and the grab strip under it undraggable.
        view.addSubview(conversation.view, positioned: .below, relativeTo: drawerDivider)

        NSLayoutConstraint.activate([
            // The conversation draws its own top inset, so it pinned to the pane's own top and
            // ran under the toolbar deliberately. The header is a real strip and cannot be run
            // under, so this is the one place that changes from `view.topAnchor`.
            conversation.view.topAnchor.constraint(equalTo: contentTopAnchor),
            conversation.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            conversation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conversation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        currentConversation = conversation
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()

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

    /// Mounts the bounded, source-validated reader used by a historical Search hit. It is a
    /// session surface for navigation and scope, but deliberately not a live conversation: no
    /// provider is launched and no composer or terminal input is admitted merely by searching.
    func showSearchConversationWindow(
        _ window: ConversationWindow,
        projectName: String,
        sessionTitle: String,
        providerName: String,
        onClose: @escaping @MainActor () -> Void
    ) {
        consumeComposerHandoff(for: nil)
        detachCurrentChild()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = window.sessionID
        applyDrawer(for: nil)

        let controller = ConversationSearchWindowViewController()
        controller.onClose = onClose
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: drawerDivider)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        controller.apply(ConversationSearchWindowPresentation(
            title: sessionTitle,
            subtitle: [
                projectName,
                providerName,
                window.isArchived ? L10n.string("Archived") : L10n.string("Search match"),
            ].joined(separator: " · "),
            rows: window.rows.map { row in
                ConversationSearchWindowRowPresentation(
                    id: row.id,
                    eyebrow: Self.searchHistoryEyebrow(for: row),
                    title: row.title.isEmpty ? nil : row.title,
                    body: row.body,
                    match: row.id == window.anchorRowID ? window.anchorMatch : nil,
                    isAnchor: row.id == window.anchorRowID
                )
            },
            anchorRowID: window.anchorRowID,
            hasEarlier: window.hasEarlier,
            hasLater: window.hasLater
        ))
        currentSearchConversationWindow = controller
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()
        applyPaneBackground(.chrome)
        refreshGitStatusOverlayRunState()
        refreshGitStatusOverlaySubagents()
    }

    private static func searchHistoryEyebrow(for row: ConversationWindowRow) -> String {
        let owner: String
        if row.hasError {
            owner = L10n.string("Error")
        } else if row.kind == .toolSummary {
            owner = L10n.string("Tool")
        } else {
            switch row.author {
            case .you: owner = L10n.string("You")
            case .agent: owner = L10n.string("Agent")
            case .system, .none: owner = L10n.string("System")
            }
        }
        guard let timestamp = row.timestamp else { return owner }
        return owner + " · " + DateFormatter.localizedString(
            from: timestamp,
            dateStyle: .medium,
            timeStyle: .short
        )
    }

    func showProjectTextSearchWindow(
        _ window: ProjectTextWindow,
        projectName: String,
        onClose: @escaping @MainActor () -> Void
    ) {
        consumeComposerHandoff(for: nil)
        detachCurrentChild()
        currentComposerProjectID = window.projectID
        currentSettingsPageID = nil
        currentTerminalID = nil
        currentSessionID = nil
        currentSearchFileRelativePath = window.relativePath
        applyDrawer(for: nil)

        let controller = ProjectTextSearchPreviewViewController()
        controller.onClose = onClose
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: drawerDivider)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentTopAnchor),
            controller.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        controller.apply(ProjectTextSearchPreviewPresentation(
            path: window.relativePath,
            project: projectName,
            lines: window.lines.map { line in
                ProjectTextSearchPreviewLinePresentation(
                    number: line.number,
                    text: line.text,
                    match: line.number == window.anchorLine ? window.anchorMatch : nil,
                    isAnchor: line.number == window.anchorLine
                )
            },
            anchorLine: window.anchorLine,
            hasEarlier: window.hasEarlier,
            hasLater: window.hasLater
        ))
        currentProjectTextSearchPreview = controller
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        hideComposerIfLoaded()
        applyPaneBackground(.chrome)
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
    /// Takes the typed ground rather than a colour because the backdrop's ownership travels with
    /// it: the split divider preserves themed border ink on chrome and derives neutral ink over a
    /// terminal palette. The chrome case also remains a live semantic role through a System
    /// light/dark switch rather than freezing the appearance resolved here — see
    /// `WindowBackdrop.Ground`.
    private func applyPaneBackground(_ ground: WindowBackdrop.Ground) {
        let color: NSColor
        switch ground {
        case .chrome: color = Design.Surface.ground
        case let .terminal(terminal): color = terminal
        }
        view.applyLayerBackground(color)

        // And record it as the window's backdrop, which reaches two readers. Whatever is drawn
        // directly on the window — the toolbar sits over this colour rather than over the
        // chrome's ground, so its ink comes from here. And the window itself: under a native
        // frame the terminal's colour is the backdrop the whole right side sits on, filling the
        // strip beneath the transparent toolbar and running into the window's rounded corners
        // instead of meeting the terminal in a hard edge. That painting is
        // `WindowChromeCoordinator`'s, not this pane's — under a shaped takeover the backing has
        // to stay clear behind the frame's curve, and a pane writing `window.backgroundColor`
        // on every session swap was painting the cleared corners opaque again.
        WindowBackdrop.set(ground)
    }

    private func detachCurrentChild() {
        // Anything else taking the pane cancels a handoff in flight: it lands on its end state
        // and takes its ghosts with it, rather than finishing a fade over the surface that
        // replaced the one it was carrying a box between.
        composerHandoff.finish()
        scheduledPlaceholderView?.isHidden = true

        if let triggerCenter, triggerCenter.view.superview != nil {
            triggerCenter.view.removeFromSuperview()
            triggerCenter.removeFromParent()
        }

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

        if let searchWindow = currentSearchConversationWindow {
            searchWindow.view.removeFromSuperview()
            searchWindow.removeFromParent()
            currentSearchConversationWindow = nil
        }

        if let preview = currentProjectTextSearchPreview {
            preview.view.removeFromSuperview()
            preview.removeFromParent()
            currentProjectTextSearchPreview = nil
            currentSearchFileRelativePath = nil
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
        // In recovery the empty pane is where the surface lives: this is the state the launch
        // opens into, and the screen explaining the launch is what belongs in it.
        guard !isRecovery else {
            showRecoverySurface()
            return
        }

        // With no projects at all, the empty pane *is* the way in: the composer in its
        // choose-a-project mode, not a placeholder describing where else to click.
        guard !ProjectStore.shared.projects.isEmpty else {
            showComposer(projectID: nil)
            return
        }

        currentComposerProjectID = nil
        currentSettingsPageID = nil
        currentTerminalID = nil
        hideComposerIfLoaded()
        placeholderView.isHidden = false
        hideLaunchFailureIfNeeded()
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

    private func showScheduledState(
        _ message: ScheduledMessage,
        session: AgentSession
    ) {
        guard case let .newSession(plan) = message.target else { return }
        let scheduledView = scheduledPlaceholderForPresentation()

        hideComposerIfLoaded()
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        recoveryView?.isHidden = true
        scheduledView.isHidden = false
        applyPaneBackground(.chrome)
        currentSessionID = session.id
        gitStatusOverlay.updateModel(nil)

        scheduledView.configure(.init(
            trigger: ScheduledTiming.automaticStartCauseSentence(
                for: message,
                watchedSessionTitle: watchedSessionTitle(for: message)
            ),
            problem: ScheduledTiming.problem(for: message.state),
            brief: message.summary,
            configuration: Self.scheduledConfiguration(plan)
        ))
        scheduledView.onStartNow = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainer(self, startScheduledMessageNow: message.id)
        }
        scheduledView.onEdit = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainer(self, editScheduledMessage: message.id)
        }
        scheduledView.onCancel = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainer(self, cancelScheduledMessage: message.id)
        }
    }

    private func watchedSessionTitle(for message: ScheduledMessage) -> String? {
        guard case let .sessionFinished(watchedSessionID) = message.trigger else { return nil }
        return ProjectStore.shared.session(withID: watchedSessionID)?.displayTitle
    }

    private func scheduledPlaceholderForPresentation() -> ScheduledSessionPlaceholderView {
        if let scheduledPlaceholderView { return scheduledPlaceholderView }
        let scheduled = ScheduledSessionPlaceholderView()
        scheduled.isHidden = true
        view.addSubview(scheduled, positioned: .below, relativeTo: drawerDivider)
        NSLayoutConstraint.activate([
            scheduled.topAnchor.constraint(equalTo: contentTopAnchor),
            scheduled.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scheduled.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scheduled.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        scheduledPlaceholderView = scheduled
        return scheduled
    }

    private func refreshScheduledStateIfShowing() {
        guard let sessionID = currentSessionID,
              scheduledPlaceholderView?.isHidden == false,
              let message = ScheduledMessageStore.shared.scheduledStart(for: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return }
        showScheduledState(message, session: session)
    }

    /// What a waiting start will be, as one line: the runtime, the login, the model, the
    /// posture, the checkout, the surface — and last, where there is one, the end it already
    /// carries.
    ///
    /// The end goes at the end of the line for the obvious reason and one better one: it is the
    /// only clause that is not a property of the agent, so keeping it apart from the others is
    /// what stops "Until 04:00" reading as another thing the model was configured with. Stated in
    /// the same words the composer's chip used when it was chosen, because a waiting row is read
    /// as the receipt for that choice.
    ///
    /// Static because nothing here is about this pane: it is a sentence made of a plan, which is
    /// how a test can ask what a plan reads as without standing a container up.
    static func scheduledConfiguration(_ plan: ScheduledSessionPlan) -> String {
        var parts = [plan.kind.displayName]
        if !plan.accountHandle.isStandard { parts.append(AccountPresentationLabels.name(for: AccountID(provider: plan.kind, handle: plan.accountHandle))) }
        if let model = plan.model { parts.append(ModelName.display(for: model)) }
        if let effort = plan.reasoningEffort {
            parts.append(AgentReasoningLevel(effort: effort, description: "").displayName)
        }
        if let fast = plan.fastMode {
            parts.append(fast ? L10n.string("Fast") : L10n.string("Standard"))
        }
        if let branch = plan.branch { parts.append(branch) }
        parts.append(plan.usesNativeUI ? L10n.string("Native chat") : L10n.string("Terminal"))
        if let curfew = CurfewMenu.title(
            for: plan.curfew,
            quietHours: CurfewSettings.shared.preferences.quietHours
        ) {
            parts.append(curfew)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Recovery

    /// Installs the surface this pane shows for the rest of a recovery launch.
    ///
    /// Held rather than rebuilt on every selection: it carries a button whose title is a state
    /// ("Extensions Will Stay Off Next Launch"), and a surface rebuilt under the user would lose
    /// what they had just pressed.
    func installRecoverySurface(_ surface: RecoveryModeView) {
        recoveryView?.removeFromSuperview()
        recoveryView = surface

        view.addSubview(surface, positioned: .below, relativeTo: drawerDivider)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentTopAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        showRecoverySurface()
    }

    /// Brings the surface back to the front of the pane — the band's "Show Options".
    func showRecoverySurface() {
        guard let recoveryView else { return }
        detachCurrentChild()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        hideComposerIfLoaded()
        placeholderView.isHidden = true
        hideLaunchFailureIfNeeded()
        recoveryView.isHidden = false
        applyPaneBackground(.chrome)
    }

    /// Takes the surface off the pane without ending recovery.
    func dismissRecoverySurface() {
        recoveryView?.isHidden = true
        showRecoveryState(for: currentSessionID)
    }

    /// What a selected session or terminal looks like when nothing will be opened for it.
    ///
    /// The placeholder rather than the surface: the surface answers "why is the app like this",
    /// which the band above already says, and repeating it on every click would bury the one
    /// sentence this moment needs. No action button — there is nothing here to press.
    private func showRecoveryState(for sessionID: SessionID?) {
        recoveryView?.isHidden = true
        hideComposerIfLoaded()
        placeholderView.isHidden = false
        hideLaunchFailureIfNeeded()
        currentComposerProjectID = nil
        currentSettingsPageID = nil
        applyPaneBackground(.chrome)

        let title = sessionID
            .flatMap { ProjectStore.shared.session(withID: $0)?.title }
            ?? L10n.string("Recovery Mode")
        placeholderView.configure(
            symbolName: "pause.circle",
            title: title,
            detail: L10n.string(
                "This session stays closed until Threading starts normally."
            )
        )
        placeholderView.onAction = nil
    }

    private func showDormantTerminalState(for terminalID: TerminalID) {
        guard let terminal = ProjectStore.shared.terminal(withID: terminalID) else {
            showEmptyState()
            return
        }

        hideComposerIfLoaded()
        placeholderView.isHidden = false
        hideLaunchFailureIfNeeded()
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

    func resumeCurrentTerminalIfNeeded() {
        guard let terminalID = currentTerminalID,
              !ProjectTerminalRuntime.shared.isRunning(terminalID: terminalID) else { return }
        resumeCurrentTerminal()
    }

    // MARK: - Launch Failure

    /// The pane for a session whose agent died on the way up.
    ///
    /// Deliberately not the dormant placeholder with different words. Dormant means "this ended
    /// and can be picked up"; this means "this did not start, and pressing the same button will
    /// do the same thing" — and the difference is the whole reason the surface exists.
    private func showLaunchFailureState(
        _ failure: SessionLaunchFailure,
        session: AgentSession
    ) {
        installLaunchFailureViewIfNeeded()
        hideComposerIfLoaded()
        placeholderView.isHidden = true
        recoveryView?.isHidden = true
        scheduledPlaceholderView?.isHidden = true
        launchFailureView.isHidden = false
        applyPaneBackground(.chrome)
        currentSessionID = session.id
        gitStatusOverlay.updateModel(nil)

        let sessionID = session.id
        launchFailureView.configure(
            title: L10n.format("%@ couldn’t start", session.displayTitle),
            summary: failure.summary,
            output: failure.detail,
            actions: launchFailureActions(failure, sessionID: sessionID)
        )
    }

    /// The ways out, in the order somebody actually tries them.
    ///
    /// Retry first because a launch failure is sometimes weather — a login that had just
    /// expired, a CLI mid-upgrade — and the cheapest correct move is to ask again. Reading and
    /// keeping the evidence comes next. Anything that reaches for another process is last, and
    /// only appears when there is something for it to work on.
    private func launchFailureActions(
        _ failure: SessionLaunchFailure,
        sessionID: SessionID
    ) -> [LaunchFailureAction] {
        var actions: [LaunchFailureAction] = [
            LaunchFailureAction(
                title: L10n.string("Try Again"),
                emphasis: .primary
            ) { [weak self] in
                self?.relaunchAfterFailure(sessionID: sessionID)
            },
            LaunchFailureAction(title: L10n.string("Copy Details")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(failure.report, forType: .string)
            },
            LaunchFailureAction(title: L10n.string("Report a Problem…")) { [weak self] in
                guard let self else { return }
                self.delegate?.terminalContainer(
                    self,
                    didRequestProblemReport: failure,
                    for: sessionID
                )
            },
        ]

        if LaunchRecoveryBrief.canAttempt(failure) {
            actions.append(
                LaunchFailureAction(title: L10n.string("Try Recovering with an Agent")) {
                    [weak self] in
                    guard let self else { return }
                    self.delegate?.terminalContainer(
                        self,
                        didRequestLaunchRecovery: failure,
                        for: sessionID
                    )
                }
            )
        }
        return actions
    }

    /// The retry the surface offers, which is the one route allowed past the selection gate.
    ///
    /// The record is cleared first so the relaunch is not immediately refused by the gate that
    /// sent us here. A second failure writes a second record, so nothing is lost by clearing an
    /// old one the user has decided to act on.
    private func relaunchAfterFailure(sessionID: SessionID) {
        ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.lastLaunchFailure = nil
        }
        currentSessionID = nil
        show(sessionID: sessionID)
    }

    private func showDormantState(for sessionID: SessionID) {
        guard let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            showEmptyState()
            return
        }

        hideComposerIfLoaded()
        placeholderView.isHidden = false
        hideLaunchFailureIfNeeded()
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
    ///
    /// A session that holds an identifier is not the same as a session that can be resumed with
    /// it. The optimistic sentence below was shown after a resume the runtime had just refused,
    /// beside a button that would refuse it again — which is how a placeholder ends up being the
    /// least accurate surface in the app. A session with a standing failure gets the launch
    /// failure surface instead of this one, and this sentence keeps the claim it can support.
    private func dormantDetail(for agentSession: AgentSession) -> String {
        if agentSession.lastLaunchFailure != nil {
            return L10n.string(
                "The last attempt to open this conversation did not finish."
            )
        }

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
        gitStatusOverlay.onOpenUsage = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalContainerDidRequestSessionInfo(self)
        }
        gitStatusOverlay.onOpenSubagents = { [weak self] in
            self?.openSubagents()
        }
        gitStatusOverlay.onOpenSharing = { [weak self] in
            self?.openSharing()
        }
        gitStatusOverlay.onOpenAttachment = { [weak self] attachmentID in
            guard let self else { return }
            self.delegate?.terminalContainer(
                self,
                didRequestAttachments: attachmentID
            )
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
            ),
        ])
    }

    /// Re-asks both halves of "is the card allowed here" and hands the card one answer.
    ///
    /// It is one answer on purpose. The card would otherwise have to reconcile a switch it
    /// cannot see with a width it cannot measure, and the two disagree constantly — every
    /// divider drag is a width change, and the switch outlives the session.
    func updateGitStatusOverlayVisibility(animated: Bool) {
        gitStatusOverlay.setAllowedOnScreen(
            StatusCardVisibility.isEnabled && paneHasRoomForGitStatusOverlay,
            animated: animated
        )
    }

    /// Whether the pane is wide enough to spend on a floating card.
    ///
    /// Measured against the card's *fitting* width rather than its frame: a withdrawn card has
    /// been laid out at that size all along, and asking the frame would make the answer depend
    /// on the answer — the card comes back, which makes it wide, which sends it away again.
    private var paneHasRoomForGitStatusOverlay: Bool {
        let cardWidth = gitStatusOverlay.fittingSize.width
        let paneWidth = view.bounds.width
        guard GitStatusOverlayDefaults.hasRoom(
            forCardWidth: cardWidth,
            inPaneWidth: paneWidth
        ) else { return false }

        // Terminal text owns the whole pane and accepts the half-width annotation rule above.
        // Conversation ink owns a centred readable column; a corner card is safe only in the
        // actual gutter beside that column. The display panel can narrow this pane without
        // making the card itself wide, which is the collision the generic share cannot see.
        guard currentConversation != nil else { return true }
        return GitStatusOverlayDefaults.hasRoomBesideConversation(
            forCardWidth: cardWidth,
            inPaneWidth: paneWidth
        )
    }

    /// Follows the selection: the card and its watcher serve the checkout on screen, and a
    /// pane showing no session — composer, settings, nothing — shows no card either.
    ///
    /// The loading raise is lowered on *every* way out, not just the read finishing while its
    /// session is still current. It used to ride only `onInitialReadComplete`, which dies with
    /// the monitor — so switching sessions before the first read of a big checkout landed left
    /// the abandoned row's spinner raised for the rest of the app's life. A monitor torn down
    /// here is a load this pane no longer serves, and saying so is this method's job; nothing
    /// downstream will.
    func updateGitChangeMonitor() {
        gitChangeMonitor?.stop()
        gitChangeMonitor = nil
        stopGitStatusOverlayChangeRequest()
        if let previous = gitStatusLoadingSessionID {
            gitStatusLoadingSessionID = nil
            delegate?.terminalContainer(self, gitStatusLoadingDidChange: false, for: previous)
        }
        gitStatusOverlay.clear()
        gitStatusOverlay.showSession(currentSessionID?.uuidString.lowercased())
        refreshGitStatusOverlayUsage()
        refreshGitStatusOverlaySubagents()
        refreshGitStatusOverlayModel()
        refreshGitStatusOverlayWorkspace()
        refreshGitStatusOverlayAudience()
        refreshGitStatusOverlayAttachments()

        if let currentSessionID {
            SessionUsageService.shared.refresh(currentSessionID)
        }

        // A remote project's checkout is on its host; the status card would otherwise report the
        // Mac folder's changes and branch as the agent's.
        guard let sessionID = currentSessionID,
              let project = ProjectStore.shared.executionProject(forSessionID: sessionID),
              project.executionHost == nil else { return }

        gitStatusLoadingSessionID = sessionID
        delegate?.terminalContainer(self, gitStatusLoadingDidChange: true, for: sessionID)

        gitChangeMonitor = GitChangeMonitor(
            root: project.folderURL,
            onChange: { [weak self] reading in
                guard let self, self.currentSessionID == sessionID else { return }
                self.gitStatusOverlay.update(with: reading)
                self.refreshGitStatusOverlayRunState()
                self.scheduleGitStatusOverlayChangeRequest(
                    for: sessionID,
                    root: project.folderURL
                )
            },
            onInitialReadComplete: { [weak self] in
                // Lowered for the session the raise was made for, current or not — the raise
                // is that session's row, and lowering an already-lowered reason costs nothing.
                guard let self else { return }
                if self.gitStatusLoadingSessionID == sessionID {
                    self.gitStatusLoadingSessionID = nil
                }
                self.delegate?.terminalContainer(
                    self,
                    gitStatusLoadingDidChange: false,
                    for: sessionID
                )
            }
        )

        guard gitChangeMonitor != nil else {
            gitStatusLoadingSessionID = nil
            delegate?.terminalContainer(
                self,
                gitStatusLoadingDidChange: false,
                for: sessionID
            )
            return
        }
        gitChangeMonitor?.start()
        refreshGitStatusOverlayRunState()
        if StatusCardVisibility.isEnabled {
            refreshGitStatusOverlayChangeRequest(
                for: sessionID,
                root: project.folderURL,
                forceRemote: false
            )
        }
    }

    /// Branch stays visible for the whole run. A structured provider checklist, when available,
    /// occupies its own row rather than replacing repository identity.
    func refreshGitStatusOverlayRunState() {
        guard gitChangeMonitor != nil else { return }

        let activity = currentConversation?.isTurnInFlight
            ?? currentChild?.activityTracker.runtimeSnapshot.hasOpenTurn
            ?? false
        gitStatusOverlay.updateRunState(
            isActive: activity,
            progress: currentConversation?.runProgress ?? currentChild?.runProgress
        )
    }

    /// Says that the chat on screen is working inside an isolated checkout Threading made for it,
    /// and what happens to that checkout when the agent says it is done.
    ///
    /// Read from the session record rather than from the directory: the states this row reports
    /// are Threading's own, and the one thing Git could contribute — a detached `HEAD` — is
    /// exactly why the card had nothing to say about a managed session before. See
    /// `GitStatusOverlayView.WorkspaceReading`.
    func refreshGitStatusOverlayWorkspace() {
        guard let sessionID = currentSessionID,
              let workspace = ProjectStore.shared.session(withID: sessionID)?.managedWorkspace
        else {
            gitStatusOverlay.updateWorkspace(nil)
            return
        }
        gitStatusOverlay.updateWorkspace(.init(workspace: workspace))
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
        let inputControl = RemoteSessionMirrorRegistry.shared.ownerInputControlState(
            for: sessionID
        )
        gitStatusOverlay.updateAudience(GitStatusOverlayView.AudienceReading(
            following: RemoteSessionMirrorRegistry.shared.followers(of: sessionID).count,
            isShared: RemoteAccessCoordinator.shared.hasSessionShares(sessionID),
            focusedControllerName: inputControl.mode == .focused
                ? inputControl.controllerDisplayName
                : nil
        ))
    }

    /// The card shows a fixed-size glimpse of the attachment chronology. The store revalidates
    /// its references before returning, so a file removed outside the app disappears here and in
    /// the pane through the same read gate.
    func refreshGitStatusOverlayAttachments() {
        guard let sessionID = currentSessionID else {
            gitStatusOverlay.updateAttachments(.init(attachments: []))
            return
        }
        gitStatusOverlay.updateAttachments(.init(
            attachments: SessionAttachmentStore.shared.attachments(for: sessionID)
        ))
    }

    /// Coalesces checkout bursts before the provider read. This callback is fed by files and
    /// index changes too, so one operation is still bounded by the remote cache below rather than
    /// turning a streamed edit into network traffic per filesystem event.
    func scheduleGitStatusOverlayChangeRequest(for sessionID: SessionID, root: URL) {
        guard StatusCardVisibility.isEnabled else { return }
        changeRequestDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentSessionID == sessionID else { return }
            self.refreshGitStatusOverlayChangeRequest(
                for: sessionID,
                root: root,
                forceRemote: false
            )
        }
        changeRequestDebounceWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + StatusCardRemoteDefaults.checkoutDebounce,
            execute: work
        )
    }

    /// Reads local repository state off-main through `ChangeRequestGit`, then performs one
    /// provider-neutral discovery. Only a connected request reaches the card; publication and
    /// every other write remain exclusively in Git Review.
    func refreshGitStatusOverlayChangeRequest(
        for sessionID: SessionID,
        root: URL,
        forceRemote: Bool
    ) {
        guard StatusCardVisibility.isEnabled, currentSessionID == sessionID else { return }
        changeRequestGeneration &+= 1
        let expected = changeRequestGeneration
        changeRequestTask?.cancel()
        changeRequestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await ChangeRequestGit.state(in: root)
                guard !Task.isCancelled,
                      expected == self.changeRequestGeneration,
                      self.currentSessionID == sessionID else { return }
                guard case let .supported(repository) = ChangeRequestRepository.detect(
                    remote: local.remote
                ) else {
                    self.lastChangeRequestReading = nil
                    self.gitStatusOverlay.updateChangeRequest(nil)
                    return
                }

                let signature = "\(local.branch):\(local.headRevision)"
                if !forceRemote,
                   let last = self.lastChangeRequestRead,
                   last.signature == signature,
                   Date().timeIntervalSince(last.date)
                   < StatusCardRemoteDefaults.remoteRefreshInterval
                {
                    if self.lastChangeRequestReading?.checks.shouldPoll == true {
                        self.scheduleGitStatusOverlayPendingChecks(
                            for: sessionID,
                            root: root
                        )
                    }
                    return
                }

                let outcome = await self.changeRequestProviders.discover(
                    repository: repository,
                    branch: local.branch,
                    headRevision: local.headRevision
                )
                guard !Task.isCancelled,
                      expected == self.changeRequestGeneration,
                      self.currentSessionID == sessionID else { return }
                self.lastChangeRequestRead = (signature, Date())
                switch outcome {
                case let .loaded(status):
                    let reading = GitStatusOverlayView.ChangeRequestReading(status: status)
                    self.lastChangeRequestReading = reading
                    self.gitStatusOverlay.updateChangeRequest(reading)
                    if reading?.checks.shouldPoll == true {
                        self.scheduleGitStatusOverlayPendingChecks(
                            for: sessionID,
                            root: root
                        )
                    }
                case .failed:
                    self.lastChangeRequestReading = nil
                    self.gitStatusOverlay.updateChangeRequest(nil)
                }
            } catch {
                guard !Task.isCancelled,
                      expected == self.changeRequestGeneration,
                      self.currentSessionID == sessionID else { return }
                self.lastChangeRequestReading = nil
                self.gitStatusOverlay.updateChangeRequest(nil)
            }
        }
    }

    /// Pending checks are the one remote fact whose value moves without a local checkout event.
    /// Poll only while that state is visible, with one replaceable work item per selected session.
    func scheduleGitStatusOverlayPendingChecks(for sessionID: SessionID, root: URL) {
        changeRequestPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentSessionID == sessionID,
                  StatusCardVisibility.isEnabled else { return }
            self.refreshGitStatusOverlayChangeRequest(
                for: sessionID,
                root: root,
                forceRemote: true
            )
        }
        changeRequestPollWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + StatusCardRemoteDefaults.pendingChecksPollInterval,
            execute: work
        )
    }

    /// Cancels every route by which a remote answer could repaint another session's card.
    func stopGitStatusOverlayChangeRequest() {
        changeRequestGeneration &+= 1
        changeRequestTask?.cancel()
        changeRequestTask = nil
        changeRequestDebounceWork?.cancel()
        changeRequestDebounceWork = nil
        changeRequestPollWork?.cancel()
        changeRequestPollWork = nil
        lastChangeRequestRead = nil
        lastChangeRequestReading = nil
        gitStatusOverlay.updateChangeRequest(nil)
    }

    /// Projects the provider-neutral hierarchy into the compact receipt beside Git status.
    func refreshGitStatusOverlaySubagents() {
        let timeline = currentConversation?.subagents
            ?? currentChild?.subagents
            ?? currentSessionID.map {
                AgentRuntime.shared.subagentState(for: $0).timeline
            }
        let usage = currentSessionID.flatMap {
            SessionUsageService.shared.snapshot(for: $0)?.subagents
        }
        gitStatusOverlay.updateSubagents(
            workingCount: timeline?.workingCount ?? 0,
            doneCount: timeline?.doneCount ?? 0,
            tokenCount: usage?.processedTokens
        )
    }

    /// Installs the immutable parent-plus-children receipt already projected off-main.
    func refreshGitStatusOverlayUsage() {
        guard let sessionID = currentSessionID else {
            gitStatusOverlay.updateUsage(nil)
            return
        }
        gitStatusOverlay.updateUsage(
            SessionUsageService.shared.snapshot(for: sessionID)?.total
        )
    }

    /// Feeds the card the agent facts *this pane* is responsible for showing.
    ///
    /// **A native conversation shows its own.** Its status row already carries model, effort and
    /// speed as chips directly above the composer, so the card would be saying them a second time
    /// in the same view — the rule the run spinner already follows.
    ///
    /// **A terminal session shows every fact this pane can extract**, whether or not the user's own
    /// Claude status line already prints one of them. Threading used to run the account's
    /// `statusLine` command and drop whichever facts it found in the output. That is gone: the
    /// probe was a subprocess per unseen command, a cache keyed on it, and a match rule whose only
    /// failure direction was hiding a fact the user asked for — bought against a fact appearing
    /// twice in one pane, which is the cheap outcome. See `ClaudeStatusLineSettings`.
    ///
    /// One fact is deliberately withheld rather than guessed. Fast mode is a reading only where
    /// Threading sets it: `appendCodexConversationOverrides` is Codex-only, and Claude's own
    /// fast-mode state is a *live* control-channel flag that its own `/fast` moves without
    /// writing anything down. `AgentModels.defaultFastMode` can now name the value a Claude
    /// session *launches* with — the composer chips say so, and that is honest there because
    /// nothing has started yet — but this card reports a session already running, where the
    /// launch value would be stale as soon as the live flag moves.
    /// Effort for a Claude terminal session is the account's configured value — what the CLI will
    /// inherit, which is the best answer available and goes stale the moment the user types
    /// `/effort`.
    func refreshGitStatusOverlayModel() {
        guard let sessionID = currentSessionID,
              let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.executionProject(forSessionID: sessionID),
              scheduledPlaceholderView?.isHidden != false,
              currentConversation == nil
        else {
            gitStatusOverlay.updateModel(nil)
            return
        }

        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        let configured = session.model ?? AgentModels.defaultModel(
            for: session.kind,
            account: account
        )
        // Neither source is set for a login that leaves the model to the CLI, and Claude then
        // picks its own from a layer this app does not read — which is how a session visibly
        // running Opus 5 reported only its effort. Its transcript records what actually
        // answered, so that is the third source; `known` reads memory, and the file is re-read
        // behind the paint. See `ClaudeTranscriptModel`.
        let transcript = observedModelTranscript(for: session, in: project)
        let observed = transcript.flatMap { ClaudeTranscriptModel.known(at: $0) }
        let model = configured ?? observed
        // A terminal session launched by alias teaches the login which version that alias is
        // today, as a native one does from its `init` — for a terminal, the transcript is where
        // the runtime reports it. The store keeps aliases only, so a versioned launch is skipped.
        if let account, let configured, let observed {
            ModelAliasResolutionStore.shared.record(observed, forLaunched: configured, in: account.id)
        }
        let effort = AgentModels.effectiveEffort(for: session, model: model, account: account)
        // A terminal can only report a Fast setting that exists before launch. A live
        // control-channel flag belongs to a running conversation, which this surface is not,
        // so its sessions report Standard rather than a state nothing here can observe.
        let isFast = session.kind.supports(.serviceTierFastMode)
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
            name: model.map { AgentModels.displayName(for: $0, account: account) },
            effort: effort.map {
                AgentReasoningLevel(effort: $0, description: "").displayName
            },
            isFast: isFast
        )

        // Behind the paint, never in front of it. The card shows what is already known and this
        // re-reads only when the transcript has grown, calling back only when the model moved —
        // so a `/model` lands on the card without a refresh per `ProjectsDidChange`, and the
        // first read of a freshly selected session arrives a beat later rather than stalling the
        // switch.
        // Re-read for a login that leaves the model to the CLI, and for a launch by alias, whose
        // version the transcript is a terminal's only source of. A launch naming its own version
        // has nothing left to learn and costs no read.
        if let transcript, configured.map({ !ModelName.isVersioned($0) }) ?? true {
            ClaudeTranscriptModel.revalidate(at: transcript) { [weak self] _ in
                guard let self, self.currentSessionID == sessionID else { return }
                self.refreshGitStatusOverlayModel()
            }
        }

        gitStatusOverlay.updateModel(reading)
    }

    /// The transcript whose records can name the model this session ran, or nil where none can.
    ///
    /// Claude only, and only once the conversation has an identifier: Codex records its model in
    /// a rollout of a different shape, and a session that has not been resumed or launched yet
    /// has nothing written to read. A path is returned whether or not the file exists —
    /// `ClaudeTranscriptModel` answers nothing for a file it cannot open, which is the same
    /// answer by a shorter route than a `fileExists` check on the main thread.
    private func observedModelTranscript(for session: AgentSession, in project: Project) -> URL? {
        guard session.kind.supports(.transcriptModelRecord),
              let transcriptID = session.resumeState.transcriptID
        else { return nil }

        return ClaudeTranscript.url(sessionID: transcriptID, for: session, in: project)
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
            case let .retryAfter(delay):
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
                state.replaceTranscriptConversation(
                    threadID: threadID,
                    events: events
                ) { [weak self, weak state] in
                    guard let self, let state else { return }
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
    }

    func agentSession(_ controller: AgentSessionViewController, didExitWithCode exitCode: Int32?) {
        // The agent exited: close its terminal but keep the sidebar entry so the
        // conversation can be resumed by identifier later.
        let sessionID = controller.sessionID
        let launchRefusal = controller.launchRefusal

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            AgentRuntime.shared.discard(sessionID: sessionID)

            if sessionID == self.currentSessionID {
                self.detachCurrentChild()
                // Disk exhaustion can refuse the failure record itself. The attempted launch's
                // diagnosis still belongs on this surface without waiting for a writable store.
                if let stored = ProjectStore.shared.session(withID: sessionID),
                   let failure = launchRefusal ?? stored.lastLaunchFailure
                {
                    self.showLaunchFailureState(failure, session: stored)
                } else {
                    self.showDormantState(for: sessionID)
                }
            }

            self.delegate?.terminalContainer(self, sessionDidExit: sessionID, exitCode: exitCode)
        }
    }

    func agentSessionDidChangeState(_ controller: AgentSessionViewController) {
        if controller.sessionID == currentSessionID {
            refreshGitStatusOverlayRunState()
        }
        AgentRuntime.shared.publishRuntimeChange(sessionID: controller.sessionID)
        RemoteSessionMirrorRegistry.shared.sessionRunProgressChanged(controller.sessionID)
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }

    func agentSessionSubagentsDidChange(_ controller: AgentSessionViewController) {
        guard controller.sessionID == currentSessionID else { return }
        SessionUsageService.shared.subagentsDidChange(for: controller.sessionID)
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
        startScheduledMessageNow id: ScheduledMessageID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        cancelScheduledMessage id: ScheduledMessageID
    )
    /// The scheduled surface's Edit: open the waiting record in its project's composer.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        editScheduledMessage id: ScheduledMessageID
    )
    func terminalContainer(
        _ container: TerminalContainerViewController,
        visibleSessionDidChange sessionID: SessionID?
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
    /// Its usage row was clicked: open the detailed receipt in Overview › Info.
    func terminalContainerDidRequestSessionInfo(_ container: TerminalContainerViewController)
    /// Its audience row was clicked: open who can reach this chat and who is on it.
    func terminalContainerDidRequestSharing(_ container: TerminalContainerViewController)
    /// One attachment row, or the bounded "View all" row, asked for the Attachments pane.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestAttachments attachmentID: String?
    )
    /// A turn's changed-files card asked for its immutable checkpoint diff.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestTurnDiff checkpointID: GitTurnCheckpointID
    )
    /// A native conversation's handoff divider asked to reveal its source session.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestOpenSession sessionID: SessionID
    )
    /// A native conversation invoked the app-owned `/usage` command.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestUsageFor accountID: AccountID?
    )
    /// The empty state's one action: begin a session, the same route ⌘N takes.
    func terminalContainerDidRequestNewSession(_ container: TerminalContainerViewController)
    /// The launch-failure surface asked to file this failure, with its captured output as
    /// evidence the user reads before anything is sent.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestProblemReport failure: SessionLaunchFailure,
        for sessionID: SessionID
    )
    /// The launch-failure surface asked for an agent to attempt a repair.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestLaunchRecovery failure: SessionLaunchFailure,
        for sessionID: SessionID
    )
    /// A diagnostic's remediation opens a settings page through the window, which owns the
    /// matching sidebar selection and navigation-history entry.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestSettingsPage pageID: String
    )
    /// The shell drawer opened or shut from inside the pane — a divider dragged past its
    /// floor — so the window's own controls must follow a change they did not make.
    func terminalContainerDidChangeShellDrawer(_ container: TerminalContainerViewController)
}

// MARK: - ConversationViewControllerDelegate

extension TerminalContainerViewController: ConversationViewControllerDelegate {
    func conversation(_ controller: ConversationViewController, didExitWithCode code: Int32) {
        if code == AgentChildProcessDefaults.spawnFailureStatus,
           controller.sessionID == currentSessionID,
           let stored = ProjectStore.shared.session(withID: controller.sessionID),
           let failure = stored.lastLaunchFailure
        {
            detachCurrentChild()
            showLaunchFailureState(failure, session: stored)
        }
        // After an ordinary exit the view is kept rather than swapped for the dormant
        // placeholder: the conversation it is showing is the only record of the turn on screen,
        // and the session can be resumed by selecting it again. A launch failure has no turn to
        // preserve and takes the shared launch-failure surface above.
        delegate?.terminalContainer(self, sessionDidExit: controller.sessionID, exitCode: code)
    }

    func conversation(
        _: ConversationViewController,
        didRequestTurnDiff checkpointID: GitTurnCheckpointID
    ) {
        delegate?.terminalContainer(self, didRequestTurnDiff: checkpointID)
    }

    func conversation(
        _: ConversationViewController,
        didRequestOpenSession sessionID: SessionID
    ) {
        delegate?.terminalContainer(self, didRequestOpenSession: sessionID)
    }

    func conversation(
        _: ConversationViewController,
        didRequestUsageFor accountID: AccountID?
    ) {
        delegate?.terminalContainer(self, didRequestUsageFor: accountID)
    }

    func conversationDidChangeActivity(_ controller: ConversationViewController) {
        if controller.sessionID == currentSessionID {
            refreshGitStatusOverlayRunState()
        }
        // Same channel a terminal session's activity uses, so the sidebar refreshes its row
        // and its attention dot the one way it already knows.
        AgentRuntime.shared.publishRuntimeChange(sessionID: controller.sessionID)
        RemoteSessionMirrorRegistry.shared.sessionRunProgressChanged(controller.sessionID)
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }

    func conversationSubagentsDidChange(_ controller: ConversationViewController) {
        guard controller.sessionID == currentSessionID else { return }
        SessionUsageService.shared.subagentsDidChange(for: controller.sessionID)
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
@MainActor
enum PaneHeaderDefaults {
    /// Deep enough for the tab and the icon buttons beside it, with air above and below.
    /// Read from `PaneHeaderView` so this strip and the sidebar's header band keep one
    /// silhouette: their hairlines land on the same line across the split.
    static var height: CGFloat { PaneHeaderView.bandHeight }

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
