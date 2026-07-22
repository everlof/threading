import AppKit
import SwiftTerm

/// Hosts the terminal for a single agent session.
///
/// The controller outlives any individual run of the agent: when the agent exits the
/// terminal stays allocated showing its final output, and the session can be relaunched
/// in place via `launch()`, which resumes the prior conversation when one exists.
final class AgentSessionViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    let session: TerminalSession

    private(set) var isRunning = false

    /// Derives whether the session is working, idle, or wants attention.
    let activityTracker = SessionActivityTracker()

    var activity: SessionActivity { activityTracker.activity }

    /// Whether this session is the one on screen. Clears any pending attention.
    var isVisible: Bool {
        get { activityTracker.isVisible }
        set { activityTracker.isVisible = newValue }
    }

    weak var delegate: AgentSessionViewControllerDelegate?

    /// The terminal's own background colour, so the pane hosting this controller can fill the
    /// strip beneath the toolbar to match rather than leaving the window's default showing.
    var paneBackgroundColor: NSColor { session.terminalView.nativeBackgroundColor }

    /// Set when the terminal is not yet large enough to start the process, so the launch
    /// can be retried from the size-change callback.
    private var pendingLaunchPlan: AgentLaunchPlan?

    // MARK: - Initialization

    init(agentSession: AgentSession) {
        self.sessionID = agentSession.id
        self.session = TerminalSession(
            profile: ProfileStorage.shared.defaultProfile,
            identifier: agentSession.id
        )
        super.init(nibName: nil, bundle: nil)
        session.delegate = self

        activityTracker.markDormant()
        activityTracker.onChange = { [weak self] _ in
            guard let self else { return }
            self.delegate?.agentSessionDidChangeState(self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Inset rather than filling the pane: SwiftTerm draws its first column hard against
        // the view's edge, which reads as cramped beside the sidebar divider.
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

        applyBackgroundColor()

        // The inset area is part of the terminal visually, so it tracks theme changes too.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(profileDidChange),
            name: .profileDidChange,
            object: nil
        )
    }

    /// Fills the inset area with the terminal's own background so the padding reads as part
    /// of the terminal rather than a gap around it.
    private func applyBackgroundColor() {
        view.wantsLayer = true
        view.layer?.backgroundColor = session.terminalView.nativeBackgroundColor.cgColor
    }

    @objc private func profileDidChange() {
        applyBackgroundColor()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusTerminal()
    }

    // MARK: - Public Methods

    /// Starts or resumes the agent.
    ///
    /// The launch is deferred to the next run loop pass so the terminal has been laid out
    /// and reports non-zero dimensions; otherwise the PTY would be sized 0x0.
    ///
    /// `initialPrompt` opens the conversation and applies to a first launch only; the
    /// launcher drops it on resume, where the conversation already has an opening.
    func launch(initialPrompt: String? = nil) {
        guard !isRunning else { return }

        guard let agentSession = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID) else {
            SkalmanLogger.agent.error("Cannot launch session \(self.sessionID, privacy: .public): not found in store")
            return
        }

        let plan = AgentLauncher.plan(for: agentSession, in: project, initialPrompt: initialPrompt)
        pendingLaunchPlan = plan

        DispatchQueue.main.async { [weak self] in
            self?.startIfTerminalIsSized()
        }
    }

    /// Terminates the agent, leaving the terminal view in place showing its final output.
    func terminate() {
        guard isRunning else { return }
        session.terminate()
        isRunning = false
        activityTracker.markDormant()
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(session.terminalView)
    }

    // MARK: - Private Methods

    private func startIfTerminalIsSized() {
        guard let plan = pendingLaunchPlan else { return }

        let terminal = session.terminalView.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else {
            return  // Retried from the sizeChanged callback once layout settles.
        }

        pendingLaunchPlan = nil
        isRunning = true
        activityTracker.markRunning()

        // The command line, before it runs. A launch that takes the app down with it leaves
        // this as the only account of what was being started.
        EventLog.shared.record(.session, "Launching agent", [
            "session": sessionID.uuidString,
            "command": ([plan.executable] + plan.arguments).joined(separator: " ")
        ])

        session.start(plan: plan)
        recordLaunch(plan: plan)
    }

    /// Persists what the launch established: that the session has run, and the identifier
    /// needed to resume it later.
    private func recordLaunch(plan: AgentLaunchPlan) {
        ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.hasLaunched = true
            stored.lastActiveAt = Date()
            stored.lastExitCode = nil
            stored.resumeState = plan.resumeState
        }

        if plan.resumeState == .awaitingIdentifier {
            discoverCodexSessionID()
        }

        delegate?.agentSessionDidChangeState(self)
    }

    /// Codex assigns its own identifier, so it is recovered from the rollout file it writes
    /// shortly after launch and stored for future resumes.
    ///
    /// Rollouts are written under the launching account's own home, so discovery is scoped
    /// to that account rather than the default one.
    private func discoverCodexSessionID() {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID),
              let agentSession = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: agentSession.kind,
                  handle: agentSession.accountHandle
              ) else { return }

        let launchedAt = Date()
        CodexSessionDiscovery.discoverSessionID(
            projectPath: project.folderPath,
            codexHome: account.configPath,
            launchedAt: launchedAt
        ) { [weak self] discoveredID in
            guard let self, let discoveredID else { return }

            ProjectStore.shared.update(sessionID: self.sessionID) { stored in
                stored.resumeState = .resumable(discoveredID)
            }

            SkalmanLogger.agent.info("Discovered Codex session \(discoveredID, privacy: .public)")
            self.delegate?.agentSessionDidChangeState(self)
        }
    }
}

// MARK: - TerminalSessionDelegate

extension AgentSessionViewController: TerminalSessionDelegate {

    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {
        delegate?.agentSession(self, titleChangedTo: title)
    }

    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {
        // The agent will repaint in response; that is not it working.
        activityTracker.noteTerminalResized()

        // Layout has settled; complete a launch that was deferred for lack of dimensions.
        if pendingLaunchPlan != nil, cols > 0, rows > 0 {
            startIfTerminalIsSized()
        }
    }

    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {
        activityTracker.recordOutput(byteCount: byteCount)
    }

    func terminalSessionDidRingBell(_ session: TerminalSession) {
        activityTracker.recordBell()
    }

    func terminalSessionDidForwardScroll(_ session: TerminalSession) {
        // The agent repaints its content in response; that is not it working.
        activityTracker.noteScrollForwarded()
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        isRunning = false
        activityTracker.markDormant()

        EventLog.shared.record(.session, "Agent exited", [
            "session": sessionID.uuidString,
            "exitCode": exitCode.map(String.init) ?? "unknown"
        ])

        ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.lastExitCode = exitCode
            stored.lastActiveAt = Date()
        }

        delegate?.agentSession(self, didExitWithCode: exitCode)
    }
}

// MARK: - AgentSessionViewControllerDelegate

protocol AgentSessionViewControllerDelegate: AnyObject {
    func agentSession(_ controller: AgentSessionViewController, titleChangedTo title: String)
    func agentSession(_ controller: AgentSessionViewController, didExitWithCode exitCode: Int32?)
    func agentSessionDidChangeState(_ controller: AgentSessionViewController)
}
