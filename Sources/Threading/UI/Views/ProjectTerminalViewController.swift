import AppKit

@MainActor
protocol ProjectTerminalViewControllerDelegate: AnyObject {
    func projectTerminalDidChangeRunningState(_ controller: ProjectTerminalViewController)
}

/// Hosts one standalone project shell.
///
/// The controller is cached by `ProjectTerminalRuntime`, so removing it from the content pane
/// does not stop the shell or discard scrollback. Its durable model only remembers identity,
/// title, cwd, branch and theme; the process remains an in-memory concern.
@MainActor
final class ProjectTerminalViewController: NSViewController {
    let terminalID: TerminalID
    let session: TerminalSession
    weak var delegate: ProjectTerminalViewControllerDelegate?

    var isRunning: Bool { session.isRunning }
    var isBusy: Bool { session.hasForegroundProcess }
    var paneBackgroundColor: NSColor { session.terminalView.nativeBackgroundColor }

    private let appEvents = AppEventObservations()
    private let directoryTimer = MainRunLoopTimer()

    init(terminal: ProjectTerminal) {
        terminalID = terminal.id
        session = TerminalSession(
            profile: ThemeAssignments.profile(forTerminal: terminal.id),
            identity: .projectTerminal(terminal.id)
        )
        super.init(nibName: nil, bundle: nil)
        session.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        session.terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(session.terminalView)
        NSLayoutConstraint.activate([
            session.terminalView.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TerminalPadding.top
            ),
            session.terminalView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -TerminalPadding.bottom
            ),
            session.terminalView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: TerminalPadding.leading
            ),
            session.terminalView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -TerminalPadding.trailing
            )
        ])

        applyTheme()
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        // Project mutations can change the owning project's inherited theme.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in self?.applyTheme() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focus()
    }

    func startIfNeeded() {
        // A standalone terminal is a shell, not an agent, and recovery starts neither: the pane
        // opens nothing, and the same guard the two agent surfaces carry belongs here so a
        // terminal cannot be the one surface that came up.
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("a project terminal start")
            return
        }

        guard !session.isRunning,
              let terminal = ProjectStore.shared.terminal(withID: terminalID),
              let home = ProjectStore.shared.homeProject(forTerminalID: terminalID)
        else { return }

        let preferred = URL(fileURLWithPath: terminal.currentDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        let startDirectory = FileManager.default.fileExists(
            atPath: preferred.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
            ? preferred
            : home.folderURL

        session.startShell(initialDirectory: startDirectory)
    }

    /// Sends one already-validated project command to this terminal's interactive shell.
    /// Starting the shell and inserting the line happen only on this explicit call path; file
    /// discovery never reaches the PTY. The returned receipt says the command was accepted by
    /// a visible terminal, while the host-owned suffix printed there reports its eventual exit.
    func runProjectScript(
        _ invocation: ProjectScriptInvocation
    ) -> ProjectScriptExecutionReceipt? {
        startIfNeeded()
        guard session.isRunning else { return nil }

        session.insertText(ProjectScriptShellCommand.source(for: invocation) + "\n")
        return ProjectScriptExecutionReceipt(
            terminalID: terminalID,
            scriptID: invocation.script.id,
            workingDirectory: invocation.workingDirectory,
            previewURL: invocation.script.previewURL
        )
    }

    /// Runs provider-authored updater commands in this visible terminal after the user pressed
    /// the update toast's action. The plan is one shell command — several terminal lines, all of
    /// them continuations the shell consumes before it runs anything — so a provider prompt
    /// cannot consume a later provider's command as if the user had typed an answer.
    func runAgentCLIUpdates(
        _ plan: AgentCLIUpdateExecutionPlan
    ) -> AgentCLIUpdateExecutionReceipt? {
        startIfNeeded()
        guard session.isRunning else { return nil }

        session.insertText(plan.shellSource + "\n")
        return AgentCLIUpdateExecutionReceipt(
            terminalID: terminalID,
            toolIDs: plan.updates.map(\.id)
        )
    }

    func terminate() {
        directoryTimer.invalidate()
        session.terminate()
    }

    func focus() {
        view.window?.makeFirstResponder(session.terminalView)
    }

    private func applyTheme() {
        session.updateProfile(ThemeAssignments.profile(forTerminal: terminalID))
        view.wantsLayer = true
        view.applyLayerBackground(session.terminalView.nativeBackgroundColor)
    }

    private func notifyRunningState() {
        NotificationCenter.default.post(
            ProjectsDidChange(sidebarImpact: .terminalRow(terminalID))
        )
        delegate?.projectTerminalDidChangeRunningState(self)
    }

    private func startDirectoryTracking() {
        refreshFromProcess()
        directoryTimer.install(Timer.scheduledTimer(
            withTimeInterval: ProjectTerminalDefaults.directoryRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromProcess()
            }
        })
    }

    /// The two things about a running shell that change without producing any output we are
    /// told about: where it is, and what it is running. Both decide what the sidebar calls it.
    private func refreshFromProcess() {
        guard session.isRunning, session.shellPid > 0 else { return }

        if let directory = ProcessUtility.workingDirectory(forPid: session.shellPid) {
            ProjectStore.shared.updateTerminalLocation(directory.path, for: terminalID)
        }

        guard session.refreshForegroundProcess() else { return }
        // Retiring a title the last program left behind is a store edit; picking up a new
        // foreground command is not, since the derived name is computed rather than stored.
        // Only the second case still needs the row told.
        let titleChanged = ProjectStore.shared.updateTerminalTitle(
            session.reportedTitle,
            for: terminalID
        )
        if !titleChanged {
            NotificationCenter.default.post(
                ProjectsDidChange(sidebarImpact: .terminalRow(terminalID))
            )
        }
    }
}

