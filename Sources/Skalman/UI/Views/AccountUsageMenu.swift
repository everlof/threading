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

    /// Puts `account`'s cached reading on `item`, and asks for a fresh one.
    ///
    /// Cached only: a menu is built synchronously and a fetch is a network round trip, so the
    /// alternative to showing what is known is showing nothing while the menu is open. The
    /// refresh it kicks off is throttled by `AccountUsageService` and lands for the next open
    /// — which `prefetch` exists to make the common case.
    static func decorate(_ item: NSMenuItem, for account: AgentAccount) {
        AccountUsageService.shared.refresh(account)

        guard let usage = AccountUsageService.shared.usage(for: account) else { return }

        // The ring first, because it is what makes three accounts comparable without reading
        // twelve numbers. The text stays: it is the precise answer, and the ring is the glance.
        if let ring = UsageRingImage.make(for: usage) {
            item.image = ring
        }

        guard let summary = usage.compactSummary() else { return }

        // An account with no usage source says nothing rather than "—": see the toolbar
        // pill, which hides for the same accounts for the same reason.
        // A second line where the system draws one (14.4 brought `subtitle`), and the same
        // reading appended to the name where it does not.
        if #available(macOS 14.4, *) {
            item.subtitle = summary
        } else {
            item.title = "\(item.title)\(AccountUsageMenuDefaults.inlineSeparator)\(summary)"
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

// MARK: - Account Usage Menu Defaults

enum AccountUsageMenuDefaults {
    /// Joins the name and the reading on the versions with no menu-item subtitle (< 14.4).
    static let inlineSeparator = " — "
}
