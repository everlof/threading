import AppKit

// MARK: - Who Asked For The Move

/// Whether the migration was pressed for or armed in advance.
///
/// It changes exactly two things, and both are about who is in the room. A press may raise a modal
/// alert, because somebody is there to read it; an unattended policy must not, since a sheet nobody
/// dismisses blocks the whole app until they come back. And a policy's failure has to lower the park
/// the coordinator raised, because the row is the only thing that will say so.
enum LimitEscapeTrigger: Equatable, Sendable {
    case press
    case policy
}

// MARK: - Taking The Usage-Limit Escape

/// What happens when a session the provider refused for a spent usage limit is moved to another
/// login — pressed on the strip, or armed in advance as `LimitRecoveryPolicy.resumeOnBestAccount`
/// or `resumeVia(_:)`.
///
/// `LimitEscapeSuggestionStore` owns *what is offered* and `LimitEscapeStripView` draws it; this
/// owns *doing it*, for `SessionCoordinator+ScheduledMessages`' reason — migrating a conversation
/// and putting its pane back is a lifecycle decision, and every one of those goes through the
/// coordinator rather than through the surface that asked.
///
/// **One routine, two callers**, the rule `LimitRecoveryCoordinator.armWaitForReset(for:)` already
/// follows in the other direction: the policy runs what the press runs, so the guards cannot drift
/// apart. Four steps, and each of the middle two is a guard rather than a formality:
///
/// 1. The button goes busy, so a second press cannot start a second migration.
/// 2. The **target's** reading is force-refreshed and eligibility re-checked. A cached figure
///    must not move somebody's conversation onto a login that is also spent, which is the guard
///    `limit-recovery.md` states for the automatic policy and which applies unchanged here.
/// 3. The move runs without a second confirmation — the button named its whole action, and the
///    policy was chosen in advance and in writing.
/// 4. The continuation rides `ScheduledMessage`, never a raw keystroke: delivery types between
///    turns in its own write and parks `.waiting` where the process is not at a prompt, which is
///    exactly the safety a just-relaunched TUI needs.
extension SessionCoordinator {

    // MARK: - Entry

    /// Somebody pressed *Continue as …* on the strip.
    func performLimitEscape(for sessionID: SessionID) {
        performLimitEscape(for: sessionID, to: nil, trigger: .press)
    }

    /// A policy asked for the move, naming the login `LimitRecoveryCoordinator` settled on.
    ///
    /// The login is carried rather than re-derived: `resumeVia(_:)` names one the user pinned,
    /// which is not necessarily the one the standing offer would name, and picking the offer's
    /// instead would be the silent escalation this subsystem refuses.
    func performAutomaticLimitEscape(for sessionID: SessionID, to accountID: AccountID) {
        performLimitEscape(for: sessionID, to: accountID, trigger: .policy)
    }

    /// Spends a banked reset on the refused login itself. It deliberately creates no
    /// continuation: only already-owed `continue on reset` records are released by the core
    /// service after Codex's authoritative post-consume read shows headroom.
    func performBankedUsageReset(for sessionID: SessionID) {
        let store = LimitEscapeSuggestionStore.shared
        guard let suggestion = store.offer(for: sessionID),
              suggestion.offersBankedReset,
              !suggestion.isBusy,
              let session = environment.projectStore.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ), account.provider.supports(.bankedUsageReset) else { return }

