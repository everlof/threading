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
    /// The **ring** is metered by that model and the **text** is not, which is the split the
    /// surface asks for rather than an inconsistency. The account is picked before the model, so
    /// the text lists every scoped window the login has — including the ones a model chosen next
    /// would run into. The ring answers the narrower question it has always answered, what stops
    /// the session that would start now, and a model this session is not running must not tint it.
    static func decorate(
        _ item: inout ThemedMenuItem,
        for account: AgentAccount,
        metering model: String? = nil
    ) {
        AccountUsageService.shared.refresh(account)

        guard let usage = AccountUsageService.shared.usage(for: account) else { return }

        // The ring first, because it is what makes three accounts comparable without reading
        // twelve numbers. The text stays: it is the precise answer, and the ring is the glance.
        if let ring = UsageRingImage.make(for: usage, metering: model) {
            item.image = ring
        }

        guard let summary = summary(for: usage, metering: model, at: Date()) else { return }
        // `ThemedMenuPresenter` draws subtitles consistently on every supported macOS version.
        // This helper describes the content without reaching into menu presentation.
        item.subtitle = summary
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
        var parts: [String] = []

        if let plan = usage.planLabel, !plan.isEmpty {
            parts.append(plan)
        }
        if let windows = usage.compactSummary(at: now, metering: model, scoped: .all) {
            parts.append(windows)
        }
        if let reset = resetLine(for: usage, metering: model, at: now) {
            parts.append(reset)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: UsageDefaults.segmentSeparator)
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
        guard let usage = AccountUsageService.shared.usage(for: account),
              let summary = modelSummary(for: usage, running: model, at: now)
        else { return }

        // The same ring the account rows draw, gauging the same thing: the window a session
        // started here runs out of first. Rings that meant different things on two menus a click
        // apart would be worse than no ring at all. One `now` for both, so a row cannot state a
        // window the ring has already decided is expired.
        item.image = UsageRingImage.make(for: usage, at: now, metering: model)
        item.subtitle = summary
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
        guard let windows = usage.compactSummary(at: now, metering: model) else { return nil }

        var parts = [windows]
        if let reset = resetLine(for: usage, metering: model, at: now) {
            parts.append(reset)
        }
        return parts.joined(separator: UsageDefaults.segmentSeparator)
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
