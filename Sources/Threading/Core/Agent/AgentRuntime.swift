import Foundation

/// Text input accepted by a running agent terminal.
///
/// Context handoff and message delivery share these two PTY operations, but neither receives the
/// terminal emulator, its view, or the controller adapting it.
@MainActor
protocol AgentTerminalInputSurface: AnyObject {
    func pasteTerminalText(_ text: String)
    func insertTerminalText(_ text: String)
}

/// The terminal facts and mutations owned by limit recovery.
///
/// This is deliberately separate from ordinary input: reading the visible grid and changing the
/// activity park are authority only the recovery policy needs.
@MainActor
protocol AgentTerminalLimitRecoverySurface: AgentTerminalInputSurface {
    func visibleTerminalScreenLines() -> [String]
    func noteLimitCleared()
    func noteLimitParked(recoveryArmed: Bool)
}

/// The process root exposed to session-scoped runtime inspection.
///
/// Extensions receive only the eventual bounded snapshot. Core's provider gets this scalar
/// identity without acquiring a terminal, controller, or process-table service.
@MainActor
protocol AgentTerminalProcessSurface: AnyObject {
    var terminalRootProcessIdentifier: pid_t? { get }
}

/// The application/runtime surface retained for a terminal-backed agent session.
///
/// Controller construction and AppKit presentation live in UI. Core retains only the lifecycle
/// and reporting operations it owns, plus the narrower terminal capability exposed to remote
/// frontends. No view or controller type crosses this boundary.
@MainActor
protocol AgentTerminalRuntimeSurface:
    AgentTerminalLimitRecoverySurface,
    AgentTerminalProcessSurface
{
    var isRunning: Bool { get }
    var activity: SessionActivity { get }
    var activityTracker: SessionActivityTracker { get }
    var runProgress: RunProgress? { get }
    var isVisible: Bool { get set }
    var remoteTerminalSurface: any RemoteTerminalSurface { get }

    /// Whether this session's child lives in `threading-ptyd` rather than in this process.
    var isHostBacked: Bool { get }

    func noteStateChanged()
    func applyRunProgress(_ report: HookRunProgressReport)
    func noteReportedCodexTranscript(path: String?, providerSessionID: TranscriptID?)
    func noteCodexTurnFinishedForContinuationDetection()
    func noteTurnFinishedForAttachmentDetection(lastAssistantMessage: String?)
    func terminate()

    /// Hands this session's child to the background PTY host instead of ending it, answering
    /// whether it did.
    ///
    /// The counterpart of `terminate()` on the one path that is not a stop: a quit. A session
    /// whose pty is in this process has nothing to hand over and answers false, and `terminate()`
    /// is still its ending. **Blocking, bounded by `deadline`** — the frame has to have left
    /// before the process does.
    func detachFromBackgroundHost(by deadline: Date) -> Bool

    func removeFromPresentation()
}

extension AgentTerminalRuntimeSurface {

    /// Defaults so a surface with no pty of its own — and every test double — is unchanged by the
    /// background host existing.
    var isHostBacked: Bool { false }

    func detachFromBackgroundHost(by deadline: Date) -> Bool { false }

    /// Only Codex terminal surfaces own a rollout reader. Other runtime surfaces and focused
    /// test doubles have no continuation protocol to reconcile.
    func noteCodexTurnFinishedForContinuationDetection() {}
}

/// The application/runtime surface retained for a natively rendered conversation.
///
/// UI owns the AppKit controller and provider-specific stream. Core retains only the live
/// capabilities shared by lifecycle, delivery, context handoff, remote control, and process
/// inspection. Keeping this parallel to `AgentTerminalRuntimeSurface` makes renderer choice a
/// runtime detail instead of an upward dependency on either concrete controller.
@MainActor
protocol AgentConversationRuntimeSurface:
    AppMessageReceiving,
    SessionContextReceiving,
    RemoteConversationSurface
{
    var activity: SessionActivity { get }
    var isTurnInFlight: Bool { get }
    var runProgress: RunProgress? { get }
    var isVisible: Bool { get set }
    var onAttention: (() -> Void)? { get set }
    var conversationRootProcessIdentifier: pid_t? { get }

    /// The input behind this surface's current state, where it has one to name. Defaulted
    /// rather than required, because a surface that computes its activity has no such input —
    /// see `AgentRuntime.activityCause(sessionID:)`.
    var activityCause: SessionActivityCause? { get }

    /// Whether this conversation's CLI lives in `threading-ptyd` rather than in this process.
    var isHostBacked: Bool { get }

    func resolveRemotePermission(id: String, decision: RemotePermissionDecision) -> Bool
    func resolveManagerPermission(id: String, decision: ControlPermissionDecision) -> Bool
    func terminate(preservingViewport: Bool)
    func checkoutMoveOutboxSnapshot() -> ConversationOutbox?
    func restoreCheckoutMoveOutbox(_ outbox: ConversationOutbox)

    /// Hands this conversation's CLI to the background PTY host instead of ending it, answering
    /// whether it did.
    ///
    /// The terminal surface's rule, one renderer over: a quit is the one teardown that is not a
    /// stop. **Blocking, bounded by `deadline`**, which the caller shares across every session.
    func detachFromBackgroundHost(by deadline: Date) -> Bool

    func removeFromPresentation()
}

