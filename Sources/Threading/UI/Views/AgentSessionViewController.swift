import AppKit
import SwiftTerm

/// Resolves the process behind a terminal session.
///
/// Production leaves this at `AgentLauncher`; the runtime can supply a per-session provider in
/// DEBUG builds so a deterministic fixture crosses the real PTY and app bridge without becoming
/// a shipping `AgentKind` or appearing in the composer.
typealias AgentLaunchPlanProvider = @MainActor (
    _ session: AgentSession,
    _ project: Project,
    _ initialPrompt: String?
) throws -> AgentLaunchPlan

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
    private let launchPlanProvider: AgentLaunchPlanProvider
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
    private var identifierLaunchDate: Date?
    private var isDiscoveringIdentifier = false
    private var nextIdentifierDiscoveryAt = Date.distantPast
    private let remoteViewportBanner = RemoteViewportBannerView()

    /// The one-tap way past a spent usage limit, under the terminal rather than over it.
    ///
    /// A terminal pane has no composer of its own — the box is inside the TUI — so the strip
    /// takes the place the composer occupies in a rendered conversation: the bottom of the
    /// column, on the terminal's own margins, directly under where the user types. It **pushes**
    /// rather than covers, the rule `PaneNoticeView` states: nothing it has to say is said over
    /// output somebody is reading.
    private lazy var limitEscapeStrip = LimitEscapeStripView()

    /// The terminal's lower edge, which belongs to the pane until the strip stands under it.
    private lazy var terminalAbovePane = session.terminalView.bottomAnchor.constraint(
        equalTo: view.bottomAnchor,
        constant: -TerminalPadding.bottom
    )
    private lazy var terminalAboveStrip = session.terminalView.bottomAnchor.constraint(
        equalTo: limitEscapeStrip.topAnchor,
        constant: -Design.Spacing.small
    )
    private var attachmentObserver: TerminalAttachmentObserver?
    private var transcriptAttachmentObserver: TerminalTranscriptAttachmentObserver?
    private var activityHadTurnInFlight = false
    private var selectedSubagentID: String?
    private var subagentTranscriptLoads = SubagentTranscriptLoadCache()
    private var transcriptRecheckGeneration: [String: Int] = [:]
    private var agentTitleRefreshWorkItem: DispatchWorkItem?
    private var codexTranscriptURL: URL?
    private var codexInterruptionRefreshWorkItem: DispatchWorkItem?
    private var claudeTranscriptURL: URL?
    private var claudeRefusalRefreshWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    init(
        agentSession: AgentSession,
        subagentState: SubagentSessionState? = nil,
        launchPlanProvider: AgentLaunchPlanProvider? = nil
    ) {
        self.sessionID = agentSession.id
        self.agentKind = agentSession.kind
        self.subagentState = subagentState
            ?? SubagentSessionState(sessionID: agentSession.id)
        self.launchPlanProvider = launchPlanProvider ?? { session, project, prompt in
            try AgentLauncher.plan(for: session, in: project, initialPrompt: prompt)
        }
        self.session = TerminalSession(
            profile: ThemeAssignments.profile(for: agentSession.id),
            identity: .agentSession(agentSession.id)
        )
        super.init(nibName: nil, bundle: nil)
        session.delegate = self

        // Names the tracker's log lines. A window holds dozens of these and every one of them
        // reports the same six states, so a trail that cannot say *which* session moved is a
        // trail nobody can follow back to a row.
        activityTracker.sessionID = agentSession.id

        // The CLI hosted here is what a dropped image has to be readable by. The shell drawer
        // below it says nothing and keeps the default, which converts nothing.
        session.terminalView.dropReader = .agent(agentSession.kind)

        let terminalSession = session
        attachmentObserver = TerminalAttachmentObserver(
            sessionID: agentSession.id,
            projectRoot: {
                ProjectStore.shared.executionProject(forSessionID: agentSession.id).map {
                    URL(fileURLWithPath: $0.folderPath, isDirectory: true)
                }
            },
            currentDirectory: { [weak terminalSession] in
                terminalSession?.effectiveWorkingDirectory()
            },
            text: { [weak terminalSession] in
                guard let terminal = terminalSession?.terminalView.getTerminal() else { return "" }
                return terminal.getRecentLogicalBufferText(
                    maximumUTF8Bytes: SessionAttachmentDefaults.maximumTerminalScanBytes
                )
            },
            isEnabled: {
                AppSettings.shared.detectsAttachmentReferences(for: agentSession.kind)
            }
        )
        transcriptAttachmentObserver = TerminalTranscriptAttachmentObserver(
            sessionID: agentSession.id,
            kind: agentSession.kind,
            projectRoot: {
                ProjectStore.shared.executionProject(forSessionID: agentSession.id).map {
                    URL(fileURLWithPath: $0.folderPath, isDirectory: true)
                }
            },
            currentDirectory: { [weak terminalSession] in
                terminalSession?.effectiveWorkingDirectory()
            },
            transcriptURL: { [weak self] in
                self?.attachmentTranscriptURL()
            },
            transcriptLookup: { [weak self] in
                self?.attachmentTranscriptLookup()
            },
            isEnabled: {
                AppSettings.shared.detectsAttachmentReferences(for: agentSession.kind)
            }
        )

        activityTracker.markDormant()
        activityTracker.onChange = { [weak self] activity in
            guard let self else { return }

            // Hooks are the exact boundary when they arrive, while the activity tracker also
            // owns the bounded quiet-period fallback for a provider whose hooks are missing.
            // Observe the shared edge so both routes recover intact transcript paths. A reported
            // turn with background work may remain visually `working`; AgentRuntime explicitly
            // scans that boundary because there is intentionally no activity edge to observe.
            let turnFinished = self.activityHadTurnInFlight && !activity.hasTurnInFlight
            // The same shared edge, the other way round, and the only honest answer to "when was
            // this conversation last used": it fires for a reported turn and for an inferred one,
            // and it cannot fire for the relaunch that merely brought the session back.
            let turnBegan = !self.activityHadTurnInFlight && activity.hasTurnInFlight
            self.activityHadTurnInFlight = activity.hasTurnInFlight
            if turnBegan {
                ProjectStore.shared.noteTurnStarted(sessionID: self.sessionID)
            }
            if turnFinished {
                self.noteTurnFinishedForAttachmentDetection()
            }
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
        view.addSubview(limitEscapeStrip)

        let terminalAtTopConstraint = session.terminalView.topAnchor.constraint(
            equalTo: view.topAnchor,
            constant: TerminalPadding.top
        )

        NSLayoutConstraint.activate([
            terminalAtTopConstraint,
            terminalAbovePane,
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
            ),

            // On the terminal's own margins, so the strip and the text it sits under share a
            // column rather than reading as two differently indented things.
            limitEscapeStrip.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: TerminalPadding.leading
            ),
            limitEscapeStrip.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -TerminalPadding.trailing
            ),
            limitEscapeStrip.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -TerminalPadding.bottom
            )
        ])

        wireLimitEscapeStrip()
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

    // MARK: - Limit Escape

    /// Draws the escape offer from the store, and reports both gestures back to it.
    ///
    /// One direction, like every other strip here: the store is the truth, this is drawn from it,
    /// and pressing is an announcement rather than an action — `SessionCoordinator` owns
    /// migrating a conversation and putting its pane back. See `SessionCoordinator+LimitEscape`.
    private func wireLimitEscapeStrip() {
        limitEscapeStrip.onContinue = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitEscapeRequested(sessionID: self.sessionID))
        }
        limitEscapeStrip.onWaitForReset = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitWaitForResetRequested(sessionID: self.sessionID))
        }
        limitEscapeStrip.onDismiss = { [weak self] in
            guard let self else { return }
            LimitEscapeSuggestionStore.shared.dismiss(self.sessionID)
        }
        appEvents.observe(LimitEscapeSuggestionDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.refreshLimitEscapeStrip()
        }
        refreshLimitEscapeStrip()
    }

    private func refreshLimitEscapeStrip() {
        let offer = LimitEscapeSuggestionStore.shared.offer(for: sessionID)
            .map(LimitEscapeStripView.Offer.init)
        limitEscapeStrip.setOffer(offer)

        // The terminal gives up the rows the strip stands in rather than being drawn over, so
        // the PTY is resized exactly once as the offer appears and once as it leaves.
        let isShowing = offer != nil
        guard terminalAboveStrip.isActive != isShowing else { return }

        // Deactivated before its replacement is activated, both ways round: two lower edges
        // active at once is an unsatisfiable pair, and AppKit says so in the log rather than
        // waiting for the next pass to sort it out.
        if isShowing {
            terminalAbovePane.isActive = false
            terminalAboveStrip.isActive = true
        } else {
            terminalAboveStrip.isActive = false
            terminalAbovePane.isActive = true
        }
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

        // The last line before a PTY exists, which is where recovery's refusal has to be. The
        // pane refuses earlier and more visibly, but this is the one every path crosses — a
        // remote resume, a scheduled send, a relaunch, an MCP tool — so a route that recovery
        // did not anticipate stops here rather than starting an agent.
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("an agent launch")
            return
        }

        guard let agentSession = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID) else {
            ThreadingLogger.agent.error("Cannot launch session \(self.sessionID, privacy: .public): not found in store")
            return
        }

        let plan: AgentLaunchPlan
        do {
            plan = try launchPlanProvider(agentSession, project, initialPrompt)
        } catch {
            // A runtime with no terminal surface has no command line to run here, and running
            // its interactive CLI anyway would open a different conversation from the one this
            // row names. The surface clamp keeps ordinary paths away from this; a route that
            // did not anticipate it stops rather than starting the wrong agent.
            ThreadingLogger.agent.error(
                "Cannot launch session \(self.sessionID, privacy: .public) in a terminal: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return
        }
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
        resetTranscriptFallbackObservation()
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(session.terminalView)
    }

