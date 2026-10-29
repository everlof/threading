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

    typealias Decorator = @MainActor (inout ThemedMenuItem, AgentAccount, String?, AgentKind?) -> Void

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
    /// established — the composer's identity menu offers every runtime's logins in one list. It
    /// spends the row's one image slot on the brand mark rather than on `UsageRingImage`, so two
    /// logins the same person named the same thing on two runtimes are told apart at a glance.
    /// Left nil where the runtime is a foregone conclusion, and the ring stays.
    ///
    /// **The reading is two meter lines, not a sentence.** It used to be one toned line —
    /// `Claude Code · Max · 5h 27% · 7d 81% · 7d resets in 19h 36m` — and for one row it read
    /// fine. The menu's job is comparing several, and in a sentence a value's position is set by
    /// the length of the name in front of it: three logins put their three 5-hour numbers at three
    /// different x positions, so the comparison the menu exists for became a search.
    ///
    /// Side-by-side columns fixed the sentence and broke on width: two bars, two values, a rule
    /// and a countdown did not fit beside a name under the panel's cap, so the `7d` column fell
    /// into the subtitle — one window read beside the name, the other under it, in different
    /// places on different menus. So each window is a `ThemedMenuMetric` on a *line* of its own:
    /// `5h` on the title's line, `7d` directly under it, on every row. Stacked, the block is one
    /// meter wide instead of two, and the room that frees goes into what a glance needs: a longer
    /// bar, the clock's tick across it — fill short of the tick is spending slower than time,
    /// fill past it faster — and the window's own countdown at the end of its line, so each
    /// reset sits beside the window it belongs to and needs no name of its own.
    ///
    /// The plan stays on the title's line; the subtitle keeps the one thing a shared line cannot
    /// hold — a scoped model window, which most logins do not have — and, when such a window is
    /// what binds the model this session would run, when it comes back. The runtime is not
    /// written at all: the composer files these rows under a section head per runtime.
    static func decorate(
        _ item: inout ThemedMenuItem,
        for account: AgentAccount,
        metering model: String? = nil,
        markedAs agent: AgentKind? = nil
    ) {
        AccountUsageService.shared.refresh(account)

        let usage = AccountUsageService.shared.usage(for: account)

        // The meter lines carry usage; the icon consistently carries account identity.
        item.image = AccountBadge.mark(for: account, surface: .chooser)

        guard let usage else { return }
        apply(
            usage,
            to: &item,
            metering: model,
            limits: CustomLimitSettings.shared.rules(for: account.id)
        )
    }

    /// The reading half of `decorate`, with the account lookup taken out.
    ///
    /// Split so the row a menu will show can be built from a `AccountUsage` value — by a test
    /// asserting the grammar, and by the render fixture drawing it — rather than each of them
    /// re-deriving what the composer assembles and drifting the first time this changes.
    static func apply(
        _ usage: AccountUsage,
        to item: inout ThemedMenuItem,
        metering model: String? = nil,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) {
        item.titleDetail = usage.planLabel?.isEmpty == false ? usage.planLabel : nil
        item.metrics = identityMetrics(for: usage, at: now, limits: limits)

        var scoped = scopedSegments(for: usage, metering: model, at: now, limits: limits)
        appendOmittedWindows(
            max(0, usage.windows.count - UsageReadingLabel.maximumReadings),
            to: &scoped
        )
        if !scoped.isEmpty { item.setSubtitle(scoped) }
    }

    /// The account's own windows as meter lines — `5h`, `7d` — in the order the provider reports
    /// them, which is the order every row's lines are then stacked in.
    ///
    /// Account windows only. A scoped model window's name is its length *and* its model
    /// (`7d Fable`), so giving each one a line would reserve a permanently empty meter on every
    /// login that does not meter that model — and most do not. Those go on the row's own
    /// subtitle instead, where they cost nothing to the rows without them.
    ///
    /// Each line carries the window's clock twice, at two resolutions: the tick on the bar is
    /// how far through the window we are, the countdown after the value is how long until it
    /// resets. A window whose reset has passed carries neither — its number is gone, and so is
    /// any position in a window that has already ended. The countdown takes the critical ink
    /// when its window does: on a spent window, when it comes back is the one number that matters.
    ///
    /// A user-authored limit moves the **tone** of a line and nothing else about it. The label
    /// is the window, the value is the provider's own percentage and the bar is that percentage's
    /// length — a line that shortened or renumbered itself under a rule would be answering a
    /// different question from the one the other logins' lines answer, on the one surface where
    /// two logins are read side by side.
    ///
    /// This is where a fenced-off login has to read as pressured, because it is the moment an
    /// account is being *chosen*: a shared login at 47% of a 50% share is nearly spent, and a
    /// menu that drew it in the same quiet ink as a free login at 47% would be handing the user
    /// the wrong one.
    static func identityMetrics(
        for usage: AccountUsage,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) -> [ThemedMenuMetric] {
        let windows = Array(usage.windows.prefix(UsageReadingLabel.maximumReadings))
        let readings = CustomLimitBounds.retinted(
            usage.readings(of: windows, at: now),
            of: windows,
            in: limits
        )
        return zip(windows, readings).map { window, reading in
            let live = !window.isExpired(at: now)
            let resetsAt = live ? window.resetsAt : nil
            let lineTone = tone(for: reading.severity)
            return ThemedMenuMetric(
                label: reading.name,
                value: reading.value,
                fraction: reading.fraction,
                tone: lineTone,
                timeMark: live ? window.elapsedFraction(at: now) : nil,
                detail: resetsAt.map { UsageFormat.remaining(until: $0, from: now) },
                spokenDetail: resetsAt.map { UsageFormat.resets(until: $0, from: now) },
                detailTone: lineTone == .critical ? .critical : .muted
            )
        }
    }

    /// The windows a shared line cannot hold: the ones scoped to a single model.
    ///
    /// Empty for most logins, which is the point — a row only writes into its subtitle when it
    /// has something the meters could not say. When one of these is what binds a session on
    /// `model`, its reset follows it here: the meter lines carry only their own windows'
    /// countdowns, and the one that would stop this session must not be the one left unsaid.
    static func scopedSegments(
        for usage: AccountUsage,
        metering model: String? = nil,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) -> [ThemedMenuSubtitleSegment] {
        let windows = Array(usage.modelWindows.prefix(UsageReadingLabel.maximumReadings))
        var segments = readingSegments(
            CustomLimitBounds.retinted(
                usage.readings(of: windows, at: now),
                of: windows,
                in: limits
            ),
            joining: false
        )
        appendOmittedWindows(usage.modelWindows.count - windows.count, to: &segments)

        if let binding = usage.bindingWindow(at: now, metering: model),
           binding.scopeName != nil,
           windows.contains(where: { $0.id == binding.id }),
           let resetsAt = binding.resetsAt {
            let countdown = UsageFormat.resets(until: resetsAt, from: now)
            segments.append(separator)
            segments.append(ThemedMenuSubtitleSegment(
                windows.count > 1 ? "\(binding.compactName) \(countdown)" : countdown,
                .muted
            ))
        }
        return segments
    }

    /// The whole identity row as one plain line — what a tooltip and VoiceOver get, and what a
    /// test asserts the grammar against.
    ///
    /// This is `ThemedMenuItem.spokenSummary` over a row `apply` has filled in, rather than a
    /// second assembly of the same facts: a summary derived independently of the row is exactly
    /// how a tooltip ends up saying something the pixels do not.
    static func summary(
        for usage: AccountUsage,
        metering model: String?,
        at now: Date = Date()
    ) -> String {
        var item = ThemedMenuItem(title: "")
        apply(usage, to: &item, metering: model, at: now)
        return item.spokenSummary
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

    /// Puts on a *model* row only what meters that model beyond the account, in the menu where
    /// the model is chosen.
    ///
    /// The other half of the same decision. The account menu says which logins have a
    /// separately metered model under pressure; this says which model that is, at the moment
    /// that choice is made — and it is the only surface where the answer is actionable, since
    /// switching model is the cheap way out of a spent scoped window.
    ///
    /// The account's own windows are *not* repeated here: they are identical on every row by
    /// construction — same login, same two windows — and they belong to the menu's header
    /// (`modelMenuHeader`), stated once. Repeating them per row was tried first, on the theory
    /// that a bare row beside a decorated one reads as a failed lookup; what it actually
    /// produced, on the common account with no scoped window at all, was five copies of one
    /// sentence — which reads as a rendering bug, not as five models. The header is what lets a
    /// bare row mean what it says: nothing beyond the line above.
    ///
    /// Every row keeps its **ring**, whatever its text: it gauges the binding window per model,
    /// so the one row whose scoped window is nearly spent sits visibly fuller than its
    /// neighbours — the glance that makes the rows comparable without reading any of them.
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

        // The same ring the account rows draw, gauging the same thing: the window a session
        // started here runs out of first. Rings that meant different things on two menus a click
        // apart would be worse than no ring at all. One `now` for both, so a row cannot state a
        // window the ring has already decided is expired.
        item.image = UsageRingImage.make(for: usage, at: now, metering: model)

        let segments = modelSummarySegments(
            for: usage,
            running: model,
            at: now,
            limits: CustomLimitSettings.shared.rules(for: account.id)
        )
        guard !segments.isEmpty else { return }
        item.setSubtitle(segments)
    }

    /// The line a model menu states once, above the rows: whose numbers these are, and the
    /// windows every row shares. Title is the login's own name — the account was chosen on
    /// another surface, and a menu of five readings had better say whose they are — and the
    /// subtitle is the account's windows with the binding reset, the denominators the scoped
    /// row lines are read against.
    ///
    /// Disabled rather than choosable, the same idiom as every other informational menu row:
    /// it states context, and a press on it should do nothing.
    ///
    /// Nil when the account has no reading, which is the same silence the rows keep — a header
    /// with nothing to say would demote the menu's first row to furniture for no reason.
    static func modelMenuHeader(
        for account: AgentAccount,
        at now: Date = Date()
    ) -> ThemedMenuItem? {
        guard let usage = AccountUsageService.shared.usage(for: account) else { return nil }
        let segments = modelMenuHeaderSegments(
            for: usage,
            at: now,
            limits: CustomLimitSettings.shared.rules(for: account.id)
        )
        guard !segments.isEmpty else { return nil }

        var item = ThemedMenuItem(title: account.presentation(in: .usage).visibleName, isEnabled: false)
        item.setSubtitle(segments)
        return item
    }

    /// `Max · 5h 41% · 7d 77% · 7d resets in 22h 10m` — the plan and the account's own windows,
    /// deliberately without the scoped ones: those belong to the rows that answer for their
    /// models, and a header restating them would put the same number on screen twice in one
    /// menu.
    static func modelMenuHeaderSegments(
        for usage: AccountUsage,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) -> [ThemedMenuSubtitleSegment] {
        var segments: [ThemedMenuSubtitleSegment] = []

        if let plan = usage.planLabel, !plan.isEmpty {
            segments.append(ThemedMenuSubtitleSegment(plan))
        }
        let windows = Array(usage.windows.prefix(UsageReadingLabel.maximumReadings))
        segments += readingSegments(
            CustomLimitBounds.retinted(
                usage.readings(of: windows, at: now),
                of: windows,
                in: limits
            ),
            joining: !segments.isEmpty
        )
        appendOmittedWindows(usage.windows.count - windows.count, to: &segments)
        if let reset = resetLine(for: usage, metering: nil, at: now) {
            if !segments.isEmpty { segments.append(separator) }
            segments.append(ThemedMenuSubtitleSegment(reset, .muted))
        }

        return segments
    }

    /// `7d Fable 89% · resets in 15h` — the windows scoped to `model`, and when the binding one
    /// comes back. Empty for a model the plan meters no differently, which is most rows: the
    /// account's windows live in the header, so an empty line here *means* "nothing beyond the
    /// line above" rather than standing in for missing data.
    ///
    /// Nil only when there is nothing scoped to say, mirroring the segments.
    static func modelSummary(
        for usage: AccountUsage,
        running model: String?,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) -> String? {
        let segments = modelSummarySegments(
            for: usage,
            running: model,
            at: now,
            limits: limits
        )
        guard !segments.isEmpty else { return nil }
        return segments.map(\.text).joined()
    }

    /// The model line as toned runs — the shared reading grammar over only the scoped windows
    /// metering `model` (`ScopedWindows.metering` narrowed further: another model's window is
    /// not this row's business, and the account's are the header's).
    ///
    /// The countdown appears only when a window *of this row's own* is what binds a session on
    /// `model` — the account windows' reset already trails the header. It names its window when
    /// the row states more than one, and stays bare beside a single reading: `7d Fable 89% ·
    /// 7d Fable resets in 15h` repeats a name three inches from itself, and the rule that a
    /// countdown must say which window it belongs to is about lists where that is ambiguous.
    static func modelSummarySegments(
        for usage: AccountUsage,
        running model: String?,
        at now: Date = Date(),
        limits: [CustomLimit] = []
    ) -> [ThemedMenuSubtitleSegment] {
        let scoped = usage.scopedWindows(metering: model)
        guard !scoped.isEmpty else { return [] }
        let visible = Array(scoped.prefix(UsageReadingLabel.maximumReadings))

        // The model menu is the one surface where a *scoped* limit is actionable — a spent Fable
        // window is escaped by picking something else — so it is also where a line drawn on one
        // has to be visible.
        var segments = readingSegments(
            CustomLimitBounds.retinted(
                usage.readings(of: visible, at: now),
                of: visible,
                in: limits
            ),
            joining: false
        )
        appendOmittedWindows(scoped.count - visible.count, to: &segments)

        if let binding = usage.bindingWindow(at: now, metering: model),
           binding.scopeName != nil,
           let resetsAt = binding.resetsAt {
            let countdown = UsageFormat.resets(until: resetsAt, from: now)
            segments.append(separator)
            segments.append(ThemedMenuSubtitleSegment(
                scoped.count > 1 ? "\(binding.compactName) \(countdown)" : countdown,
                .muted
            ))
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

    /// Compact menu rows keep a constant amount of attributed and meter state. The virtual
    /// account popover owns the complete inventory; the row states when that inventory was cut
    /// instead of silently pretending its first few windows are all the provider reported.
    private static func appendOmittedWindows(
        _ count: Int,
        to segments: inout [ThemedMenuSubtitleSegment]
    ) {
        guard count > 0 else { return }
        if !segments.isEmpty { segments.append(separator) }
        segments.append(ThemedMenuSubtitleSegment(
            L10n.format("%d more windows", count),
            .muted
        ))
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
