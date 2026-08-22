import AppKit

// MARK: - The Chat A Broken Conversation Opens

/// Creating and retiring the chat that repairs another conversation.
///
/// `LaunchRecoveryBrief` owns *what to tell it*; this owns *bringing it into being*, for the
/// reason `SessionCoordinator+DeveloperReportChat` exists — the coordinator already owns every
/// lifecycle decision, and a route that reached for its own sidebar would be a second answer to
/// "where does a session appear".
extension SessionCoordinator {

    // MARK: - Public Methods

    /// Opens a chat briefed to repair one broken conversation, and selects it.
    ///
    /// Selected rather than started quietly: the user pressed a button a moment ago and is
    /// waiting to watch an agent work on their conversation. The same reason the report chat is
    /// selected, and the opposite of a scheduled start, which fires with nobody present.
    ///
    /// **Configured like the broken session, not from app defaults.** A repair chat that came up
    /// on a different agent or a different login would be one the user has to reconfigure before
    /// it is useful, and — worse here than anywhere else — a runtime that knows nothing about the
    /// file format it has been asked to repair.
    func startLaunchRecoveryChat(
        for session: AgentSession,
        failure: SessionLaunchFailure,
        original: URL,
        workingCopy: URL
    ) -> AgentSession? {
        guard let project = environment.projectStore.project(forSessionID: session.id) else {
            return nil
        }

        let plan = ScheduledSessionPlan(
            projectID: project.id,
            kind: session.kind,
            accountHandle: session.accountHandle,
            model: session.model,
            reasoningEffort: session.reasoningEffort,
            fastMode: session.fastMode,
            branch: nil,
            usesNativeUI: session.usesNativeUI,
            permissionMode: session.permissionMode,
            managedWorkspacePlan: nil
        )

        let title = LaunchRecoveryDefaults.chatTitle(for: session.displayTitle)
        guard let recovery = startSessionUnattended(plan: plan, title: title) else { return nil }

        // The brief alone, without the user's standing opening message. Every other new chat
        // composes the two, and this is the one chat where that would be wrong: a reusable "always
        // start by reading the README" instruction handed to an agent whose whole job is a
        // one-file repair outside the project is an instruction to go somewhere else first.
        let brief = LaunchRecoveryBrief.prompt(
            conversationTitle: session.displayTitle,
            workingCopy: workingCopy,
            original: original,
            failure: failure,
            toolName: MCPTools.proposeConversationRepair
        )

        guard container.launchInBackground(sessionID: recovery.id, initialPrompt: brief) else {
            return nil
        }

        sidebar.reload()
        sidebar.select(sessionID: recovery.id)
        return recovery
    }

    /// Retires the repair chat once its proposal has been accepted.
    ///
    /// The receipt carries the way to report what happened, because a repair that *worked* is
    /// the interesting one to tell somebody about and the alert that accepted it had already
    /// spent its buttons. Offered rather than opened: the user asked for their conversation
    /// back, and they now have it.
    func archiveSessionAfterRecovery(
        _ sessionID: SessionID,
        repaired title: String,
        onReport: @escaping () -> Void
    ) {
        guard let session = environment.projectStore.session(withID: sessionID),
              !session.isArchived else { return }
        archiveAfterRecovery(sessionID, repaired: title, onReport: onReport)
    }
}
