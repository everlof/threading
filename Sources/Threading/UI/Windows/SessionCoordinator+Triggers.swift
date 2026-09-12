import AppKit

@MainActor
private final class TriggerFixStageRegistry {
    static let shared = TriggerFixStageRegistry()

    private var bySessionID: [SessionID: (run: TriggerRun, revision: TriggerRevision)] = [:]

    func arm(run: TriggerRun, revision: TriggerRevision) {
        guard let sessionID = run.sessionID else { return }
        bySessionID[sessionID] = (run, revision)
    }

    func take(sessionID: SessionID) -> (run: TriggerRun, revision: TriggerRevision)? {
        bySessionID.removeValue(forKey: sessionID)
    }
}

@MainActor
extension SessionCoordinator {
    func performTriggerDispatch(_ dispatch: TriggerDispatch) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let triggerName = (try? await TriggerStore.shared.trigger(id: dispatch.run.triggerID))?
                .definition.name ?? L10n.string("Automated trigger")
            let managedPlan = dispatch.revision.checkoutPolicy == .managedWorktree
                ? ManagedWorkspacePlan(delivery: .keepForReview, publication: nil)
                : nil
            guard dispatch.revision.agentKind.supportsNativeUI,
                  dispatch.revision.agentKind.supportsPermissionModes else {
                await holdBeforeLaunch(
                    dispatch.run,
                    because: L10n.string(
                        "The configured agent cannot guarantee a read-only assessment stage."
                    )
                )
                return
            }
            let runtimeDeadline = Date().addingTimeInterval(
                TimeInterval(dispatch.revision.limits.maximumRuntimeMinutes * 60)
            )
            var run = dispatch.run
            if run.sessionID == nil {
                run.sessionID = SessionID()
                do {
                    try await TriggerStore.shared.updateRun(run)
                } catch {
                    await settleNeedsAttention(
                        dispatch.run,
                        because: L10n.string("The assessment agent could not be started.")
                    )
                    return
                }
            }
            let plan = ScheduledSessionPlan(
                reservedSessionID: run.sessionID,
                projectID: dispatch.revision.projectID,
                kind: dispatch.revision.agentKind,
                accountHandle: AccountHandle(storedName: dispatch.revision.accountHandleName),
                model: dispatch.revision.model,
                reasoningEffort: dispatch.revision.reasoningEffort,
                branch: nil,
                usesNativeUI: dispatch.revision.agentKind.supportsNativeUI,
                permissionMode: .plan,
                managedWorkspacePlan: managedPlan,
                role: .chat,
                curfew: .at(runtimeDeadline)
            )
            guard let session = startSessionUnattended(plan: plan, title: triggerName) else {
                run.sessionID = nil
                await holdBeforeLaunch(
                    run,
                    because: L10n.string("The configured project or workspace is unavailable.")
                )
                return
            }
            run.sessionID = session.id
            // Managed workspaces are session-owned in the existing model; the owning session id
            // is therefore their stable run receipt rather than a second invented identity.
            run.managedWorkspaceID = session.managedWorkspace == nil ? nil : session.id.rawValue
            armCurfew(plan.curfew, forSessionID: session.id)
            let prompt = TriggerPromptBuilder.assessment(
                dispatch: dispatch,
                triggerName: triggerName
            )
            run.state = .assessing
            run.startedAt = run.startedAt ?? Date()
            run.holdReason = nil
            run.boundedDiagnostic = nil
            do {
                try await TriggerStore.shared.updateRun(run)
            } catch {
                _ = environment.projectStore.removeSession(id: session.id)
                SessionAttachmentStore.shared.removeSession(session.id)
                if let workspace = session.managedWorkspace {
                    try? ManagedGitWorkspace.discardUnstarted(workspace)
                }
                await settleNeedsAttention(
                    dispatch.run,
                    because: L10n.string("The assessment agent could not be started.")
                )
                return
            }
            guard container.launchInBackground(sessionID: session.id, initialPrompt: prompt) else {
                await settleNeedsAttention(
                    run,
                    because: L10n.string("The assessment agent could not be started.")
                )
                return
            }
            sidebar.reload()
            onPresentationChanged()
        }
    }

    private func holdBeforeLaunch(_ original: TriggerRun, because diagnostic: String) async {
        var run = original
        run.state = .queued
        run.sessionID = nil
        run.managedWorkspaceID = nil
        run.startedAt = nil
        run.holdReason = .backgroundUnavailable
        run.boundedDiagnostic = String(diagnostic.prefix(1_024))
        try? await TriggerStore.shared.updateRun(run)
    }

    func triggerAssessmentDidFinish(_ event: TriggerAssessmentDidFinish) {
        guard event.run.state == .fixQueued,
              event.run.result?.disposition == .straightforwardFix,
              event.revision.executionMode == .assessThenFix else {
            presentTriggerReceipt(for: event.run)
            return
        }
        TriggerFixStageRegistry.shared.arm(run: event.run, revision: event.revision)
    }

    func startRecoveredTriggerFix(_ dispatch: TriggerDispatch) async {
        guard dispatch.run.state == .fixQueued || dispatch.run.state == .queued,
              dispatch.run.sessionID != nil,
              dispatch.run.result?.disposition == .straightforwardFix,
              dispatch.revision.executionMode == .assessThenFix else {
            await settleNeedsAttention(
                dispatch.run,
                because: L10n.string("The trigger run needs review.")
            )
            return
        }
        await startTriggerFix(dispatch.run, revision: dispatch.revision)
    }

    func triggerRuntimeDidChange(_ event: SessionRuntimeDidChange) {
        guard event.transition.completedPendingOutcome else { return }
        if let pending = TriggerFixStageRegistry.shared.take(sessionID: event.sessionID) {
            Task { @MainActor [weak self] in
                await self?.startTriggerFix(pending.run, revision: pending.revision)
            }
        } else {
            Task { @MainActor [weak self] in
                await self?.settleUnreportedTriggerRun(sessionID: event.sessionID)
            }
        }
    }

    private func settleUnreportedTriggerRun(sessionID: SessionID) async {
        guard var run = try? await TriggerStore.shared.run(sessionID: sessionID),
              run.state == .assessing || run.state == .fixing else { return }
        let diagnostic = run.state == .fixing
            ? L10n.string("The fix agent ended without reporting a final result.")
            : L10n.string("The assessment agent ended without reporting an assessment.")
        run.state = .needsAttention
        run.settledAt = Date()
        run.boundedDiagnostic = diagnostic
        try? await TriggerStore.shared.updateRun(run)
        presentTriggerReceipt(for: run)
        try? await TriggerRuntime.shared.releaseQueue()
    }

    private func startTriggerFix(_ original: TriggerRun, revision: TriggerRevision) async {
        guard let sessionID = original.sessionID,
              let session = environment.projectStore.session(withID: sessionID),
              session.usesNativeUI else {
            await settleNeedsAttention(
                original,
                because: L10n.string(
                    "The configured agent surface cannot safely receive an unattended second-stage prompt."
                )
            )
            return
        }

        if revision.checkoutPolicy == .projectCheckout,
           let project = environment.projectStore.project(withID: revision.projectID) {
            let path = project.folderPath
            let isClean = (try? await Task.detached(priority: .utility) {
                try ManagedGitWorkspace.existingCheckoutIsClean(path)
            }.value) ?? false
            guard isClean else {
                await settleNeedsAttention(
                    original,
                    because: L10n.string(
                        "The existing checkout changed after assessment. Review it before allowing automated edits."
                    ),
                    holdReason: .dirtyCheckout
                )
                return
            }
        }

        guard environment.projectStore.setPermissionMode(
            .acceptEdits,
            for: sessionID
        ) != .persistenceRefused else {
            await settleNeedsAttention(
                original,
                because: L10n.string("Threading could not save the fix-stage permission mode.")
            )
            return
        }
        environment.agentRuntime.terminate(sessionID: sessionID)
        environment.agentRuntime.discard(sessionID: sessionID)

        guard let assessment = original.result else {
            await settleNeedsAttention(
                original,
                because: L10n.string("The trigger run needs review.")
            )
            return
        }
        var run = original
        run.state = .fixing
        run.holdReason = nil
        run.boundedDiagnostic = nil
        do {
            try await TriggerStore.shared.updateRun(run)
        } catch {
            await settleNeedsAttention(
                original,
                because: L10n.string("The authorized fix agent could not be started.")
            )
            return
        }
        guard container.launchInBackground(
                sessionID: sessionID,
                initialPrompt: TriggerPromptBuilder.fix(
                    runID: original.id,
                    assessment: assessment
                )
              ) else {
            await settleNeedsAttention(
                run,
                because: L10n.string("The authorized fix agent could not be started.")
            )
            return
        }
        sidebar.reload()
    }

    private func settleNeedsAttention(
        _ original: TriggerRun,
        because diagnostic: String,
        holdReason: TriggerRunHoldReason? = nil
    ) async {
        var run = original
        run.state = .needsAttention
        run.holdReason = holdReason
        run.settledAt = Date()
        run.boundedDiagnostic = String(diagnostic.prefix(1_024))
        try? await TriggerStore.shared.updateRun(run)
        presentTriggerReceipt(for: run)
        try? await TriggerRuntime.shared.releaseQueue()
    }

    func triggerFixDidFinish(_ event: TriggerFixDidFinish) {
        presentTriggerReceipt(for: event.run)
    }

    private func presentTriggerReceipt(for run: TriggerRun) {
        let summary = run.result?.summary
            ?? run.boundedDiagnostic
            ?? L10n.string("The trigger run needs review.")
        let title: String
        switch run.state {
        case .completed:
            title = L10n.string("Trigger fix ready to verify")
        case .failed:
            title = L10n.string("Trigger run failed")
        default:
            title = L10n.string("Trigger run needs attention")
        }
        toastPresenter(ToastRequest(
            message: title,
            detail: summary,
            dwell: ToastDefaults.unattendedDwell
        ))
        if let sessionID = run.sessionID {
            _ = AttentionAlertCenter.shared.postRequestedUpdate(
                eventID: run.id.uuidString,
                sessionID: sessionID,
                title: title,
                body: summary,
                destination: .session
            )
            if environment.settings.remoteAccessEnabled {
                _ = RemoteNotificationService.shared.notifyRequested(
                    sessionID: sessionID,
                    title: title,
                    body: summary,
                    recipient: nil,
                    destination: .session
                )
            }
        }
    }
}