extension AgentConversationRuntimeSurface {

    /// A surface that derives its own state names no input, and says so rather than guessing.
    var activityCause: SessionActivityCause? { nil }

    /// Defaults so a renderer with no host-backed path — and every test double — is unchanged by
    /// the background host existing.
    var isHostBacked: Bool { false }

    func detachFromBackgroundHost(by deadline: Date) -> Bool { false }

    func checkoutMoveOutboxSnapshot() -> ConversationOutbox? { nil }
    func restoreCheckoutMoveOutbox(_ outbox: ConversationOutbox) {}
}

/// Tracks the live terminal runtimes backing agent sessions.
///
/// Runtime surfaces are cached per session so switching away in the sidebar and back does not
/// restart the agent or lose scrollback. A session with no entry here is dormant: it exists
/// in `ProjectStore` and can be resumed, but owns no PTY.
@MainActor
final class AgentRuntime: RemoteTerminalSurfaceQuerying {

    // MARK: - Singleton

    static let shared = AgentRuntime(
        currentSessionProjection: .projectStore(ProjectStore.shared)
    )

    private let currentSessionProjection: CurrentSessionProjection
    private let readReceipts: SessionReadReceiptStore
    private let remotelyViewingParticipantIDs: @MainActor (SessionID) -> Set<String>
    private let ownerAlertWasAcknowledged: @MainActor (SessionID) -> Void
    private let localSessionVisibilityChanged: @MainActor (SessionID?) -> Void

    init(
        currentSessionProjection: CurrentSessionProjection,
        readReceipts: SessionReadReceiptStore = .shared,
        remotelyViewingParticipantIDs: @escaping @MainActor (SessionID) -> Set<String> = {
            RemoteSessionMirrorRegistry.shared.viewingParticipantIDs(for: $0)
        },
        ownerAlertWasAcknowledged: @escaping @MainActor (SessionID) -> Void = {
            AttentionAlertCenter.shared.sessionWasViewed($0)
        },
        localSessionVisibilityChanged: @escaping @MainActor (SessionID?) -> Void = {
            RemoteSessionMirrorRegistry.shared.localSessionVisibilityChanged($0)
        }
    ) {
        self.currentSessionProjection = currentSessionProjection
        self.readReceipts = readReceipts
        self.remotelyViewingParticipantIDs = remotelyViewingParticipantIDs
        self.ownerAlertWasAcknowledged = ownerAlertWasAcknowledged
        self.localSessionVisibilityChanged = localSessionVisibilityChanged
    }

    // MARK: - Properties

    private var controllers: [SessionID: any AgentTerminalRuntimeSurface] = [:]
    private var checkoutMoveOutboxes: [SessionID: ConversationOutbox] = [:]

#if DEBUG
    /// Per-session launch seams for deterministic whole-app tests.
    ///
    /// The key is the containment: a fixture can replace one process only, and only before its
    /// controller exists. Shipping identity and capability policy remain `AgentKind`'s job.
    private var fixtureLaunchPlanProviders: [SessionID: AgentLaunchPlanProvider] = [:]
#endif

    /// Live conversation runtimes, for sessions Threading renders itself.
    ///
    /// Kept separate from `controllers` rather than behind a shared protocol: the two drive
    /// the CLI in different ways and share almost no surface beyond starting and stopping.
    /// A session appears in exactly one of the two.
    private var conversations: [SessionID: any AgentConversationRuntimeSurface] = [:]

    /// Provider-neutral child timelines outlive either renderer.
    ///
    /// A native/terminal switch deliberately discards its controller and process. Keeping this
    /// state beside the controllers, rather than inside either one, preserves the hierarchy
    /// across that switch and restores its compact snapshot after an app relaunch.
    private var subagentStates: [SessionID: SubagentSessionState] = [:]

    /// Identifiers of every session currently holding a live terminal.
    var liveSessionIDs: Set<SessionID> {
        Set(controllers.keys)
    }

    // MARK: - UI Composition

    /// The typed runtime value behind UI's concrete adapter lookup.
    func terminalRuntimeSurface(for sessionID: SessionID) -> (any AgentTerminalRuntimeSurface)? {
        controllers[sessionID]
    }

    /// A running terminal's text-input capability, used by context handoff and message delivery.
    func runningTerminalInputSurface(
        for sessionID: SessionID
    ) -> (any AgentTerminalInputSurface)? {
        guard let surface = controllers[sessionID], surface.isRunning else { return nil }
        return surface
    }

    /// Limit recovery may lower a park after the process exits, so this query intentionally
    /// includes an allocated stopped terminal. Callers that type use the running-only variant.
    func limitRecoverySurface(
        for sessionID: SessionID
    ) -> (any AgentTerminalLimitRecoverySurface)? {
        controllers[sessionID]
    }

    func runningLimitRecoverySurface(
        for sessionID: SessionID
    ) -> (any AgentTerminalLimitRecoverySurface)? {
        guard let surface = controllers[sessionID], surface.isRunning else { return nil }
        return surface
    }

    /// The live agent process root, as a value rather than an exposed runtime object.
    func terminalRootProcessIdentifier(for sessionID: SessionID) -> pid_t? {
        controllers[sessionID]?.terminalRootProcessIdentifier
    }

