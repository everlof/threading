import Foundation

/// The numbers behind a project's ordered logins.
enum ProjectAccountDefaults {

    /// Where a listed login counts as out of usage, as a share of its effective bound.
    ///
    /// The same point at which the toolbar turns critical, rather than the provider's 100%:
    /// starting a chat on a login at 97% buys one turn, and the chat then has to be moved.
    static let spentFraction = UsageDefaults.criticalFraction

    /// A list may name at most as many logins as discovery admits.
    static let maximumEntries = 32
}

enum ProjectAccountList {
    /// The stored form of a list: de-duplicated in order, capped, and nil rather than empty.
    static func normalized(_ accounts: [AccountID]?) -> [AccountID]? {
        guard let accounts else { return nil }
        var seen = Set<AccountID>()
        var result: [AccountID] = []
        for account in accounts where seen.insert(account).inserted {
            result.append(account)
            if result.count == ProjectAccountDefaults.maximumEntries { break }
        }
        return result.isEmpty ? nil : result
    }
}
