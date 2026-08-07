import AppKit

/// Shows each account's latest usage where an account is *chosen*, rather than only in the
/// toolbar once a session is already running.
///
/// Which login to start on is exactly the moment the number matters: an account at 90% of its
/// weekly window is a bad place to begin a long task, and by the time the pill says so the
/// session exists. Both places that offer accounts — the composer's account chip and the
/// `+` menu's per-agent submenus — go through here, so the reading reads the same in both.
@MainActor
enum AccountUsageMenu {

    // MARK: - Public Methods

    /// Puts `account`'s cached reading on a semantic chip item, and asks for a fresh one.
    ///
    /// Cached only: a menu is built synchronously and a fetch is a network round trip, so the
    /// alternative to showing what is known is showing nothing while the menu is open. The
    /// refresh it kicks off is throttled by `AccountUsageService` and lands for the next open
    /// — which `prefetch` exists to make the common case.
    ///
    /// `model` is what the session will run if this account is chosen. It belongs here because
    /// the plan meters some models separately: comparing two logins on their weekly windows
    /// alone can recommend the one whose Fable window is nearly spent.
    ///
    /// The **gauge** is metered by that model and the **text** is not, which is the split the
    /// surface asks for rather than an inconsistency. The account is picked before the model, so
    /// the text lists every scoped window the login has — including the ones a model chosen next
    /// would run into. The gauge answers the narrower question it has always answered, what stops
    /// the session that would start now, and a model this session is not running must not tint it.
    ///
    /// `agent` is the runtime this login belongs to, on a surface where that is *not* already
    /// established — the composer's identity menu offers every runtime's logins in one list, so
    /// each row has to name its own. Naming it costs the ring: a menu row has one image slot, and
    /// `AccountMarkImage` spends it on the brand mark with the same reading underneath. Left nil
    /// where the runtime is a foregone conclusion, and the ring stays.
    ///
    /// The runtime is written **as well as** drawn, leading the subtitle. The mark answers the
    /// glance, but one person's logins are often named the same thing on two runtimes, and two
    /// rows reading `Everlof` told apart only by a 14pt silhouette is a coin toss. It leads
    /// rather than trails because the eye finds the start of a line, and it is the only segment
    /// there that survives an account with no reading at all.
    static func decorate(
        _ item: inout ThemedMenuItem,
        for account: AgentAccount,
        metering model: String? = nil,
        markedAs agent: AgentKind? = nil
    ) {
        AccountUsageService.shared.refresh(account)

        let usage = AccountUsageService.shared.usage(for: account)

        // The gauge first, because it is what makes three accounts comparable without reading
        // twelve numbers. The text stays: it is the precise answer, and the gauge is the glance.
        if let agent {
            // Drawn whatever usage says: on this surface the mark is identity, and a row that
            // lost its runtime because a reading had not landed would be worse than one with no
            // meter under it.
            item.image = AccountMarkImage.make(for: agent, usage: usage, metering: model)
        } else if let usage, let ring = UsageRingImage.make(for: usage, metering: model) {
            item.image = ring
        }

        let segments = identitySegments(runtime: agent, for: usage, metering: model)
        guard !segments.isEmpty else { return }

        // `ThemedMenuPresenter` draws subtitles consistently on every supported macOS version.
        // This helper describes the content without reaching into menu presentation.
        item.setSubtitle(segments)
    }

    /// An identity row's whole subtitle: the runtime leading — the one segment that survives a
    /// login with no reading — then the reading's toned runs. Not private so the render fixture
    /// can draw the same rows the composer assembles, rather than a hand-copied approximation
    /// that drifts the first time this grammar changes.
    static func identitySegments(
        runtime agent: AgentKind?,
        for usage: AccountUsage?,
        metering model: String?,
        at now: Date = Date()
    ) -> [ThemedMenuSubtitleSegment] {
        var segments: [ThemedMenuSubtitleSegment] = []
        if let agent {
            segments.append(ThemedMenuSubtitleSegment(agent.displayName))
        }
        if let usage {
            let reading = summarySegments(for: usage, metering: model, at: now)
            if !reading.isEmpty {
                if !segments.isEmpty { segments.append(separator) }
                segments += reading
            }
        }
        return segments
    }