    /// Registers the UI-created adapter once. Main-actor composition makes this atomic without
    /// a second cache or a controller lookup hidden inside Core.
    @discardableResult
    func registerTerminalRuntimeSurface(
        _ surface: any AgentTerminalRuntimeSurface,
        for sessionID: SessionID
    ) -> Bool {
        guard controllers[sessionID] == nil else { return false }
        surface.activityTracker.onAttention = { [weak self] in
            self?.noteSessionAttention(sessionID)
        }
        controllers[sessionID] = surface
        return true
    }

    /// The typed runtime value behind UI's concrete native-conversation adapter lookup.
    func conversationRuntimeSurface(
        for sessionID: SessionID
    ) -> (any AgentConversationRuntimeSurface)? {
        conversations[sessionID]
    }

    /// Registers the UI-created native adapter once. Attention is wired at the same ownership
    /// edge so every renderer enters Core with the complete lifecycle contract installed.
    @discardableResult
    func registerConversationRuntimeSurface(
        _ surface: any AgentConversationRuntimeSurface,
        for sessionID: SessionID
    ) -> Bool {
        guard conversations[sessionID] == nil else { return false }
        surface.onAttention = { [weak self] in
            self?.noteSessionAttention(sessionID)
        }
        conversations[sessionID] = surface
        return true
    }

    /// UI needs the same current-session projection that Core was previously passing into the
    /// concrete constructor. Exposing the model seam preserves one source of current truth
    /// without exposing controller construction in the opposite direction.
    func conversationSessionProjection() -> CurrentSessionProjection {
        currentSessionProjection
    }

    func fixtureLaunchPlanProvider(for sessionID: SessionID) -> AgentLaunchPlanProvider? {
#if DEBUG
        fixtureLaunchPlanProviders[sessionID]
#else
        nil
#endif
    }

    // MARK: - RemoteTerminalSurfaceQuerying

    var remoteTerminalIdentities: Set<TerminalInstanceIdentity> {
        Set(controllers.keys.map(TerminalInstanceIdentity.agentSession))
    }

    func remoteTerminalSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)? {
        guard case .agentSession(let sessionID) = identity else { return nil }
        return controllers[sessionID]?.remoteTerminalSurface
    }

    // MARK: - Public Methods

#if DEBUG
    /// Installs a deterministic process for one not-yet-materialized session.
    ///
    /// Returning false instead of replacing a live controller keeps the seam from changing the
    /// meaning of an already-running session halfway through a test.
    @discardableResult
    func installFixtureLaunchPlan(
        for sessionID: SessionID,
        provider: @escaping AgentLaunchPlanProvider
    ) -> Bool {
        guard controllers[sessionID] == nil, conversations[sessionID] == nil else {
            return false
        }
        fixtureLaunchPlanProviders[sessionID] = provider
        return true
    }

    func removeFixtureLaunchPlan(for sessionID: SessionID) {
        fixtureLaunchPlanProviders.removeValue(forKey: sessionID)
    }
