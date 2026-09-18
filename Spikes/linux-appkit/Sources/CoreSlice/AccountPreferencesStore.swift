import Foundation
import ThreadingDomain

// MARK: - New-Session Run Choice

/// The model-specific part of the last new session this login started successfully.
///
/// Provider and login are the `AccountID` key around this value. Keeping the choice there avoids
/// carrying a model between two accounts whose catalogues only happen to share a provider. Nil
/// values retain the runtime's automatic/default semantics rather than pinning today's resolved
/// defaults.
struct NewSessionRunChoice: Codable, Equatable, Sendable {
    let model: String?
    let reasoningEffort: String?
}

// MARK: - Account Preference

/// User customisation for a discovered agent account.
struct AccountPreference: Codable, Equatable {
    /// Emoji shown in place of the agent's symbol. Nil uses the symbol.
    var emoji: String?

    var appearance: AccountAppearancePreferences?

    /// Name shown instead of the alias-derived one. Nil uses the discovered name.
    var displayNameOverride: String?

    /// Set when the user has switched this login off, which withdraws it from everywhere an
    /// account is *offered* without touching the config directory it was discovered from.
    ///
    /// Written as "disabled" rather than "enabled" so its absence — every preference stored
    /// before the switch existed, and every account nobody has touched — reads as on.
    var isDisabled: Bool?

    /// The model this account's runtime last announced for a session that pinned none.
    ///
    /// Observed, not chosen: it is what the CLI resolved "no `--model`" to the last time this
    /// login ran, which is the only local answer for an account whose config names no model and
    /// whose organisation names none either. Recorded only from unpinned sessions — a session
    /// running the user's explicit pick says nothing about what the default would have been.
    var lastReportedModel: String?

    /// What the user last launched explicitly from the new-session composer on this login.
    /// This is configuration, unlike `lastReportedModel`, which is runtime evidence.
    var newSessionRunChoice: NewSessionRunChoice?

    /// The user's own limits on this account — the lines their quota is measured against, ahead
    /// of the provider's.
    ///
    /// **Absent means inherit**, which is why this is optional rather than an empty array: the
    /// app-wide defaults in `CustomLimitSettings` apply until an account answers for itself, and
    /// an empty array is the distinct, deliberate answer "this account has no limits, whatever
    /// the app-wide default says". A plain `[CustomLimit]` could not express the second, and the
    /// account whose owner cleared its rules would silently pick the app default back up.
    var customLimits: [CustomLimit]?

    /// Catalogue models the owner withdrew from new-session pickers for this login.
    ///
    /// Optional for backwards compatibility and storage hygiene: an account nobody has
    /// customised carries no key, while an explicitly restored account collapses back to the
    /// same empty preference. The account qualifier matters because providers may reuse model
    /// identifiers and two logins can receive different catalogues.
    var hiddenModelIDs: Set<String>?