#if DEBUG
    /// Starts a deterministic PTY for the opt-in cross-client browser journey. It exercises the
    /// shipping server, terminal mirror, WebSocket and composer without spending an agent turn
    /// or depending on a developer's Claude/Codex account. The test host owns the controller and
    /// removes the temporary project when the journey finishes.
    func startRemoteBrowserE2EFixture() {
        guard !isRunning else { return }
        _ = view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        view.layoutSubtreeIfNeeded()

        isRunning = true
        activityTracker.markRunning()
        RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: sessionID)
        session.start(plan: AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"""
                printf '\033[2J\033[HThreading remote E2E host\r\n'
                printf 'Atomic terminal composer ready.\r\nthreading-demo> '
                while IFS= read -r line; do
                  printf '\r\nreceived once: %s\r\n' "$line"
                  if [ "$line" = "finish-e2e" ]; then
                    printf 'E2E complete.\r\n'
                    exit 0
                  fi
                  printf 'threading-demo> '
                done
                """#,
            ],
            resumeState: .unavailable
        ))
    }
#endif

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
                self.subagentState.replaceTranscriptConversation(
                    threadID: threadID,
                    events: events
                ) { [weak self] in
                    guard let self else { return }
                    if isTruncated {
                        self.subagentState.apply(.activity(
                            threadID: threadID,
                            text: ClaudeSubagentHistoryDefaults.truncatedActivity
                        ))
                    }
                    self.scheduleTranscriptStabilityChecks(threadID: threadID)
                }
            }
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

        // Whatever the launch decided about this session stops being the reason it is dormant the
        // moment it runs. See `SessionRestorationLedger`.
        SessionRestorationLedger.shared.forget(sessionID: sessionID)

        let recorded = ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.hasLaunched = true
            stored.lastActiveAt = Date()
            stored.lastExitCode = nil
            stored.resumeState = plan.resumeState
        }
        guard recorded.succeeded else {
            pendingLaunchPlan = nil
            ThreadingLogger.agent.error(
                "Refused to launch session \(self.sessionID, privacy: .public): project state could not be saved"
            )
            let alert = ThemedAlert()
            alert.messageText = L10n.string("Couldn’t start")
            alert.informativeText = L10n.string("The project data could not be saved.")
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        pendingLaunchPlan = nil
        isRunning = true
        resetTranscriptFallbackObservation()
        activityTracker.markRunning()
        if AppSettings.shared.remoteAccessEnabled {
            RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: sessionID)
        }

        // The command line, before it runs. A launch that takes the app down with it leaves
        // this as the only account of what was being started.
        EventLog.shared.record(.session, "Launching agent", [
            "session": sessionID.uuidString,
            "command": ([plan.executable] + plan.arguments).joined(separator: " ")
        ])

        if plan.resumeState == .awaitingIdentifier {
            identifierLaunchDate = Date()
        }
        session.start(plan: plan)
        finishRecordedLaunch(plan: plan)
    }

    /// Starts discovery and repaint work after the process launch record has already committed.
    private func finishRecordedLaunch(plan: AgentLaunchPlan) {
        if plan.resumeState == .awaitingIdentifier {
            discoverAssignedSessionID()
        }

        if agentKind.supports(.providerTitleMetadata) {
            SessionNaming.refreshAgentTitle(forSessionID: sessionID)
        }

        delegate?.agentSessionDidChangeState(self)
    }

    /// Re-reads provider metadata on the quiet edge of a TUI repaint.
    ///
    /// Codex writes `session_index.jsonl` before confirming `/rename` in the terminal. Waiting
    /// for the output burst to settle gives that write time to finish and coalesces ordinary
    /// screen repaints to one small index scan.
    private func scheduleProviderTitleRefresh() {
        guard agentKind.supports(.providerTitleMetadata) else { return }

        agentTitleRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentTitleRefreshWorkItem = nil
            SessionNaming.refreshAgentTitle(forSessionID: self.sessionID)
        }
        agentTitleRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionNamingDefaults.providerTitleRefreshDelay,
            execute: item
        )
    }

    /// Tells the delegate this session's stored record changed underneath it.
    ///
    /// Used where something outside the controller updates the session — adopting the
    /// identifier an agent reports through `SessionStart`, for one — and the sidebar still has
    /// to redraw.
    func noteStateChanged() {
        delegate?.agentSessionDidChangeState(self)
    }

    /// Adopts the exact rollout path Codex included in a lifecycle report.
    ///
    /// The provider session id in the same report is preferred; a resumed session's stored id is
    /// the fallback. `CodexTranscript` validates both the account boundary and filename before
    /// caching the path, so output callbacks never enumerate the provider's growing session tree.
    func noteReportedCodexTranscript(
        path: String?,
        providerSessionID: TranscriptID?
    ) {
        guard agentKind.supports(.transcriptInterruptedTurnRecord),
              let path,
              let stored = ProjectStore.shared.session(withID: sessionID),
              let transcriptID = providerSessionID ?? stored.resumeState.transcriptID,
              let account = AgentAccountDiscovery.account(
                  for: stored.kind,
                  handle: stored.accountHandle
              ),
              let url = CodexTranscript.url(
                  reportedPath: path,
                  sessionID: transcriptID,
                  account: account
              ) else {
            return
        }

        codexTranscriptURL = url
        scheduleCodexInterruptionRefresh()
        scheduleClaudeRefusalRefresh()
    }

    /// A completed terminal turn has an intact provider message even when its TUI painted that
    /// message as independently positioned rows. The transcript observer reads it off-main and
    /// feeds only assistant prose through the ordinary attachment admission door.
    func noteTurnFinishedForAttachmentDetection(lastAssistantMessage: String? = nil) {
        transcriptAttachmentObserver?.noteTurnFinished(
            lastAssistantMessage: lastAssistantMessage
        )
    }

    private func attachmentTranscriptURL() -> URL? {
        switch agentKind {
        case .codex:
            // The reported hook path is exact and cached. Discovering it by walking Codex's
            // externally growing session tree is background work; see the lookup below.
            return codexTranscriptURL
        case .claude:
            return resolvedClaudeTranscriptURL()
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    /// A value-only fallback the observer may execute away from the main actor when Codex's
    /// lifecycle hook did not supply its rollout path.
    private func attachmentTranscriptLookup()
        -> TerminalTranscriptAttachmentObserver.TranscriptURLLookup? {
        guard agentKind.supports(.transcriptInterruptedTurnRecord),
              codexTranscriptURL == nil,
              let stored = ProjectStore.shared.session(withID: sessionID),
              let transcriptID = stored.resumeState.transcriptID,
              let account = AgentAccountDiscovery.account(
                  for: stored.kind,
                  handle: stored.accountHandle
              ) else {
            return nil
        }

        return {
            CodexTranscript.url(sessionID: transcriptID, account: account)
        }
    }

    /// Revalidates once after an output burst settles. The transcript reader performs the stat
    /// and capped tail scan off-main; this main-queue work is only cancellation and scheduling.
    private func scheduleCodexInterruptionRefresh() {
        guard codexTranscriptURL != nil else { return }

        codexInterruptionRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let url = self.codexTranscriptURL else { return }
            self.codexInterruptionRefreshWorkItem = nil

            CodexTranscriptInterruption.revalidate(at: url) { [weak self] interruption in
                guard let self, self.isRunning, self.codexTranscriptURL == url,
                      let interruption,
                      self.activityTracker.noteTurnInterrupted(turnID: interruption.turnID)
                else { return }

                ThreadingLogger.agent.info(
                    "Recovered interrupted Codex turn \(interruption.turnID, privacy: .public) from rollout"
                )
                EventLog.shared.record(.hooks, "Codex interruption recovered from transcript", [
                    "session": self.sessionID.uuidString,
                    "turn": interruption.turnID
                ])
            }
        }
        codexInterruptionRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CodexInterruptionDefaults.quietDelay,
            execute: item
        )
    }

    /// Revalidates once after an output burst settles, for the boundary Claude omits when a
    /// request fails outright.
    ///
    /// Gated on a turn actually being in flight, so a session sitting at its prompt does no work
    /// at all: the tracker would refuse the result anyway, and this is a terminal-output callback.
    /// The generation is read inside the work item rather than when it is scheduled, which is as
    /// late as it can be read and still be the turn the scan is about — narrowing the window this
    /// guards to the background read itself.
    private func scheduleClaudeRefusalRefresh() {
        guard agentKind.supports(.transcriptRefusedTurnRecord),
              activityTracker.reportsOwnActivity,
              activityTracker.activity.hasTurnInFlight,
              let url = resolvedClaudeTranscriptURL() else {
            return
        }

        claudeRefusalRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.claudeRefusalRefreshWorkItem = nil
            let generation = self.activityTracker.turnGeneration

            ClaudeTranscriptTurnRefusal.revalidate(at: url) { [weak self] refusal in
                guard let self, self.isRunning, self.claudeTranscriptURL == url,
                      let refusal,
                      self.activityTracker.noteTurnRefused(turn: generation)
                else { return }

                ThreadingLogger.agent.info(
                    "Recovered refused Claude turn (\(refusal.reason, privacy: .public)) from transcript"
                )
                EventLog.shared.record(.hooks, "Claude turn refusal recovered from transcript", [
                    "session": self.sessionID.uuidString,
                    "reason": refusal.reason,
                    "message": refusal.message
                ])
            }
        }
        claudeRefusalRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClaudeRefusalDefaults.quietDelay,
            execute: item
        )
    }

    /// Where this session's Claude transcript is, derived from the session's own record rather
    /// than from a path a hook reported: the id is Threading's own, minted before launch, so
    /// there is nothing here to validate an outside string against.
    ///
    /// Resolved once per launch and then remembered, because the last step of it asks
    /// `AgentAccountDiscovery`, whose cache expires after seven seconds and rescans the config
    /// directories when it does — which is not work a terminal-output callback may repeat. The
    /// two store lookups are checked *first* for the same reason: a session whose identifier has
    /// not been recorded yet answers nil without ever reaching the scan, and is asked again on
    /// its next burst rather than being written off for the rest of the process.
    private func resolvedClaudeTranscriptURL() -> URL? {
        if let claudeTranscriptURL { return claudeTranscriptURL }

        guard let session = ProjectStore.shared.session(withID: sessionID),
              let transcriptID = session.resumeState.transcriptID,
              let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
        else { return nil }

        claudeTranscriptURL = ClaudeTranscript.url(
            sessionID: transcriptID,
            for: session,
            in: project
        )
        return claudeTranscriptURL
    }

    /// Drops both transcript fallbacks. A new process re-earns them: its rollout path arrives on
    /// its own hooks, and its transcript is resolved again from whatever the session record says
    /// by then — a resumed conversation and a migrated account both change the answer.
    private func resetTranscriptFallbackObservation() {
        codexInterruptionRefreshWorkItem?.cancel()
        codexInterruptionRefreshWorkItem = nil
        codexTranscriptURL = nil
        claudeRefusalRefreshWorkItem?.cancel()
        claudeRefusalRefreshWorkItem = nil
        claudeTranscriptURL = nil
    }

    /// Persists the identifier needed to resume a fresh conversation. Codex and OpenCode assign
    /// theirs; Grok's UUID is known but is not resumable until its first conversation record
    /// exists. Claude's identifier is immediately resumable and never enters this path.
    private func discoverAssignedSessionID() {
        guard !isDiscoveringIdentifier,
              let launchedAt = identifierLaunchDate,
              let agentSession = ProjectStore.shared.session(withID: sessionID),
              agentSession.resumeState == .awaitingIdentifier else { return }

        isDiscoveringIdentifier = true
        switch agentSession.kind {
        case .claude:
            isDiscoveringIdentifier = false
        case .codex:
            discoverCodexSessionID(for: agentSession, launchedAt: launchedAt)
        case .grok:
            discoverGrokSessionID(for: agentSession)
        case .openCode:
            discoverOpenCodeSessionID(launchedAt: launchedAt)
        case .cursor:
            // No terminal surface, so nothing here ever hosts a Cursor session. Its identifier
            // arrives on the wire in the ACP `session/new` result instead.
            isDiscoveringIdentifier = false
        }
    }

    /// Codex rollouts live under the launching account's own home, so discovery is scoped to
    /// that account rather than the default one.
    private func discoverCodexSessionID(for agentSession: AgentSession, launchedAt: Date) {
        guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: agentSession.kind,
                  handle: agentSession.accountHandle
              ) else {
            isDiscoveringIdentifier = false
            return
        }

        CodexSessionDiscovery.discoverSessionID(
            projectPath: project.folderPath,
            codexHome: account.configPath,
            launchedAt: launchedAt
        ) { [weak self] discoveredID in
            guard let self else { return }
            self.isDiscoveringIdentifier = false
            guard let discoveredID else { return }

            ProjectStore.shared.update(sessionID: self.sessionID) { stored in
                stored.resumeState = .resumable(discoveredID)
            }

            SessionNaming.refreshAgentTitle(forSessionID: self.sessionID)

            ThreadingLogger.agent.info("Discovered Codex session \(discoveredID, privacy: .public)")
            self.delegate?.agentSessionDidChangeState(self)
        }
    }

    /// OpenCode exposes its session list as JSON, including the creation time and directory.
    /// Querying that public surface avoids coupling Threading to OpenCode's private SQLite
    /// schema, which has already changed between releases.
    private func discoverOpenCodeSessionID(launchedAt: Date) {
        guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else {
            isDiscoveringIdentifier = false
            return
        }

        OpenCodeSessionDiscovery.discoverSessionID(
            projectPath: project.folderPath,
            launchedAt: launchedAt
        ) { [weak self] discoveredID in
            guard let self else { return }
            self.isDiscoveringIdentifier = false
            guard let discoveredID else {
                self.nextIdentifierDiscoveryAt = Date().addingTimeInterval(5)
                return
            }

            ProjectStore.shared.update(sessionID: self.sessionID) { stored in
                stored.resumeState = .resumable(discoveredID)
            }

            ThreadingLogger.agent.info(
                "Discovered OpenCode session \(discoveredID, privacy: .public)"
            )
            self.delegate?.agentSessionDidChangeState(self)
        }
    }

    /// Grok lets Threading name a new UUID, but a first-launch authentication screen does not
    /// create that conversation. Confirm it through the supported session list before storing a
    /// resume state, so quitting login cannot strand the sidebar row on a nonexistent UUID.
    private func discoverGrokSessionID(for agentSession: AgentSession) {
        guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else {
            isDiscoveringIdentifier = false
            return
        }

        let expectedID = TranscriptID(agentSession.id.uuidString.lowercased())
        GrokSessionDiscovery.discoverSessionID(
            expectedID,
            projectPath: project.folderPath
        ) { [weak self] discoveredID in
            guard let self else { return }
            self.isDiscoveringIdentifier = false
            guard let discoveredID else {
                self.nextIdentifierDiscoveryAt = Date().addingTimeInterval(5)
                return
            }

            ProjectStore.shared.update(sessionID: self.sessionID) { stored in
                stored.resumeState = .resumable(discoveredID)
            }

            ThreadingLogger.agent.info(
                "Confirmed Grok session \(discoveredID, privacy: .public)"
            )
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
        scheduleProviderTitleRefresh()
        scheduleCodexInterruptionRefresh()

        // Grok and OpenCode do not create a record for a blank TUI. Output after the initial
        // discovery window may mean the first prompt landed; retry at a bounded cadence until
        // the public session list contains it.
        if agentKind.supports(.deferredSessionIdentifier),
           Date() >= nextIdentifierDiscoveryAt {
            discoverAssignedSessionID()
        }
    }

    /// The one surface that can say why a bell rang: it keeps the activity tracker, so the
    /// three facts the causes are told apart by are all here.
    ///
    /// The attribution question is asked of the resolution chain first. Without an entry of its
    /// own, `bell.otherProgram` resolves to whatever `bell.agentAsking` resolves to, so reading
    /// the PTY's foreground group would cost two syscalls per bell to choose between two
    /// identical sounds.
    func terminalSessionDidReceiveBell(_ session: TerminalSession) -> SoundEvent? {
        activityTracker.recordBell(
            attributesOtherPrograms: SoundResolution.attributesOtherPrograms(
                sessionID: sessionID
            ),
            otherProgramHoldsPTY: { session.foregroundIsAnotherProgram() }
        )
    }

    func terminalSessionDidForwardMouseReport(_ session: TerminalSession) {
        // The agent repaints its content in response — its transcript under a wheel tick, the
        // row under the pointer as it moves. That is not it working.
        activityTracker.noteMouseReportForwarded()
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        attachmentObserver?.scanNow()
        agentTitleRefreshWorkItem?.cancel()
        agentTitleRefreshWorkItem = nil
        if agentKind.supports(.providerTitleMetadata) {
            SessionNaming.refreshAgentTitle(forSessionID: sessionID)
        }
        isRunning = false
        activityTracker.markDormant()
        resetTranscriptFallbackObservation()
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)

        EventLog.shared.record(.session, "Agent exited", [
            "session": sessionID.uuidString,
            "exitCode": exitCode.map(String.init) ?? "unknown"
        ])

        ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.lastExitCode = exitCode
            stored.lastActiveAt = Date()
        }

        if let exitCode, exitCode != 0 {
            SessionSnoozeCenter.shared.record(.failed, for: sessionID)
        }

        // A blank TUI of this kind creates no session until the first prompt. If the initial
        // poll finished before the user typed, exiting is the next exact point at which to retry.
        if agentKind.supports(.deferredSessionIdentifier) {
            nextIdentifierDiscoveryAt = .distantPast
            discoverAssignedSessionID()
        }

        delegate?.agentSession(self, didExitWithCode: exitCode)
    }
}

