import AppKit

// MARK: - Performing A Scheduled Send

/// What actually happens when a scheduled send's moment arrives.
///
/// `ScheduledMessageScheduler` owns *when* and announces it; this owns *how*, for the same reason
/// `archiveAtAgentRequest` lives here — the coordinator already owns every lifecycle decision, and
/// the scheduler is in Core and knows nothing about sidebars, surfaces or launching.
extension SessionCoordinator {

    // MARK: - Entry

    /// Takes a due send and delivers it, or says why it could not.
    ///
    /// **The claim comes first, before anything is read or launched.** In the running app there
    /// is one coordinator, but the hosted test bundle builds `MainWindowController` in a good
    /// many test methods, so more than one can be observing the default centre at once.
    /// `SessionArchiveRequestDidBecomeDue` survives that because re-archiving is idempotent —
    /// a send is not, and a message delivered twice is not something an undo can take back.
    func performScheduledSend(_ id: ScheduledMessageID) {
        guard let message = ScheduledMessageStore.shared.claim(id) else { return }
        guard !standAsideForUnresetWindow(message) else { return }
        guard !standAsideForCustomLimit(message) else { return }

        switch message.target {
        case .session(let sessionID):
            deliverScheduled(message, to: sessionID)
        case .newSession(let plan):
            startScheduledSession(message, plan: plan)
        }
    }

    /// Starts a waiting scheduled item because the user explicitly asked, regardless of whether
    /// its original trigger is still in the future or its earlier attempt needs attention.
    func startScheduledMessageNow(_ id: ScheduledMessageID) {
        guard ScheduledMessageStore.shared.prepareForImmediateAttempt(id) else { return }
        performScheduledSend(id)
    }

    /// Opens a waiting scheduled start in its project's composer, from the reserved
    /// conversation's own surface or its sidebar row.
    ///
    /// The composer owns the editing contract (`beginEditingScheduledStart`): the record stays
    /// in the store, still armed, while the box holds a loan of its words, pictures and plan.
    func editScheduledMessage(_ id: ScheduledMessageID) {
        guard let message = ScheduledMessageStore.shared[id],
              case .newSession(let plan) = message.target else { return }
        sidebar.select(projectID: plan.projectID)
        container.showComposer(projectID: plan.projectID)
        container.composerViewController.beginEditingScheduledStart(id)
    }

    /// Cancels a scheduled start and removes the empty conversation reserved to represent it.
    func cancelScheduledMessage(_ id: ScheduledMessageID) {
        guard let message = ScheduledMessageStore.shared[id],
              case .newSession(let plan) = message.target else { return }
        guard ScheduledMessageStore.shared.remove(id) else { return }

        if let sessionID = plan.reservedSessionID {
            let wasShowing = container.currentSessionID == sessionID
            _ = environment.projectStore.removeSession(id: sessionID)
            sidebar.reload()
            if wasShowing { sidebar.select(projectID: plan.projectID) }
        } else {
            sidebar.reload()
        }
    }

    // MARK: - A Window That Had Not Actually Reset

    /// Re-reads the usage window a send was aimed at, and stands aside if it has not turned over.
    ///
    /// Only ever for a send whose anchor *was* a reset — a wall-clock moment is its own reason
    /// and has nothing to re-read. `ScheduledResetPolicy` owns how patient to be; this owns
    /// asking. Answers whether the send was postponed.
    private func standAsideForUnresetWindow(_ message: ScheduledMessage) -> Bool {
        guard let windowID = message.anchor?.usageWindowID,
              let account = accountFor(message.target),
              let window = AccountUsageService.shared.usage(for: account)?
                .allWindows.first(where: { $0.id == windowID })
        else { return false }

        // **Room, not the clock.** The first version asked whether `resetsAt` was still in the
        // future and called that "has reset", which is exactly backwards — a reset moment ahead
        // of us means the window has *not* turned over yet. Reading it off the clock at all is
        // the deeper mistake: at the instant we fire, a rolled-over window reports a reset five
        // hours away and a stale reading reports one in the past, so the same field says
        // opposite things about the same state. What the user actually asked for is "send this
        // when I have usage again", and `fraction` is the field that answers it. An unknown
        // fraction reads as room: refusing to send on a reading we do not have would strand the
        // message for a provider that simply reports less.
        //
        // The user's own line joins the comparison: "I have usage again" means usage they are
        // willing to spend, and on an account fenced at half, 60% is not room. With no line drawn
        // the effective bound is 1 and this is the shipped formula exactly.
        let bound = CustomLimitBounds.effectiveBound(
            on: windowID,
            in: CustomLimitSettings.shared.rules(for: account.id),
            window: window
        )
        let hasRoom = (window.fraction ?? 0) / bound < UsageDefaults.criticalFraction
        guard ScheduledResetPolicy.current.shouldStandAside(
            alreadyRearmed: message.resetRearmCount,
            windowHasReset: hasRoom
        ), let resetsAt = window.resetsAt, resetsAt > Date() else { return false }

        ScheduledMessageStore.shared.replace(
            message.id,
            with: message.rescheduled(
                to: resetsAt.addingTimeInterval(PresetDefaults.resetPadding),
                countingRearm: true
            )
        )
        ScheduledMessageStore.shared.relinquish(message.id)
        environment.eventLog.record(.composer, "Scheduled send stood aside for its usage window", [
            "window": windowID,
            "resetsAt": ISO8601DateFormatter().string(from: resetsAt)
        ])
        return true
    }

