import AppKit

/// A shell, under the conversation it belongs to.
///
/// Shells used to be a *kind of session* — a row in the sidebar beside the chats, with a
/// title, a launch record and an account slot it could never use. That was the wrong shape:
/// a shell has no conversation to resume, nothing to import, no transcript, and none of the
/// state a session record exists to hold. What people actually want it for is running a
/// command *about* the conversation they are reading — so it belongs to that conversation,
/// as a surface, the way the review pane and the browser do.
///
/// It opens **where the agent currently is**, not where the session started. A terminal
/// session's shell reports its directory over OSC 7 and can be asked for it directly
/// (`TerminalSession.effectiveWorkingDirectory`), so an agent that has spent the last ten
/// minutes inside a subpackage hands its shell that subpackage. The project's folder is the
/// fallback, which is also exactly right for a natively-rendered conversation: there is no PTY
/// to ask, and the CLI was launched in that folder anyway.
///
/// It takes the session's **resolved terminal profile** too — the same
/// `ThemeAssignments.profile(for:)` the agent's own terminal uses — so a themed session's
/// drawer matches the surface above it rather than the app default.
final class ShellDrawerViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID

    /// Resolved when the shell is *started*, not when the drawer is built — an agent that has
    /// moved during its run has moved by then, and starting the shell where the session began
    /// would put it somewhere the conversation above it left long ago.
    private let directory: () -> URL

    private lazy var session = TerminalSession(
        profile: ThemeAssignments.profile(for: sessionID),
        identity: .sessionShell(sessionID)
    )
    private let appEvents = AppEventObservations()

    /// Kept so a session's shell survives being switched away from and back: the process is the
    /// point, and a shell that forgets its directory and history on every tab change is a worse
    /// shell than the one in the terminal beside it.
    private(set) var hasStarted = false

    /// What the tab strip calls this shell.
    ///
    /// Every drawer tab used to be the literal word "Terminal", which is no name at all once a
    /// session has two of them: the strip is the only thing telling one shell from another, and
    /// it was telling the user nothing. Derived on the same rules a standalone terminal's row
    /// uses (`TerminalNaming`), so both surfaces answer the same question the same way.
    private(set) var currentTitle = TerminalNamingDefaults.fallback

    /// Fired when `currentTitle` moves, so the host can persist and redraw the strip. The
    /// browser tab's `onPageChange` is the same seam for the same reason.
    var onTitleChange: (() -> Void)?

    private var titleTimer: Timer?

    // MARK: - Initialization

    init(sessionID: SessionID, directory: @escaping () -> URL) {
        self.sessionID = sessionID
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // The session's own theme, not the app default: a drawer under a themed terminal that
        // ignored the theme would read as a different application.
        session.terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(session.terminalView)

        // The same inset every terminal pane takes: SwiftTerm draws its first row hard
        // against the strip's rule and its first column against the pane's edge, and this
        // was the one flush terminal left. `applyBackground` paints the margin in the
        // terminal's own colour, so it reads as the terminal's air rather than a gap
        // around it.
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

        applyBackground()
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.applyProfile() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in self?.applyProfile() }
        // A session set to "Follow App Theme" draws with a palette the app theme owns, so an
        // app theme switch is a terminal theme switch for it — the other terminal hosts
        // already listen, and without this the margin painted above would keep the old
        // palette while the terminal repaints.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyProfile() }
    }

    // MARK: - Public Methods

    /// Starts the shell on first reveal, not at construction: a drawer that has never been
    /// opened should cost no process.
    func startIfNeeded() {
        guard !hasStarted else { return }
        // The drawer's shell is the fourth process this app can start, and recovery starts none
        // of the four. Refused before `hasStarted` is set, so the drawer opens for real on the
        // next normal launch rather than believing it already has.
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("a shell drawer start")
            return
        }
        hasStarted = true
        session.delegate = self
        session.startShell(initialDirectory: directory())
    }

    func focus() {
        view.window?.makeFirstResponder(session.terminalView)
    }

    /// The shell's own root process, for the info panel's attribution of processes and ports.
    ///
    /// Nil until the drawer has actually been revealed: a shell nobody opened has no process, and
    /// the panel should then say the session has one origin rather than an empty second one.
    var shellRootPid: pid_t? {
        guard hasStarted, isViewLoaded, session.shellPid > 0 else { return nil }
        return session.shellPid
    }

    func terminate() {
        guard hasStarted else { return }
        titleTimer?.invalidate()
        titleTimer = nil
        session.terminate()
        hasStarted = false
    }

    var backgroundColor: NSColor {
        guard isViewLoaded else { return Design.Surface.ground }
        return session.terminalView.nativeBackgroundColor
    }

    // MARK: - Private Methods

    private func applyProfile() {
        session.updateProfile(ThemeAssignments.profile(for: sessionID))
        applyBackground()
    }

    private func applyBackground() {
        view.applyLayerBackground(session.terminalView.nativeBackgroundColor)
    }

    /// A shell changes directory and starts commands without producing anything the app is
    /// otherwise told about, so the name has to be asked for rather than waited on. The
    /// standalone terminal polls on the same interval for the same reason.
    private func startTitleTracking() {
        titleTimer?.invalidate()
        refreshTitle()
        titleTimer = Timer.scheduledTimer(
            withTimeInterval: ProjectTerminalDefaults.directoryRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTitle()
            }
        }
    }

    private func refreshTitle() {
        guard session.isRunning, session.shellPid > 0 else { return }
        session.refreshForegroundProcess()

        // OSC 7 first, then the process's own cwd — not every shell reports the former, which
        // is the same fallback `TerminalSession.effectiveWorkingDirectory` makes.
        let directory = session.currentDirectory?.path
            ?? ProcessUtility.workingDirectory(forPid: session.shellPid)?.path
            ?? directory().path

        let title = TerminalNaming.displayTitle(
            // A drawer tab has no rename of its own: it is a surface under a conversation
            // rather than a record, and the conversation is what carries a chosen name.
            custom: nil,
            reported: session.reportedTitle,
            directory: directory,
            projectRoot: ProjectStore.shared.workingDirectory(forSessionID: sessionID),
            foregroundProcess: session.foregroundProcessName,
            shellPath: ProfileStorage.shared.defaultProfile.shellPath
        )

        guard title != currentTitle else { return }
        currentTitle = title
        onTitleChange?()
    }
}

