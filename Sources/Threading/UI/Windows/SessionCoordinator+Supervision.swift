import Foundation

@MainActor
extension SessionCoordinator {
    /// Creates, adopts, and only then launches a managed child. The supervision row is durable
    /// before the child can speak, so a launch failure never leaves running work outside the
    /// manager's fleet and a manager recovering from compaction can list the child immediately.
    func spawnSupervisedSession(
        plan: ScheduledSessionPlan,
        brief: String,
        sideChatParentID: SessionID?,
        managerID: SessionID
    ) -> Result<AgentSession, SupervisionActionFailure> {
        let opening = guardrailedBrief(brief, from: managerID)
        let session: AgentSession?
        if let sideChatParentID {
            session = environment.projectStore.addSideChat(
                of: sideChatParentID,
                title: SessionNaming.promptTitle(from: brief)
            )
        } else {
            session = startSessionUnattended(plan: plan, title: brief)
        }
        guard let session else {
            return .failure(.init(L10n.string("The child session could not be created.")))
        }

        switch ControlGrantStore.shared.adopt(
            childID: session.id,
            by: managerID,
            brief: brief
        ) {
        case .adopted, .alreadyManaged:
            break
        case .released, .refused:
            discardUnlaunchedSupervisedSession(session)
            return .failure(.init(L10n.string("The supervision record could not be saved.")))
        }

        guard container.launchInBackground(sessionID: session.id, initialPrompt: opening) else {
            _ = ControlGrantStore.shared.release(
                childID: session.id,
                by: managerID,
                outcome: "Launch failed"
            )
            discardUnlaunchedSupervisedSession(session)
            return .failure(.init(L10n.string("The child session could not be launched.")))
        }

        sidebar.reload()
        onPresentationChanged()
        environment.eventLog.record(.session, "Manager spawned supervised session", [
            "manager": managerID.uuidString,
            "child": session.id.uuidString,
            "sideChat": sideChatParentID?.uuidString ?? "none",
        ])
        return .success(session)
    }

    func resumeSupervisedSession(_ sessionID: SessionID) -> Bool {
        let launched = container.launchInBackground(sessionID: sessionID)
        if launched {
            sidebar.refreshRows()
            onPresentationChanged()
        }
        return launched
    }

    func moveSupervisedSession(
        _ sessionID: SessionID,
        to account: AgentAccount,
        managerID: SessionID
    ) -> Result<String, SupervisionActionFailure> {
        guard let session = environment.projectStore.session(withID: sessionID) else {
            return .failure(.init(L10n.string("The child session is no longer available.")))
        }
        let oldAccount = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        guard moveSessionWithoutConfirmation(sessionID, to: account) else {
            return .failure(.init(L10n.string("The conversation could not be moved.")))
        }

        if let supervision = ControlGrantStore.shared.activeManager(of: sessionID) {
            _ = ControlGrantStore.shared.appendEvent(
                .moved,
                detail: "\(oldAccount?.displayName ?? session.accountHandle.name) → \(account.displayName)",
                to: supervision
            )
        }
        ManagerActionNoticeStore.shared.recordMove(
            sessionID: sessionID,
            managerID: managerID,
            from: oldAccount,
            to: account
        )
        return .success(oldAccount?.displayName ?? session.accountHandle.name)
    }

    func finishSupervisedWorkspace(_ sessionID: SessionID, managerID: SessionID) -> Bool {
        guard environment.projectStore.session(withID: sessionID) != nil else { return false }
        if let supervision = ControlGrantStore.shared.activeManager(of: sessionID) {
            _ = ControlGrantStore.shared.appendEvent(
                .workspaceFinished,
                detail: "Requested by manager \(managerID.uuidString.lowercased())",
                to: supervision
            )
        }
        archiveAtAgentRequest(
            sessionID,
            reason: "Finished by manager",
            requestedByManagerID: managerID
        )
        return true
    }

    private func guardrailedBrief(_ brief: String, from managerID: SessionID) -> String {
        guard let manager = environment.projectStore.session(withID: managerID) else { return brief }
        return WorkspaceControlPlane.provenancePrefixed(brief, from: manager)
    }

    private func discardUnlaunchedSupervisedSession(_ session: AgentSession) {
        if let workspace = session.managedWorkspace {
            try? ManagedGitWorkspace.discardUnstarted(workspace)
        }
        _ = environment.projectStore.removeSession(id: session.id)
        sidebar.reload()
    }
}
