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
final class AccountPreferencesStore {

    // MARK: - Singleton

    static let shared = AccountPreferencesStore()

    // MARK: - Properties

    private let defaults: UserDefaults
    private var preferences: [String: AccountPreference]

    // MARK: - Initialization

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults)
    }

    // MARK: - Public Methods

    func preference(for accountID: String) -> AccountPreference {
        preferences[accountID] ?? AccountPreference()
    }

    func emoji(for accountID: String) -> String? {
        preferences[accountID]?.emoji
    }

    func displayNameOverride(for accountID: String) -> String? {
        preferences[accountID]?.displayNameOverride
    }

    /// Sets the emoji for an account. Pass nil or blank to clear it.
    func setEmoji(_ emoji: String?, for accountID: String) {
        update(accountID) { $0.emoji = normalized(emoji) }
    }

    /// Sets the display name for an account. Pass nil or blank to fall back to discovery.
    func setDisplayNameOverride(_ name: String?, for accountID: String) {
        update(accountID) { $0.displayNameOverride = normalized(name) }
    }

    func clear(accountID: String) {
        preferences[accountID] = nil
        save()
    }

    // MARK: - Private Methods

    private func update(_ accountID: String, _ mutate: (inout AccountPreference) -> Void) {
        var preference = preferences[accountID] ?? AccountPreference()
        mutate(&preference)

        // Drop empty entries rather than persisting placeholders.
        preferences[accountID] = preference.isEmpty ? nil : preference

        save()
    }

    /// Trims whitespace and treats an empty result as "not set".
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Keys.accountPreferences)
        NotificationCenter.default.post(name: .accountPreferencesDidChange, object: self)
    }

    private static func load(from defaults: UserDefaults) -> [String: AccountPreference] {
        guard let data = defaults.data(forKey: Keys.accountPreferences),
              let decoded = try? JSONDecoder().decode([String: AccountPreference].self, from: data)
        else { return [:] }

        return decoded
    }

    // MARK: - Keys

    private enum Keys {
        static let accountPreferences = "accountPreferences"
    }
}