#endif

    /// Whether the session's agent process is currently running.
    func isRunning(sessionID: SessionID) -> Bool {
        controllers[sessionID]?.isRunning ?? conversations[sessionID]?.isRunning ?? false
    }

    /// Every session holding a live agent, from either renderer.
    ///
    /// Asks `isRunning` per session rather than filtering the two caches separately, so it
    /// cannot answer differently from the check every other caller makes — a session with both
    /// a terminal and a rendered conversation appears once, and appears by the same rule.
    /// Also what the quit path records for the next launch to relaunch.
    var runningSessionIDs: Set<SessionID> {
        Set(controllers.keys).union(conversations.keys)
            .filter { isRunning(sessionID: $0) }
    }

    /// How many sessions have a live agent, for the quit confirmation to name.
    var runningSessionCount: Int {
        runningSessionIDs.count
    }

    /// How many of those are mid-turn — the subset a quit actually costs something.
    ///
    /// Counted apart from `runningSessionCount` because the two are usually far apart: a
    /// session sits alive and idle at its prompt for hours between turns, so most of what is
    /// "running" at any moment is waiting on the user, not working. The quit sheet names both,
    /// and leads with this one.
    var inFlightTurnCount: Int {
        inFlightTurnCount(among: runningSessionIDs)
    }

    /// The same count over a stated set, for a caller that has already decided which sessions
    /// its question is about.
    func inFlightTurnCount(among sessionIDs: Set<SessionID>) -> Int {
        sessionIDs
            .filter { activity(sessionID: $0).hasTurnInFlight }
            .count
    }

    /// Every running session whose child lives in `threading-ptyd` rather than in this process.
    ///
    /// A quit hands these over rather than ending them, so a question about what quitting costs
    /// must not count them. The wording of that question is the visibility surface's — slice 9 of
    /// [`pty-host.md`](../../../../docs/architecture/pty-host.md) — and this is only the count
    /// refusing to claim a loss that does not happen.
    /// Both renderers, because both can have one: a terminal's pty and a native conversation's
    /// three pipes are the same `channel` discriminator on the same `spawn` frame.
    var hostBackedSessionIDs: Set<SessionID> {
        let terminals = controllers.compactMap { sessionID, surface in
            surface.isHostBacked && surface.isRunning ? sessionID : nil
        }
        let conversed = conversations.compactMap { sessionID, surface in
            surface.isHostBacked && surface.isRunning ? sessionID : nil
        }
        return Set(terminals).union(conversed)
    }

    /// Hands every host-backed session's child to `threading-ptyd`, and answers which they were.
    ///
    /// The quit path's step, taken **before** `terminateAll`, which would otherwise kill exactly
    /// these children. It is also where the two seeds only this process can compute are handed
    /// over, so it has to run while the emulators are still here.
    ///
    /// **Blocking, and bounded once for the whole set**: one deadline shared by every session, so
    /// forty host-backed sessions cost the same wait as one.
    @discardableResult
    func detachHostBackedSessions() -> Set<SessionID> {
        let deadline = Date().addingTimeInterval(PTYHostSessionDefaults.detachDrainSeconds)
        var detached: Set<SessionID> = []
        for (sessionID, controller) in controllers
        where controller.detachFromBackgroundHost(by: deadline) {
            detached.insert(sessionID)
        }
        for (sessionID, conversation) in conversations
        where conversation.detachFromBackgroundHost(by: deadline) {
            detached.insert(sessionID)
        }
        guard !detached.isEmpty else { return detached }
        EventLog.shared.record(.session, "Sessions left running in the PTY host", [
            "sessions": String(detached.count)
        ])
        return detached
    }

    /// Ends every host-backed session's child rather than handing it over, and answers which they
    /// were.
    ///
    /// The other half of the quit question's third answer. It runs **before**
    /// `detachHostBackedSessions()`, which then finds nothing left to hand over — `terminate()`
    /// clears `isRunning`, and detaching guards on it — so the two steps compose rather than
    /// racing. Nothing else may call this: a stop that nobody asked for is exactly what the
    /// daemon exists to prevent, and every other teardown path deliberately hands these children
    /// over instead.
    @discardableResult
    func terminateHostBackedSessions() -> Set<SessionID> {
        let hosted = hostBackedSessionIDs
        guard !hosted.isEmpty else { return [] }
        for sessionID in hosted {
            controllers[sessionID]?.terminate()
            // The viewport is preserved for the same reason every other teardown preserves it:
            // the conversation is being stopped, not closed, and it opens again where it was.
            conversations[sessionID]?.terminate(preservingViewport: true)
        }
        EventLog.shared.record(.session, "Background host sessions stopped at quit", [
            "sessions": String(hosted.count)
        ])
        return hosted
    }

    /// What the session is currently doing. Sessions with no terminal are dormant.
    func activity(sessionID: SessionID) -> SessionActivity {
        activity(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        )
    }

    /// Reader-specific activity for remote catalogues. Operational states are shared; only the
    /// finished-result mark is projected through the stable participant's durable receipt.
    func activity(sessionID: SessionID, participantID: String) -> SessionActivity {
        readReceipts.project(
            sharedActivity(sessionID: sessionID),
            sessionID: sessionID,
            participantID: participantID
        )
    }

    /// Why this session's activity last moved, where its runtime keeps that answer.
    ///
    /// Exposed for `AttentionAlertCenter`, so a journalled banner can name the input that
    /// produced it rather than leaving a reader with the three candidates the state alone
    /// allows — a turn that ended off screen, the runtime's own idle-prompt notice, a bell.
    /// `nil` where the runtime *derives* its state instead of being told it: a native
    /// conversation computes `activity` from the stream and holds no separate fact to report.
    func activityCause(sessionID: SessionID) -> SessionActivityCause? {
        controllers[sessionID]?.activityTracker.lastCause
            ?? conversations[sessionID]?.activityCause
    }

    private func sharedActivity(sessionID: SessionID) -> SessionActivity {
        controllers[sessionID]?.activity ?? conversations[sessionID]?.activity ?? .dormant
    }

    /// Opens one unread generation and spends it immediately for participants who already have
    /// this conversation on screen. Socket presence is reduced to stable person identities here.
    func noteSessionAttention(_ sessionID: SessionID) {
        var viewers = remotelyViewingParticipantIDs(sessionID)
        if visibleSessionID == sessionID {
            viewers.insert(SessionReadReceiptStore.ownerParticipantID)
        }
        _ = readReceipts.recordAttention(for: sessionID, seenBy: viewers)
        NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
    }

    /// Marks the current generation read for one person across all of their devices.
    ///
    /// The owner's acknowledgement also withdraws the macOS alert unconditionally. The system
    /// may still hold a notification posted by an earlier app process, while this process has no
    /// in-memory activity edge or receipt mutation with which to discover it. Removing by the
    /// session's stable request identifier is idempotent and closes that relaunch path.
    func acknowledgeAttention(sessionID: SessionID, participantID: String) {
        if participantID == SessionReadReceiptStore.ownerParticipantID {
            ownerAlertWasAcknowledged(sessionID)
        }
        guard readReceipts.acknowledge(
            sessionID: sessionID,
            participantID: participantID
        ) else { return }
        NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
    }

    /// Applies a lifecycle report from an agent's own hooks to the session that raised it.
    ///
    /// Only terminal sessions are routed here. A rendered conversation learns its turn
    /// boundaries from the stream it is already reading — it sent the message and it sees the
    /// result — so a hook would tell it something it knows, one process later.
    func applyLifecycle(_ report: HookLifecycleReport) {
        if report.event == .subagentStarted || report.event == .subagentStopped {
            applySubagentLifecycle(report)
            return
        }

        if report.event == .sessionStarted {
            adoptReportedIdentifier(report)
        }

        // The first prompt names a session that nothing has named yet — the one case the
        // composer cannot cover, a prompt typed straight into the terminal. Applied before
        // the tracker guard because a rendered conversation's report carries a prompt too.
        if report.event == .turnStarted, let prompt = report.prompt, !prompt.isEmpty {
            ProjectStore.shared.applyPromptTitle(prompt, forSessionID: report.sessionID)
        }

        // Before the tracker guard on purpose: the receipt is about the report arriving,
        // and a session mid-registration still owes its waiters the answer.
        if report.event == .turnStarted {
            resolveTurnStartWaiters(for: report.sessionID)
        }

        guard let controller = controllers[report.sessionID] else {
            // Ordinary for a rendered conversation, which learns its boundaries from the stream
            // and has no terminal controller. Recorded at debug because it is also what a
            // report for an already-closed session looks like.
            ThreadingLogger.agent.debug(
                "Lifecycle report for a session with no terminal: \(report.sessionID.uuidString, privacy: .public)"
            )
            return
        }
        let tracker = controller.activityTracker

        // Codex reports the rollout's exact path on its hooks. Remembering that path avoids a
        // session-tree walk on terminal output and gives the transcript fallback for the one
        // terminal boundary Codex 0.147.0 omits from hooks: an interrupted turn.
        controller.noteReportedCodexTranscript(
            path: report.transcriptPath,
            providerSessionID: report.agentSessionID
        )

        // The one transition worth a durable record. Before it, a session's status is inferred
        // from output; after it, the agent is saying so. "Did the hooks actually reach this
        // session" is the first question any report about this feature raises, and this is the
        // only line that answers it.
        let wasInferring = !tracker.reportsOwnActivity

        // These are new edges, not readings of the resulting state. That distinction is what
        // lets Snooze ignore a request that was already pending when the action was chosen.
        switch report.event {
        case .turnFinished:
            SessionSnoozeCenter.shared.record(.turnCompleted, for: report.sessionID)
            // The turn's own boundary is where this session's observed work catches up. A hook
            // per tool call would be exact and would spend a spawned process on every `Read`;
            // the transcript already holds every call, and the turn end is when it is complete.
            AgentWorkHydration.hydrate(sessionID: report.sessionID)
        case .awaitingUser:
            // Asked of the tracker rather than assumed. A runtime's "waiting" notice is not
            // always a request for input — an idle prompt on a session paused on its own child
            // is the CLI stating that nothing is being asked — and ending a snooze for one is
            // the same misreading the sidebar already refuses. One rule, one answer.
            if tracker.honoursAwaitingUserNotice(report.notification) {
                SessionSnoozeCenter.shared.record(.inputRequested, for: report.sessionID)
            }
        case .blockingAskOpened:
            SessionSnoozeCenter.shared.record(.inputRequested, for: report.sessionID)
        case .turnStarted, .blockingAskClosed, .sessionStarted, .subagentStarted, .subagentStopped:
            break
        }

        switch report.event {
        case .turnStarted: tracker.noteTurnStarted(turnID: report.turnID)
        case .turnFinished:
            if !report.backgroundWork.isEmpty {
                // The one line that explains a session sitting at `working` with a quiet
                // terminal: its agent is waiting on something it started, not on the user.
                // The delegated count is called out separately because it is the half that
                // pauses the session however old it is.
                let delegated = report.backgroundWork.filter { $0.kind == .delegated }.count
                ThreadingLogger.agent.debug(
                    """
                    Turn ended with \(report.backgroundWork.count, privacy: .public) \
                    background task(s) in flight, \(delegated, privacy: .public) delegated, for \
                    \(report.sessionID.uuidString, privacy: .public)
                    """
                )
            }
            let continuationGrace = ProjectStore.shared.session(withID: report.sessionID)?.kind
                == .codex
                ? CodexTurnBoundaryDefaults.continuationGrace
                : nil
            tracker.noteTurnFinished(
                backgroundWork: report.backgroundWork,
                continuationGrace: continuationGrace
            )
            if continuationGrace != nil {
                controller.noteCodexTurnFinishedForContinuationDetection()
            }
            // Usually the activity edge above has already scheduled this scan. Starting the
            // generation again here preserves the hook's intact fast-path message and also
            // covers turns that remain visually `working` because they left background work.
            controller.noteTurnFinishedForAttachmentDetection(
                lastAssistantMessage: report.lastAssistantMessage
            )
        case .awaitingUser: tracker.noteAwaitingUser(report.notification)
        case .blockingAskOpened: tracker.noteBlockingAskOpened(id: report.toolCallID)
        case .blockingAskClosed: tracker.noteBlockingAskClosed(id: report.toolCallID)
        // Not a turn boundary, but the earliest proof the CLI is up: delivery gates on it.
        // Dropped on the floor here, it left every session idle since an app relaunch
        // reading as still-booting — refused by send_to_session while listed as idle.
        //
        // It is announced as an activity change even though the *state* did not move, because
        // what moved is the thing delivery asks about: a session that could not be typed into
        // a moment ago can be now. `SessionWatchCenter` drains the notices it held for exactly
        // this session on that edge, and without the announcement a notice held during a boot
        // waits for some unrelated later edge — for a session that then sits idle, forever.
        case .sessionStarted:
            tracker.noteSessionStarted()
            NotificationCenter.default.post(SessionActivityDidChange(sessionID: report.sessionID))
        case .subagentStarted, .subagentStopped: break
        }

        if wasInferring, tracker.reportsOwnActivity {
            ThreadingLogger.agent.info(
                "Session reports its own activity: \(report.sessionID.uuidString, privacy: .public)"
            )
            EventLog.shared.record(.hooks, "Session began reporting its own activity", [
                "session": report.sessionID.uuidString,
                "event": report.event.rawValue
            ])
        }
    }

    /// Routes structured todo/plan observations only to terminal sessions. Native conversations
    /// already receive the same provider-neutral events over their own stream.
    func applyRunProgress(_ report: HookRunProgressReport) {
        guard let controller = controllers[report.sessionID] else {
            ThreadingLogger.agent.debug(
                "Run progress for a session with no terminal: \(report.sessionID.uuidString, privacy: .public)"
            )
            return
        }
        controller.applyRunProgress(report)
    }

    func runProgress(for sessionID: SessionID) -> RunProgress? {
        if let controller = controllers[sessionID],
           controller.activity.hasTurnInFlight {
            return controller.runProgress
        }
        if let conversation = conversations[sessionID], conversation.isTurnInFlight {
            return conversation.runProgress
        }
        return nil
    }

    /// Folds terminal hook events into the same hierarchy native transports report.
    ///
    /// Claude native uses an Agent tool-use id as its stable UI identity, while Claude's hook
    /// reports a different agent id. Applying both would create twins, so Claude hooks are the
    /// terminal adapter only. Codex app-server and Codex hooks use the child thread id in both
    /// places, allowing the hook to enrich a native row with its transcript path too.
    private func applySubagentLifecycle(_ report: HookLifecycleReport) {
        guard let stored = ProjectStore.shared.session(withID: report.sessionID),
              let childID = report.subagentID, !childID.isEmpty else {
            return
        }

        if !stored.kind.supports(.sharedSubagentIdentity),
           conversations[report.sessionID] != nil {
            return
        }

        let state = subagentState(for: report.sessionID)

        // Not every subagent hook is about a subagent: Claude reports the root agent's own turn
        // through the same events. See `describesChildAgent` for the shape and the measurements.
        guard report.describesChildAgent(
            isAlreadyTracked: state.timeline.contains(threadID: childID)
        ) else {
            ThreadingLogger.agent.debug(
                """
                Ignored a \(report.event.rawValue, privacy: .public) naming no child agent for \
                \(report.sessionID.uuidString, privacy: .public)
                """
            )
            return
        }

        state.apply(.discovered(SubagentDescriptor(
            threadID: childID,
            parentThreadID: report.agentSessionID?.rawValue,
            // An empty type is the parent reporting itself, never a child's role. Storing it
            // would put `""` on the descriptor and leave `displayName` guessing.
            role: report.subagentType.flatMap { $0.isEmpty ? nil : $0 },
            path: report.subagentTranscriptPath
        )))

        switch report.event {
        case .subagentStarted:
            state.apply(.state(
                threadID: childID,
                status: .working,
                message: nil
            ))
        case .subagentStopped:
            let finalMessage = report.lastAssistantMessage.map(
                SubagentDefaults.compactActivity
            )
            state.apply(.state(
                threadID: childID,
                status: .completed,
                message: finalMessage
            ))
            if let path = report.subagentTranscriptPath, !path.isEmpty {
                SubagentUsageReader.load(path: path, kind: stored.kind) { totalTokens in
                    guard let totalTokens else { return }
                    state.apply(.progress(
                        threadID: childID,
                        progress: SubagentProgress(totalTokens: totalTokens)
                    ))
                }
            }
        case .turnStarted, .turnFinished, .awaitingUser, .sessionStarted,
             .blockingAskOpened, .blockingAskClosed:
            break
        }
    }

    /// Adopts the identifier an agent reports for itself at launch.
    ///
    /// This is what `CodexSessionDiscovery` recovers by watching the rollout directory and
    /// matching on a launch timestamp. `SessionStart` simply hands it over, already attributed
    /// to the session by the token in the hook's URL — so there is nothing to match and no
    /// window in which two sessions launched together can be confused.
    ///
    /// Only a session still `awaitingIdentifier` is updated. Claude reports one too, but it
    /// reports the identifier Threading minted and already stored, and a resumed Codex session
    /// reports the one it was resumed with — in both cases writing it back is a no-op worth
    /// skipping rather than a correction.
    private func adoptReportedIdentifier(_ report: HookLifecycleReport) {
        guard let reported = report.agentSessionID,
              let stored = ProjectStore.shared.session(withID: report.sessionID),
              stored.resumeState == .awaitingIdentifier else {
            return
        }

        ProjectStore.shared.update(sessionID: report.sessionID) { session in
            session.resumeState = .resumable(reported)
        }

        ThreadingLogger.agent.info(
            "Adopted reported session \(reported.rawValue, privacy: .public)"
        )
        controllers[report.sessionID]?.noteStateChanged()
    }

    /// The session currently on screen, as last reported by the container.
    private(set) var visibleSessionID: SessionID?

    /// Marks which session is on screen, so only the others flag finished work.
    func setVisibleSession(_ sessionID: SessionID?) {
        visibleSessionID = sessionID
        // Selection is a viewport owner as well as attention state. A disconnected phone may
        // keep its grid only while no local renderer is looking at this session; publishing the
        // transition here also catches a Mac opening a chat after the phone's grace began.
        localSessionVisibilityChanged(sessionID)
        for (id, controller) in controllers {
            controller.isVisible = (id == sessionID)
        }
        for (id, conversation) in conversations {
            conversation.isVisible = (id == sessionID)
        }
        // Coming on screen answers the session's notification the same way it lowers its
        // sidebar flag — the no-op before `start()` keeps notification machinery out of tests.
        if let sessionID {
            acknowledgeAttention(
                sessionID: sessionID,
                participantID: SessionReadReceiptStore.ownerParticipantID
            )
            SessionSnoozeCenter.shared.acknowledge(sessionID)
        }
    }

    /// Whether the session's agent declares its own turn boundaries — a hook-reporting
    /// terminal or a native conversation — rather than being inferred from output. What
    /// separates "a turn ended" from "a shell went quiet".
    func reportsOwnTurns(sessionID: SessionID) -> Bool {
        if let controller = controllers[sessionID] {
            return controller.activityTracker.reportsOwnActivity
        }
        return conversations[sessionID] != nil
    }

    /// Whether the session's current process has been heard from at all — its `SessionStart`
    /// hook or any later lifecycle report. Deliberately weaker than `reportsOwnTurns`: it
    /// proves the CLI is up without claiming turn boundaries will be declared, which is the
    /// question delivery asks before typing into a PTY.
    func hasHeardFromProcess(sessionID: SessionID) -> Bool {
        if let controller = controllers[sessionID] {
            return controller.activityTracker.hasHeardFromProcess
        }
        return conversations[sessionID] != nil
    }

    // MARK: - Turn-Start Receipts

    private struct TurnStartWaiter {
        let token: UUID
        let sessionID: SessionID
        let completion: @MainActor (Bool) -> Void
    }

    /// Ordered, because a turn report is evidence for **one** message rather than for every
    /// message outstanding. Held as an array so the oldest waiter — the delivery that typed
    /// first — is the one a report answers for.
    private var turnStartWaiters: [TurnStartWaiter] = []

    /// One-shot: answers `true` when the session next *reports* a started turn, `false` at the
    /// timeout. Resolved only by the session's own lifecycle reports, never by the output
    /// heuristic — the caller is asking "did the CLI accept what was typed", and inferred
    /// turns are precisely what a compaction repaint fakes.
    func awaitReportedTurnStart(
        sessionID: SessionID,
        timeout: TimeInterval,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let token = UUID()
        turnStartWaiters.append(
            TurnStartWaiter(token: token, sessionID: sessionID, completion: completion)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  let index = self.turnStartWaiters.firstIndex(where: { $0.token == token })
            else { return }
            let waiter = self.turnStartWaiters.remove(at: index)
            waiter.completion(false)
        }
    }

    /// Spends one turn report on the session's oldest outstanding waiter.
    ///
    /// **One report, one receipt.** Resolving every waiter for the session handed the same
    /// evidence to each of them: two deliveries outstanding, one `UserPromptSubmit` arrives,
    /// and both callers are told `.sentNow` while the CLI accepted one — the silent loss the
    /// receipt exists to prevent, reintroduced by the thing preventing it. Deliveries to one
    /// terminal are serialized upstream (`SessionMessageDelivery.terminalsMidDelivery`), so
    /// in practice there is one waiter to answer; this keeps the arithmetic honest if that
    /// ever stops being true.
    private func resolveTurnStartWaiters(for sessionID: SessionID) {
        guard let index = turnStartWaiters.firstIndex(where: { $0.sessionID == sessionID }) else {
            return
        }
        let waiter = turnStartWaiters.remove(at: index)
        waiter.completion(true)
    }

    /// Whether the session has a terminal allocated, running or exited.
    func hasTerminal(sessionID: SessionID) -> Bool {
        controllers[sessionID] != nil || conversations[sessionID] != nil
    }

    // MARK: - Conversations

    /// The projection/submission seam consumed by Core's remote transport.
    func remoteConversationSurface(for sessionID: SessionID) -> (any RemoteConversationSurface)? {
        conversations[sessionID]
    }

    func resolveRemotePermission(
        sessionID: SessionID,
        id: String,
        decision: RemotePermissionDecision
    ) -> Bool {
        conversations[sessionID]?.resolveRemotePermission(id: id, decision: decision) == true
    }

    /// The same bounded evidence paired clients receive, projected into Core's control contract.
    /// Raw provider arguments stay behind the permission card boundary.
    func pendingControlPermission(sessionID: SessionID) -> ControlPendingPermission? {
        guard let request = conversations[sessionID]?.remoteSnapshot.permission else {
            return nil
        }
        return ControlPendingPermission(
            requestID: request.id,
            toolName: request.toolName,
            summary: request.summary,
            filePath: request.filePath,
            diff: request.diff.compactMap { line in
                guard let kind = ControlPermissionDiffLine.Kind(rawValue: line.kind.rawValue) else {
                    return nil
                }
                return ControlPermissionDiffLine(kind: kind, text: line.text)
            },
            canDecide: request.canDecide,
            unavailableReason: request.unavailableReason
        )
    }

    func resolveManagerPermission(
        sessionID: SessionID,
        id: String,
        decision: ControlPermissionDecision,
        managerID: SessionID
    ) -> Bool {
        guard conversations[sessionID]?.resolveManagerPermission(
            id: id,
            decision: decision
        ) == true else { return false }
        EventLog.shared.record(.session, "Manager resolved permission", [
            "manager": managerID.uuidString,
            "session": sessionID.uuidString,
            "request": id,
            "decision": decision.rawValue,
        ])
        return true
    }

    func subagentState(for sessionID: SessionID) -> SubagentSessionState {
        if let existing = subagentStates[sessionID] { return existing }

        let state = SubagentSessionState(
            sessionID: sessionID,
            store: SubagentStateStore.shared
        )
        subagentStates[sessionID] = state
        return state
    }

    /// Terminates the agent but keeps the terminal so its final output stays visible.
    func terminate(sessionID: SessionID) {
        controllers[sessionID]?.terminate()
        conversations[sessionID]?.terminate(preservingViewport: true)
    }

    /// Terminates the agent and releases its terminal, returning the session to dormant.
    func discard(sessionID: SessionID, preservingViewport: Bool = true) {
#if DEBUG
        fixtureLaunchPlanProviders.removeValue(forKey: sessionID)
#endif
        var discardedRuntime = false
        defer {
            if discardedRuntime {
                // Both renderers have left the runtime maps, so the common activity projection
                // now answers dormant. Consumers must receive that edge even for a native chat,
                // which has no TerminalSessionDidEnd callback of its own.
                NotificationCenter.default.post(
                    SessionActivityDidChange(sessionID: sessionID)
                )
            }
        }

        // No notification exists for a discarded controller, so the mirror is told explicitly:
        // a remote watcher must learn the session ended rather than wait on a dead socket.
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)

        if let conversation = conversations.removeValue(forKey: sessionID) {
            discardedRuntime = true
            conversation.terminate(preservingViewport: preservingViewport)
            subagentStates[sessionID]?.stopWorking(
                message: "Stopped when the session process ended."
            )
            conversation.removeFromPresentation()
        }

        guard let controller = controllers[sessionID] else { return }
        discardedRuntime = true
        controller.terminate()
        subagentStates[sessionID]?.stopWorking(
            message: "Stopped when the session process ended."
        )
        controller.removeFromPresentation()
        controllers[sessionID] = nil
    }

    func preserveCheckoutMoveOutbox(sessionID: SessionID) {
        preserveCheckoutMoveOutbox(
            conversations[sessionID]?.checkoutMoveOutboxSnapshot(),
            for: sessionID
        )
    }

    /// Stores the queue at the runtime ownership edge so replacement is lossless even though
    /// the concrete conversation controller is about to be terminated and removed.
    func preserveCheckoutMoveOutbox(
        _ snapshot: ConversationOutbox?,
        for sessionID: SessionID
    ) {
        guard let snapshot, !snapshot.isEmpty else {
            checkoutMoveOutboxes.removeValue(forKey: sessionID)
            return
        }
        checkoutMoveOutboxes[sessionID] = snapshot
    }

    func takeCheckoutMoveOutbox(sessionID: SessionID) -> ConversationOutbox? {
        checkoutMoveOutboxes.removeValue(forKey: sessionID)
    }

    /// Ends a permanently deleted session and drops its child-agent index without scanning the
    /// state of every unrelated chat. Provider transcripts remain provider-owned.
    func discardDeletedSession(_ sessionID: SessionID) {
        discard(sessionID: sessionID, preservingViewport: false)
        if let state = subagentStates.removeValue(forKey: sessionID) {
            state.invalidate()
        }
        SubagentStateStore.shared.remove(sessionID: sessionID)
    }

    /// Drops memory and disk state for sessions that no longer exist.
    func retainOnly(sessionIDs: Set<SessionID>) {
        for (sessionID, state) in subagentStates where !sessionIDs.contains(sessionID) {
            state.invalidate()
        }
        subagentStates = subagentStates.filter { sessionIDs.contains($0.key) }
        SubagentStateStore.shared.retainOnly(sessionIDs: sessionIDs)
    }

    /// Tears down every live session, used on application exit.
    func terminateAll() {
#if DEBUG
        fixtureLaunchPlanProviders.removeAll()
#endif
        // A host-backed child is the daemon's and outlives this process, so it is handed over
        // rather than ended. `detachHostBackedSessions()` has normally already done it on the
        // quit path and this answers false; the guard is here because tearing every session down
        // must not be a way to kill a child nobody asked to stop.
        let detachDeadline = Date().addingTimeInterval(PTYHostSessionDefaults.detachDrainSeconds)
        for sessionID in controllers.keys {
            RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
            guard controllers[sessionID]?.detachFromBackgroundHost(by: detachDeadline) != true
            else { continue }
            controllers[sessionID]?.terminate()
        }
        controllers.removeAll()

        for sessionID in conversations.keys {
            RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
            guard conversations[sessionID]?.detachFromBackgroundHost(by: detachDeadline) != true
            else { continue }
            conversations[sessionID]?.terminate(preservingViewport: true)
        }
        conversations.removeAll()

        for state in subagentStates.values {
            state.flushPersistence()
        }
    }
}