    var isEmpty: Bool {
        emoji == nil
            && appearance == nil
            && displayNameOverride == nil
            && isDisabled == nil
            && lastReportedModel == nil
            && newSessionRunChoice == nil
            && customLimits == nil
            && hiddenModelIDs == nil
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

    private var preferences: [String: AccountPreference]
    private let persistence: RecoverableDefaultsStore<[String: AccountPreference]>

    // MARK: - Initialization

    /// Not private so a test can stand one up over its own suite: the app uses `shared`, and
    /// the alternative is a test that writes account state into the user's real defaults.
    ///
    /// The default is `PreferenceStore.shared` rather than `.standard` because everything in this
    /// blob is a **choice** — an icon, a name, a login switched off, and now the lines a user drew
    /// on their own quota. The tests are hosted in the app, so `.standard` here was the
    /// developer's own account preferences; a suite that adds a limit rule must not be able to
    /// leave one standing on the login they are actually working with.
    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.persistence = RecoverableDefaultsStore(
            defaults: defaults,
            key: Keys.accountPreferences,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.preferences = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Public Methods

    func preference(for accountID: AccountID) -> AccountPreference {
        preferences[accountID.rawValue] ?? AccountPreference()
    }

    var defaultAppearance: AccountAppearancePreferences {
        preferences[Keys.appearanceDefaults]?.appearance ?? AccountAppearancePreferences()
    }

    func appearance(for accountID: AccountID) -> AccountAppearancePreferences {
        preferences[accountID.rawValue]?.appearance ?? AccountAppearancePreferences()
    }

    func setAppearance(_ value: AccountAppearancePreferences, for accountID: AccountID?) {
        var normalizedValue = value
        normalizedValue.shortName = normalized(value.shortName).map { String($0.prefix(80)) }
        normalizedValue.shared = value.shared?.normalized()
        normalizedValue.surfaces = value.surfaces.map { surfaces in
            Dictionary(uniqueKeysWithValues: AccountAppearanceSurface.allCases.compactMap { surface in
                surfaces[surface.rawValue].map { (surface.rawValue, $0.normalized()) }
            })
        }
        let key = accountID?.rawValue ?? Keys.appearanceDefaults
        var candidate = preferences
        var preference = candidate[key] ?? AccountPreference()
        preference.appearance = normalizedValue == AccountAppearancePreferences() ? nil : normalizedValue
        candidate[key] = preference.isEmpty ? nil : preference
        guard candidate != preferences, persistence.save(candidate) else { return }
        preferences = candidate
        NotificationCenter.default.post(AccountPreferencesDidChange())
    }

    func emoji(for accountID: AccountID) -> String? {
        preferences[accountID.rawValue]?.emoji
    }

    func displayNameOverride(for accountID: AccountID) -> String? {
        preferences[accountID.rawValue]?.displayNameOverride
    }

    /// Whether the account is offered for new work. An account nobody has switched off is on.
    func isEnabled(_ accountID: AccountID) -> Bool {
        preferences[accountID.rawValue]?.isDisabled != true
    }

    /// Switches an account on or off. Enabling clears the flag rather than storing `false`, so
    /// an untouched account and a re-enabled one are the same stored value.
    func setEnabled(_ isEnabled: Bool, for accountID: AccountID) {
        update(accountID) { $0.isDisabled = isEnabled ? nil : true }
    }

    /// Sets the emoji for an account. Pass nil or blank to clear it.
    func setEmoji(_ emoji: String?, for accountID: AccountID) {
        update(accountID) { $0.emoji = normalized(emoji) }
    }

    /// Sets the display name for an account. Pass nil or blank to fall back to discovery.
    func setDisplayNameOverride(_ name: String?, for accountID: AccountID) {
        update(accountID) { $0.displayNameOverride = normalized(name) }
    }

    /// The model this account's runtime last resolved "no model chosen" to, if it ever has.
    func lastReportedModel(for accountID: AccountID) -> String? {
        preferences[accountID.rawValue]?.lastReportedModel
    }

    /// Records what an account's runtime reported. Writes only on a change, because this is
    /// called on every session start and each write persists and posts a change notification.
    func setLastReportedModel(_ model: String?, for accountID: AccountID) {
        let normalisedModel = normalized(model)
        guard normalisedModel != preferences[accountID.rawValue]?.lastReportedModel else { return }
        update(accountID) { $0.lastReportedModel = normalisedModel }
    }

    // MARK: - New-Session Defaults

    func newSessionRunChoice(for accountID: AccountID) -> NewSessionRunChoice? {
        preferences[accountID.rawValue]?.newSessionRunChoice
    }

    /// Records an accepted composer start. An all-automatic choice clears an older explicit one,
    /// which is how choosing Auto becomes just as durable as choosing a named model.
    func setNewSessionRunChoice(_ choice: NewSessionRunChoice, for accountID: AccountID) {
        let model = normalized(choice.model)
        let effort = normalized(choice.reasoningEffort)
        guard model?.utf8.count ?? 0 <= NewSessionChoice.maximumIdentifierBytes,
              effort?.utf8.count ?? 0 <= NewSessionChoice.maximumIdentifierBytes else { return }
        let normalizedChoice = model == nil && effort == nil
            ? nil
            : NewSessionRunChoice(model: model, reasoningEffort: effort)
        update(accountID) { $0.newSessionRunChoice = normalizedChoice }
    }

    // MARK: - Model Visibility

    /// Models hidden from new-session choice surfaces for this provider-qualified login.
    func hiddenModelIDs(for accountID: AccountID) -> Set<String> {
        preferences[accountID.rawValue]?.hiddenModelIDs ?? []
    }

    /// Adds or removes one catalogue identifier from the hidden set.
    ///
    /// The UI only calls this with an identifier from the bounded provider catalogue. Keep a
    /// second persistence bound here anyway: a malformed defaults blob or a future caller must
    /// not turn a compact-metadata preference into an allocation proportional to provider input.
    func setModel(_ modelID: String, hidden: Bool, for accountID: AccountID) {
        guard let modelID = normalized(modelID),
              modelID.utf8.count <= ModelVisibility.maximumIdentifierBytes else { return }
        update(accountID) { preference in
            var hiddenIDs = preference.hiddenModelIDs ?? []
            if hidden {
                guard hiddenIDs.contains(modelID)
                    || hiddenIDs.count < ModelVisibility.maximumHiddenModels else { return }
                hiddenIDs.insert(modelID)
            } else {
                hiddenIDs.remove(modelID)
            }
            preference.hiddenModelIDs = hiddenIDs.isEmpty ? nil : hiddenIDs
        }
    }

    /// Restores every model for one login, including identifiers no longer in today's catalogue.
    func showAllModels(for accountID: AccountID) {
        update(accountID) { $0.hiddenModelIDs = nil }
    }

    // MARK: - Custom Limits

    /// The limits stored *on this account*, or nil when it has never answered and inherits the
    /// app-wide defaults. Callers that want the rules actually in force ask
    /// `CustomLimitSettings.rules(for:)`, which resolves the two scopes.
    func customLimits(for accountID: AccountID) -> [CustomLimit]? {
        preferences[accountID.rawValue]?.customLimits
    }

    /// Replaces this account's limits. Pass nil to hand the account back to the app-wide
    /// defaults — which is a different instruction from passing `[]`, and the only way to undo
    /// "this account has none".
    func setCustomLimits(_ limits: [CustomLimit]?, for accountID: AccountID) {
        update(accountID) {
            $0.customLimits = limits.map { Array($0.prefix(CustomLimitDefaults.maximumRulesPerAccount)) }
        }
    }

    /// Appends one rule to this account's **own** list, leaving the two-scope question alone.
    ///
    /// Deliberately low-level: whether an account that has answered nothing yet should start from
    /// the app-wide defaults or from nothing is a resolution question, and it is answered once in
    /// `CustomLimitSettings.add(_:for:)` rather than here, where this store would have to learn
    /// about a scope above it.
    func appendCustomLimit(_ limit: CustomLimit, for accountID: AccountID) {
        var limits = customLimits(for: accountID) ?? []
        guard limits.count < CustomLimitDefaults.maximumRulesPerAccount else { return }
        limits.append(limit)
        setCustomLimits(limits, for: accountID)
    }

    /// Restores the discovered icon and name, leaving the account switched however it is.
    /// Reset is about presentation, and quietly putting a login the user turned off back into
    /// every menu is not something that button says.
    func clearPresentation(for accountID: AccountID) {
        update(accountID) {
            $0.emoji = nil
            $0.displayNameOverride = nil
            $0.appearance = nil
        }
    }

    // MARK: - Private Methods

    private func update(_ accountID: AccountID, _ mutate: (inout AccountPreference) -> Void) {
        var candidate = preferences
        var preference = candidate[accountID.rawValue] ?? AccountPreference()
        mutate(&preference)

        // Drop empty entries rather than persisting placeholders.
        candidate[accountID.rawValue] = preference.isEmpty ? nil : preference
        guard candidate != preferences else { return }
        if persistence.save(candidate) {
            preferences = candidate
            NotificationCenter.default.post(AccountPreferencesDidChange())
        }
    }

    /// Trims whitespace and treats an empty result as "not set".
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Keys

    private enum Keys {
        static let accountPreferences = "accountPreferences"
        static let appearanceDefaults = "_appearanceDefaults"
    }

    private enum ModelVisibility {
        static let maximumHiddenModels = 256
        static let maximumIdentifierBytes = 512
    }

    private enum NewSessionChoice {
        static let maximumIdentifierBytes = 1_024
    }
}
