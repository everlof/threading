import AppKit

// MARK: - Curfew Menu

/// When this session stops being spent, assembled in one place for every surface that asks.
///
/// The draft view asks it while somebody is writing a prompt, the chat chip asks it about a
/// conversation already running, and the sidebar fold asks it about a row — the same question in
/// three places, which is the reason `ScheduleMenu` exists one shelf along and the reason this
/// sits beside it rather than inside any of the three.
///
/// Nothing here decides anything. It turns `ScheduledTimePresets`, the standing quiet hours and
/// an already-resolved answer into rows, and hands the choice back. In particular it does not
/// read `CurfewSettings` or `ProjectStore`: the caller resolves, because only the caller knows
/// whether the subject is a session, a checkout, or a draft that has neither yet.
///
/// **The checkmark reads the resolved answer, never the record.** A chat inside an exempt
/// checkout is exempt, and a row that showed nothing selected there would be stating the
/// opposite of what happens to it tonight — the rule `limitRecoveryEntry` follows for the same
/// reason.
@MainActor
enum CurfewMenu {

    /// What a chosen row asks for.
    enum Choice {
        case atUsage(percent: Int, windowID: String)
        /// End at this moment.
        case at(Date)
        /// End when quiet hours next begin. The date is what the menu named, so a caller that
        /// arms immediately has the moment and one that freezes a plan can store the *choice*.
        case atQuietHours(Date)
        /// End at this exact window's scheduled boundary, or at an earlier proven reset of it.
        /// A 5h or Spark reset cannot satisfy a 7d choice.
        case untilUsageReset(expectedAt: Date, windowID: String)
        /// Never hold this session, whatever the standing window says.
        case exempt
        /// Say nothing of its own and follow whatever the scope above answers.
        case inherit
        /// End the curfew that is holding it now.
        case lift
        case custom
    }

    /// What each row means, for the callers and tests that need to find one.
    ///
    /// A named identity rather than a title match: the titles carry times and are localized, and
    /// a test asserting on "At quiet hours (04:00)" would be asserting on a formatter.
    enum RowID: String {
        case usageThreshold
        case atQuietHours
        case endsAt
        case inherit
        case exempt
        case lift
        case custom
    }

    // MARK: - Entries

    /// Builds the rows.
    ///
    /// `usage` is passed rather than fetched, for `ScheduleMenu.entries`' reason: a menu is built
    /// in one run-loop pass and a usage fetch is a network round trip, so the caller hands over
    /// the cached reading it already asked `AccountUsageService` for.
    ///
    /// `quietHours` nil — or configured and switched off — removes every quiet-hours row and
    /// leaves a single "No curfew" answer, because "Follow quiet hours" beside a window nobody
    /// has set up names a rule that does not exist.
    ///
    /// `offersExempt` is false on the draft view: a session that has not started cannot be
    /// exempted from anything, and the row would be an answer to a question about a record that
    /// is not there yet.
    static func entries(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        usage: AccountUsage? = nil,
        metering model: String? = nil,
        quietHours: QuietHours? = nil,
        resolved: CurfewResolution.Answer,
        holds: Bool,
        offersExempt: Bool = true,
        onChoose: @escaping (Choice) -> Void
    ) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []

        for preset in ScheduledTimePresets.curfewWallClock(
            now: now,
            calendar: calendar,
            locale: locale
        ) {
            entries.append(.item(row(preset, onChoose: onChoose)))
        }

        // The reset offers answer a different question from "when suits me" — they answer "how
        // much of this window is mine to spend" — and running the two lists together would read
        // as one list of times, half of which move.
        let resets = ScheduledTimePresets.curfewUsageResets(
            usage: usage,
            metering: model,
            now: now,
            locale: locale
        )
        if !resets.isEmpty {
            entries.append(.separator)
            for preset in resets {
                entries.append(.item(resetRow(
                    preset,
                    resolved: resolved,
                    onChoose: onChoose
                )))
            }
        }

