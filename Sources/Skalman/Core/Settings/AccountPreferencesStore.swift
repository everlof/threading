import Foundation

// MARK: - Account Preference

/// User customisation for a discovered agent account.
struct AccountPreference: Codable, Equatable {
    /// Emoji shown in place of the agent's symbol. Nil uses the symbol.
    var emoji: String?

    /// Name shown instead of the alias-derived one. Nil uses the discovered name.
    var displayNameOverride: String?

    var isEmpty: Bool {
        emoji == nil && displayNameOverride == nil
    }
}

// MARK: - Account Preferences Store

/// Persists per-account customisation.
///
/// Preferences are keyed by the account's stable identifier rather than its path, so they
/// survive a config directory being moved, and are kept separate from discovery so an
/// account that temporarily disappears does not lose its icon.
@MainActor
final class AccountPreferencesStore {

    // MARK: - Singleton

    static let shared = AccountPreferencesStore()

    // MARK: - Properties

    private let defaults: UserDefaults
    private var preferences: [String: AccountPreference]

    /// False only when a stored value could not be decoded *and* could not be kept aside. A
    /// write then has nowhere to put what it would destroy, so it does not happen.
    private var writesAllowed = true

    // MARK: - Initialization

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loaded = Self.load(from: defaults)
        self.preferences = loaded.preferences
        self.writesAllowed = loaded.writesAllowed
    }

    // MARK: - Public Methods

    func preference(for accountID: AccountID) -> AccountPreference {
        preferences[accountID.rawValue] ?? AccountPreference()
    }

    func emoji(for accountID: AccountID) -> String? {
        preferences[accountID.rawValue]?.emoji
    }

    func displayNameOverride(for accountID: AccountID) -> String? {
        preferences[accountID.rawValue]?.displayNameOverride
    }

    /// Sets the emoji for an account. Pass nil or blank to clear it.
    func setEmoji(_ emoji: String?, for accountID: AccountID) {
        update(accountID) { $0.emoji = normalized(emoji) }
    }

    /// Sets the display name for an account. Pass nil or blank to fall back to discovery.
    func setDisplayNameOverride(_ name: String?, for accountID: AccountID) {
        update(accountID) { $0.displayNameOverride = normalized(name) }
    }

    func clear(accountID: AccountID) {
        preferences[accountID.rawValue] = nil
        save()
    }

    // MARK: - Private Methods

    private func update(_ accountID: AccountID, _ mutate: (inout AccountPreference) -> Void) {
        var preference = preferences[accountID.rawValue] ?? AccountPreference()
        mutate(&preference)

        // Drop empty entries rather than persisting placeholders.
        preferences[accountID.rawValue] = preference.isEmpty ? nil : preference

        save()
    }

    /// Trims whitespace and treats an empty result as "not set".
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func save() {
        guard writesAllowed else {
            SkalmanLogger.session.error(
                "Refusing to save account preferences: the unreadable previous value is still there"
            )
            return
        }

        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: Keys.accountPreferences)
            NotificationCenter.default.post(AccountPreferencesDidChange())
        } catch {
            // An encode that fails leaves the stored value alone, which is the right outcome —
            // but silently returning made an edit that never landed look exactly like one that
            // did, so the emoji reverted on the next launch with nothing to explain it.
            SkalmanLogger.session.error(
                "Could not save account preferences: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Missing and unreadable are different answers.
    ///
    /// Both used to return an empty dictionary, and the next customisation then wrote *that*
    /// over the stored blob — so a user whose preferences failed to decode lost every account
    /// emoji and name they had set, permanently, the first time they changed one. The unreadable
    /// case is now kept aside and only then overwritten; see `DefaultsQuarantine`.
    private static func load(
        from defaults: UserDefaults
    ) -> (preferences: [String: AccountPreference], writesAllowed: Bool) {
        guard let data = defaults.data(forKey: Keys.accountPreferences) else {
            return ([:], true)
        }

        guard let decoded = try? JSONDecoder().decode(
            [String: AccountPreference].self,
            from: data
        ) else {
            let quarantined = DefaultsQuarantine.quarantine(
                data,
                forKey: Keys.accountPreferences,
                in: defaults
            )
            return ([:], quarantined)
        }

        return (decoded, true)
    }

    // MARK: - Keys

    private enum Keys {
        static let accountPreferences = "accountPreferences"
    }
}
