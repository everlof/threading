import AppKit

/// The application's single window: a project sidebar beside the active session's terminal.
final class MainWindowController: NSWindowController {

    // MARK: - Properties

    /// Not private: the toolbar delegate needs the split view for its tracking separator.
    private(set) var splitViewController: NSSplitViewController!
    private var sidebarViewController: ProjectSidebarViewController!
    private var containerViewController: TerminalContainerViewController!

    /// Retained so the sidebar can be collapsed and restored directly.
    private var sidebarItem: NSSplitViewItem!

    /// Opening prompt from the composer, handed to the next session that launches.
    /// Consumed once, so a later resume of the same session does not repeat it.
    private var pendingPrompt: String?

    /// The session that was on screen before Settings opened, restored when it closes.
    private var preSettingsSessionID: SessionID?

    /// The panel agents display content in, and its split item, retained so it can be
    /// revealed when content arrives.
    ///
    /// Not private: the MCP tool handlers put content into it. See `MainWindowMCPTools`.
    private(set) var displayPaneController: DisplayPaneController!
    private var displayItem: NSSplitViewItem!

    /// Suppresses width recording while the panel is being revealed, so the transient
    /// thickness that pass produces is not mistaken for a width the user chose.
    private var isRestoringDisplayPaneWidth = false

    /// Toolbar content naming the current project and session.
    let sessionTitleItemView = SessionTitleItemView()

    /// Toolbar pill showing the current account's rate-limit usage.
    let accountUsageItemView = AccountUsageItemView()

    /// The account the usage pill was last pointed at, so title churn does not re-run
    /// account discovery — agents rewrite the terminal title constantly, and each rewrite
    /// funnels through `updateSessionTitleItem`.
    private var usageAccountKey: AccountID?

    /// Exposed to the toolbar delegate, which needs the split view for its tracking separator.
    var splitView: NSSplitView { splitViewController.splitView }

    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?

