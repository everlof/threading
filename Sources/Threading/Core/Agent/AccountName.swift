import Foundation

/// The name to show for an agent login where the *person* is what matters.
///
/// An account's `displayName` is the user's own shell alias — `claudenh`, `claudeik` — which is
/// how they invoke it and a fine name for a session. It is a poor name for *choosing between
/// logins*, where the question is whose account this is, and aliases are named after the agent
/// rather than the person: `claude-nhartley` and `claude-ikeller` differ by four characters in
/// the middle of a word.
///
/// So this derives a name from the login email the CLIs already record. The alias stays where
/// it is useful; nothing here renames a session.
enum AccountName {

    /// Splits a local part on the separators people actually use.
    private static let separators = CharacterSet(charactersIn: "._-+")

    /// `nova.hartley3@example.com` → `Nova Hartley`.
    ///
    /// Trailing digits are dropped from each word, since they are almost always disambiguation
    /// for a taken address rather than part of a name. Nil when nothing readable comes out,
    /// which the caller answers with the alias.
    static func derived(fromEmail email: String) -> String? {
        // `prefix(while:)`, not `split(separator: "@")` — split omits empty subsequences, so an
        // address with no local part hands back the *domain* and "@x.io" gets named "Io".
        let local = String(email.prefix { $0 != "@" })

        let words = local
            .components(separatedBy: separators)
            .map { $0.drop(while: \.isNumber).reversed().drop(while: \.isNumber).reversed() }
            .map(String.init)
            .filter { $0.count > 1 }

        guard !words.isEmpty else { return nil }

        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Names for a set of accounts, resolved together.
    ///
    /// Together, because the failure this prevents is only visible across the list: two logins
    /// belonging to the same person derive the same name, and a menu offering "Nova Hartley"
    /// twice is worse than one offering two aliases. A collision falls back to the address,
    /// which is the one thing guaranteed to differ.
    @MainActor
    static func names(for accounts: [AgentAccount]) -> [AccountID: String] {
        var emails: [AccountID: String] = [:]
        var derivedNames: [AccountID: String] = [:]
        var explicitNames: [AccountID: String] = [:]

        for account in accounts {
            if let displayNameOverride = account.displayNameOverride {
                explicitNames[account.id] = displayNameOverride
                continue
            }

            // What the CLI wrote down, else what it told us when asked. The default Claude
            // login is the second case: it records only a hashed id on disk.
            guard let email = AccountAvatarStore.cachedEmail(for: account)
                ?? AccountEmailProbe.cachedEmail(for: account) else { continue }
            emails[account.id] = email
            if let name = derived(fromEmail: email) {
                derivedNames[account.id] = name
            }
        }

        var counts: [String: Int] = [:]
        for name in derivedNames.values { counts[name, default: 0] += 1 }
        // A derived answer that collides with an explicit one falls back to the address. The
        // explicit name still wins unchanged: it is the answer the user deliberately chose.
        for name in explicitNames.values { counts[name, default: 0] += 1 }

        var resolved: [AccountID: String] = [:]
        for account in accounts {
            if let explicitName = explicitNames[account.id] {
                resolved[account.id] = explicitName
            } else if let name = derivedNames[account.id], counts[name] == 1 {
                resolved[account.id] = name
            } else if let email = emails[account.id] {
                resolved[account.id] = email
            } else {
                // No address recorded: the alias is all anyone has, and it is at least the name
                // the user types.
                resolved[account.id] = account.displayName
            }
        }

        return resolved
    }

    /// One account's name, resolved against its siblings so collisions are still caught.
    @MainActor
    static func display(for account: AgentAccount) -> String {
        // Every login, switched off or not: a name is resolved against its collisions, and a
        // disabled sibling still owns the address that would make this one ambiguous.
        if account.presentationNameIsResolved { return account.displayName }
        let siblings = AgentAccountDiscovery.allAccounts(for: account.provider)
        return names(for: siblings)[account.id] ?? account.displayName
    }
}
