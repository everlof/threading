import AppKit

/// Tracks the live terminal controllers backing agent sessions.
///
/// Controllers are cached per session so switching away in the sidebar and back does not
/// restart the agent or lose scrollback. A session with no entry here is dormant: it exists
/// in `ProjectStore` and can be resumed, but owns no PTY.
@MainActor
final class AgentRuntime {

    // MARK: - Singleton

    static let shared = AgentRuntime()
    private init() {}

    // MARK: - Properties

    private var controllers: [SessionID: AgentSessionViewController] = [:]

#if DEBUG
    /// Per-session launch seams for deterministic whole-app tests.
    ///
    /// The key is the containment: a fixture can replace one process only, and only before its
    /// controller exists. Shipping identity and capability policy remain `AgentKind`'s job.
    private var fixtureLaunchPlanProviders: [SessionID: AgentLaunchPlanProvider] = [:]
#endif

    /// Live conversation controllers, for sessions Threading renders itself.
    ///
    /// Kept separate from `controllers` rather than behind a shared protocol: the two drive
    /// the CLI in different ways and share almost no surface beyond starting and stopping.
    /// A session appears in exactly one of the two.
    private var conversations: [SessionID: ConversationViewController] = [:]

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

    // MARK: - Public Methods

    func controller(for sessionID: SessionID) -> AgentSessionViewController? {
        controllers[sessionID]
    }

    /// Returns the cached controller for a session, creating one if needed.
    ///
    /// Creating a controller allocates the terminal but does not start the agent; call
    /// `launch()` on the result once it is installed in the view hierarchy.
    func makeController(for agentSession: AgentSession) -> AgentSessionViewController {
        if let existing = controllers[agentSession.id] {
            return existing
        }

#if DEBUG
        let fixtureLaunchPlanProvider = fixtureLaunchPlanProviders[agentSession.id]
#else
        let fixtureLaunchPlanProvider: AgentLaunchPlanProvider? = nil
#endif
        let controller = AgentSessionViewController(
            agentSession: agentSession,
            subagentState: subagentState(for: agentSession.id),
            launchPlanProvider: fixtureLaunchPlanProvider
        )
        controllers[agentSession.id] = controller
        return controller
    }

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
        runningSessionIDs
            .filter { activity(sessionID: $0).hasTurnInFlight }
            .count
    }

    /// What the session is currently doing. Sessions with no terminal are dormant.
    func activity(sessionID: SessionID) -> SessionActivity {
        controllers[sessionID]?.activity ?? conversations[sessionID]?.activity ?? .dormant
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
            tracker.noteTurnFinished(backgroundWork: report.backgroundWork)
            // Usually the activity edge above has already scheduled this scan. Starting the
            // generation again here preserves the hook's intact fast-path message and also
            // covers turns that remain visually `working` because they left background work.
            controller.noteTurnFinishedForAttachmentDetection(
                lastAssistantMessage: report.lastAssistantMessage
            )
        case .awaitingUser: tracker.noteAwaitingUser()
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
        for (id, controller) in controllers {
            controller.isVisible = (id == sessionID)
        }
        for (id, conversation) in conversations {
            conversation.isVisible = (id == sessionID)
        }
        // Coming on screen answers the session's notification the same way it lowers its
        // sidebar flag — the no-op before `start()` keeps notification machinery out of tests.
        if let sessionID {
            AttentionAlertCenter.shared.sessionWasViewed(sessionID)
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

    func conversation(for sessionID: SessionID) -> ConversationViewController? {
        conversations[sessionID]
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

    /// Returns the cached conversation for a session, creating one if needed.
    func makeConversation(
        for agentSession: AgentSession,
        in project: Project
    ) -> ConversationViewController? {
        if let existing = conversations[agentSession.id] {
            return existing
        }

        guard let conversation = ConversationViewController(
            agentSession: agentSession,
            project: project,
            subagentState: subagentState(for: agentSession.id)
        ) else { return nil }
        conversations[agentSession.id] = conversation
        return conversation
    }

    /// Terminates the agent but keeps the terminal so its final output stays visible.
    func terminate(sessionID: SessionID) {
        controllers[sessionID]?.terminate()
        conversations[sessionID]?.terminate()
    }

    /// Terminates the agent and releases its terminal, returning the session to dormant.
    func discard(sessionID: SessionID) {
#if DEBUG
        fixtureLaunchPlanProviders.removeValue(forKey: sessionID)
#endif
        // No notification exists for a discarded controller, so the mirror is told explicitly:
        // a remote watcher must learn the session ended rather than wait on a dead socket.
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)

        if let conversation = conversations.removeValue(forKey: sessionID) {
            conversation.terminate()
            subagentStates[sessionID]?.stopWorking(
                message: "Stopped when the session process ended."
            )
            conversation.view.removeFromSuperview()
        }

        guard let controller = controllers[sessionID] else { return }
        controller.terminate()
        subagentStates[sessionID]?.stopWorking(
            message: "Stopped when the session process ended."
        )
        controller.view.removeFromSuperview()
        controllers[sessionID] = nil
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
        for sessionID in controllers.keys {
            RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
            controllers[sessionID]?.terminate()
        }
        controllers.removeAll()

        for sessionID in conversations.keys {
            RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
            conversations[sessionID]?.terminate()
        }
        conversations.removeAll()

        for state in subagentStates.values {
            state.flushPersistence()
        }
    }
}