    /// `Max · 5h 7% · 7d 56% · Fable 89% · Fable resets in 15h`.
    ///
    /// The line answers, in order, the three questions asked while picking a login: what plan is
    /// this, how much of it is left, and when does the tight one come back. The reset names its
    /// window rather than trailing the list bare — the binding window is not always the last one
    /// written, and an unattributed countdown is read as belonging to whichever is.
    ///
    /// Every scoped window is listed, not only the ones metering `model`: this is the menu where
    /// the login is chosen and the model is not, so a Fable window at 89% is exactly the thing to
    /// say out loud, whatever the account's configured default happens to be. `model` still
    /// decides which window *binds* — the countdown, and the ring `decorate` draws.
    ///
    /// Not private, and takes its own `now`, so the line a menu will show can be asserted
    /// without building a menu.
    static func summary(
        for usage: AccountUsage,
        metering model: String?,
        at now: Date = Date()
    ) -> String? {
        let segments = summarySegments(for: usage, metering: model, at: now)
        guard !segments.isEmpty else { return nil }
        return segments.map(\.text).joined()
    }

    /// The same line as toned runs, which is what the menu row actually draws.
    ///
    /// The grammar is the toolbar pill's, transplanted: window names and separators recede to
    /// the muted tier, values hold the subtitle's own ink until their window is under pressure
    /// and then take its severity colour, and the reset clause stays muted — it is the
    /// footnote, not the finding. What that buys is rhythm: the twelve numbers a three-login
    /// comparison reads stop being twelve equally grey tokens, and the one worth seeing is the
    /// one inked differently. The plain `summary` is this list's own text joined, so the two
    /// cannot say different things.
    static func summarySegments(
        for usage: AccountUsage,
        metering model: String?,
        at now: Date = Date()
    ) -> [ThemedMenuSubtitleSegment] {
        var segments: [ThemedMenuSubtitleSegment] = []

        if let plan = usage.planLabel, !plan.isEmpty {
            segments.append(ThemedMenuSubtitleSegment(plan))
        }
        segments += readingSegments(usage.readings(at: now, scoped: .all), joining: !segments.isEmpty)
        if let reset = resetLine(for: usage, metering: model, at: now) {
            if !segments.isEmpty { segments.append(separator) }
            segments.append(ThemedMenuSubtitleSegment(reset, .muted))
        }

        return segments
    }

    /// `7d Fable resets in 15h` — when the window that binds a session on `model` comes back.
    ///
    /// Attributed to its window rather than trailing the list bare: the binding window is not
    /// always the last one written, and an unattributed countdown is read as belonging to
    /// whichever is.
    private static func resetLine(
        for usage: AccountUsage,
        metering model: String?,
        at now: Date
    ) -> String? {
        guard let binding = usage.bindingWindow(at: now, metering: model),
              let resetsAt = binding.resetsAt
        else { return nil }

        return "\(binding.compactName) \(UsageFormat.resets(until: resetsAt, from: now))"
    }

    // MARK: - Model Rows

    /// Puts what a session on `model` would be measured against on a *model* row, in the menu
    /// where the model is chosen.
    ///
    /// The other half of the same decision. The account menu says which logins have a
    /// separately metered model under pressure; this says which model that is, at the moment
    /// that choice is made — and it is the only surface where the answer is actionable, since
    /// switching model is the cheap way out of a spent scoped window.
    ///
    /// Every row carries its reading, including the models the plan meters no differently.
    /// Stating only the scoped ones was defensible — the account windows are identical on every
    /// row and distinguish nothing — but it read as *missing*: three models listed and one with
    /// a number beside it looks like two failed lookups, not like two models with nothing of
    /// their own to say. Repetition is cheaper than a row that appears to have no data.
    ///
    /// `model` is nil for the row that leaves the choice to the CLI on an account that names no
    /// default: nothing is known about which model will run, so the account's own windows are
    /// the whole honest answer.
    ///
    /// No refresh from here, unlike the account rows. The composer prefetches when it appears
    /// and the account menu asks again on every open, so this list is already warm — and a
    /// model list is not a new reason to spend a network round trip per row.
    static func decorate(
        _ item: inout ThemedMenuItem,
        forModel model: String?,
        on account: AgentAccount
    ) {
        let now = Date()
        guard let usage = AccountUsageService.shared.usage(for: account) else { return }
        let segments = modelSummarySegments(for: usage, running: model, at: now)
        guard !segments.isEmpty else { return }

        // The same ring the account rows draw, gauging the same thing: the window a session
        // started here runs out of first. Rings that meant different things on two menus a click
        // apart would be worse than no ring at all. One `now` for both, so a row cannot state a
        // window the ring has already decided is expired.
        item.image = UsageRingImage.make(for: usage, at: now, metering: model)
        item.setSubtitle(segments)
    }

