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

        let controller = AgentSessionViewController(
            agentSession: agentSession,
            subagentState: subagentState(for: agentSession.id)
        )
        controllers[agentSession.id] = controller
        return controller
    }

    /// Whether the session's agent process is currently running.
    func isRunning(sessionID: SessionID) -> Bool {
        controllers[sessionID]?.isRunning ?? conversations[sessionID]?.isRunning ?? false
    }

    /// How many sessions have a live agent, for the quit confirmation to name.
    ///
    /// Asks `isRunning` per session rather than filtering the two caches separately, so it
    /// cannot answer differently from the check every other caller makes — a session with both
    /// a terminal and a rendered conversation counts once, and counts by the same rule.
    var runningSessionCount: Int {
        Set(controllers.keys).union(conversations.keys)
            .filter { isRunning(sessionID: $0) }
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

        guard let tracker = controllers[report.sessionID]?.activityTracker else {
            // Ordinary for a rendered conversation, which learns its boundaries from the stream
            // and has no terminal controller. Recorded at debug because it is also what a
            // report for an already-closed session looks like.
            ThreadingLogger.agent.debug(
                "Lifecycle report for a session with no terminal: \(report.sessionID.uuidString, privacy: .public)"
            )
            return
        }

        // The one transition worth a durable record. Before it, a session's status is inferred
        // from output; after it, the agent is saying so. "Did the hooks actually reach this
        // session" is the first question any report about this feature raises, and this is the
        // only line that answers it.
        let wasInferring = !tracker.reportsOwnActivity

        switch report.event {
        case .turnStarted: tracker.noteTurnStarted()
        case .turnFinished:
            if !report.backgroundTaskIDs.isEmpty {
                // The one line that explains a session sitting at `working` with a quiet
                // terminal: its agent is waiting on something it started, not on the user.
                ThreadingLogger.agent.debug(
                    """
                    Turn ended with \(report.backgroundTaskIDs.count, privacy: .public) \
                    background task(s) in flight for \
                    \(report.sessionID.uuidString, privacy: .public)
                    """
                )
            }
            tracker.noteTurnFinished(backgroundWork: report.backgroundTaskIDs)
        case .awaitingUser: tracker.noteAwaitingUser()
        case .sessionStarted: break
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

        if stored.kind == .claude, conversations[report.sessionID] != nil {
            return
        }

        let state = subagentState(for: report.sessionID)
        state.apply(.discovered(SubagentDescriptor(
            threadID: childID,
            parentThreadID: report.agentSessionID,
            role: report.subagentType,
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
        case .turnStarted, .turnFinished, .awaitingUser, .sessionStarted:
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
        guard let reported = report.agentSessionID, !reported.isEmpty,
              let stored = ProjectStore.shared.session(withID: report.sessionID),
              stored.resumeState == .awaitingIdentifier else {
            return
        }

        ProjectStore.shared.update(sessionID: report.sessionID) { session in
            session.resumeState = .resumable(TranscriptID(reported))
        }

        ThreadingLogger.agent.info("Adopted reported session \(reported, privacy: .public)")
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
    ) -> ConversationViewController {
        if let existing = conversations[agentSession.id] {
            return existing
        }

        let conversation = ConversationViewController(
            agentSession: agentSession,
            project: project,
            subagentState: subagentState(for: agentSession.id)
        )
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