    /// The session currently shown, if any.
    var currentSessionID: SessionID? {
        containerViewController.currentSessionID
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

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = SidebarDefaults.minWidth
        sidebarItem.maximumThickness = SidebarDefaults.maxWidth
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        containerViewController = TerminalContainerViewController()
        containerViewController.delegate = self
        containerViewController.composerViewController.delegate = self

        let contentItem = NSSplitViewItem(viewController: containerViewController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = MainWindowDefaults.minContentWidth
        splitViewController.addSplitViewItem(contentItem)

        setupDisplayPane()

        window?.contentViewController = splitViewController

        // Installed after the split view exists: the tracking separator item needs it.
        window?.toolbar = makeToolbar()

        // Compact, not `.unified`: the large style sizes system items (the sidebar toggle)
        // for a 15pt window title, which dwarfed the deliberately quiet 13pt session title
        // beside it. Compact sizes both to the same small scale.
        window?.toolbarStyle = .unifiedCompact

        unifySidebarWithBackdrop()
    }

    /// Makes the sidebar's material sample the window's own backdrop rather than the desktop,
    /// so the terminal colour set as the window background (see
    /// `TerminalContainerViewController.applyPaneBackground`) tints the sidebar too. The sidebar
    /// then reads as a translucent panel floating over the terminal's colour — no hard seam
    /// where a solid sidebar met a coloured terminal.
    private func unifySidebarWithBackdrop() {
        // The split item wraps the sidebar in a system `NSVisualEffectView`; find it and switch
        // its blending. Deferred a turn so the wrapper exists after the split view lays out.
        DispatchQueue.main.async { [weak self] in
            guard let effectView = self?.sidebarViewController.view.enclosingVisualEffectView else {
                return
            }
            effectView.blendingMode = .withinWindow
        }
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

        displayItem = NSSplitViewItem(viewController: displayPaneController)
        displayItem.canCollapse = true
        displayItem.minimumThickness = DisplayPaneDefaults.minWidth
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
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        guard let displayItem, !displayItem.isCollapsed, !isRestoringDisplayPaneWidth else {
            return
        }

        let width = displayItem.viewController.view.bounds.width
        guard width > 0 else { return }

        DisplayPaneWidth.stored = width
    }

    // MARK: - Display Pane

    /// Shows or hides the display panel.
    func setDisplayPaneVisible(_ visible: Bool) {
        guard displayItem.isCollapsed == visible else { return }

        guard visible else {
            displayItem.isCollapsed = true
            return
        }

        // Read *before* uncollapsing. The layout that follows fires resize notifications
        // carrying a transient thickness — the item's minimum — and recording that would
        // overwrite the width about to be restored with 260 on every first reveal.
        let target = DisplayPaneWidth.stored
        isRestoringDisplayPaneWidth = true
        displayItem.isCollapsed = false

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

    // MARK: - Public Methods

    /// Restores the session that was selected when the app last quit.
    func restoreSelectedSession() {
        guard AppSettings.shared.restoresLastSession,
              let sessionID = ProjectStore.shared.selectedSessionID,
              ProjectStore.shared.session(withID: sessionID) != nil else { return }

        sidebarViewController.select(sessionID: sessionID)
    }

    /// Shows or hides the sidebar. Shared by the View menu and the toolbar's system item.
    func toggleSidebar() {
        splitViewController.toggleSidebar(nil)
    }

    /// Keeps the toolbar naming whatever is on screen.
    func updateSessionTitleItem() {
        if containerViewController.isShowingSettings {
            sessionTitleItemView.configure(title: "Settings")
            updateAccountUsageItem(session: nil)
            return
        }

        let sessionID = containerViewController.currentSessionID
        let session = sessionID.flatMap { ProjectStore.shared.session(withID: $0) }

        sessionTitleItemView.configure(
            project: sessionID.flatMap { ProjectStore.shared.project(forSessionID: $0) },
            session: session
        )
        updateAccountUsageItem(session: session)
    }

    /// Points the usage pill at the shown session's account, or clears it.
    ///
    /// Skipped when the account is unchanged: this runs on every terminal-title rewrite,
    /// and account discovery reads the filesystem.
    private func updateAccountUsageItem(session: AgentSession?) {
        let key = session.map { AccountID(provider: $0.kind, handle: $0.accountHandle) }
        guard key != usageAccountKey else { return }
        usageAccountKey = key

        guard let session else {
            accountUsageItemView.configure(account: nil)
            return
        }

        accountUsageItemView.configure(
            account: AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)
        )
    }

    /// Opens Settings, or does nothing if already open. Used by the menu and ⌘,.
    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        guard !containerViewController.isShowingSettings else { return }
        toggleSettings()
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
            containerViewController.showSettingsPage(index: 0)
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
        let projectID: ProjectID?

        if let currentSessionID {
            projectID = ProjectStore.shared.project(forSessionID: currentSessionID)?.id
        } else {
            projectID = ProjectStore.shared.projects.first?.id
        }

        guard let projectID else {
            addProject()
            return
        }

        sidebarViewController.select(projectID: projectID)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to add as a project."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }

            let project = ProjectStore.shared.addProject(folderURL: url)
            self.sidebarViewController.reload()
            self.sidebarViewController.select(projectID: project.id)
        }
    }

    /// Closes the current session's terminal, leaving it dormant and resumable.
    func closeCurrentSession() {
        guard let currentSessionID else { return }
        guard confirmCloseIfRunning(sessionID: currentSessionID) else { return }

        containerViewController.closeTerminal(for: currentSessionID)
        sidebarViewController.refreshRows()
    }

    /// Asks before ending a running agent, when that preference is enabled.
    ///
    /// Returns true when closing should proceed.
    private func confirmCloseIfRunning(sessionID: SessionID) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let alert = NSAlert()
        alert.messageText = "Close \"\(session.displayTitle)\"?"
        alert.informativeText = session.kind.supportsResume
            ? "The agent will stop. The session stays in the sidebar and can be resumed."
            : "The shell will stop. The session stays in the sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
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
            context.duration = FindBarDefaults.animationDuration
            contentView.layoutSubtreeIfNeeded()
        }

        findBar?.focus()
    }

    func hideFindBar() {
        guard let contentView = window?.contentView, findBar != nil else { return }

        findBarTopConstraint?.constant = -FindBarDefaults.height
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = FindBarDefaults.animationDuration
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
        let prompt = pendingPrompt
        pendingPrompt = nil

        containerViewController.show(sessionID: sessionID, initialPrompt: prompt)
        syncDisplayPane(to: sessionID)
        sidebar.refreshRows()
        updateSessionTitleItem()
    }

    /// A project has no terminal of its own, so selecting one offers the composer: the
    /// choices that are only made when a session starts.
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: ProjectID) {
        containerViewController.showComposer(projectID: projectID)
        syncDisplayPane(to: nil)
        sidebar.refreshRows()
        updateSessionTitleItem()
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
            updateSessionTitleItem()
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
        guard confirmSurfaceSwitchIfRunning(sessionID: sessionID, toNative: usesNative) else {
            return
        }

        AgentRuntime.shared.discard(sessionID: sessionID)
        ProjectStore.shared.setUsesNativeUI(usesNative, for: sessionID)

        containerViewController.reopenIfShowing(sessionID: sessionID)
        sidebar.reload()
        updateSessionTitleItem()
    }

    /// Forks a session into a side chat and opens it.
    ///
    /// Nothing here stops the parent: a fork writes its own transcript, which is exactly what
    /// lets the side chat run *beside* a live session instead of queueing behind it — the one
    /// constraint the surface switch has and this does not.
    ///
    /// An opening question travels the same route the composer's does, through
    /// `pendingPrompt`, so "Ask on the Side…" needs no launch path of its own.
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        createSideChatOf sessionID: SessionID,
        prompt: String?
    ) {
        guard let session = ProjectStore.shared.addSideChat(of: sessionID) else { return }

        EventLog.shared.record(.composer, "Side chat forked", [
            "session": session.id.uuidString,
            "parent": sessionID.uuidString,
            "prompt": prompt ?? ""
        ])

        pendingPrompt = prompt

        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    /// Asks before a switch ends a running agent, under the same preference that guards
    /// closing one. The conversation survives either way; what is lost is the work in flight.
    private func confirmSurfaceSwitchIfRunning(sessionID: SessionID, toNative: Bool) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let surface = toNative ? "Conversation" : "Terminal"
        let alert = NSAlert()
        alert.messageText = "Show \"\(session.displayTitle)\" as \(surface.lowercased())?"
        alert.informativeText = """
            The agent stops and starts again on the new surface, resuming this conversation \
            where it left off. Anything it is working on right now is interrupted.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show as \(surface)")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
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
        updateSessionTitleItem()
    }

    func projectSidebarDidToggleSettings(_ sidebar: ProjectSidebarViewController) {
        toggleSettings()
    }

    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSettingsPage index: Int) {
        containerViewController.showSettingsPage(index: index)
    }
}

// MARK: - TerminalContainerViewControllerDelegate

// MARK: - SessionComposerViewControllerDelegate

extension MainWindowController: SessionComposerViewControllerDelegate {

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        branch: String?,
        usesNativeUI: Bool,
        prompt: String
    ) {
        // A branch other than this checkout's means the session belongs in the checkout
        // standing on it, which is a project of its own — the branch menu only offers
        // checkouts that exist, so this resolves unless one was removed since it opened.
        let targetProjectID = branch.flatMap {
            ProjectStore.shared.checkout(onBranch: $0, inRepositoryOf: projectID)
        } ?? projectID

        guard let session = ProjectStore.shared.addSession(
            to: targetProjectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI
        ) else { return }

        let opening = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Journalled before the draft is dropped, and before anything is launched. Between
        // those two points the prompt would otherwise live only in memory and in a command
        // line — which is precisely where it was when a crash took one.
        EventLog.shared.record(.composer, "Session started from composer", [
            "session": session.id.uuidString,
            "project": targetProjectID.uuidString,
            "agent": kind.rawValue,
            "account": accountHandle.name,
            "prompt": opening
        ])

        DraftStore.shared.clear(for: projectID)
        pendingPrompt = opening

        sidebarViewController.reload()
        sidebarViewController.select(sessionID: session.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    ) {
        guard let adopted = ProjectStore.shared.importSession(session, into: projectID) else {
            return
        }

        // Selected rather than launched: the conversation already exists, so showing it is
        // the resume, and the user decides when to reopen it.
        sidebarViewController.reload()
        sidebarViewController.select(sessionID: adopted.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {
        // Registering it as a project is what makes the new checkout selectable, and the
        // repository grouping picks it up automatically.
        let project = ProjectStore.shared.addProject(folderURL: url)
        sidebarViewController.reload()
        containerViewController.showComposer(projectID: project.id)
    }

}

extension MainWindowController: TerminalContainerViewControllerDelegate {

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

            // The tree probably changed too; an on-screen review tab refreshes itself.
            displayPaneController.noteSessionStoppedWorking(sessionID)

            // It also just spent tokens, so the finish is the moment the pill is most
            // likely stale. The service's spacing keeps a chatty session polite.
            if sessionID == currentSessionID, let account = accountUsageItemView.account {
                AccountUsageService.shared.refresh(account, force: true)
            }
        }
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
    static let animationDuration: TimeInterval = 0.2
}

// MARK: - Visual Effect Lookup

private extension NSView {
    /// The nearest visual-effect view at or above this one — e.g. the system material a
    /// sidebar split item wraps its content controller's view inside.
    var enclosingVisualEffectView: NSVisualEffectView? {
        var view: NSView? = self
        while let current = view {
            if let effect = current as? NSVisualEffectView { return effect }
            view = current.superview
        }
        return nil
    }
}