extension ProjectTerminalViewController: TerminalSessionDelegate {
    func terminalSessionDidStart(_ session: TerminalSession) {
        startDirectoryTracking()
        // The agent surfaces begin capturing at launch so the ring follows a live terminal
        // before anybody attaches; a standalone shell is mirrored on the same terms, or a
        // client joining later replays only what it happened to be present for.
        if AppSettings.shared.remoteAccessEnabled {
            RemoteSessionMirrorRegistry.shared.beginCapturing(terminalID: terminalID)
        }
        notifyRunningState()
    }

    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {
        ProjectStore.shared.updateTerminalTitle(title, for: terminalID)
    }

    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {
        guard let directory else { return }
        ProjectStore.shared.updateTerminalLocation(directory.path, for: terminalID)
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        directoryTimer.invalidate()
        notifyRunningState()
    }
}

// MARK: - Project Terminal Runtime Composition

extension ProjectTerminalViewController: ProjectTerminalRuntimeSurface {
    var foregroundProcessName: String? { session.foregroundProcessName }
    var remoteTerminalSurface: any RemoteTerminalSurface { session }

    func removeFromPresentation() {
        view.removeFromSuperview()
        removeFromParent()
    }
}

extension ProjectTerminalRuntime {
    /// UI's concrete adapter lookup. Core retains only `ProjectTerminalRuntimeSurface`.
    func controller(for terminalID: TerminalID) -> ProjectTerminalViewController? {
        runtimeSurface(for: terminalID) as? ProjectTerminalViewController
    }

    /// Returns the cached controller for a terminal, creating it at the UI composition edge.
    func makeController(for terminal: ProjectTerminal) -> ProjectTerminalViewController {
        if let existing = controller(for: terminal.id) { return existing }

        let controller = ProjectTerminalViewController(terminal: terminal)
        precondition(
            registerRuntimeSurface(controller, for: terminal.id),
            "A project terminal runtime must have one UI adapter"
        )
        return controller
    }
}
