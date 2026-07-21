import AppKit

/// Tracks the live terminal controllers backing agent sessions.
///
/// Controllers are cached per session so switching away in the sidebar and back does not
/// restart the agent or lose scrollback. A session with no entry here is dormant: it exists
/// in `ProjectStore` and can be resumed, but owns no PTY.
final class AgentRuntime {

    // MARK: - Singleton

    static let shared = AgentRuntime()
    private init() {}

    // MARK: - Properties

    private var controllers: [UUID: AgentSessionViewController] = [:]

    /// Live conversation controllers, for sessions Skalman renders itself.
    ///
    /// Kept separate from `controllers` rather than behind a shared protocol: the two drive
    /// the CLI in different ways and share almost no surface beyond starting and stopping.
    /// A session appears in exactly one of the two.
    private var conversations: [UUID: ConversationViewController] = [:]

    /// Identifiers of every session currently holding a live terminal.
    var liveSessionIDs: Set<UUID> {
        Set(controllers.keys)
    }

    // MARK: - Public Methods

    func controller(for sessionID: UUID) -> AgentSessionViewController? {
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
    func isRunning(sessionID: UUID) -> Bool {
        controllers[sessionID]?.isRunning ?? conversations[sessionID]?.isRunning ?? false
    }

    /// What the session is currently doing. Sessions with no terminal are dormant.
    func activity(sessionID: UUID) -> SessionActivity {
        controllers[sessionID]?.activity ?? conversations[sessionID]?.activity ?? .dormant
    }

    /// Marks which session is on screen, so only the others flag finished work.
    func setVisibleSession(_ sessionID: UUID?) {
        for (id, controller) in controllers {
            controller.isVisible = (id == sessionID)
        }
        for (id, conversation) in conversations {
            conversation.isVisible = (id == sessionID)
        }
    }

    /// Whether the session has a terminal allocated, running or exited.
    func hasTerminal(sessionID: UUID) -> Bool {
        controllers[sessionID] != nil || conversations[sessionID] != nil
    }

    // MARK: - Conversations

    func conversation(for sessionID: UUID) -> ConversationViewController? {
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
    func terminate(sessionID: UUID) {
        controllers[sessionID]?.terminate()
        conversations[sessionID]?.terminate()
    }

    /// Terminates the agent and releases its terminal, returning the session to dormant.
    func discard(sessionID: UUID) {
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
            controllers[sessionID]?.terminate()
        }
        controllers.removeAll()

        for sessionID in conversations.keys {
            conversations[sessionID]?.terminate()
        }
        conversations.removeAll()
    }
}