        store.setBusy(.useBankedReset, for: sessionID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let offer = try await BankedUsageResetService.shared.prepare(account: account)
                guard await confirmBankedUsageReset(offer) else {
                    store.setBusy(nil, for: sessionID)
                    return
                }
                let result = try await BankedUsageResetService.shared.redeem(
                    account: account,
                    offer: offer
                )
                switch result.outcome {
                case .reset where result.hasVerifiedHeadroom,
                     .alreadyRedeemed where result.hasVerifiedHeadroom:
                    store.clear(sessionID)
                case .reset, .alreadyRedeemed, .nothingToReset, .noCredit:
                    store.note(
                        problem: BankedUsageResetConfirmation.resultMessage(result),
                        for: sessionID
                    )
                }
                toastPresenter(ToastRequest(
                    message: BankedUsageResetConfirmation.resultMessage(result),
                    identifier: "sidebar.toast.banked-usage-reset"
                ))
            } catch {
                store.note(problem: error.localizedDescription, for: sessionID)
            }
        }
    }

    private func confirmBankedUsageReset(_ offer: BankedUsageResetOffer) async -> Bool {
        await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(
                BankedUsageResetConfirmation.request(for: offer),
                in: container.view.window
            ) { continuation.resume(returning: $0) }
        }
    }

    private func performLimitEscape(
        for sessionID: SessionID,
        to requestedAccountID: AccountID?,
        trigger: LimitEscapeTrigger
    ) {
        let store = LimitEscapeSuggestionStore.shared
        guard let offer = store.offer(for: sessionID), !offer.isBusy else { return }
        // A refusal with no login named is not the *button's* business at all — the strip does not
        // draw the account control for one, so reaching here on a press means the offer changed
        // under it, and the answer is the same as a login that has since gone. A policy names its
        // own login and does not consult the offer for one.
        guard let targetAccountID = requestedAccountID ?? offer.accountID,
              let session = environment.projectStore.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: targetAccountID.handle
              ), account.id == targetAccountID else {
            let reason = "the login named for the escape is gone"
            store.note(
                problem: L10n.string("That login could not be found."),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape refused, the login is gone", [
                "session": sessionID.uuidString,
                "account": (requestedAccountID ?? offer.accountID)?.description ?? "",
                "trigger": String(describing: trigger)
            ])
            reportFailureToPolicy(trigger, sessionID: sessionID, reason: reason)
            return
        }

        // A policy's login is not necessarily the one the offer names — `resumeVia(_:)` names the
        // pinned one — and the strip's busy line is drawn from this record, so it is pointed at the
        // login actually being moved to before it starts saying so.
        if requestedAccountID != nil {
            store.retarget(
                to: account.id,
                name: AccountName.display(for: account),
                reading: AccountUsageService.shared.usage(for: account)?
                    .compactSummary(metering: offer.model),
                for: sessionID
            )
        }

        store.setBusy(.moveAccount, for: sessionID)
        environment.eventLog.record(.limitRecovery, "Escape started", [
            "session": sessionID.uuidString,
            "account": account.id.description,
            "trigger": String(describing: trigger)
        ])

        // Forced, and still paced: `AccountUsageService` honours a `notBefore` the endpoint set
        // by answering 429 even here, because a user pressing a button must not be a way to
        // spend a rate limit faster. The receipt fires either way, so a pause the server asked
        // for degrades to "decide on what is cached" rather than hanging the press.
        AccountUsageService.shared.refresh(account, force: true) { [weak self] in
            self?.continueEscape(
                for: sessionID,
                to: account,
                model: offer.model,
                trigger: trigger
            )
        }
    }

    // MARK: - After The Reading Settled

    private func continueEscape(
        for sessionID: SessionID,
        to account: AgentAccount,
        model: String?,
        trigger: LimitEscapeTrigger
    ) {
        let store = LimitEscapeSuggestionStore.shared
        guard store.suggestion(for: sessionID) != nil else { return }

        let usage = AccountUsageService.shared.usage(for: account)
        let candidate = LimitEscapeRanking.Candidate(
            accountID: account.id,
            usage: usage,
            limits: CustomLimitSettings.shared.rules(for: account.id)
        )
        guard LimitEscapeRanking.hasHeadroom(candidate, metering: model) else {
            // Degraded with its reason, and deliberately **not** escalated to whichever login
            // now ranks best: choosing a second account on the user's behalf is what a *pinned*
            // policy and a press both refuse to do. A better candidate becomes a new offer the
            // next time the readings move, and it is pressed the same way this one was.
            store.note(
                problem: L10n.format(
                    "%@ is close to its own limit now.",
                    AccountName.display(for: account)
                ),
                reading: usage?.compactSummary(metering: model),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape stood down, the target has no room", [
                "session": sessionID.uuidString,
                "account": account.id.description,
                "reading": usage?.compactSummary(metering: model) ?? "",
                "trigger": String(describing: trigger)
            ])
            reportFailureToPolicy(
                trigger,
                sessionID: sessionID,
                reason: "the chosen login had no room on its forced reading"
            )
            return
        }

        // **No modal for an unattended move.** The alert is right for a press — the person who
        // asked is looking at the pane — and wrong for a policy, where a sheet nobody dismisses
        // stops the app until somebody comes back to it. The failure is still news: it goes to the
        // journal and onto the strip, which is where the session will be found.
        guard moveSessionWithoutConfirmation(
            sessionID,
            to: account,
            alertingOnFailure: trigger == .press
        ) else {
            // A press also gets the move's own alert. The strip says so either way, because an
            // alert is gone as soon as it is dismissed — and for a policy there was none.
            store.note(
                problem: L10n.string("The conversation could not be moved."),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape failed, the move was refused", [
                "session": sessionID.uuidString,
                "account": account.id.description,
                "trigger": String(describing: trigger)
            ])
            reportFailureToPolicy(
                trigger,
                sessionID: sessionID,
                reason: "the conversation could not be moved"
            )
            return
        }

        scheduleContinuation(for: sessionID, account: account, trigger: trigger)
    }

    // MARK: - The Continuation

    /// Files the word the user would have typed, as an ordinary scheduled send.
    ///
    /// Not typed here, and not handed to the launch as an opening prompt: `AgentLauncher` omits
    /// the prompt on `--resume`, and a resumed TUI can only be typed into once it is at its own
    /// prompt. Every rule about *when* that is safe already lives in
    /// [`scheduled-messages.md`](scheduled-messages.md), and is inherited rather than restated —
    /// including the one that decides what an unattended move looks like when it lands: a session
    /// whose pane was not showing has no process to type into, so the send waits visibly in the
    /// strip rather than being typed into a terminal nobody can see, and goes as soon as the
    /// session is opened.
    private func scheduleContinuation(
        for sessionID: SessionID,
        account: AgentAccount,
        trigger: LimitEscapeTrigger
    ) {
        let store = LimitEscapeSuggestionStore.shared
        let message = ScheduledMessage(
            dueAt: Date().addingTimeInterval(LimitEscapeDefaults.continuationDelay),
            target: .session(sessionID),
            text: LimitRecoveryDefaults.continuationText,
            purpose: .limitRecovery
        )

        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            store.clear(sessionID)
            environment.eventLog.record(.limitRecovery, "Escape taken, continuation scheduled", [
                "session": sessionID.uuidString,
                "account": account.id.description,
                "text": message.text,
                "trigger": String(describing: trigger)
            ])
            ThreadingLogger.agent.info(
                """
                Limit escape moved \(sessionID.uuidString, privacy: .public) to another login \
                and queued its continuation
                """
            )

        case .failure(let refusal):
            // The conversation *did* move — that half is done and durable — so the offer is
            // gone and what is left to say is that the word was not queued.
            store.note(
                problem: ScheduledRefusalText.sentence(for: refusal),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape moved but the continuation was refused", [
                "session": sessionID.uuidString,
                "account": account.id.description,
                "refusal": String(describing: refusal),
                "trigger": String(describing: trigger)
            ])
            reportFailureToPolicy(
                trigger,
                sessionID: sessionID,
                reason: "the conversation moved but its continuation was refused"
            )
        }
    }

    // MARK: - Telling The Policy

    /// Hands a failure back to the coordinator, which owns the park.
    ///
    /// A press needs none of this: the session was already flagged when the strip appeared, and the
    /// sentence on that strip is the answer. A policy raised a `recovering` park before it started,
    /// and leaving it up would draw an idle row over a session that is still refused with nothing
    /// coming to fix it.
    private func reportFailureToPolicy(
        _ trigger: LimitEscapeTrigger,
        sessionID: SessionID,
        reason: String
    ) {
        guard trigger == .policy else { return }
        LimitRecoveryCoordinator.shared.noteAutomaticResumeFailed(for: sessionID, reason: reason)
    }
}
