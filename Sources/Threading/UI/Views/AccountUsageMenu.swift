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
        if let binding = usage.bindingWindow(at: now, metering: model),
           let resetsAt = binding.resetsAt {
            parts.append("\(binding.id) \(UsageFormat.resets(until: resetsAt, from: now))")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: UsageDefaults.segmentSeparator)
    }

    // MARK: - Model Rows

    /// Puts the window metering `model` on a *model* row, in the menu where the model is chosen.
    ///
    /// The other half of the same decision. The account menu says which logins have a
    /// separately metered model under pressure; this says which model that is, at the moment
    /// that choice is made — and it is the only surface where the answer is actionable, since
    /// switching model is the cheap way out of a spent scoped window.
    ///
    /// Silent on models the plan does not meter separately: their pressure is the account's,
    /// which every row would then repeat identically and none would distinguish.
    ///
    /// No refresh from here, unlike the account rows. The composer prefetches when it appears
    /// and the account menu asks again on every open, so this list is already warm — and a
    /// model list is not a new reason to spend a network round trip per row.
    static func decorate(
        _ item: inout ThemedMenuItem,
        forModel model: String,
        on account: AgentAccount
    ) {
        guard let usage = AccountUsageService.shared.usage(for: account),
              let summary = modelSummary(for: usage, running: model, at: Date())
        else { return }

        if let window = usage.tightestScopedWindow(metering: model), let fraction = window.fraction {
            item.image = UsageRingImage.make(
                fraction: fraction,
                tint: UsageSeverity.from(fraction: fraction).glyphColor
            )
        }
        item.subtitle = summary
    }

    /// `7d 89% · resets in 1h 1m` — the scoped windows metering `model`, and when the tight one
    /// comes back. Nil when the plan meters this model no differently from anything else.
    ///
    /// Each window is named by its *length* rather than by the model, which the row it sits
    /// under already says; and the countdown needs no attribution here for the same reason.
    static func modelSummary(
        for usage: AccountUsage,
        running model: String,
        at now: Date = Date()
    ) -> String? {
        let scoped = usage.scopedWindows(metering: model)
        guard !scoped.isEmpty else { return nil }

        var parts = scoped.map { window in
            let name = UsageDefaults.windowID(forDuration: window.windowDuration) ?? window.id
            return "\(name) \(AccountUsage.value(of: window, at: now))"
        }

        if let tightest = usage.tightestScopedWindow(at: now, metering: model),
           let resetsAt = tightest.resetsAt {
            parts.append(UsageFormat.resets(until: resetsAt, from: now))
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
