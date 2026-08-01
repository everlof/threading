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
    private let agentKind: AgentKind
    private let subagentState: SubagentSessionState
    private let appEvents = AppEventObservations()

    private(set) var isRunning = false
    var subagents: SubagentTimeline { subagentState.timeline }
    var selectedSubagentThreadID: String? { subagentState.selectedThreadID }

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
    private let remoteViewportBanner = RemoteViewportBannerView()
    private var attachmentObserver: TerminalAttachmentObserver?
    private var selectedSubagentID: String?
    private var subagentTranscriptLoads = SubagentTranscriptLoadCache()
    private var transcriptRecheckGeneration: [String: Int] = [:]

    // MARK: - Initialization

    init(
        agentSession: AgentSession,
        subagentState: SubagentSessionState? = nil
    ) {
        self.sessionID = agentSession.id
        self.agentKind = agentSession.kind
        self.subagentState = subagentState
            ?? SubagentSessionState(sessionID: agentSession.id)
        self.session = TerminalSession(
            profile: ThemeAssignments.profile(for: agentSession.id),
            identity: .agentSession(agentSession.id)
        )
        super.init(nibName: nil, bundle: nil)
        session.delegate = self

        // The CLI hosted here is what a dropped image has to be readable by. The shell drawer
        // below it says nothing and keeps the default, which converts nothing.
        session.terminalView.dropReader = .agent(agentSession.kind)

        let terminalSession = session
        attachmentObserver = TerminalAttachmentObserver(
            sessionID: agentSession.id,
            projectRoot: {
                ProjectStore.shared.project(forSessionID: agentSession.id).map {
                    URL(fileURLWithPath: $0.folderPath, isDirectory: true)
                }
            },
            currentDirectory: { [weak terminalSession] in
                terminalSession?.effectiveWorkingDirectory()
            },
            text: { [weak terminalSession] in
                guard let terminal = terminalSession?.terminalView.getTerminal() else { return "" }
                let rendered = terminal.getBufferAsData()
                return String(
                    decoding: rendered.suffix(SessionAttachmentDefaults.maximumTerminalScanBytes),
                    as: UTF8.self
                )
            },
            isEnabled: {
                AppSettings.shared.detectsAttachmentReferences(for: agentSession.kind)
            }
        )

        activityTracker.markDormant()
        activityTracker.onChange = { [weak self] _ in
            guard let self else { return }
            self.delegate?.agentSessionDidChangeState(self)
        }
        self.subagentState.onChange = { [weak self] in
            self?.refreshSubagentState()
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
        view.addSubview(remoteViewportBanner)

        let terminalAtTopConstraint = session.terminalView.topAnchor.constraint(
            equalTo: view.topAnchor,
            constant: TerminalPadding.top
        )

        NSLayoutConstraint.activate([
            terminalAtTopConstraint,
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
            ),
            remoteViewportBanner.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.large
            ),
            remoteViewportBanner.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.large
            )
        ])

        applyBackgroundColor()
        selectedSubagentID = subagentState.selectedThreadID
        refreshSubagentState()

        // Two notifications, one response: the profile changed (font, cursor, the app-wide
        // default theme), or an assignment did (this session's, or its project's). Either way
        // the answer is to resolve *this* session's theme again rather than to adopt a value
        // the notification carried, which is what lets a narrower assignment survive a change
        // to a wider one.
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.themeDidChange() }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in
            self?.themeDidChange()
        }
        // A session set to "Follow App Theme" draws with a palette the app theme owns, so an app
        // theme switch is a terminal theme switch for it — and a no-op for every other session.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.themeDidChange() }
    }

    /// Fills the inset area with the terminal's own background so the padding reads as part
    /// of the terminal rather than a gap around it.
    private func applyBackgroundColor() {
        view.wantsLayer = true
        view.applyLayerBackground(session.terminalView.nativeBackgroundColor)
    }

    private func themeDidChange() {
        session.updateProfile(ThemeAssignments.profile(for: sessionID))
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
            ThreadingLogger.agent.error("Cannot launch session \(self.sessionID, privacy: .public): not found in store")
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
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
        session.terminate()
        isRunning = false
        activityTracker.markDormant()
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(session.terminalView)
    }

    func selectSubagent(_ threadID: String?) {
        guard let threadID,
              let selected = subagentState.timeline.agents.first(where: {
                  $0.descriptor.threadID == threadID
              }) else { return }

        selectedSubagentID = threadID
        subagentState.select(threadID: threadID)
        delegate?.agentSession(self, didSelectSubagent: selected)
        loadSubagentTranscriptIfNeeded(selected)
    }

    private func refreshSubagentState() {
        let timeline = subagentState.timeline
        let hasAgents = !timeline.agents.isEmpty

        guard hasAgents else {
            selectedSubagentID = nil
            delegate?.agentSessionSubagentsDidChange(self)
            return
        }

        if let selectedSubagentID,
           let selected = timeline.agents.first(where: {
               $0.descriptor.threadID == selectedSubagentID
           }) {
            delegate?.agentSession(self, didUpdateSelectedSubagent: selected)
            // Codex learns the real rollout filename from the stop hook, after the logical
            // child row already exists. Retry here when that descriptor becomes loadable.
            loadSubagentTranscriptIfNeeded(selected)
        }
        delegate?.agentSessionSubagentsDidChange(self)
    }

    private func loadSubagentTranscriptIfNeeded(_ agent: SubagentTimeline.Agent) {
        let threadID = agent.descriptor.threadID
        // Terminal mode has lifecycle hooks, not a structured child stream. Reading a growing
        // JSONL once would freeze a partial transcript behind the loaded-id cache, so wait for
        // the stop event and then replay the provider's completed file.
        guard agent.status.isDone,
              let signature = SubagentTranscriptLoader.signature(for: agent.descriptor),
              subagentTranscriptLoads.begin(
                  threadID: threadID,
                  signature: signature
              ) else {
            return
        }

        SubagentTranscriptLoader.load(
            descriptor: agent.descriptor,
            kind: agentKind
        ) { [weak self] events, isTruncated in
            guard let self else { return }
            switch self.subagentTranscriptLoads.finish(
                threadID: threadID,
                signature: signature,
                eventCount: events.count
            ) {
            case .retryAfter(let delay):
                self.scheduleTranscriptRecheck(threadID: threadID, after: delay)
                return
            case .unavailable:
                return
            case .loaded:
                self.subagentState.replaceConversation(
                    threadID: threadID,
                    events: events
                )
            }
            if isTruncated {
                self.subagentState.apply(.activity(
                    threadID: threadID,
                    text: ClaudeSubagentHistoryDefaults.truncatedActivity
                ))
            }
            self.refreshSubagentState()
            self.scheduleTranscriptStabilityChecks(threadID: threadID)
        }
    }

    private func scheduleTranscriptRecheck(threadID: String, after delay: TimeInterval) {
        let generation = (transcriptRecheckGeneration[threadID] ?? 0) + 1
        transcriptRecheckGeneration[threadID] = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.transcriptRecheckGeneration[threadID] == generation,
                  let agent = self.subagentState.timeline.agents.first(where: {
                      $0.descriptor.threadID == threadID
                  }) else {
                return
            }
            self.loadSubagentTranscriptIfNeeded(agent)
        }
    }

    private func scheduleTranscriptStabilityChecks(threadID: String) {
        let generation = (transcriptRecheckGeneration[threadID] ?? 0) + 1
        transcriptRecheckGeneration[threadID] = generation
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.transcriptRecheckGeneration[threadID] == generation,
                      let agent = self.subagentState.timeline.agents.first(where: {
                          $0.descriptor.threadID == threadID
                      }) else {
                    return
                }
                self.loadSubagentTranscriptIfNeeded(agent)
            }
        }
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
        if AppSettings.shared.remoteAccessEnabled {
            RemoteSessionMirrorRegistry.shared.beginCapturing(session, sessionID: sessionID)
        }

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

    /// Tells the delegate this session's stored record changed underneath it.
    ///
    /// Used where something outside the controller updates the session — adopting the
    /// identifier an agent reports through `SessionStart`, for one — and the sidebar still has
    /// to redraw.
    func noteStateChanged() {
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

            ThreadingLogger.agent.info("Discovered Codex session \(discoveredID, privacy: .public)")
            self.delegate?.agentSessionDidChangeState(self)
        }
    }
}

