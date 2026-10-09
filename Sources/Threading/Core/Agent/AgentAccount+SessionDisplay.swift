import Foundation

// MARK: - Session Account Display

extension AgentSession {

    /// The account name for this session's tooltip, if one is worth showing.
    ///
    /// Only alternate accounts are labelled: the default account needs no badge, and a
    /// session already titled after its account would only repeat itself.
    @MainActor
    var accountLineText: String? {
        guard let account = AgentAccountDiscovery.account(for: kind, handle: accountHandle),
              !account.presentation(in: .sidebar).visibleName.isEmpty,
              !displayTitle.localizedCaseInsensitiveContains(account.presentation(in: .sidebar).visibleName)
        else { return nil }

        return account.presentation(in: .sidebar).visibleName
    }
}
