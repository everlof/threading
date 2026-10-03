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
            guard let self, let claimed = try? await TriggerStore.shared.claimDispatch(dispatch.run.id) else { return }
            var run = claimed
            let triggerName = (try? await TriggerStore.shared.trigger(id: dispatch.run.triggerID))?
                .definition.name ?? L10n.string("Automated trigger")
            let managedPlan = dispatch.revision.checkoutPolicy == .managedWorktree
                ? ManagedWorkspacePlan(delivery: .keepForReview, publication: nil)
                : nil
            guard dispatch.revision.agentKind.supportsNativeUI,
                  dispatch.revision.agentKind.supportsPermissionModes else {
                await holdBeforeLaunch(
                    run,
                    revision: dispatch.revision,
                    because: L10n.string(
                        "The configured agent cannot guarantee a read-only assessment stage."
                    )
                )
                return
            }
            if dispatch.revision.executionMode == .taskLocalEdits,
               dispatch.revision.checkoutPolicy == .projectCheckout,
               let project = environment.projectStore.project(withID: dispatch.revision.projectID) {
                let path = project.folderPath
                guard (try? await Task.detached(priority: .utility) {
                    try ManagedGitWorkspace.existingCheckoutIsClean(path)
                }.value) == true else {
                    // No session was started, so the receipt must not name the reserved one.
                    run.sessionID = nil
                    await settleNeedsAttention(
                        run,
                        because: L10n.string("The existing checkout is not clean. Review it before allowing automated edits."),
                        holdReason: .dirtyCheckout
                    )
                    return
                }
            }
            let runtimeDeadline = Date().addingTimeInterval(
                TimeInterval(dispatch.revision.limits.maximumRuntimeMinutes * 60)
            )
            let plan = ScheduledSessionPlan(
                reservedSessionID: run.sessionID,
                projectID: dispatch.revision.projectID,
                kind: dispatch.revision.agentKind,
                accountHandle: AccountHandle(storedName: dispatch.revision.accountHandleName),
                model: dispatch.revision.model,
                reasoningEffort: dispatch.revision.reasoningEffort,
                branch: nil,
                usesNativeUI: dispatch.revision.agentKind.supportsNativeUI,
                permissionMode: dispatch.revision.executionMode == .taskLocalEdits ? .acceptEdits : .plan,
                managedWorkspacePlan: managedPlan,
                role: .chat,
                curfew: .at(runtimeDeadline)
            )
            guard let session = startSessionUnattended(plan: plan, title: triggerName) else {
                run.sessionID = nil
                await holdBeforeLaunch(
                    run,
                    revision: dispatch.revision,
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
            run.state = dispatch.revision.executionMode.isTask ? .running : .assessing
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
                    run,
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

    private func holdBeforeLaunch(_ original: TriggerRun, revision: TriggerRevision, because diagnostic: String) async {
        guard original.canWaitForRelease(under: revision) else {
            var run = original
            run.sessionID = nil
            run.managedWorkspaceID = nil
            await settleNeedsAttention(run, because: diagnostic, holdReason: .backgroundUnavailable)
            return
        }
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
            if event.run.state != .finishing { presentTriggerReceipt(for: event.run) }
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
                if event.transition.current.isPromptReady {
                    await self?.startTriggerFix(pending.run, revision: pending.revision)
                } else {
                    await self?.settleNeedsAttention(pending.run, because: L10n.string("The trigger run needs review."))
                }
            }
        } else {
            Task { @MainActor [weak self] in
                await self?.settleUnreportedTriggerRun(sessionID: event.sessionID, promptReady: event.transition.current.isPromptReady)
            }
        }
    }

    private func settleUnreportedTriggerRun(sessionID: SessionID, promptReady: Bool) async {
        guard var run = try? await TriggerStore.shared.run(sessionID: sessionID),
              run.state == .assessing || run.state == .fixing || run.state == .running || run.state == .finishing else { return }
        if run.state == .finishing, promptReady, let result = run.result {
            switch result.disposition {
            case .succeeded, .fixed, .noChangeNeeded: run.state = .completed
            case .failed: run.state = .failed
            case .straightforwardFix, .needsHuman: run.state = .needsAttention
            }
            run.settledAt = Date()
            do { try await TriggerStore.shared.updateRun(run) } catch { return }
            if run.state == .completed,
               let revision = try? await TriggerStore.shared.revision(id: run.triggerRevisionID),
               revision.automation?.archiveOnSuccess == true {
                _ = SessionArchiveScheduler.shared.request(sessionID: sessionID, reason: result.summary, successfulAutomation: true)
            }
            presentTriggerReceipt(for: run)
            try? await TriggerRuntime.shared.releaseQueue()
            return
        }
        // The provider's typed refusal names the real cause where it gave one — on 2026-10-03 a
        // scheduled run settled as "ended without reporting a result" when its login had
        // simply stopped signing in.
        let diagnostic = TriggerRunDiagnostic.unreported(
            state: run.state,
            failure: environment.agentRuntime.lastTurnFailure(sessionID: sessionID),
            login: environment.projectStore.session(withID: sessionID)
                .map(TriggerRunDiagnostic.login(for:))
        )
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

    private func presentTriggerReceipt(for run: TriggerRun) {
        let summary = run.result?.summary
            ?? run.boundedDiagnostic
            ?? L10n.string("The trigger run needs review.")
        let title: String
        switch run.state {
        case .completed:
            title = L10n.string("Automation completed")
        case .failed:
            title = L10n.string("Automation failed")
        default:
            title = L10n.string("Automation needs attention")
        }
        toastPresenter(ToastRequest(
            message: title,
            detail: summary,
            dwell: ToastDefaults.unattendedDwell
        ))
        // Off-screen delivery is `TriggerRunAlerts`' decision: failures only, once per run,
        // Mac and paired iPhone. The name is read from the store because a run refused before
        // its session started has no session title to borrow.
        Task { @MainActor in
            let name = (try? await TriggerStore.shared.trigger(id: run.triggerID))?.definition.name
            TriggerRunAlerts.shared.announce(run, automationName: name)
        }
    }
}