// MARK: - TerminalSessionDelegate

extension AgentSessionViewController: TerminalSessionDelegate {

    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {
        RemoteSessionMirrorRegistry.shared.sessionTitleChanged(sessionID, title: title)
        delegate?.agentSession(self, titleChangedTo: title)
    }

    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {
        RemoteSessionMirrorRegistry.shared.sessionResized(sessionID, cols: cols, rows: rows)

        // The agent will repaint in response; that is not it working.
        activityTracker.noteTerminalResized()

        // Layout has settled; complete a launch that was deferred for lack of dimensions.
        if pendingLaunchPlan != nil, cols > 0, rows > 0 {
            startIfTerminalIsSized()
        }
    }

    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    ) {
        if let grid {
            remoteViewportBanner.show(cols: grid.cols, rows: grid.rows)
        } else {
            remoteViewportBanner.hide()
        }
    }

    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {
        activityTracker.recordOutput(byteCount: byteCount)
        attachmentObserver?.noteOutput()
    }

    func terminalSessionDidRingBell(_ session: TerminalSession) {
        activityTracker.recordBell()
    }

    func terminalSessionDidForwardScroll(_ session: TerminalSession) {
        // The agent repaints its content in response; that is not it working.
        activityTracker.noteScrollForwarded()
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        attachmentObserver?.scanNow()
        isRunning = false
        activityTracker.markDormant()
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)

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

