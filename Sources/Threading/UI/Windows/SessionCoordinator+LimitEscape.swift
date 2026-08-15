import AppKit

// MARK: - Taking The Usage-Limit Escape

/// What happens when somebody presses *Continue as …* on a session the provider refused for a
/// spent usage limit.
///
/// `LimitEscapeSuggestionStore` owns *what is offered* and `LimitEscapeStripView` draws it; this
/// owns *doing it*, for `SessionCoordinator+ScheduledMessages`' reason — migrating a conversation
/// and putting its pane back is a lifecycle decision, and every one of those goes through the
/// coordinator rather than through the surface that asked.
///
/// Four steps, and each of the middle two is a guard rather than a formality:
///
/// 1. The button goes busy, so a second press cannot start a second migration.
/// 2. The **target's** reading is force-refreshed and eligibility re-checked. A cached figure
///    must not move somebody's conversation onto a login that is also spent, which is the guard
///    `limit-recovery.md` states for the automatic policy and which applies unchanged here.
/// 3. The move runs without a second confirmation — the button named its whole action.
/// 4. The continuation rides `ScheduledMessage`, never a raw keystroke: delivery types between
///    turns in its own write and parks `.waiting` where the process is not at a prompt, which is
///    exactly the safety a just-relaunched TUI needs.
extension SessionCoordinator {

    // MARK: - Entry

    func performLimitEscape(for sessionID: SessionID) {
        let store = LimitEscapeSuggestionStore.shared
        guard let offer = store.offer(for: sessionID), !offer.isBusy else { return }
        // A refusal with no login named is not this button's business at all — the strip does not
        // draw the account control for one, so reaching here means the offer changed under the
        // press, and the answer is the same as a login that has since gone.
        guard let offeredAccountID = offer.accountID,
              let session = environment.projectStore.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: offeredAccountID.handle
              ), account.id == offeredAccountID else {
            store.note(
                problem: L10n.string("That login could not be found."),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape refused, the login is gone", [
                "session": sessionID.uuidString,
                "account": offer.accountID?.description ?? ""
            ])
            return
        }

        store.setBusy(.moveAccount, for: sessionID)
        environment.eventLog.record(.limitRecovery, "Escape pressed", [
            "session": sessionID.uuidString,
            "account": account.id.description
        ])

        // Forced, and still paced: `AccountUsageService` honours a `notBefore` the endpoint set
        // by answering 429 even here, because a user pressing a button must not be a way to
        // spend a rate limit faster. The receipt fires either way, so a pause the server asked
        // for degrades to "decide on what is cached" rather than hanging the press.
        AccountUsageService.shared.refresh(account, force: true) { [weak self] in
            self?.continueEscape(for: sessionID, to: account, model: offer.model)
        }
    }

    // MARK: - After The Reading Settled

    private func continueEscape(
        for sessionID: SessionID,
        to account: AgentAccount,
        model: String?
    ) {
        let store = LimitEscapeSuggestionStore.shared
        guard store.suggestion(for: sessionID) != nil else { return }

        let usage = AccountUsageService.shared.usage(for: account)
        let candidate = LimitEscapeRanking.Candidate(accountID: account.id, usage: usage)
        guard LimitEscapeRanking.hasHeadroom(candidate, metering: model) else {
            // Degraded with its reason, and deliberately **not** escalated to whichever login
            // now ranks best: choosing a second account on the user's behalf is the automatic
            // policy this feature exists to avoid. A better candidate becomes a new offer the
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
                "reading": usage?.compactSummary(metering: model) ?? ""
            ])
            return
        }

        guard moveSessionWithoutConfirmation(sessionID, to: account) else {
            // The move states its own failure in an alert. The strip says so too, because the
            // alert is gone as soon as it is dismissed and the offer is still standing there.
            store.note(
                problem: L10n.string("The conversation could not be moved."),
                for: sessionID
            )
            environment.eventLog.record(.limitRecovery, "Escape failed, the move was refused", [
                "session": sessionID.uuidString,
                "account": account.id.description
            ])
            return
        }

        scheduleContinuation(for: sessionID, account: account)
    }

    // MARK: - The Continuation

    /// Files the word the user would have typed, as an ordinary scheduled send.
    ///
    /// Not typed here, and not handed to the launch as an opening prompt: `AgentLauncher` omits
    /// the prompt on `--resume`, and a resumed TUI can only be typed into once it is at its own
    /// prompt. Every rule about *when* that is safe already lives in
    /// [`scheduled-messages.md`](scheduled-messages.md), and is inherited rather than restated.
    private func scheduleContinuation(for sessionID: SessionID, account: AgentAccount) {
        let store = LimitEscapeSuggestionStore.shared
        let message = ScheduledMessage(
            dueAt: Date().addingTimeInterval(LimitEscapeDefaults.continuationDelay),
            target: .session(sessionID),
            text: LimitRecoveryDefaults.continuationText
        )

        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            store.clear(sessionID)
            environment.eventLog.record(.limitRecovery, "Escape taken, continuation scheduled", [
                "session": sessionID.uuidString,
                "account": account.id.description,
                "text": message.text
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
                "refusal": String(describing: refusal)
            ])
        }
    }
}
