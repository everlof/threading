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

    private var session: TerminalSession!
    private let appEvents = AppEventObservations()

    /// Kept so a session's shell survives being switched away from and back: the process is the
    /// point, and a shell that forgets its directory and history on every tab change is a worse
    /// shell than the one in the terminal beside it.
    private(set) var hasStarted = false

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
        session = TerminalSession(profile: ThemeAssignments.profile(for: sessionID))
        session.terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(session.terminalView)

        NSLayoutConstraint.activate([
            session.terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            session.terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            session.terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            session.terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        applyBackground()
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.applyProfile() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in self?.applyProfile() }
    }

    // MARK: - Public Methods

    /// Starts the shell on first reveal, not at construction: a drawer that has never been
    /// opened should cost no process.
    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        session.startShell(initialDirectory: directory())
    }

    func focus() {
        view.window?.makeFirstResponder(session.terminalView)
    }

    func terminate() {
        guard hasStarted else { return }
        session.terminate()
        hasStarted = false
    }

    var backgroundColor: NSColor {
        session?.terminalView.nativeBackgroundColor ?? .textBackgroundColor
    }

    // MARK: - Private Methods

    private func applyProfile() {
        session.updateProfile(ThemeAssignments.profile(for: sessionID))
        applyBackground()
    }

    private func applyBackground() {
        view.layer?.backgroundColor = session.terminalView.nativeBackgroundColor.cgColor
    }
}

// MARK: - Defaults

enum ShellDrawerDefaults {
    /// Opening height, and the floor a drag can shrink it to — below this a shell shows one
    /// line of output and reads as broken rather than small.
    static let defaultHeight: CGFloat = 220
    static let minimumHeight: CGFloat = 80

    /// The drawer never takes the whole pane: the conversation above it is what it is *about*.
    static let maximumHeightFraction: CGFloat = 0.7

    /// The grab strip. Thin enough to read as a seam, thick enough to hit.
    static let dividerHeight: CGFloat = 5
}
