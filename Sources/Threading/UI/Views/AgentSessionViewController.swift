import AppKit
import SwiftTerm
import ThreadingPTYHostKit

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
    private let projectStore: ProjectStore
    private let appEvents = AppEventObservations()

    private(set) var isRunning = false
    /// A failed write cannot persist its own diagnosis. Keep the current attempt's value until
    /// the container has presented it, even when the database refuses the failure record too.
    private(set) var launchRefusal: SessionLaunchFailure?
    var subagents: SubagentTimeline { subagentState.timeline }
    var selectedSubagentThreadID: String? { subagentState.selectedThreadID }

    /// Derives whether the session is working, idle, or wants attention.
    let activityTracker = SessionActivityTracker()

    var activity: SessionActivity { activityTracker.activity }
    var runtimeSnapshot: SessionRuntimeSnapshot { activityTracker.runtimeSnapshot }
    var hasCodexTurnBoundarySource: Bool { codexTranscriptURL != nil }

    /// Structured provider-owned checklist for the current terminal turn.
    private(set) var runProgress: RunProgress?
    private let runProgressMonitor = TerminalRunProgressMonitor()
    private var runProgressRefreshWorkItem: DispatchWorkItem?
    private var runProgressGeneration = 0

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
    /// Set beside `pendingLaunchPlan` when the session's project runs on a remote execution host.
    /// The local plan is then only a placeholder: the command line is composed from the host's
    /// facts once the host is prepared, which may take a while the first time.
    private var pendingRemoteLaunch: PendingRemoteLaunch?
    /// Retries a remote launch when its host's preparation settles. Registered only while one waits.
    private var remoteHostObserver: NSObjectProtocol?
    /// While the off-main process-table preflight decides whether another CLI owns this resume
    /// identifier. It is also the duplicate-launch guard for clicks arriving before that answer.
    private var externalResumePreflightID: UUID?
    private var identifierLaunchDate: Date?

    /// When this controller's current process started, for every launch rather than only the
    /// ones awaiting an identifier. `SessionLaunchFailure` is decided on how long a process
    /// lived, so the clock has to start for launches that already know who they are.
    private var processLaunchDate: Date?

    /// Cancels the "this launch survived" check when the process exits before it fires.
    private var launchSurvivalWorkItem: DispatchWorkItem?

    private var isDiscoveringIdentifier = false
    private var nextIdentifierDiscoveryAt = Date.distantPast
    private let remoteViewportBanner = TerminalStatusBanner(
        symbol: AgentSessionBannerDefaults.remoteViewportSymbol,
        identifier: AgentSessionBannerDefaults.remoteViewportIdentifier
    )
    /// Says a remote host is out of reach while its session reconnects. See `remoteReconnect`.
    private let remoteHostBanner = TerminalStatusBanner(
        symbol: RemoteExecutionHostMark.symbol,
        identifier: AgentSessionBannerDefaults.remoteHostIdentifier
    )
    /// Both banners, stacked at the pane's corner so two statements never overlap.
    private let bannerStack = NSStackView()
    /// Set while a remote-host session whose connection dropped is being taken back.
    private var remoteReconnect: RemoteReconnect?

    /// The one-tap way past a spent usage limit, in the pane's standing-condition ribbon.
    ///
    /// A terminal pane has no composer of its own — the box is inside the TUI — so the refusal
    /// occupies the same pane-width slot as it does over a rendered conversation. It **pushes**
    /// rather than covers: nothing it has to say is said over output somebody is reading.
    private lazy var limitEscapeStrip = LimitEscapeStripView()

    /// The terminal normally starts at the pane's content edge; the ribbon takes that edge while
    /// a refusal stands. The lower edge never moves, so only one dimension of the PTY changes.
    private lazy var terminalBelowPaneTop = session.terminalView.topAnchor.constraint(
        equalTo: view.topAnchor,
        constant: TerminalPadding.top
    )
    private lazy var terminalBelowLimitRibbon = session.terminalView.topAnchor.constraint(
        equalTo: limitEscapeStrip.bottomAnchor,
        constant: TerminalPadding.top
    )
    private var attachmentObserver: TerminalAttachmentObserver?
    private var transcriptAttachmentObserver: TerminalTranscriptAttachmentObserver?
    private var lastRuntimeSnapshot: SessionRuntimeSnapshot = .dormant
    private var selectedSubagentID: String?
    private var subagentTranscriptLoads = SubagentTranscriptLoadCache()
    private var transcriptRecheckGeneration: [String: Int] = [:]
    private var agentTitleRefreshWorkItem: DispatchWorkItem?
    private var codexTranscriptURL: URL?
    private let codexTurnBoundaryMonitor = CodexTurnBoundaryMonitor()
    private var codexTranscriptBoundaryObserver: CodexTranscriptBoundaryObserver?
    private var codexTranscriptResolutionTask: Task<Void, Never>?
    private var codexTranscriptObservationGeneration = 0
    private var codexTurnBoundaryRefreshWorkItem: DispatchWorkItem?
    private var codexContinuationBoundaryRefreshWorkItem: DispatchWorkItem?
    private var codexContinuationBoundaryRefreshIsOutputPrompted = false
    private var claudeTranscriptAccount: AgentAccount?
    private var claudeBoundaryRefreshWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    init(
        agentSession: AgentSession,
        subagentState: SubagentSessionState? = nil,
        launchPlanProvider: AgentLaunchPlanProvider? = nil,
        projectStore: ProjectStore = .shared
    ) {
        self.sessionID = agentSession.id
        self.projectStore = projectStore
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
        // Follows the screen this session's agent will actually draw on, not the runtime alone.
        // The capability is the fixed half — Codex is always launched inline — and the resolved
        // renderer is the chosen half: a Claude session told to use the main screen leaves the
        // same empty rows under a short conversation that pinning Codex inline was about, and a
        // flick that settles on them looks like output that scrolled away. An unstated choice
        // keeps the whole screen, because then the agent may still take the alternate one.
        session.terminalView.scrollbackEnd =
            agentSession.kind.supports(.inlineTerminalViewport)
                || AgentLauncher.terminalRendererAtStartup(for: agentSession) == false
            ? .lastPopulatedRow
            : .screen

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
                projectStore.executionProject(forSessionID: agentSession.id).map {
                    URL(fileURLWithPath: $0.folderPath, isDirectory: true)
                }
            },
            currentDirectory: { [weak terminalSession] in
                terminalSession?.effectiveWorkingDirectory()
            },
            text: { [weak terminalSession] since in
                guard let terminalView = terminalSession?.terminalView else {
                    return .empty
                }
                let read = terminalView.recentLogicalBufferText(
                    maximumUTF8Bytes: SessionAttachmentDefaults.maximumTerminalScanBytes,
                    sinceAbsoluteRow: since
                )
                return TerminalScanRead(text: read.text, nextAbsoluteRow: read.nextAbsoluteRow)
            },
            isEnabled: {
                AppSettings.shared.detectsAttachmentReferences(for: agentSession.kind)
            }
        )
        transcriptAttachmentObserver = TerminalTranscriptAttachmentObserver(
            sessionID: agentSession.id,
            kind: agentSession.kind,
            projectRoot: {
                projectStore.executionProject(forSessionID: agentSession.id).map {
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
        activityTracker.onRuntimeChange = { [weak self] snapshot in
            guard let self else { return }
            let transition = SessionRuntimeTransition(
                previous: self.lastRuntimeSnapshot,
                current: snapshot
            )
            self.lastRuntimeSnapshot = snapshot
            if transition.beganTurn {
                self.beginRunProgressTurn()
                projectStore.noteTurnStarted(sessionID: self.sessionID)
            }
            if transition.endedTurn || transition.completedPendingOutcome {
                projectStore.noteTurnEnded(sessionID: self.sessionID)
            }
            if transition.endedTurn {
                self.clearRunProgress(resetTranscriptCursor: false)
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
        bannerStack.orientation = .vertical
        bannerStack.alignment = .trailing
        bannerStack.spacing = Design.Spacing.small
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        bannerStack.addArrangedSubview(remoteHostBanner)
        bannerStack.addArrangedSubview(remoteViewportBanner)
        view.addSubview(bannerStack)
        view.addSubview(limitEscapeStrip)

        NSLayoutConstraint.activate([
            terminalBelowPaneTop,
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
            bannerStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.large
            ),
            bannerStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.large
            ),

            // Pane-wide and top-anchored, matching the rendered-conversation host. The ribbon's
            // own content inset aligns its ink; its silhouette does not become a rounded terminal
            // row floating inside the output column.
            limitEscapeStrip.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            limitEscapeStrip.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            limitEscapeStrip.topAnchor.constraint(
                equalTo: view.topAnchor
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
        limitEscapeStrip.onUseBankedReset = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitBankedResetRequested(sessionID: self.sessionID))
        }
        limitEscapeStrip.onDismiss = { [weak self] in
            guard let self else { return }
            LimitEscapeSuggestionStore.shared.dismiss(self.sessionID)
        }
        // The rule is the user's own, so ending it is an ordinary act rather than an exception —
        // and it is the only answer a curfew's ribbon carries. See `LimitEscapeStripView`.
        limitEscapeStrip.onLiftCurfew = { [weak self] in
            guard let self else { return }
            SessionCurfewCenter.shared.lift(sessionID: self.sessionID)
        }
        appEvents.observe(LimitEscapeSuggestionDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.refreshLimitEscapeStrip()
        }
        // A curfew engaging, being lifted, or giving up moves this ribbon with nothing else
        // having changed: no suggestion arrived and no usage reading moved.
        appEvents.observe(CurfewDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.refreshLimitEscapeStrip()
        }
        // The standing quiet hours reach every session that never answered for itself, and say
        // nothing about which ones.
        appEvents.observe(CurfewSettingsDidChange.self) { [weak self] _ in
            self?.refreshLimitEscapeStrip()
        }
        refreshLimitEscapeStrip()
    }

    private func refreshLimitEscapeStrip() {
        // A provider refusal first: it is the one the user cannot answer, and telling somebody
        // about their own bedtime while the provider has stopped them would be the smaller fact
        // on top of the larger one.
        let offer = LimitEscapeSuggestionStore.shared.offer(for: sessionID)
            .map(LimitEscapeStripView.Offer.init)
            ?? curfewOffer()
        limitEscapeStrip.setOffer(offer)

        // The terminal gives up the rows the ribbon stands in rather than being drawn over, so
        // the PTY is resized exactly once as the offer appears and once as it leaves.
        let isShowing = offer != nil
        guard terminalBelowLimitRibbon.isActive != isShowing else { return }

        // Deactivated before its replacement is activated, both ways round: two upper edges
        // active at once is an unsatisfiable pair, and AppKit says so in the log rather than
        // waiting for the next pass to sort it out.
        if isShowing {
            terminalBelowPaneTop.isActive = false
            terminalBelowLimitRibbon.isActive = true
        } else {
            terminalBelowLimitRibbon.isActive = false
            terminalBelowPaneTop.isActive = true
        }
    }

    /// The ribbon's curfew state, or nil while nothing is holding this session.
    ///
    /// Only a **held** curfew draws, exactly as it does over a rendered conversation: an armed
    /// one is a fact about tonight rather than a state the pane is in, and the terminal gives up
    /// real rows to this ribbon.
    ///
    /// The cannot-tell clause arrives on its own through `canTellWorking`, which is where most of
    /// these sessions land: a CLI that does not read Escape as *stop*, or a runtime reporting no
    /// turns, still gets the hold and never gets a keystroke — and the sentence says so rather
    /// than implying a fence that is not there.
    private func curfewOffer() -> LimitEscapeStripView.Offer? {
        let now = Date()
        guard case .held(_, let curfew, let state) = CurfewHoldPolicy.hold(
            sessionID: sessionID,
            at: now
        ) else { return nil }

        return .curfew(line: CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: SessionCurfewCenter.shared.canTellWorking(sessionID: sessionID),
            now: now
        ))
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
        launchRefusal = nil
        guard externalResumePreflightID == nil else { return }
        continueLaunch(initialPrompt: initialPrompt, checksExternalOwner: true)
    }

    /// The main-actor half of launch. A successful external-owner check re-enters here with that
    /// one check suppressed; every store and filesystem preflight is intentionally asked again
    /// because the process-table read crossed an executor boundary.
    private func continueLaunch(initialPrompt: String?, checksExternalOwner: Bool) {
        guard !isRunning, !SessionTerminalRestart.shared.contains(sessionID) else { return }

        // The last line before a PTY exists, which is where recovery's refusal has to be. The
        // pane refuses earlier and more visibly, but this is the one every path crosses — a
        // remote resume, a scheduled send, a relaunch, an MCP tool — so a route that recovery
        // did not anticipate stops here rather than starting an agent.
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("an agent launch")
            return
        }

        guard let agentSession = self.projectStore.session(withID: sessionID),
              let project = self.projectStore.project(forSessionID: sessionID) else {
            ThreadingLogger.agent.error("Cannot launch session \(self.sessionID, privacy: .public): not found in store")
            return
        }

        // A project can outlive a checkout removed outside Threading. Refuse before the login
        // shell spends a process on a `cd` that cannot succeed; this also gives an existing row a
        // durable, actionable failure instead of an empty exit-code-1 report.
        if let refusal = ProjectLaunchPreflight.launchFailure(for: project) {
            recordLaunchRefusal(refusal)
            return
        }

        // Where this project's sessions run, before anything is planned: a host this build cannot
        // honour refuses here, rather than letting the launch below run the agent on this Mac.
        let remoteHost: ProjectExecutionHost?
        switch RemoteExecutionHostRoute.resolve(project.executionHost) {
        case .local:
            remoteHost = nil
        case .remote(let host):
            remoteHost = host
        case .refused(let refusal):
            cancelRemoteReconnect()
            recordLaunchRefusal(SessionLaunchFailure(
                origin: .preflight,
                summary: L10n.string("Couldn’t start this session on its remote host."),
                detail: [refusal.message],
                knownCause: "remoteHost.\(refusal.token)"
            ))
            return
        }
        // A reconnect exists only to take back a remote agent. If the host was removed from the
        // project meanwhile there is nothing to take back, and starting the agent on this Mac
        // instead is exactly what the reconnect must never do.
        if remoteReconnect != nil, remoteHost == nil {
            finishRemoteReconnectAsEnded(exitCode: nil)
            return
        }

        // Asked before a plan exists, because the answer is that no plan should be built: the
        // conversation this row names cannot be reopened, and every command line that could be
        // built from here either fails the same way or quietly opens a different conversation.
        // Recording it as a launch failure is what makes the pane say so.
        if let refusal = AgentLauncher.resumeRefusal(for: agentSession, in: project) {
            recordLaunchRefusal(refusal)
            return
        }

        // Reading every process's argv is variable work supplied by the machine, not the row.
        // The cheap process-table filter and the matching command-line reads therefore stay off
        // the main actor. Only runtimes with a measured exclusive-resume contract enter here.
        if checksExternalOwner,
           agentSession.kind.supports(.detectableExternalResume),
           let transcriptID = agentSession.resumeState.transcriptID
        {
            beginExternalResumePreflight(
                executableName: agentSession.kind.executableName,
                transcriptID: transcriptID,
                hostedReplacementSessionID: remoteHost == nil ? sessionID : nil,
                initialPrompt: initialPrompt
            )
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
        pendingRemoteLaunch = remoteHost.map {
            PendingRemoteLaunch(host: $0, initialPrompt: initialPrompt, reattachOnly: remoteReconnect != nil)
        }
        // Opening an existing prompt is presentation, even when this is the selected session.
        // A restart can select it and then switch away before boot output goes quiet. Apply
        // the same grace as background restoration when this launch submits no new work.
        if initialPrompt?.isEmpty != false {
            activityTracker.noteUnattendedLaunch()
        }

        DispatchQueue.main.async { [weak self] in
            self?.startIfTerminalIsSized()
        }
    }

    private func beginExternalResumePreflight(
        executableName: String,
        transcriptID: TranscriptID,
        hostedReplacementSessionID: SessionID?,
        initialPrompt: String?
    ) {
        let requestID = UUID()
        externalResumePreflightID = requestID
        let rawTranscriptID = transcriptID.rawValue
        let hostDecision = hostedReplacementSessionID.map { _ in
            PTYHostDecision.live(settings: .shared, bundle: .main)
        }
        let hostSurvey = PTYHostHoldingsSurvey.connecting()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let owner = ExternalConversationPreflight.runningProcessID(
                executableName: executableName,
                transcriptID: rawTranscriptID,
                sessionID: hostedReplacementSessionID,
                // The socket round trip is lazy: ordinary launches with no matching resume
                // process still spend only the process-table scan. It is also off-main with the
                // argv reads, because either source can block on machine-supplied work.
                hostedSessions: {
                    guard let hostDecision else { return [] }
                    return hostSurvey.holdings(for: hostDecision)?.sessions ?? []
                }
            )

            DispatchQueue.main.async {
                guard let self, self.externalResumePreflightID == requestID else { return }
                self.externalResumePreflightID = nil
                guard !self.isRunning else { return }

                // A migration or provider discovery could replace the id during the queue hop.
                // The answer belongs only to the exact id it checked; restart every preflight for
                // a different state rather than applying a stale refusal or skipping its owner.
                guard self.projectStore.session(withID: self.sessionID)?
                    .resumeState.transcriptID?.rawValue == rawTranscriptID
                else {
                    self.continueLaunch(
                        initialPrompt: initialPrompt,
                        checksExternalOwner: true
                    )
                    return
                }

                if owner != nil {
                    let transcriptPath = self.projectStore.session(withID: self.sessionID)
                        .flatMap { stored -> URL? in
                            guard let project = self.projectStore.project(
                                forSessionID: self.sessionID
                            ) else { return nil }
                            return SessionTranscript.existingURL(for: stored, in: project)
                        }?.path
                    self.recordLaunchRefusal(ExternalConversationPreflight.launchFailure(
                        kind: self.agentKind,
                        transcriptPath: transcriptPath
                    ))
                    return
                }

                self.continueLaunch(initialPrompt: initialPrompt, checksExternalOwner: false)
            }
        }
    }

    private func recordLaunchRefusal(_ refusal: SessionLaunchFailure) {
        launchRefusal = refusal
        EventLog.shared.record(.session, "Refused agent launch", [
            "session": sessionID.uuidString,
            "cause": refusal.knownCause ?? "unrecognised"
        ])
        self.projectStore.update(sessionID: sessionID) { stored in
            stored.lastLaunchFailure = refusal
        }
        delegate?.agentSession(self, didExitWithCode: nil)
    }

    /// Terminates the agent, leaving the terminal view in place showing its final output.
    func terminate() {
        pendingLaunchPlan = nil
        clearPendingRemoteLaunch()
        externalResumePreflightID = nil
        if remoteReconnect != nil {
            // The path to the host is gone, so no stop can reach the agent from here; what ends is
            // this Mac's attempt to take it back. The session is dormant and resumable as usual.
            cancelRemoteReconnect()
            activityTracker.markDormant()
        }
        guard isRunning else {
            session.terminate()
            return
        }
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
        session.terminate()
        isRunning = false
        activityTracker.markDormant()
        resetTranscriptFallbackObservation()
    }

    /// Takes back an agent `threading-ptyd` has been running since the last quit.
    ///
    /// Deliberately not `launch(initialPrompt:)` and deliberately sharing none of it: there is no
    /// plan to build, no resume refusal to consider, no `hasLaunched` to record and no launch
    /// failure to arm. This conversation never stopped, and everything `launch` does is about
    /// starting one that had.
    ///
    /// **What activity this re-derives, and what it cannot.** The tracker is a new one, so there
    /// is no stale `working` to correct — the staleness R7 names comes from hooks posted into a
    /// dead socket while the app was closed, and those never reached a tracker that did not
    /// exist. From here the ordinary readings resume: output inference for every runtime,
    /// Claude's transcript readers when output re-arms them, and Codex's rollout observer as soon
    /// as its stored conversation id resolves. Grok and OpenCode have no transcript boundary to
    /// read and stay on output inference, which is R7's accepted cost; no second reconciliation
    /// is invented here.
    ///
    /// **For a runtime with no transcript source, output inference is the only thing that can
    /// say a reattached session is busy**, and it has to survive the replay to do it. A turn that began before the relaunch raised its
    /// `turnStarted` hook into a socket nobody was listening on, so no report is coming to say
    /// the session is working and — before this — none was coming to end the launch grace either:
    /// `noteUnattendedLaunch` made every burst inert, and a Codex session visibly painting
    /// "Working" sat at idle in the sidebar until its *next* turn ended. So the grace is armed
    /// for the replay and ended at the replay's own boundary, which the link reports. Claude's
    /// readers still cannot stand in for it — `ClaudeTranscriptTurnRefusal` and
    /// `ClaudeTranscriptInterruption` recover a turn that *ended*, and Claude's transcript
    /// records no open one. Codex's rollout does, and `CodexTranscriptTurnBoundary` reads it, so
    /// a reattached Codex session recovers a running turn exactly rather than by inference once
    /// its stored rollout resolves off-main — adopting that rollout latches reporting, which is
    /// what lets its first read be admitted at all. The grace covers that lookup and every
    /// runtime that has no such durable boundary.
    @discardableResult
    func reattachToBackgroundHost(
        socketPath: String,
        grid: PTYHostGrid,
        placement: PTYHostPlacement = .local,
        settings: AppSettings = .shared,
        bundle: Bundle = .main
    ) -> Bool {
        guard !isRunning else { return false }
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("taking a session back from the PTY host")
            return false
        }

        // A selected-session restore can have a launch queued for the next run-loop turn while
        // the host survey is in flight. The daemon owns the child named by this attach attempt,
        // so that local launch must stay cancelled even if attaching the surface fails.
        pendingLaunchPlan = nil
        clearPendingRemoteLaunch()
        externalResumePreflightID = nil

        session.hostPlacement = placement
        session.hostTransportFactory = PTYHostPolicy.attachingTransportFactory(
            socketPath: socketPath,
            bundle: bundle
        )
        // Armed before the attach, because the link fires it from the first coalesced flush and
        // that can be the very next main-queue turn.
        session.onHostAttachReplayFinished = { [weak self] in
            self?.activityTracker.endUnattendedLaunchGrace()
        }
        guard session.attachToHost(grid: grid) else {
            session.onHostAttachReplayFinished = nil
            session.hostTransportFactory = nil
            return false
        }

        isRunning = true
        launchRefusal = nil
        if projectStore.session(withID: sessionID)?.lastLaunchFailure != nil {
            projectStore.update(sessionID: sessionID) { $0.lastLaunchFailure = nil }
        }
        // Not a launch date: nothing launched, so nothing can have failed to launch. The
        // survival check exists to retire a *previous* launch's failure band, and a reattach has
        // no evidence either way.
        resetTranscriptFallbackObservation()
        activityTracker.markRunning()
        beginCodexTranscriptBoundaryObservation()
        // Nobody is looking, and the replay is a repaint: without this the reattach's first
        // burst reads as a finished turn and marks every recovered session unread. Same reason
        // `launchInBackground` does it — but here it is armed for the replay only, and
        // `onHostAttachReplayFinished` above ends it as soon as the replay has been fed.
        activityTracker.noteUnattendedLaunch()
        if settings.remoteAccessEnabled {
            RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: sessionID)
        }

        EventLog.shared.record(.session, "Session taken back from the PTY host", [
            "session": sessionID.uuidString,
            "cols": String(grid.cols),
            "rows": String(grid.rows)
        ])
        if remoteReconnect != nil {
            cancelRemoteReconnect()
            EventLog.shared.record(.session, "Reconnected to remote host session", [
                "session": sessionID.uuidString
            ])
        }
        if placement.isRemote {
            // The agent may have been working the whole time nobody was connected; its transcript
            // grew on the host. Catch the mirror up now, so the first reader after taking it back
            // does not describe the conversation as it was when this Mac last saw it.
            RemoteTranscriptMirror.shared.refresh(sessionID: sessionID) {}
        }
        delegate?.agentSessionDidChangeState(self)
        return true
    }

    /// Hands the keyboard to the terminal, and names what that costs.
    ///
    /// Becoming first responder activates the terminal's text input context, and that is not
    /// the cheap part: the Text Services Manager queues the activation of the selected input
    /// method on the main queue and then waits, synchronously, for that input method to answer
    /// over XPC. On 2026-09-03 the wait was 1.6–2.3 s after every archive and most session
    /// switches, and it left the stall trace an empty interval, because no span of ours was
    /// open. The block queued here runs behind whatever the activation queued, so ending the
    /// span there is what lets a stall trace say "the input method" rather than nothing.
    /// A repeated call for the view that already holds the keyboard changes nothing and is not
    /// measured.
    func focusTerminal() {
        guard let window = view.window, window.firstResponder !== session.terminalView else {
            return
        }
        let span = PerformanceRecorder.shared.begin(
            "focus.terminal-input",
            category: "responsiveness"
        )
        window.makeFirstResponder(session.terminalView)
        DispatchQueue.main.async { span.end() }
    }

