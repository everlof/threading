import AppKit

// MARK: - Choosing An End While Writing The Brief

/// When a session started from this screen stops being spent.
///
/// The other half of the clock beside it: that one says when a session *starts*, this one says
/// when it ends. Both are decisions made in advance for something that happens with nobody
/// watching, and both are frozen into `ScheduledSessionPlan` rather than acted on here — a draft
/// has no session to arm anything on, and the end is armed at the moment one actually starts.
///
/// The rows come from `CurfewMenu`, which is the same menu the chat chip and the sidebar fold
/// open, so the question is answered identically wherever it is asked. What is specific to a
/// draft is only what it can *mean*: no exemption is offered, because a session that does not
/// exist cannot be exempted from anything, and nothing can be lifted for the same reason.
extension SessionComposerViewController {

    // MARK: - The Menu

    /// Opens the offers under the button that asked for them.
    func presentCurfewMenu(from source: NSView) {
        let entries = curfewEntries()
        guard !entries.isEmpty else { return }
        ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 0),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: {}
        )
    }

    /// The offers behind the end button and behind the chip that appears once one is taken.
    ///
    /// Built fresh on every open, like the schedule menu beside it: a quiet-hours window switched
    /// on since the last press, or a usage window that reset five minutes ago, must not still be
    /// offered as it was.
    func curfewEntries() -> [ThemedMenuEntry] {
        let now = Date()
        let preferences = CurfewSettings.shared.preferences

        // The account's cached reading, refreshed once for the whole menu rather than once per
        // row — `scheduleEntries()`' rule, and the same reason: a menu is built in one run-loop
        // pass and a usage fetch is a network round trip.
        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil
        if let account { AccountUsageService.shared.refresh(account) }

        return CurfewMenu.entries(
            now: now,
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: account.flatMap { modelIdentifierToLaunch(on: $0) },
            quietHours: preferences.quietHours,
            resolved: resolvedCurfewAnswer(preferences: preferences, now: now),
            holds: false,
            // A session that has not started cannot be exempted from anything, and the row would
            // be an answer about a record that is not there yet.
            offersExempt: false
        ) { [weak self] choice in
            self?.chooseCurfew(choice)
        }
    }

    /// What this draft is answering *against* — the reading the menu's checkmarks come from.
    ///
    /// There is no record to resolve, so the answer is composed: the checkout's own rule if the
    /// composer is pointed at one, the standing quiet hours behind that, and the draft's own
    /// chosen end standing in for the session scope. That last part is what makes the menu honest
    /// about a choice already taken — without it a draft ending at 04:00 would still show
    /// "Follow quiet hours" ticked, which is the opposite of what it is going to do.
    private func resolvedCurfewAnswer(
        preferences: CurfewPreferences,
        now: Date
    ) -> CurfewResolution.Answer {
        let sessionRule: CurfewRule?
        if case .untilUsageReset(let expectedAt, let windowID)? = selectedCurfew {
            sessionRule = .untilUsageReset(
                expectedAt: expectedAt,
                armedAt: now,
                accountID: AccountID(
                    provider: selectedAgent,
                    handle: selectedAccountHandle
                ),
                windowID: windowID
            )
        } else {
            sessionRule = chosenCurfewDeadline(
                preferences: preferences,
                now: now
            ).map(CurfewRule.until)
        }
        return CurfewResolution.resolve(
            session: sessionRule,
            project: projectID
                .flatMap { ProjectStore.shared.project(withID: $0) }?
                .curfewRule,
            preferences: preferences,
            // A draft has no instance of its own, so there is nothing it could have lifted.
            state: nil,
            now: now
        )
    }

    // MARK: - Taking One

    private func chooseCurfew(_ choice: CurfewMenu.Choice) {
        switch choice {
        case .at(let deadline):
            selectedCurfew = .at(deadline)

        case .atQuietHours:
            // The *choice* rather than the moment behind it, which is the one place this differs
            // from the running chat's menu. A start may be days away, and a plan that wrote down
            // Tuesday's 04:00 would name a deadline before its own session began; the window is
            // read again when the session actually starts.
            selectedCurfew = .atQuietHours

        case .untilUsageReset(let expectedAt, let windowID):
            selectedCurfew = .untilUsageReset(
                expectedAt: expectedAt,
                windowID: windowID
            )

        case .inherit:
            // "No curfew" and "Follow quiet hours" are the same answer from a draft: it says
            // nothing of its own, and whatever governs the session it becomes will govern it.
            selectedCurfew = nil

        case .exempt, .lift:
            // Neither row is offered — `offersExempt` is false and nothing holds a draft — and
            // neither has a meaning here. Listed rather than defaulted so a new row added to
            // `CurfewMenu.Choice` is a compiler error on this screen rather than a silent no-op.
            break

        case .custom:
            ScheduleMomentPickerViewController.present(
                over: self,
                title: L10n.string("End this session"),
                confirmTitle: L10n.string("Set Curfew")
            ) { [weak self] date in
                guard let self, let date else { return }
                self.selectedCurfew = .at(date)
            }
        }
    }

    // MARK: - What The Chip Says

    /// The moment this draft's chosen end resolves to, or nil where it names none.
    ///
    /// `atQuietHours` answers only while a window is configured and switched on. The choice still
    /// stands when it is not — it is resolved again at fire time — so this being nil is a
    /// statement about the *clock*, never about the plan.
    func chosenCurfewDeadline(
        preferences: CurfewPreferences = CurfewSettings.shared.preferences,
        now: Date = Date()
    ) -> Date? {
        guard case .arm(let deadline) = ScheduledCurfewPlanResolution.deadline(
            for: selectedCurfew,
            preferences: preferences,
            now: now
        ) else { return nil }
        return deadline
    }

    /// The whole ladder the chosen end will run, for the chip's tooltip: when it ends, when the
    /// wrap-up goes, and when a turn still running is interrupted — each clause present only
    /// where the margin behind it is switched on in Settings.
    ///
    /// Nil where the choice names no moment yet, which is the `atQuietHours`-with-no-window case:
    /// the chip keeps its own title then rather than inventing times for a window nobody set.
    func curfewLadderSentence(now: Date = Date()) -> String? {
        let preferences = CurfewSettings.shared.preferences
        if case .untilUsageReset(_, let windowID)? = selectedCurfew {
            return L10n.format(
                "Stops at the %@ window’s scheduled reset, or sooner if the provider resets that same window early.",
                windowID
            )
        }
        guard let deadline = chosenCurfewDeadline(preferences: preferences, now: now) else {
            return nil
        }
        return CurfewReceiptWords.plannedLadder(curfew: ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: preferences.windDownMargin,
            grace: preferences.grace,
            windDownText: preferences.windDownText
        ))
    }
}