    // MARK: - A Line The User Drew

    /// Stands a send aside because one of the user's own limits is holding this account.
    ///
    /// Unlike `standAsideForUnresetWindow`, this applies to **every** scheduled send rather than
    /// only the reset-anchored ones: the user's line is a statement about spending, not about a
    /// window's phase, and a send timed to a wall-clock moment spends exactly as much as one timed
    /// to a reset. Threading can hold back what Threading starts, and a scheduled send is the
    /// clearest case of that — nobody is at the keyboard when it fires.
    ///
    /// The send is **re-armed at the window's reset** rather than cancelled: the user asked for
    /// this message to go, and a limit is a "not yet", not a "no". `ScheduledResetPolicy` owns how
    /// many times that may happen, so a rule cannot silently defer a message forever.
    private func standAsideForCustomLimit(_ message: ScheduledMessage) -> Bool {
        guard let account = accountFor(message.target) else { return false }

        let usage = AccountUsageService.shared.usage(for: account)
        let hold = CustomLimitBounds.hold(
            on: usage,
            in: CustomLimitSettings.shared.rules(for: account.id)
        )
        guard hold.isHolding, let rule = hold.rule else { return false }

        let resetsAt = usage?.allWindows
            .first { $0.id == rule.windowID }?
            .resetsAt

        guard ScheduledResetPolicy.current.shouldStandAside(
            alreadyRearmed: message.resetRearmCount,
            windowHasReset: false
        ), let resetsAt, resetsAt > Date() else {
            // Nothing to wait for — no reset in the reading, or the policy is out of patience.
            // The send goes, and the receipt says the line was reached: holding a message
            // indefinitely with nowhere to re-arm to would be the feature quietly eating it.
            environment.eventLog.record(.composer, "Scheduled send passed a limit with no reset to wait for", [
                "rule": rule.windowID,
                "reason": CustomLimitReceipt.holdReason(hold)
            ])
            return false
        }

        ScheduledMessageStore.shared.replace(
            message.id,
            with: message.rescheduled(
                to: resetsAt.addingTimeInterval(PresetDefaults.resetPadding),
                countingRearm: true
            )
        )
        ScheduledMessageStore.shared.relinquish(message.id)
        environment.eventLog.record(.composer, "Scheduled send held by one of your own limits", [
            "rule": rule.windowID,
            "reason": CustomLimitReceipt.holdReason(hold),
            "resetsAt": ISO8601DateFormatter().string(from: resetsAt)
        ])
        return true
    }

    private func accountFor(_ target: ScheduledMessage.Target) -> AgentAccount? {
        switch target {
        case .session(let sessionID):
            guard let session = environment.projectStore.session(withID: sessionID) else { return nil }
            return AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
        case .newSession(let plan):
            return AgentAccountDiscovery.account(for: plan.kind, handle: plan.accountHandle)
        }
    }

    // MARK: - A Reply To A Session That Exists

