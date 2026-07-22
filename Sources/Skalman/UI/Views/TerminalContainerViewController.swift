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
    private(set) var currentSessionID: SessionID?

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
    private var settingsPageCache: [Int: NSViewController] = [:]

    /// Whether settings is the surface currently on screen, so the window can title the pane.
    var isShowingSettings: Bool { settingsPage != nil }

    weak var delegate: TerminalContainerViewControllerDelegate?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDrawer()
        setupPlaceholder()
        setupComposer()
        showEmptyState()

        // A theme change repaints the terminal but not the pane behind it, so the seam would
        // return until the next surface swap; re-apply the colour when the theme changes,
        // whether that was the app default or an assignment on this session or its project.
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.themeDidChange() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in
            self?.themeDidChange()
        }
    }

    /// Resolves the colour here rather than reading it off the terminal view, because the
    /// session controller observes the same notification and the order between two observers
    /// is not defined — reading its view could paint the pane the colour it is leaving.
    private func themeDidChange() {
        guard currentChild != nil || currentConversation != nil else { return }
        applyPaneBackground(ThemeAssignments.theme(for: currentSessionID).background)
    }

    /// The composer sits alongside the placeholder, hidden until a project is selected.
    private func setupComposer() {
        addChild(composerViewController)

        let composer = composerViewController.view
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.isHidden = true
        view.addSubview(composer)

        NSLayoutConstraint.activate([
            composer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// Shows the composer for a project, replacing whatever session was on screen.
    func showComposer(projectID: ProjectID) {
        detachCurrentChild()
        currentSessionID = nil
        AgentRuntime.shared.setVisibleSession(nil)

        placeholderView.isHidden = true
        composerViewController.view.isHidden = false
        applyPaneBackground(.windowBackgroundColor)
        composerViewController.show(projectID: projectID)
    }

    /// Shows a settings page centred in the pane, replacing whatever session or composer was on
    /// screen. The section list lives in the sidebar; this only draws the chosen page.
    ///
    /// The page is pinned straight to the pane — centred, capped at a readable width, floored by
    /// margins — rather than through an intermediate container, which did not size its child.
    func showSettingsPage(index: Int) {
        guard index >= 0, index < SettingsPages.all.count else { return }

        if settingsPage == nil {
            detachCurrentChild()
            currentSessionID = nil
            AgentRuntime.shared.setVisibleSession(nil)
            placeholderView.isHidden = true
            composerViewController.view.isHidden = true
            applyPaneBackground(.windowBackgroundColor)
        } else if let current = settingsPage {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        let page = settingsPageCache[index] ?? {
            let made = SettingsPages.all[index].make()
            settingsPageCache[index] = made
            return made
        }()

        addChild(page)
        let content = page.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        let preferred = content.widthAnchor.constraint(equalToConstant: Design.Size.readableWidth)
        preferred.priority = .defaultHigh

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            preferred,
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Design.Spacing.large),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Design.Spacing.large)
        ])

        settingsPage = page
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
            placeholderView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        guard sessionID != currentSessionID else { return }

        detachCurrentChild()
        currentSessionID = sessionID
        applyDrawer(for: sessionID)

        guard let sessionID,
              let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            AgentRuntime.shared.setVisibleSession(nil)
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

        // Only sessions off screen flag that they finished something.
        AgentRuntime.shared.setVisibleSession(sessionID)

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
        view.addSubview(controller.view)

        // Pinned to the safe area, which the toolbar insets for us.
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        applyPaneBackground(controller.paneBackgroundColor)
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

        AgentRuntime.shared.setVisibleSession(agentSession.id)
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
        view.addSubview(conversation.view)

        NSLayoutConstraint.activate([
            conversation.view.topAnchor.constraint(equalTo: view.topAnchor),
            conversation.view.bottomAnchor.constraint(equalTo: drawerHost.topAnchor),
            conversation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conversation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        currentConversation = conversation
        placeholderView.isHidden = true
        composerViewController.view.isHidden = true

        // A native conversation has no terminal, but it should read like one: the backdrop is
        // its resolved terminal theme's background, so it — and the sidebar sampling it — match a
        // Claude or shell session rather than the flatter `windowBackgroundColor`, which shows
        // through the sidebar's material as a subtly different tone. This is also the whole
        // extent to which a theme reaches a natively-rendered session: the conversation itself
        // is drawn in system colours, per the design system.
        applyPaneBackground(ThemeAssignments.theme(for: currentSessionID).background)
        conversation.focusPrompt()
    }

    /// Fills the pane behind its content. Only the strip above a toolbar-inset terminal ever
    /// shows it, but leaving a stale colour there is exactly the seam this avoids — so every
    /// surface swap sets it, resetting to the window's own colour for anything but a terminal.
    private func applyPaneBackground(_ color: NSColor) {
        view.layer?.backgroundColor = color.cgColor

        // Also paint the window itself, so the terminal's colour is the backdrop the whole
        // right side sits on: it fills the strip beneath the transparent toolbar and runs into
        // the window's rounded corners, instead of a neutral chrome meeting the terminal in a
        // hard edge. The sidebar's own material floats on top of this, unaffected.
        view.window?.backgroundColor = color
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
        composerViewController.view.isHidden = true
        placeholderView.isHidden = false
        applyPaneBackground(.windowBackgroundColor)
        placeholderView.onAction = nil
        placeholderView.configure(
            symbolName: "terminal",
            title: "No Session Selected",
            detail: "Select a session in the sidebar, or add a project to get started."
        )
    }

    private func showDormantState(for sessionID: SessionID) {
        guard let agentSession = ProjectStore.shared.session(withID: sessionID) else {
            showEmptyState()
            return
        }

        composerViewController.view.isHidden = true
        placeholderView.isHidden = false
        applyPaneBackground(.windowBackgroundColor)
        placeholderView.configure(
            symbolName: "arrow.clockwise.circle",
            title: "\(agentSession.title) ended",
            detail: dormantDetail(for: agentSession),
            actionTitle: agentSession.isResumable ? "Resume Session" : "Start Again"
        )
        placeholderView.onAction = { [weak self] in
            self?.resumeCurrentSession()
        }
    }

    /// Explains what resuming will do, which differs once a resumable identifier is known.
    private func dormantDetail(for agentSession: AgentSession) -> String {
        if agentSession.isResumable {
            return "The conversation is saved and will pick up where it left off."
        }

        if agentSession.kind.supportsResume {
            return "No saved conversation was found, so this will start fresh."
        }

        return "Starting again opens a new shell."
    }
}

// MARK: - AgentSessionViewControllerDelegate

extension TerminalContainerViewController: AgentSessionViewControllerDelegate {

    func agentSession(_ controller: AgentSessionViewController, titleChangedTo title: String) {
        // Agents report progress through the terminal title, so this drives the sidebar
        // name as well as the window subtitle.
        ProjectStore.shared.updateTerminalTitle(title, for: controller.sessionID)

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
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }
}

// MARK: - TerminalContainerViewControllerDelegate

protocol TerminalContainerViewControllerDelegate: AnyObject {
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
        // Same channel a terminal session's activity uses, so the sidebar refreshes its row
        // and its attention dot the one way it already knows.
        delegate?.terminalContainer(self, sessionStateDidChange: controller.sessionID)
    }
}


// MARK: - Drawer Divider

/// The grab strip above the shell drawer.
///
/// A hand-rolled divider rather than an `NSSplitView`, because the pane is not a split: the
/// conversation fills it and the drawer is a strip taken off the bottom. A split view would
/// bring its own collapse behaviour, its own delegate and its own idea of priorities, all of
/// which would have to be argued out of the way.
final class ShellDrawerDivider: NSView {

    /// Positive as the pointer moves down, which is the direction that *shrinks* the drawer.
    var onDrag: ((CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaY)
    }
}
