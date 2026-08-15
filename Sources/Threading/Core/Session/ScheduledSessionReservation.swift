import Foundation

/// Creates the durable conversation that represents a scheduled session before it starts.
///
/// The reservation is deliberately an ordinary `AgentSession`: the project tree, selection,
/// navigation and title chrome already know how to carry that identity. The scheduled-message
/// record remains the authority for why it has not launched and when it will. Managed workspaces
/// are the exception to "create now" because provisioning changes the repository; they remain a
/// launch-time operation and are attached to this same record immediately before the agent starts.
@MainActor
enum ScheduledSessionReservation {

    @discardableResult
    static func reserve(
        _ message: ScheduledMessage,
        in projectStore: ProjectStore
    ) -> AgentSession? {
        guard case .newSession(let plan) = message.target,
              let sessionID = plan.reservedSessionID else { return nil }

        if let existing = projectStore.session(withID: sessionID) {
            return existing.hasLaunched ? nil : existing
        }

        let targetProjectID: ProjectID
        if let branch = plan.branch {
            guard let checkout = projectStore.checkout(
                onBranch: branch,
                inRepositoryOf: plan.projectID
            ) else { return nil }
            targetProjectID = checkout
        } else {
            targetProjectID = plan.projectID
        }

        return projectStore.addSession(
            to: targetProjectID,
            kind: plan.kind,
            accountHandle: plan.accountHandle,
            model: plan.model,
            reasoningEffort: plan.reasoningEffort,
            fastMode: plan.fastMode,
            usesNativeUI: plan.usesNativeUI,
            permissionMode: plan.permissionMode,
            title: SessionNaming.promptTitle(from: message.text),
            id: sessionID
        )
    }
}