@MainActor
protocol AgentSessionViewControllerDelegate: AnyObject {
    func agentSession(_ controller: AgentSessionViewController, titleChangedTo title: String)
    func agentSession(_ controller: AgentSessionViewController, didExitWithCode exitCode: Int32?)
    func agentSessionDidChangeState(_ controller: AgentSessionViewController)
    func agentSessionSubagentsDidChange(_ controller: AgentSessionViewController)
    func agentSession(
        _ controller: AgentSessionViewController,
        didSelectSubagent agent: SubagentTimeline.Agent
    )
    func agentSession(
        _ controller: AgentSessionViewController,
        didUpdateSelectedSubagent agent: SubagentTimeline.Agent
    )
}

// MARK: - Remote Viewport Banner

/// Explains the otherwise surprising desktop shrink while the iPhone owns the PTY geometry.
/// It floats over the terminal's own palette, so its ink is derived from the active backdrop.
private final class RemoteViewportBannerView: BackdropOverlay {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: L10n.string("Fit to iPhone"))
    private let detailLabel = NSTextField(
        labelWithString: L10n.string("Mac size returns when the remote view closes")
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        wantsLayer = true
        layer?.cornerCurve = .continuous

        icon.image = NSImage(
            systemSymbolName: "iphone",
            accessibilityDescription: L10n.string("Controlled from iPhone")
        )
        icon.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.control,
            weight: .medium
        )
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.applyFont(.control)
        detailLabel.applyFont(.detail())
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [icon, labels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.medium
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            icon.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    override func applyInk(_ ink: Design.Ink) {
        layer?.cornerRadius = Design.Radius.control
        applyLayerBackground(ink.surface)
        layer?.borderWidth = Design.Radius.border
        applyLayerBorder(ink.border)
        icon.contentTintColor = ink.label
        titleLabel.textColor = ink.label
        detailLabel.textColor = ink.secondary
    }

    func show(cols: Int, rows: Int) {
        titleLabel.stringValue = L10n.format(
            "Fit to iPhone · %lld×%lld",
            Int64(cols),
            Int64(rows)
        )
        toolTip = L10n.string(
            "The iPhone controls the terminal size while its remote view is open."
        )
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