// MARK: - TerminalSessionDelegate

extension ShellDrawerViewController: TerminalSessionDelegate {

    /// Tracking begins here rather than beside `startShell` so the first reading is taken once
    /// there is a pid to read: asked any earlier it finds no process and the tab keeps the
    /// placeholder until the first tick.
    func terminalSessionDidStart(_ session: TerminalSession) {
        startTitleTracking()
    }

    /// A program's own OSC title outranks anything derived, so the strip should show it at once
    /// rather than at the next poll.
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {
        refreshTitle()
    }

    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {
        refreshTitle()
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        titleTimer?.invalidate()
        titleTimer = nil
    }
}

// MARK: - Defaults

enum ShellDrawerDefaults {
    /// Opening height of the drawer's *content*, and the floor a drag can shrink it to —
    /// below this a shell shows one line of output and reads as broken rather than small.
    /// The tab strip's band rides on top of both; the container adds it when clamping.
    static let defaultHeight: CGFloat = 220
    static let minimumHeight: CGFloat = 80

    /// The drawer never takes the whole pane: the conversation above it is what it is *about*.
    static let maximumHeightFraction: CGFloat = 0.7

    /// The grab strip. Thin enough to read as a seam, thick enough to hit.
    static let dividerHeight: CGFloat = 5
}

// MARK: - Height Persistence

/// Remembers how tall the user left the drawer.
///
/// Kept out of `AppSettings` for the display-panel width's reason: this is window geometry,
/// and belongs with the frame autosave rather than beside deliberate preferences. One value
/// app-wide — a drawer height is a working preference for a window, not a fact about the
/// session, which is also why it was never in the session payload.
@MainActor
enum ShellDrawerHeight {
    private static let key = "ThreadingShellDrawerHeight"

    static var stored: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: key)
            // Absent, or below the floor a drag could ever reach, means "never set".
            guard saved >= ShellDrawerDefaults.minimumHeight else {
                return ShellDrawerDefaults.defaultHeight + ThemedTabStripView.bandHeight
            }
            return CGFloat(saved)
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: key)
        }
    }

    /// Forgets the height. On `.standard` like the value itself — this one is not routed through
    /// `PreferenceStore`, and a reset that cleared a different domain would clear nothing.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