    private func deliverScheduled(_ message: ScheduledMessage, to sessionID: SessionID) {
        guard let session = environment.projectStore.session(withID: sessionID) else {
            return finish(message, failedBecause: L10n.string(
                "That session is no longer in Threading's sidebar."
            ))
        }
        guard !session.isArchived else {
            return finish(message, failedBecause: L10n.string(
                "That session was archived before this was due."
            ))
        }

        // **The receipt form, not the synchronous one.** A typed delivery reports `.sentNow` only
        // once the target's own turn-started report confirms it arrived. Without that, a
        // scheduled send would complete on the strength of "we pressed Return" — a fact about
        // our keystrokes, not about the message — and that gap costs more here than anywhere
        // else it exists: nobody is watching, and `complete` deletes the only durable copy.
        let prompt = handingOverImages(of: message, to: sessionID)
        SessionMessageDelivery.deliver(prompt, to: sessionID) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .sentNow, .queuedBehindTurn:
                self.deliveredScheduled(message, to: sessionID)

            case .busyTerminal, .notTaken:
                // Owed another try when the session settles. `ScheduledMessageScheduler` watches
                // the activity edge and re-announces, bounding how long that politeness lasts.
                self.waitScheduled(
                    message,
                    because: L10n.string("Waiting for the session to be free")
                )

            case .typedUnconfirmed:
                // Typed, and the session never said a turn began — a `/compact` swallowing the
                // paste looks exactly like this. **Kept and shown rather than retried.** The
                // earlier arm here waited, on the reasoning that a duplicate beats a loss; that
                // is the right trade for a message a user is watching go, and the wrong one for
                // an unattended send, where a retry can hand an agent the same instruction twice
                // with nobody present to notice. The record survives either way, so the user
                // still decides — from the strip, with Send now.
                self.finish(message, failedBecause: L10n.string(
                    "It was typed into the session, which never confirmed a turn started."
                ))

            case .noLiveSurface:
                self.wakeAndDeliver(message, session: session)
            }
        }
    }

    /// Starts a dormant session's agent so a scheduled message has somewhere to land.
    ///
    /// **A departure from `control-plane.md` slice one, and a deliberate one.** That rule refuses
    /// to resume a dormant target because "resuming is the user's decision, made by selecting the
    /// row" — which is exactly right for one agent messaging another. Here the actor *is* the
    /// user, and the decision was made in advance and in writing; a scheduled send that refuses
    /// to wake a session would be useless in the overnight and weekend cases it exists for.
    ///
    /// **What it will not do is type into a terminal.** `AgentLauncher` omits the opening prompt
    /// on `--resume`, so a resumed TUI can only be *typed* into — and a resumed Claude comes up
    /// on its own question about whether to summarise the conversation or read it in full.
    /// Answering that question with the user's message, unattended and unseen, is the one
    /// outcome worth refusing over: `session-activity.md`'s unattended-launch grace deliberately
    /// ignores the very signals that would tell these two states apart, so the app cannot know
    /// it is safe. The send waits, visibly, for one click instead.
    private func wakeAndDeliver(_ message: ScheduledMessage, session: AgentSession) {
        guard session.usesNativeUI, session.kind.supportsNativeUI else {
            return waitScheduled(message, because: L10n.string(
                "Its agent is not running. Threading will not type into a terminal it cannot see."
            ))
        }

        // A conversation kept after its agent exited still occupies the runtime's slot, and
        // `launchInBackground` refuses a session that already has one. Discarding first is what
        // the dormant placeholder's own Resume button does.
        if environment.agentRuntime.hasTerminal(sessionID: session.id) {
            environment.agentRuntime.discard(sessionID: session.id)
        }

        environment.eventLog.record(.composer, "Waking a session for a scheduled message", [
            "session": session.id.uuidString
        ])

        guard container.launchInBackground(
            sessionID: session.id,
            initialPrompt: handingOverImages(of: message, to: session.id).transportTextForWake
        ) else {
            return finish(message, failedBecause: L10n.string(
                "Its agent could not be started."
            ))
        }

        deliveredScheduled(message, to: session.id, wokeTheAgent: true)
    }

    // MARK: - A Session That Does Not Exist Yet

    /// Starts a session from a plan frozen when the send was scheduled.
    ///
    /// The plan is **re-validated rather than trusted**. `targetProjectID` falls back to the base
    /// project when a named checkout has gone, which is right for a composer somebody is looking
    /// at and wrong for an unattended start that would then run in the wrong folder. A project,
    /// branch or login that has since disappeared fails the send visibly instead.
    private func startScheduledSession(_ message: ScheduledMessage, plan: ScheduledSessionPlan) {
        guard let project = environment.projectStore.project(withID: plan.projectID) else {
            return finish(message, failedBecause: L10n.string(
                "Its project is no longer in Threading."
            ))
        }
        guard FileManager.default.fileExists(atPath: project.folderPath) else {
            return finish(message, failedBecause: L10n.format(
                "Its folder is missing: %@", project.folderPath
            ))
        }
        if let branch = plan.branch,
           environment.projectStore.checkout(onBranch: branch, inRepositoryOf: plan.projectID) == nil {
            return finish(message, failedBecause: L10n.format(
                "Its checkout for %@ is gone.", branch
            ))
        }
        if plan.managedWorkspacePlan != nil,
           !ManagedWorkspaceEligibility.supportsFinishHandshake(
                kind: plan.kind,
                usesNativeUI: plan.usesNativeUI
           ) {
            return finish(message, failedBecause: L10n.string(
                "Its agent surface no longer has Threading session tools."
            ))
        }
        if plan.managedWorkspacePlan?.publication != nil {
            let targetProjectID = Self.targetProjectID(
                startingAt: plan.projectID,
                branch: plan.branch,
                checkout: environment.projectStore.checkout(onBranch:inRepositoryOf:)
            )
            guard let targetProject = environment.projectStore.project(withID: targetProjectID),
                  ManagedWorkspaceEligibility.supportsPublication(from: targetProject) else {
                return finish(message, failedBecause: L10n.string(
                    "Its checkout no longer has a supported change-request remote."
                ))
            }
        }

        guard let session = startSessionUnattended(plan: plan, title: message.text) else {
            return finish(message, failedBecause: L10n.string(
                "Its session could not be created."
            ))
        }

        // Composed after the session exists rather than before it, because the pictures can only
        // be filed against a session that has a folder — and the paths that go into the opening
        // prompt have to be the ones that filing produced.
        var opening = NewChatOpeningMessage.compose(
            prompt: handingOverImages(of: message, to: session.id).text,
            reusableMessage: environment.settings.newChatOpeningMessage
        )
        if let managedPlan = plan.managedWorkspacePlan {
            opening = ManagedWorkspaceInstructions.append(
                to: opening,
                plan: managedPlan
            )
        }

        environment.eventLog.record(.composer, "Session started from a schedule", [
            "session": session.id.uuidString,
            "project": plan.projectID.uuidString,
            "agent": plan.kind.rawValue,
            "account": plan.accountHandle.name,
            "prompt": opening ?? ""
        ])

        // A session that has never run takes its opening prompt as a launch argument on both
        // surfaces, so unlike a resume this is safe in a terminal too — there is no restored
        // conversation for the CLI to ask a question about.
        guard container.launchInBackground(sessionID: session.id, initialPrompt: opening) else {
            return finish(message, failedBecause: L10n.string(
                "Its agent could not be started."
            ))
        }
        sidebar.reload()
        deliveredScheduled(message, to: session.id, wokeTheAgent: true)
        container.reopenIfShowing(sessionID: session.id)
    }

    // MARK: - The Pictures It Was Carrying

    /// Hands a scheduled send's images to the session receiving it, and answers the prompt with
    /// their paths on the end.
    ///
    /// **Custody moves before the words do.** The copies this record has been holding since
    /// Friday live in a directory `complete` is about to delete, so naming one of them in the
    /// prompt would hand the agent a path that stops existing the moment the send succeeds. The
    /// files are therefore recorded against the session first — the same door the composer's own
    /// images go through, which is also what makes them show up in the attachments pane — and it
    /// is the session's copies that are named.
    ///
    /// Repeatable on purpose. A delivery that finds its target busy is retried, and
    /// `SessionAttachmentStore` matches a second mention against the source path it already has,
    /// so the row is refreshed rather than duplicated.
    private func handingOverImages(
        of message: ScheduledMessage,
        to sessionID: SessionID
    ) -> ConversationPrompt {
        let held = ScheduledMessageStore.shared.attachments.urls(for: message)
        guard !held.isEmpty,
              let folder = environment.projectStore.workingDirectory(forSessionID: sessionID)
        else { return message.prompt }

        let handed = PromptAttachment.handOver(
            paths: held.map(\.path),
            sessionID: sessionID,
            projectRoot: URL(fileURLWithPath: folder, isDirectory: true)
        )
        return ConversationPrompt(
            text: PromptAttachment.appending(paths: handed, to: message.text),
            context: message.context
        )
    }

    // MARK: - Recording What Happened

    private func deliveredScheduled(
        _ message: ScheduledMessage,
        to sessionID: SessionID,
        wokeTheAgent: Bool = false
    ) {
        ScheduledMessageStore.shared.complete(message.id)
        ScheduledMessageScheduler.shared.forgetWaiting(message.id)
        environment.eventLog.record(.composer, "Scheduled message delivered", [
            "session": sessionID.uuidString,
            "wokeTheAgent": wokeTheAgent ? "yes" : "no",
            "prompt": message.text
        ])
        ScheduledMessageNotifier.shared.report(.delivered(message, sessionID: sessionID))
    }

    private func waitScheduled(_ message: ScheduledMessage, because reason: String) {
        ScheduledMessageScheduler.shared.noteWaiting(message.id)
        ScheduledMessageStore.shared.relinquish(message.id, waitingBecause: reason)
    }

    private func finish(_ message: ScheduledMessage, failedBecause reason: String) {
        ScheduledMessageStore.shared.fail(message.id, reason: reason)
        ScheduledMessageScheduler.shared.forgetWaiting(message.id)
        environment.eventLog.record(.composer, "Scheduled message failed", [
            "reason": reason,
            "prompt": message.text
        ])
        ScheduledMessageNotifier.shared.report(.failed(message, reason: reason))
    }
}

// MARK: - Waking Text

private extension ConversationPrompt {
    /// What a woken session is handed. Context rides as the provider-neutral envelope, because
    /// the surface it is going to has not been built yet and there is no rail to stage it in.
    var transportTextForWake: String {
        context.isEmpty ? visibleText : transportText
    }
}
