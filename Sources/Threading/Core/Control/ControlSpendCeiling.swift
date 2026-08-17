import Foundation

/// Live admission for the optional ceiling carried by a manager grant.
///
/// Unknown stays unknown and therefore refuses new spend. A ceiling is an upper bound the user
/// explicitly placed on delegated work; treating an unreadable meter as headroom would turn a
/// missing credential or stale provider response into permission.
@MainActor
enum ControlSpendCeiling {
    static func currentRefusal(ceiling: SpendCeiling, session: AgentSession) -> String? {
        let account: AgentAccount?
        if let accountID = ceiling.accountID {
            account = AgentAccountDiscovery.allAccounts(for: accountID.provider)
                .first { $0.id == accountID }
        } else {
            account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
        }
        guard let account else {
            return "The grant's account is unavailable, so its spend ceiling cannot be checked."
        }
        guard let usage = AccountUsageService.shared.reading(for: account).usage else {
            return "Usage for \(account.displayName) is unknown, so the manager's spend ceiling cannot be checked."
        }

        let windows: [AccountUsage.Window]
        if let identifier = ceiling.windowIdentifier {
            windows = usage.allWindows.filter { $0.id == identifier }
        } else {
            windows = usage.windows(metering: session.model)
        }
        guard !windows.isEmpty,
              windows.allSatisfy({ !$0.isExpired() && $0.fraction != nil }) else {
            return "The metering window for \(account.displayName) is unknown, so the manager's spend ceiling cannot be checked."
        }
        guard let reached = windows.first(where: {
            ($0.fraction ?? 1) >= ceiling.maximumFraction
        }) else { return nil }
        let percent = Int((ceiling.maximumFraction * 100).rounded())
        return "\(reached.compactName) has reached the manager grant's \(percent)% spend ceiling."
    }
}