// MARK: - Agent Runtime Composition

extension AgentSessionViewController: AgentTerminalRuntimeSurface {
    var remoteTerminalSurface: any RemoteTerminalSurface { session }

    var terminalRootProcessIdentifier: pid_t? {
        session.shellPid > 0 ? session.shellPid : nil
    }

    func pasteTerminalText(_ text: String) {
        session.pasteText(text)
    }

    func insertTerminalText(_ text: String) {
        session.insertText(text)
    }

    func visibleTerminalScreenLines() -> [String] {
        session.visibleScreenLines()
    }

    func noteLimitCleared() {
        activityTracker.noteLimitCleared()
    }

    func noteLimitParked(recoveryArmed: Bool) {
        activityTracker.noteLimitParked(recoveryArmed: recoveryArmed)
    }

    func removeFromPresentation() {
        view.removeFromSuperview()
    }
}

extension AgentRuntime {
    /// UI's concrete adapter lookup. Application and server code use the narrower runtime
    /// capabilities on `AgentRuntime` and never acquire this controller.
    func controller(for sessionID: SessionID) -> AgentSessionViewController? {
        terminalRuntimeSurface(for: sessionID) as? AgentSessionViewController
    }

    /// Returns the cached controller for a session, creating one at the UI composition edge.
    /// Allocating the terminal does not start the agent; the container launches it only after
    /// installing the controller in a laid-out view hierarchy.
    func makeController(for agentSession: AgentSession) -> AgentSessionViewController {
        if let existing = controller(for: agentSession.id) {
            return existing
        }

        let controller = AgentSessionViewController(
            agentSession: agentSession,
            subagentState: subagentState(for: agentSession.id),
            launchPlanProvider: fixtureLaunchPlanProvider(for: agentSession.id)
        )
        precondition(
            registerTerminalRuntimeSurface(controller, for: agentSession.id),
            "A terminal runtime must have one UI adapter"
        )
        return controller
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