        let thresholds = usageThresholdEntries(usage: usage, model: model, resolved: resolved,
                                               onChoose: onChoose)
        if !thresholds.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: thresholds)
        }

        let quietHours = quietHours.flatMap { $0.isEnabled ? $0 : nil }
        if let start = quietHours?.nextWindow(after: now, calendar: calendar)?.start {
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.format(
                    "At quiet hours (%@)",
                    ScheduledTimePresets.time(start, locale: locale)
                ),
                help: L10n.string("Ends this session when the standing quiet hours next begin."),
                representedValue: RowID.atQuietHours,
                onChoose: { onChoose(.atQuietHours(start)) }
            )))
        }

        entries.append(.separator)
        entries.append(contentsOf: standingChoices(
            resolved: resolved,
            hasQuietHours: quietHours != nil,
            offersExempt: offersExempt,
            locale: locale,
            onChoose: onChoose
        ))

        // Legitimate because the rule is the user's own: this is not a provider limit being
        // waved away, it is somebody changing their mind about their own bedtime.
        if holds {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Lift Curfew"),
                help: L10n.string("Releases this session now; nothing else about the rule changes."),
                representedValue: RowID.lift,
                onChoose: { onChoose(.lift) }
            )))
        }

        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Custom time…"),
            representedValue: RowID.custom,
            onChoose: { onChoose(.custom) }
        )))
        return entries
    }

    // MARK: - Chip Title

    /// What a chip carrying a chosen plan says.
    ///
    /// `atQuietHours` is resolved late on purpose, the way the plan itself is: the choice is
    /// "whenever quiet hours next begin", and a chip that had written Tuesday's 04:00 down would
    /// keep saying it on Thursday. Nil is *no plan* — the chip is absent rather than empty, the
    /// `managedWorkspaceDeliveryChip` rule.
    static func title(
        for plan: ScheduledCurfewPlan?,
        quietHours: QuietHours?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        switch plan {
        case .atUsage(let percent, let windowID):
            return CurfewReceiptWords.usageThreshold(percent: percent, windowID: windowID)
        case nil:
            return nil
        case .at(let deadline):
            return L10n.format("Until %@", ScheduledTimePresets.time(deadline, locale: locale))
        case .atQuietHours:
            // The window can be switched off between choosing the plan and reading it back. The
            // choice still stands and still has to be visible — it resolves against whatever is
            // configured when the start fires — so the chip drops the time rather than the chip.
            guard let quietHours, quietHours.isEnabled,
                  let start = quietHours.nextWindow(after: now, calendar: calendar)?.start else {
                return L10n.string("Until quiet hours")
            }
            return L10n.format(
                "Until quiet hours (%@)",
                ScheduledTimePresets.time(start, locale: locale)
            )
        case .untilUsageReset(_, let windowID):
            return L10n.format("Until the %@ window resets", windowID)
        }
    }

    // MARK: - Private Methods

    /// The standing answers — the ones that are a rule rather than a moment.
    ///
    /// A session that named its own moment marks **none** of them: it is not following quiet
    /// hours and it is not exempt from them, it has an end of its own, and a checkmark on either
    /// row would be a claim about a rule it is not under. The moment is stated instead, as a row
    /// that says it and cannot be chosen — the shape `scheduleEntries()` uses for a refusal,
    /// where a disabled row is a sentence rather than a dead control.
    private static func standingChoices(
        resolved: CurfewResolution.Answer,
        hasQuietHours: Bool,
        offersExempt: Bool,
        locale: Locale,
        onChoose: @escaping (Choice) -> Void
    ) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []

        if case .usageThreshold(let percent, _, _, let windowID)? = resolved.condition {
            entries.append(.item(ThemedMenuItem(
                title: CurfewReceiptWords.usageThreshold(percent: percent, windowID: windowID),
                representedValue: RowID.usageThreshold,
                isSelected: true,
                isEnabled: false
            )))
        }

        if resolved.scope == .session,
           resolved.condition == nil,
           let curfew = resolved.curfew {
            entries.append(.item(ThemedMenuItem(
                title: L10n.format(
                    "Ends at %@",
                    ScheduledTimePresets.time(curfew.deadline, locale: locale)
                ),
                representedValue: RowID.endsAt,
                isSelected: true,
                isEnabled: false
            )))
        }

        guard hasQuietHours else {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("No curfew"),
                help: L10n.string("Nothing ends this session; it runs until you stop it."),
                representedValue: RowID.inherit,
                isSelected: resolved.curfew == nil && resolved.condition == nil,
                onChoose: { onChoose(.inherit) }
            )))
            return entries
        }

        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Follow quiet hours"),
            help: L10n.string("Held every night with every other session that has not said otherwise."),
            representedValue: RowID.inherit,
            // The standing window answered, which is what following it looks like from here.
            isSelected: resolved.scope == .app && resolved.curfew != nil,
            onChoose: { onChoose(.inherit) }
        )))

        if offersExempt {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Exempt from quiet hours"),
                help: L10n.string("Quiet hours never hold this session; it keeps working through them."),
                representedValue: RowID.exempt,
                // Nothing resolved, and it was this record or its checkout that said so — the
                // standing window answering "no curfew" is a window that is simply not on.
                isSelected: resolved.curfew == nil && resolved.condition == nil && resolved.scope != .app,
                onChoose: { onChoose(.exempt) }
            )))
        }

        return entries
    }

    /// A fixed percentage list per window; cached provider values stay menu models. Bound both
    /// the source scan and the output before constructing rows (normally two to four windows).
    private static func usageThresholdEntries(
        usage: AccountUsage?,
        model: String?,
        resolved: CurfewResolution.Answer,
        onChoose: @escaping (Choice) -> Void
    ) -> [ThemedMenuEntry] {
        guard let usage else { return [] }
        let maximumWindows = 8
        let windows = Array(usage.windows.prefix(maximumWindows))
            + usage.modelWindows.prefix(maximumWindows).filter {
                guard let model else { return false }
                return ModelName.scope($0.id, meters: model)
            }
        return windows.prefix(maximumWindows).map { window in
            let selected: Int?
            if case .usageThreshold(let percent, _, _, let windowID)? = resolved.condition,
               windowID == window.id {
                selected = percent
            } else {
                selected = nil
            }
            var choices: [ThemedMenuEntry] = CurfewDefaults.usagePercentPresets.map { percent in
                .item(ThemedMenuItem(
                    title: L10n.format("%lld%%", Int64(percent)),
                    representedValue: percent,
                    isSelected: selected == percent,
                    onChoose: { onChoose(.atUsage(percent: percent, windowID: window.id)) }
                ))
            }
            choices.append(.separator)
            choices.append(.item(ThemedMenuItem(
                title: L10n.string("Custom percentage…"),
                onChoose: {
                    guard let percent = IntegerPromptAlert.ask(usagePrompt(
                        windowID: window.compactName,
                        current: selected ?? CurfewDefaults.defaultUsagePercent
                    ))?.first else { return }
                    onChoose(.atUsage(percent: percent, windowID: window.id))
                }
            )))
            return .item(ThemedMenuItem(
                title: L10n.format("At usage percentage (%@)", window.compactName),
                help: CurfewReceiptWords.usageThresholdHelp,
                representedValue: window.id,
                isSelected: selected != nil,
                submenu: choices
            ))
        }
    }

    static func usagePrompt(windowID: String, current: Int) -> IntegerPromptRequest {
        IntegerPromptRequest(
            title: L10n.format("Usage curfew (%@)", windowID),
            message: CurfewReceiptWords.usageThresholdHelp,
            confirmTitle: L10n.string("Set Curfew"),
            fields: [IntegerPromptFieldRequest(
                title: L10n.string("Stop at"),
                accessibilityLabel: L10n.string("Usage percentage"),
                suffix: "%",
                current: current,
                range: CurfewDefaults.usagePercentRange
            )],
            helperText: L10n.string("Enter a whole percentage from 1 to 100.")
        )
    }

    /// One offer, with its reading placed by how much of a reading it is — `ScheduleMenu.row`'s
    /// rule, and the same reason: `ThemedMenuMetrics.heights` gives every row in a run the height
    /// of the tallest kind in it, so one subtitle in the wall-clock run makes three tall rows
    /// holding one line of text each. A reset offer's "04:00 · resets in 4h 37m" is two facts and
    /// keeps its second line, behind a separator of its own.
    private static func row(
        _ preset: ScheduledTimePreset,
        onChoose: @escaping (Choice) -> Void
    ) -> ThemedMenuItem {
        var item = ThemedMenuItem(
            title: preset.title,
            subtitle: preset.anchor == .wallClock ? nil : preset.detail,
            representedValue: preset.id,
            onChoose: { onChoose(.at(preset.date)) }
        )
        if preset.anchor == .wallClock { item.titleDetail = preset.detail }
        return item
    }

    /// A usage end follows one named window, never whichever provider counter happens to move
    /// first. Its scheduled boundary remains the latest end; matching provider evidence may
    /// bring it forward, while a reset on another window cannot satisfy it.
    private static func resetRow(
        _ preset: ScheduledTimePreset,
        resolved: CurfewResolution.Answer,
        onChoose: @escaping (Choice) -> Void
    ) -> ThemedMenuItem {
        guard let windowID = preset.anchor.usageWindowID else {
            return row(preset, onChoose: onChoose)
        }
        let isSelected: Bool
        if case .usageReset(_, _, _, let selectedWindowID)? = resolved.condition {
            isSelected = selectedWindowID == windowID
        } else {
            isSelected = false
        }
        return ThemedMenuItem(
            title: preset.title,
            help: L10n.string(
                "Stops at this window’s scheduled reset, or sooner if the provider resets this same window early."
            ),
            subtitle: preset.detail,
            representedValue: preset.id,
            isSelected: isSelected,
            onChoose: {
                onChoose(.untilUsageReset(expectedAt: preset.date, windowID: windowID))
            }
        )
    }
}