    /// `5h 10% · 7d 22% · 7d Fable 89% · 7d Fable resets in 15h` — every window a session on
    /// `model` is measured against, and when the binding one comes back.
    ///
    /// Nil only when the account has no windows at all, which is the same silence every other
    /// usage surface keeps when there is nothing to report.
    ///
    /// Narrow where the account menu is broad: this row *is* a model, so the scoped windows of
    /// other models are not its business — that is `ScopedWindows.metering`, and the reason the
    /// two menus do not share one line.
    static func modelSummary(
        for usage: AccountUsage,
        running model: String?,
        at now: Date = Date()
    ) -> String? {
        let segments = modelSummarySegments(for: usage, running: model, at: now)
        guard !segments.isEmpty else { return nil }
        return segments.map(\.text).joined()
    }

    /// The model line as toned runs — `summarySegments`' grammar, minus the plan the account
    /// row already stated, scoped to the windows that meter `model`.
    static func modelSummarySegments(
        for usage: AccountUsage,
        running model: String?,
        at now: Date = Date()
    ) -> [ThemedMenuSubtitleSegment] {
        let readings = usage.readings(at: now, metering: model)
        guard !readings.isEmpty else { return [] }

        var segments = readingSegments(readings, joining: false)
        if let reset = resetLine(for: usage, metering: model, at: now) {
            segments.append(separator)
            segments.append(ThemedMenuSubtitleSegment(reset, .muted))
        }
        return segments
    }

    // MARK: - Segment Grammar

    /// ` · ` in the muted tier — the furniture between values, never louder than them.
    private static var separator: ThemedMenuSubtitleSegment {
        ThemedMenuSubtitleSegment(UsageDefaults.segmentSeparator, .muted)
    }

    /// Each reading as a muted name and a value inked by that window's own pressure.
    ///
    /// A `.normal` value keeps the subtitle's standard ink rather than a green: the pill set
    /// this rule — calm is the absence of a signal, not a third colour — and two surfaces a
    /// click apart disagreeing about what calm looks like would be worse than either choice.
    private static func readingSegments(
        _ readings: [AccountUsage.Reading],
        joining: Bool
    ) -> [ThemedMenuSubtitleSegment] {
        var segments: [ThemedMenuSubtitleSegment] = []
        for (index, reading) in readings.enumerated() {
            if joining || index > 0 { segments.append(separator) }
            segments.append(ThemedMenuSubtitleSegment("\(reading.name) ", .muted))
            segments.append(ThemedMenuSubtitleSegment(reading.value, tone(for: reading.severity)))
        }
        return segments
    }

    private static func tone(for severity: UsageSeverity) -> ThemedMenuSubtitleSegment.Tone {
        switch severity {
        case .normal: return .standard
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    /// Warms every account of every agent, so a menu opened in a moment has numbers in it.
    ///
    /// Called when a surface that offers accounts appears rather than when its menu opens,
    /// because a fetch started as the menu opens is always too late for that menu.
    static func prefetch() {
        for kind in AgentKind.allCases where kind.supportsAccounts {
            for account in AgentAccountDiscovery.accounts(for: kind) {
                AccountUsageService.shared.refresh(account)
            }
        }
    }
}