#if DEBUG
    /// Starts an explicit deterministic command on the session's real PTY. Opt-in integration
    /// harnesses use this instead of the ordinary provider launcher so they exercise the same
    /// terminal mirror as a live agent without reading an account or spending a provider turn.
    func startRemoteTerminalFixture(plan: AgentLaunchPlan) {
        guard !isRunning else { return }
        _ = view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        view.layoutSubtreeIfNeeded()

        isRunning = true
        activityTracker.markRunning()
        session.start(plan: plan)
    }

    /// Starts a deterministic PTY for the opt-in cross-client browser journey. It exercises the
    /// shipping server, terminal mirror, WebSocket and composer without spending an agent turn
    /// or depending on a developer's Claude/Codex account. The test host owns the controller and
    /// removes the temporary project when the journey finishes.
    func startRemoteBrowserE2EFixture() {
        startRemoteTerminalFixture(plan: AgentLaunchPlan(
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
        guard var plan = pendingLaunchPlan,
              !SessionTerminalRestart.shared.contains(sessionID) else { return }

        let dimensions = session.terminalView.terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else {
            return  // Retried from the sizeChanged callback once layout settles.
        }

        // Resolve ownership before recording a launch. A session that requested durability is
        // either handed to the background host or remains stopped with an actionable failure;
        // it is never silently converted into an app-owned process.
        let hostFactory: PTYHostTransportFactory?
        let placement: PTYHostPlacement
        if let remote = pendingRemoteLaunch {
            // A project on a remote host is hosted there or not at all: running its agent on this
            // Mac instead would put the work in a checkout the person did not choose.
            switch resolveRemoteLaunch(remote) {
            case .waiting:
                return
            case .refused(let failure):
                pendingLaunchPlan = nil
                clearPendingRemoteLaunch()
                cancelRemoteReconnect()
                recordLaunchRefusal(failure)
                return
            case .retryReconnect(let reason):
                pendingLaunchPlan = nil
                clearPendingRemoteLaunch()
                scheduleRemoteReconnect(reason: reason)
                return
            case .endedWhileDisconnected(let exitCode):
                pendingLaunchPlan = nil
                clearPendingRemoteLaunch()
                finishRemoteReconnectAsEnded(exitCode: exitCode)
                return
            case .ready(let launch, let socketPath):
                EventLog.shared.record(.session, "Launching session on remote host", [
                    "session": sessionID.uuidString,
                    "host": remote.host.sshDestination.identifier,
                    "reason": "projectExecutionHost"
                ])
                clearPendingRemoteLaunch()
                plan = launch.plan
                hostFactory = PTYHostPolicy.attachingTransportFactory(socketPath: socketPath)
                placement = .remote(environment: launch.environment)
            case .attach(let summary, let context):
                EventLog.shared.record(.session, "Taking session back from remote host", [
                    "session": sessionID.uuidString,
                    "host": remote.host.sshDestination.identifier,
                    "reason": "projectExecutionHost"
                ])
                // The host has been running this conversation since before this launch — across an
                // app quit, a crash or a Mac restart. Taking it back is the durable answer;
                // spawning would replace it and end a turn that may still be in flight.
                if !reattachToBackgroundHost(
                    socketPath: context.localSocketPath,
                    grid: summary.grid,
                    placement: .remote(environment: RemoteAgentLaunch.environment(for: context.facts))
                ), !isRunning {
                    recordLaunchRefusal(SessionLaunchFailure(
                        origin: .preflight,
                        summary: L10n.string("Couldn’t start this session on its remote host."),
                        detail: [],
                        knownCause: "remoteHost.attachFailed"
                    ))
                }
                return
            }
        } else {
            placement = .local
            switch PTYHostPolicy.launchRoute(
                for: session.identity,
                session: self.projectStore.session(withID: sessionID)
            ) {
            case .local:
                hostFactory = nil
            case .hosted(let factory):
                hostFactory = factory
            case .unavailable(let failure):
                pendingLaunchPlan = nil
                recordLaunchRefusal(SessionLaunchFailure(
                    origin: .preflight,
                    summary: L10n.string("Couldn’t start this background session."),
                    detail: [failure.localizedDescription],
                    knownCause: "ptyHost.\(failure.cause)"
                ))
                return
            }
        }

        // Whatever the launch decided about this session stops being the reason it is dormant the
        // moment it runs. See `SessionRestorationLedger`.
        SessionRestorationLedger.shared.forget(sessionID: sessionID)

        let recorded = self.projectStore.update(sessionID: sessionID) { stored in
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
            recordLaunchRefusal(SessionLaunchFailure(
                origin: .preflight,
                summary: L10n.string("Couldn’t start"),
                detail: [L10n.string("The project data could not be saved.")],
                knownCause: self.projectStore.persistenceBlockReason == .storageExhausted
                    ? "storage-exhausted" : "persistence-unavailable"
            ))
            return
        }

        pendingLaunchPlan = nil
        isRunning = true
        processLaunchDate = Date()
        armLaunchSurvivalCheck()
        resetTranscriptFallbackObservation()
        activityTracker.markRunning()
        beginCodexTranscriptBoundaryObservation()

        // The command line, before it runs. A launch that takes the app down with it leaves
        // this as the only account of what was being started.
        EventLog.shared.record(.session, "Launching agent", [
            "session": sessionID.uuidString,
            "command": ([plan.executable] + plan.arguments).joined(separator: " ")
        ])

        if plan.resumeState == .awaitingIdentifier {
            identifierLaunchDate = Date()
        }

        // The route was resolved before the launch record above so an unavailable requested host
        // remains a refusal rather than a launch that never happened.
        session.hostPlacement = placement
        session.hostTransportFactory = hostFactory
        session.start(plan: plan)
        guard isRunning else { return }
        finishRecordedLaunch(plan: plan)
    }

    // MARK: - Private Methods — remote execution hosts

    private struct PendingRemoteLaunch {
        let host: ProjectExecutionHost
        let initialPrompt: String?
        /// A reconnect: take back a running agent or report that it ended, and never spawn one.
        let reattachOnly: Bool
        /// Whether this launch has already asked for the host to be prepared. A later retry only
        /// reads the phase, so a failed preparation is reported rather than started again.
        var requestedPreparation = false
        /// What the prepared host's daemon holds, asked once per launch before anything spawns.
        var survey: RemoteHoldingsSurvey = .notAsked
        /// The launch's settings and MCP configuration, encoded off the main actor once composed.
        var encoding: RemoteLaunchEncoding = .notStarted
    }

    private enum RemoteLaunchEncoding {
        case notStarted
        case encoding
        case encoded(RemoteAgentLaunch)
    }

    private enum RemoteHoldingsSurvey {
        case notAsked
        case asking
        case answered([PTYHostSessionSummary])
        case unanswered
    }

    private enum RemoteLaunchResolution {
        case waiting
        case refused(SessionLaunchFailure)
        case ready(RemoteAgentLaunch, socketPath: String)
        /// The host is still running this session on a pseudo-terminal.
        case attach(PTYHostSessionSummary, RemoteHostLaunchContext)
        /// A reconnect could not reach the host yet; try again later.
        case retryReconnect(String)
        /// A reconnect reached the host and the agent is no longer running there.
        case endedWhileDisconnected(Int32?)
    }

    /// Where a remote launch stands. Never blocks: preparing a host is `ssh` work on
    /// `RemoteExecutionHosts`' own queue, and this waits for its change notification.
    private func resolveRemoteLaunch(_ remote: PendingRemoteLaunch) -> RemoteLaunchResolution {
        let hosts = RemoteExecutionHosts.shared
        let destination = remote.host.sshDestination
        let phase: RemoteHostPhase
        if remote.requestedPreparation {
            phase = hosts.phase(for: destination)
        } else {
            pendingRemoteLaunch?.requestedPreparation = true
            phase = hosts.readiness(
                for: destination,
                components: RemoteHostComponentSource.current(),
                appSocketPath: MCPServer.shared.socketPath
            )
        }

        switch phase {
        case .idle, .preparing:
            observeRemoteHostChanges()
            return .waiting
        case .failed(let failure):
            if remote.reattachOnly { return .retryReconnect(failure.token) }
            return .refused(SessionLaunchFailure(
                origin: .preflight,
                summary: L10n.string("Couldn’t start this session on its remote host."),
                detail: [failure.detail],
                knownCause: "remoteHost.\(failure.token)"
            ))
        case .ready(let context):
            switch remote.survey {
            case .notAsked:
                pendingRemoteLaunch?.survey = .asking
                observeRemoteHostChanges()
                hosts.holdings(socketPath: context.localSocketPath) { [weak self] sessions in
                    guard let self, self.pendingRemoteLaunch != nil else { return }
                    self.pendingRemoteLaunch?.survey = sessions.map { .answered($0) } ?? .unanswered
                    self.startIfTerminalIsSized()
                }
                return .waiting
            case .asking:
                return .waiting
            case .unanswered:
                if remote.reattachOnly { return .retryReconnect("surveyFailed") }
                return .refused(SessionLaunchFailure(
                    origin: .preflight,
                    summary: L10n.string("Couldn’t start this session on its remote host."),
                    detail: [],
                    knownCause: "remoteHost.surveyFailed"
                ))
            case .answered(let held):
                if let running = held.first(where: {
                    $0.sessionID == sessionID && $0.exit == nil && $0.resolvedChannel == .pty
                }) {
                    return .attach(running, context)
                }
                if remote.reattachOnly {
                    let ending = held.first { $0.sessionID == sessionID }?.exit
                    return .endedWhileDisconnected(ending)
                }
            }
            guard let agentSession = projectStore.session(withID: sessionID),
                  let project = projectStore.project(forSessionID: sessionID) else {
                return .refused(SessionLaunchFailure(
                    origin: .preflight,
                    summary: L10n.string("Couldn’t start this session on its remote host."),
                    detail: [],
                    knownCause: "remoteHost.sessionMissing"
                ))
            }
            switch remote.encoding {
            case .encoded(let launch):
                return .ready(launch, socketPath: context.localSocketPath)
            case .encoding:
                return .waiting
            case .notStarted:
                break
            }
            do {
                let unencoded = try RemoteAgentLaunch.make(
                    for: agentSession,
                    in: project,
                    host: remote.host,
                    context: context,
                    initialPrompt: remote.initialPrompt
                )
                pendingRemoteLaunch?.encoding = .encoding
                DispatchQueue.global(qos: .userInitiated).async {
                    let launch = unencoded.encode()
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.pendingRemoteLaunch != nil else { return }
                            self.pendingRemoteLaunch?.encoding = .encoded(launch)
                            self.startIfTerminalIsSized()
                        }
                    }
                }
                return .waiting
            } catch let refusal as RemoteAgentLaunchError {
                return .refused(SessionLaunchFailure(
                    origin: .preflight,
                    summary: L10n.string("Couldn’t start this session on its remote host."),
                    detail: [refusal.localizedDescription],
                    knownCause: "remoteHost.\(refusal.token)"
                ))
            } catch {
                return .refused(SessionLaunchFailure(
                    origin: .preflight,
                    summary: L10n.string("Couldn’t start this session on its remote host."),
                    detail: [error.localizedDescription],
                    knownCause: "remoteHost.unexpected"
                ))
            }
        }
    }

    // MARK: - Private Methods — reconnecting to a remote host

    private struct RemoteReconnect {
        let destination: String
        var attempt = 0
        var retry: DispatchWorkItem?
    }

    /// Takes back the agent through the ordinary remote launch, reattach-only: prepare the host
    /// again (the old tunnel is gone), survey it, and attach — or learn that the agent ended.
    private func attemptRemoteReconnect() {
        guard remoteReconnect != nil, !isRunning else { return }
        remoteReconnect?.retry = nil
        continueLaunch(initialPrompt: nil, checksExternalOwner: false)
    }

    /// The host is out of reach — asleep, off the network, rebooting. Retried on a backoff for as
    /// long as the pane exists: an agent can keep working for hours while its Mac is closed, and
    /// giving up after a few tries would strand it behind a Resume button nobody knows to press.
    private func scheduleRemoteReconnect(reason: String) {
        guard var reconnect = remoteReconnect else { return }
        let delay = RemoteReconnectDefaults.delay(afterAttempt: reconnect.attempt)
        reconnect.attempt += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.attemptRemoteReconnect() }
        }
        reconnect.retry?.cancel()
        reconnect.retry = work
        remoteReconnect = reconnect
        remoteHostBanner.show(
            title: L10n.format("Reconnecting to %@…", reconnect.destination),
            detail: L10n.format("Couldn’t reach it. Trying again in %lld s.", Int64(delay)),
            toolTip: reason
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRemoteReconnect() {
        remoteReconnect?.retry?.cancel()
        remoteReconnect = nil
        remoteHostBanner.hide()
    }

    /// The host answered and the agent is not running there any more: an ending, recorded the way
    /// any other ending is, with the status the daemon kept when it has one.
    private func finishRemoteReconnectAsEnded(exitCode: Int32?) {
        cancelRemoteReconnect()
        EventLog.shared.record(.session, "Remote host session ended while disconnected", [
            "session": sessionID.uuidString
        ])
        terminalSession(session, didTerminateWithExitCode: exitCode)
    }

    private func observeRemoteHostChanges() {
        guard remoteHostObserver == nil else { return }
        remoteHostObserver = NotificationCenter.default.addObserver(
            forName: RemoteExecutionHosts.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startIfTerminalIsSized()
            }
        }
    }

    private func clearPendingRemoteLaunch() {
        pendingRemoteLaunch = nil
        if let remoteHostObserver {
            NotificationCenter.default.removeObserver(remoteHostObserver)
            self.remoteHostObserver = nil
        }
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

    // MARK: - Launch Failure

    /// Retires a previous failure once this launch has outlived the window that defines one.
    ///
    /// Cleared on survival rather than on start, so a retry that fails the same way never blinks
    /// the band off and on again, and a band the user is still reading is not taken away by the
    /// press that is about to reproduce it. One work item per launch, cancelled by the exit.
    private func armLaunchSurvivalCheck() {
        launchSurvivalWorkItem?.cancel()
        guard self.projectStore.session(withID: sessionID)?.lastLaunchFailure != nil else {
            launchSurvivalWorkItem = nil
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.launchSurvivalWorkItem = nil
            guard self.isRunning else { return }
            self.projectStore.update(sessionID: self.sessionID) { stored in
                stored.lastLaunchFailure = nil
            }
            self.delegate?.agentSessionDidChangeState(self)
        }
        launchSurvivalWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionLaunchFailureDefaults.youngProcessWindow,
            execute: item
        )
    }

    /// Builds the record for an exit that reads as a failed launch, or nil for an ordinary one.
    ///
    /// The screen is passed in rather than read here because the caller reads it first, before
    /// any of the teardown that follows an exit has run.
    private func launchFailure(
        exitCode: Int32?,
        screen: [String]
    ) -> SessionLaunchFailure? {
        guard let launchedAt = processLaunchDate else { return nil }
        let ranFor = Date().timeIntervalSince(launchedAt)
        guard SessionLaunchFailure.looksLikeLaunchFailure(
            exitCode: exitCode,
            ranFor: ranFor
        ) else { return nil }

        let detail = Array(screen.suffix(SessionLaunchFailureDefaults.capturedLineCount))
        let diagnosis = SessionLaunchDiagnosis.classify(lines: detail, kind: agentKind)
        let transcriptPath = self.projectStore.session(withID: sessionID)
            .flatMap { stored -> URL? in
                guard let project = self.projectStore.project(forSessionID: sessionID) else {
                    return nil
                }
                return SessionTranscript.existingURL(for: stored, in: project)
            }?.path

        return SessionLaunchFailure(
            origin: .processExit,
            exitCode: exitCode,
            ranFor: ranFor,
            summary: diagnosis?.summary ?? L10n.format(
                "%@ stopped right after starting.",
                agentKind.displayName
            ),
            detail: detail,
            transcriptPath: transcriptPath,
            knownCause: diagnosis?.knownCause
        )
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

    /// Applies a plan mutation delivered by the session's observational hook.
    func applyRunProgress(_ report: HookRunProgressReport) {
        let generation = runProgressGeneration
        runProgressMonitor.apply(report) { [weak self] progress in
            self?.publishRunProgress(progress, generation: generation)
        }
    }

    private func publishRunProgress(_ progress: RunProgress?, generation: Int) {
        guard generation == runProgressGeneration,
              activityTracker.runtimeSnapshot.hasOpenTurn,
              runProgress != progress else { return }
        runProgress = progress
        delegate?.agentSessionDidChangeState(self)
    }

    private func beginRunProgressTurn() {
        runProgressGeneration &+= 1
        let generation = runProgressGeneration
        runProgressRefreshWorkItem?.cancel()
        runProgressMonitor.beginTurn { [weak self] progress in
            self?.publishRunProgress(progress, generation: generation)
        }
        scheduleRunProgressTranscriptRefresh()
    }

    private func clearRunProgress(resetTranscriptCursor: Bool) {
        runProgressGeneration &+= 1
        runProgressRefreshWorkItem?.cancel()
        runProgressRefreshWorkItem = nil
        let hadProgress = runProgress != nil
        runProgress = nil
        if resetTranscriptCursor {
            runProgressMonitor.clear { _ in }
        } else {
            runProgressMonitor.endTurn { _ in }
        }
        if hadProgress {
            delegate?.agentSessionDidChangeState(self)
            RemoteSessionMirrorRegistry.shared.sessionRunProgressChanged(sessionID)
        }
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
              let stored = self.projectStore.session(withID: sessionID),
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

        adoptCodexTranscriptURL(url)
        scheduleRunProgressTranscriptRefresh()
    }

    /// Resolves a resumed rollout once per process lifetime, with the externally growing
    /// session-tree discovery off the main actor. Fresh sessions have no provider id yet and earn
    /// their exact path from the first lifecycle report instead.
    private func beginCodexTranscriptBoundaryObservation() {
        guard codexTranscriptURL == nil,
              codexTranscriptResolutionTask == nil,
              let lookup = attachmentTranscriptLookup() else { return }

        let generation = codexTranscriptObservationGeneration
        codexTranscriptResolutionTask = Task { @MainActor [weak self] in
            let url = await Task.detached(priority: .utility) { lookup() }.value
            guard let self else { return }
            self.codexTranscriptResolutionTask = nil
            guard !Task.isCancelled,
                  self.isRunning,
                  generation == self.codexTranscriptObservationGeneration,
                  let url else { return }
            self.adoptCodexTranscriptURL(url)
        }
    }

    /// Makes one validated rollout the controller's event-driven lifecycle source.
    ///
    /// The observer remains alive for the process rather than only for an open turn: Codex goal
    /// mode can append its next `task_started` while the tracker is between turns, with no start
    /// hook and no user input to recreate a watcher.
    private func adoptCodexTranscriptURL(_ url: URL) {
        codexTranscriptResolutionTask?.cancel()
        codexTranscriptResolutionTask = nil

        if codexTranscriptURL != url {
            codexTurnBoundaryMonitor.reset()
            codexTranscriptBoundaryObserver?.stop()
            codexTranscriptBoundaryObserver = nil
            codexTranscriptURL = url
        }

        if codexTranscriptBoundaryObserver == nil {
            let observer = CodexTranscriptBoundaryObserver(url: url) { [weak self] in
                guard let self, self.isRunning, self.codexTranscriptURL == url else { return }
                self.scheduleCodexTurnBoundaryRefresh()
            }
            if observer.start() {
                codexTranscriptBoundaryObserver = observer
                // The rollout is a turn-boundary source from here on, and the read scheduled
                // below is what recovers a turn the CLI already has open. A reattach fires no
                // `SessionStart` to latch on, and without this the reader refused that read
                // while inference span idle prompts into work.
                activityTracker.noteTranscriptBoundarySourceAdopted()
            } else {
                ThreadingLogger.agent.error(
                    "Could not observe Codex rollout for \(self.sessionID.uuidString, privacy: .public)"
                )
                EventLog.shared.record(.hooks, "Codex rollout observation failed", [
                    "session": sessionID.uuidString
                ])
            }
        }

        // Also schedules an immediate quiet-edge read. The observer starts first, so an append
        // between path adoption and this read is either already visible or wakes a trailing one.
        scheduleCodexTurnBoundaryRefresh()
    }

    /// Looks past Codex's `Stop` for the `task_started` record goal mode writes shortly after it.
    ///
    /// This is separate from the output-coalesced refresh below. Coalescing is right for normal
    /// transcript observation, but a continuation can keep painting for longer than the activity
    /// grace; repeatedly postponing this read would publish the exact false attention edge the
    /// rollout is authoritative enough to prevent.
    func noteCodexTurnFinishedForContinuationDetection() {
        scheduleCodexContinuationBoundaryRefresh(
            after: CodexTurnBoundaryDefaults.continuationProbeDelay,
            outputPrompted: false
        )
    }

    /// Coalesces terminal repaint bursts into one resumable, off-main transcript pass.
    private func scheduleRunProgressTranscriptRefresh(after delay: TimeInterval = 0.25) {
        guard activityTracker.runtimeSnapshot.hasOpenTurn,
              TranscriptReplayFormat(kind: agentKind) != nil else { return }

        runProgressRefreshWorkItem?.cancel()
        let generation = runProgressGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.runProgressGeneration,
                  self.activityTracker.runtimeSnapshot.hasOpenTurn else { return }
            self.runProgressRefreshWorkItem = nil

            if let url = self.attachmentTranscriptURL() {
                self.scanRunProgressTranscript(at: url, generation: generation)
                return
            }
            guard let lookup = self.attachmentTranscriptLookup() else { return }
            Task { @MainActor [weak self] in
                let url = await Task.detached(priority: .utility) { lookup() }.value
                guard let self, let url,
                      generation == self.runProgressGeneration else { return }
                if self.agentKind.supports(.lifecycleReportedTranscriptPath) {
                    self.adoptCodexTranscriptURL(url)
                }
                self.scanRunProgressTranscript(at: url, generation: generation)
            }
        }
        runProgressRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scanRunProgressTranscript(at url: URL, generation: Int) {
        runProgressMonitor.scan(at: url, kind: agentKind) { [weak self] result in
            guard let self, generation == self.runProgressGeneration else { return }
            if result.hasMore {
                self.scheduleRunProgressTranscriptRefresh(after: 0.01)
            } else {
                // A first hydration can cross several bounded chunks. Publishing the middle of
                // an older turn would flash a stale checklist before the newest boundary lands.
                self.publishRunProgress(result.progress, generation: generation)
            }
        }
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
              let stored = self.projectStore.session(withID: sessionID),
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

    /// Coalesces rollout events and terminal-output hints into one quiet-edge revalidation. The
    /// transcript reader performs the stat and capped tail scan off-main; this main-queue work is
    /// only cancellation and scheduling.
    ///
    /// Deliberately **not** gated on a turn being in flight, unlike its Claude sibling: the
    /// boundary this exists for most is a turn that began without anybody being told, so a
    /// session the tracker believes is idle is exactly the state worth reading.
    private func scheduleCodexTurnBoundaryRefresh() {
        // A repaint must not push the first read back forever. One scheduled refresh is
        // enough; the monitor catches up every appended byte in bounded worker passes.
        guard codexTranscriptURL != nil, codexTurnBoundaryRefreshWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let url = self.codexTranscriptURL else { return }
            self.codexTurnBoundaryRefreshWorkItem = nil

            self.codexTurnBoundaryMonitor.revalidate(at: url) { [weak self] boundary in
                guard let self, self.isRunning, self.codexTranscriptURL == url,
                      let boundary else { return }
                self.apply(boundary)
            }
        }
        codexTurnBoundaryRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CodexTurnBoundaryDefaults.quietDelay,
            execute: item
        )
    }

    /// Schedules one non-postponing continuation read. The first output after `Stop` replaces
    /// the slower look-ahead with a prompt read; later chunks leave that earlier deadline alone.
    private func scheduleCodexContinuationBoundaryRefresh(
        after delay: TimeInterval,
        outputPrompted: Bool
    ) {
        guard codexTranscriptURL != nil,
              activityTracker.hasPendingReportedTurnFinish else { return }

        if codexContinuationBoundaryRefreshWorkItem != nil {
            // The first output after `Stop` is later evidence than the fallback timer and earns
            // the earlier read. Further chunks may not slide that prompt read forward again.
            guard outputPrompted, !codexContinuationBoundaryRefreshIsOutputPrompted else {
                return
            }
            codexContinuationBoundaryRefreshWorkItem?.cancel()
            codexContinuationBoundaryRefreshWorkItem = nil
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, let url = self.codexTranscriptURL else { return }
            self.codexContinuationBoundaryRefreshWorkItem = nil
            self.codexContinuationBoundaryRefreshIsOutputPrompted = false

            self.codexTurnBoundaryMonitor.revalidate(at: url) { [weak self] boundary in
                guard let self, self.isRunning, self.codexTranscriptURL == url,
                      let boundary else { return }
                self.apply(boundary)
            }
        }
        codexContinuationBoundaryRefreshWorkItem = item
        codexContinuationBoundaryRefreshIsOutputPrompted = outputPrompted
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Crosses the one activity edge a rollout boundary is allowed to cross, and says so.
    ///
    /// Each of the three is refused unless it is about the turn the tracker is actually in, so
    /// the ordinary case — `task_complete` landing a few milliseconds behind the `Stop` that
    /// already closed the turn — costs one comparison and writes nothing.
    private func apply(_ boundary: CodexTurnBoundary) {
        let admitted: Bool
        switch boundary {
        case .started(let turnID):
            admitted = activityTracker.noteTurnStartedFromTranscript(turnID: turnID)
        case .completed(let turnID):
            admitted = activityTracker.noteTurnFinishedFromTranscript(
                turnID: turnID,
                continuationGrace: CodexTurnBoundaryDefaults.continuationGrace
            )
        case .interrupted(let turnID):
            admitted = activityTracker.noteTurnInterrupted(turnID: turnID)
        }
        guard admitted else { return }

        ThreadingLogger.agent.info(
            """
            Recovered Codex turn \(boundary.turnID, privacy: .public) \
            (\(boundary.logName, privacy: .public)) from rollout
            """
        )
        EventLog.shared.record(.hooks, "Codex turn boundary recovered from transcript", [
            "session": sessionID.uuidString,
            "turn": boundary.turnID,
            "boundary": boundary.logName
        ])
    }

    /// Revalidates once after an output burst settles, for the two turn boundaries Claude omits:
    /// a request that failed outright, and a turn the user interrupted.
    ///
    /// One quiet edge rather than one per fact. Both readers answer off the same tail of the same
    /// file, both are asked by the same terminal-output callback, and both are Claude's; two
    /// timers would only mean the same burst scheduling the same beat twice.
    ///
    /// Gated on a turn actually being in flight, so a session sitting at its prompt does no work
    /// at all: the tracker would refuse the result anyway, and this is a terminal-output callback.
    /// The generation is read inside the work item rather than when it is scheduled, which is as
    /// late as it can be read and still be the turn the scans are about — narrowing the window
    /// this guards to the background reads themselves.
    private func scheduleClaudeBoundaryRefresh() {
        guard agentKind.supports(.transcriptRefusedTurnRecord)
                || agentKind.supports(.transcriptInterruptedMessageRecord),
              activityTracker.reportsOwnActivity,
              activityTracker.runtimeSnapshot.hasOpenTurn,
              let url = resolvedClaudeTranscriptURL() else {
            return
        }

        claudeBoundaryRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.claudeBoundaryRefreshWorkItem = nil
            let generation = self.activityTracker.turnGeneration

            if self.agentKind.supports(.transcriptRefusedTurnRecord) {
                self.readClaudeRefusal(at: url, turn: generation)
            }
            if self.agentKind.supports(.transcriptInterruptedMessageRecord) {
                self.readClaudeInterruption(at: url, turn: generation)
            }
        }
        claudeBoundaryRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClaudeRefusalDefaults.quietDelay,
            execute: item
        )
    }

    /// The boundary Claude omits when a request fails outright — an expired login, a dropped
    /// connection. See `ClaudeTranscriptTurnRefusal`.
    private func readClaudeRefusal(at url: URL, turn generation: Int) {
        ClaudeTranscriptTurnRefusal.revalidate(at: url) { [weak self] refusal in
            guard let self, self.isRunning, self.resolvedClaudeTranscriptURL() == url,
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

    /// The boundary Claude omits when the user presses Escape. See `ClaudeTranscriptInterruption`.
    private func readClaudeInterruption(at url: URL, turn generation: Int) {
        ClaudeTranscriptInterruption.revalidate(at: url) { [weak self] interruption in
            guard let self, self.isRunning, self.resolvedClaudeTranscriptURL() == url,
                  let interruption,
                  self.activityTracker.noteTurnInterrupted(turn: generation)
            else { return }

            ThreadingLogger.agent.info(
                "Recovered interrupted Claude turn \(interruption.recordID, privacy: .public) from transcript"
            )
            EventLog.shared.record(.hooks, "Claude interruption recovered from transcript", [
                "session": self.sessionID.uuidString,
                "record": interruption.recordID,
                "message": interruption.interruptedMessageID ?? ""
            ])
        }
    }

    /// Cache account discovery per launch, but always ask the shared resolver for the source.
    /// A hook may correct the initial checkout-derived path after the first output callback.
    /// Store and location lookups are O(1), with no filesystem work after account resolution.
    private func resolvedClaudeTranscriptURL() -> URL? {
        guard let session = self.projectStore.session(withID: sessionID),
              let transcriptID = session.resumeState.transcriptID,
              let project = self.projectStore.executionProject(forSessionID: sessionID)
        else { return nil }

        if claudeTranscriptAccount?.handle != session.accountHandle {
            claudeTranscriptAccount = AgentAccountDiscovery.account(
                for: session.kind, handle: session.accountHandle
            )
        }
        guard let account = claudeTranscriptAccount else { return nil }
        return SessionTranscript.url(
            sessionID: transcriptID,
            for: session,
            in: project,
            account: account
        )
    }

    /// Drops both transcript fallbacks. A new process re-earns them: Codex's rollout arrives from
    /// its own hooks or stored conversation id, and Claude's transcript is resolved again from
    /// whatever the session record says by then — a resume and an account migration both change
    /// the answer.
    private func resetTranscriptFallbackObservation() {
        codexTurnBoundaryMonitor.reset()
        codexTranscriptObservationGeneration &+= 1
        codexTranscriptResolutionTask?.cancel()
        codexTranscriptResolutionTask = nil
        codexTranscriptBoundaryObserver?.stop()
        codexTranscriptBoundaryObserver = nil
        codexTurnBoundaryRefreshWorkItem?.cancel()
        codexTurnBoundaryRefreshWorkItem = nil
        codexContinuationBoundaryRefreshWorkItem?.cancel()
        codexContinuationBoundaryRefreshWorkItem = nil
        codexContinuationBoundaryRefreshIsOutputPrompted = false
        codexTranscriptURL = nil
        claudeBoundaryRefreshWorkItem?.cancel()
        claudeBoundaryRefreshWorkItem = nil
        claudeTranscriptAccount = nil
        clearRunProgress(resetTranscriptCursor: true)
    }

    /// Persists the identifier needed to resume a fresh conversation. Codex and OpenCode assign
    /// theirs; Grok's UUID is known but is not resumable until its first conversation record
    /// exists. Claude's identifier is immediately resumable and never enters this path.
    private func discoverAssignedSessionID() {
        guard !isDiscoveringIdentifier,
              let launchedAt = identifierLaunchDate,
              let agentSession = self.projectStore.session(withID: sessionID),
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
        guard let project = self.projectStore.executionProject(forSessionID: sessionID),
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

            self.projectStore.update(sessionID: self.sessionID) { stored in
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
        guard let project = self.projectStore.executionProject(forSessionID: sessionID) else {
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

            self.projectStore.update(sessionID: self.sessionID) { stored in
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
        guard let project = self.projectStore.executionProject(forSessionID: sessionID) else {
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

            self.projectStore.update(sessionID: self.sessionID) { stored in
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

    /// The PTY is now a real live surface, so remote capture can succeed and wake any phone
    /// waiting in the host-owned dormant-session startup transaction. Calling this before
    /// `TerminalSession.start` only observes `.unavailable`; without this process-start edge the
    /// socket keeps waiting even though the agent is already running.
    func terminalSessionDidStart(_ session: TerminalSession) {
        guard AppSettings.shared.remoteAccessEnabled else { return }
        RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: sessionID)
    }

    func terminalSession(_ session: TerminalSession, didFailToStart failure: PTYHostLaunchError) {
        launchSurvivalWorkItem?.cancel()
        launchSurvivalWorkItem = nil
        processLaunchDate = nil
        isRunning = false
        activityTracker.markDormant()
        resetTranscriptFallbackObservation()
        recordLaunchRefusal(SessionLaunchFailure(
            origin: .preflight,
            summary: L10n.string("Couldn’t start this background session."),
            detail: [failure.localizedDescription],
            knownCause: "ptyHost.\(failure.cause)"
        ))
    }

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

    /// The link to a remote host dropped while its agent was presumably still running there.
    /// Nothing is recorded as an exit: the pane says it is reconnecting and takes the agent back.
    func terminalSessionDidLoseRemoteHost(_ session: TerminalSession, cause: String) -> Bool {
        guard let host = projectStore.project(forSessionID: sessionID)?.executionHost else { return false }
        isRunning = false
        remoteReconnect?.retry?.cancel()
        remoteReconnect = RemoteReconnect(destination: host.destination)
        remoteHostBanner.show(
            title: L10n.format("Reconnecting to %@…", host.destination),
            detail: L10n.string("The session is still running there."),
            toolTip: cause
        )
        delegate?.agentSessionDidChangeState(self)
        attemptRemoteReconnect()
        return true
    }

    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    ) {
        if let grid {
            remoteViewportBanner.show(
                title: L10n.format("Fit to iPhone · %lld×%lld", Int64(grid.cols), Int64(grid.rows)),
                detail: L10n.string("Mac size returns shortly after the remote view closes"),
                toolTip: L10n.string("The iPhone controls the terminal size while its remote view is open.")
            )
        } else {
            remoteViewportBanner.hide()
        }
    }

    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {
        // A terminated runtime still drains its last bytes through here while its processes
        // exit. Registering that output would have the process observer sample a tree that is
        // dying in the checkout a move just left, and read it as fresh drift.
        if isRunning {
            SessionExecutionProcessObserver.shared.noteOutput(
                sessionID: sessionID,
                rootPID: session.localShellPid
            )
        }
        if let acceptedByteCount = activityTracker.recordOutput(byteCount: byteCount) {
            AgentWorkloadMonitor.shared.recordActivity(
                sessionID: sessionID,
                magnitude: AgentActivityPulse.output(byteCount: acceptedByteCount)
            )
        }
        attachmentObserver?.noteOutput()
        scheduleProviderTitleRefresh()
        scheduleCodexTurnBoundaryRefresh()
        scheduleCodexContinuationBoundaryRefresh(
            after: CodexTurnBoundaryDefaults.continuationOutputProbeDelay,
            outputPrompted: true
        )
        scheduleClaudeBoundaryRefresh()
        scheduleRunProgressTranscriptRefresh()

        // Grok and OpenCode do not create a record for a blank TUI. Output after the initial
        // discovery window may mean the first prompt landed; retry at a bounded cadence until
        // the public session list contains it.
        if agentKind.supports(.deferredSessionIdentifier),
           Date() >= nextIdentifierDiscoveryAt {
            discoverAssignedSessionID()
        }
    }

    func terminalSession(_ session: TerminalSession, didReceiveUserInput input: TerminalUserInput) {
        ProjectStore.shared.noteUserWriting(in: sessionID)
        activityTracker.noteUserInput(submitsLine: input.submitsLine)
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
        launchSurvivalWorkItem?.cancel()
        launchSurvivalWorkItem = nil

        // Read the screen before anything else touches this controller: the terminal buffer is
        // still whole here — `processTerminated` closes the PTY and leaves the view alone — and
        // it is about to be the only place the reason for this exit was ever written down.
        let failure = launchFailure(exitCode: exitCode, screen: session.visibleScreenLines())
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

        if let failure {
            // A second record, because the first one is a line in a journal and this one is the
            // thing a person will be shown. Its summary is logged rather than its captured
            // output: the journal is not reviewed before it is read, and the output is not.
            EventLog.shared.record(.session, "Agent failed to launch", [
                "session": sessionID.uuidString,
                "exitCode": exitCode.map(String.init) ?? "unknown",
                "cause": failure.knownCause ?? "unrecognised"
            ])
        }

        self.projectStore.update(sessionID: sessionID) { stored in
            stored.lastExitCode = exitCode
            stored.lastActiveAt = Date()
            if let failure {
                stored.lastLaunchFailure = failure
            }
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

    var isHostBacked: Bool { session.isHostBacked }

    /// A quit hands this session over rather than ending it. The seeds only this process can
    /// compute go with it, which is why this runs while the emulator is still here.
    ///
    /// The tracker is deliberately **not** marked dormant: nothing became dormant. The agent is
    /// still working, in a process that is about to outlive this one.
    func detachFromBackgroundHost(by deadline: Date) -> Bool {
        detachFromBackgroundHost(by: deadline, idleExpiresAt: nil)
    }

    func detachFromBackgroundHost(by deadline: Date, idleExpiresAt: Date?) -> Bool {
        guard isRunning,
              session.detachFromHost(by: deadline, idleExpiresAt: idleExpiresAt) else {
            return false
        }
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
        isRunning = false
        resetTranscriptFallbackObservation()
        return true
    }

    var terminalRootProcessIdentifier: pid_t? {
        session.localShellPid > 0 ? session.localShellPid : nil
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

// MARK: - Banners

enum AgentSessionBannerDefaults {
    static let remoteViewportSymbol = "iphone"
    static let remoteViewportIdentifier = "session.banner.remote-viewport"
    static let remoteHostIdentifier = "session.banner.remote-host"
}
