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
    static func decorate(_ item: inout ThemedMenuItem, for account: AgentAccount) {
        AccountUsageService.shared.refresh(account)

        guard let usage = AccountUsageService.shared.usage(for: account) else { return }

        // The ring first, because it is what makes three accounts comparable without reading
        // twelve numbers. The text stays: it is the precise answer, and the ring is the glance.
        if let ring = UsageRingImage.make(for: usage) {
            item.image = ring
        }

        guard let summary = usage.compactSummary() else { return }
        // `ThemedMenuPresenter` draws subtitles consistently on every supported macOS version.
        // This helper describes the content without reaching into menu presentation.
        item.subtitle = summary
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
