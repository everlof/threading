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

    /// Live conversation controllers, for sessions Skalman renders itself.
    ///
    /// Kept separate from `controllers` rather than behind a shared protocol: the two drive
    /// the CLI in different ways and share almost no surface beyond starting and stopping.
    /// A session appears in exactly one of the two.
    private var conversations: [SessionID: ConversationViewController] = [:]

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

        let controller = AgentSessionViewController(agentSession: agentSession)
        controllers[agentSession.id] = controller
        return controller
    }

    /// Whether the session's agent process is currently running.
    func isRunning(sessionID: SessionID) -> Bool {
        controllers[sessionID]?.isRunning ?? conversations[sessionID]?.isRunning ?? false
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
            SkalmanLogger.agent.debug(
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
        case .turnFinished: tracker.noteTurnFinished()
        case .awaitingUser: tracker.noteAwaitingUser()
        case .sessionStarted: break
        }

        if wasInferring, tracker.reportsOwnActivity {
            SkalmanLogger.agent.info(
                "Session reports its own activity: \(report.sessionID.uuidString, privacy: .public)"
            )
            EventLog.shared.record(.hooks, "Session began reporting its own activity", [
                "session": report.sessionID.uuidString,
                "event": report.event.rawValue
            ])
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
    /// reports the identifier Skalman minted and already stored, and a resumed Codex session
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

        SkalmanLogger.agent.info("Adopted reported session \(reported, privacy: .public)")
        controllers[report.sessionID]?.noteStateChanged()
    }

    /// Marks which session is on screen, so only the others flag finished work.
    func setVisibleSession(_ sessionID: SessionID?) {
        for (id, controller) in controllers {
            controller.isVisible = (id == sessionID)
        }
        for (id, conversation) in conversations {
            conversation.isVisible = (id == sessionID)
        }
    }

    /// Whether the session has a terminal allocated, running or exited.
    func hasTerminal(sessionID: SessionID) -> Bool {
        controllers[sessionID] != nil || conversations[sessionID] != nil
    }

    // MARK: - Conversations

    func conversation(for sessionID: SessionID) -> ConversationViewController? {
        conversations[sessionID]
    }

    /// Returns the cached conversation for a session, creating one if needed.
    func makeConversation(
        for agentSession: AgentSession,
        in project: Project
    ) -> ConversationViewController {
        if let existing = conversations[agentSession.id] {
            return existing
        }

        let conversation = ConversationViewController(agentSession: agentSession, project: project)
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
            conversation.view.removeFromSuperview()
        }

        guard let controller = controllers[sessionID] else { return }
        controller.terminate()
        controller.view.removeFromSuperview()
        controllers[sessionID] = nil
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
    }
}
