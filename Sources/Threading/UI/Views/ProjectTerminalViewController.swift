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
    var paneBackgroundColor: NSColor { session.terminalView.nativeBackgroundColor }

    private let appEvents = AppEventObservations()
    private var directoryTimer: Timer?

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
        // A cwd change may move this terminal under a differently themed project.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in self?.applyTheme() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focus()
    }

    func startIfNeeded() {
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

    func terminate() {
        directoryTimer?.invalidate()
        directoryTimer = nil
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
        directoryTimer?.invalidate()
        refreshFromProcess()
        directoryTimer = Timer.scheduledTimer(
            withTimeInterval: ProjectTerminalDefaults.directoryRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromProcess()
            }
        }
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
        directoryTimer?.invalidate()
        directoryTimer = nil
        notifyRunningState()
    }
}
