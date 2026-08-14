import Foundation

// MARK: - Custom Limit Settings

/// The app-wide half of the user's own limits, and the seam that resolves the two scopes.
///
/// A limit is an **account** fact, so this feature deliberately uses two of the three scopes the
/// app already conventions on — the app-wide default and the account's own answer, with the
/// project and session scopes not offered. A per-session budget is an *authority* rather than a
/// limit, and belongs to the control plane's grants.
///
/// Through `PreferenceStore` for the reason `UsageWindowSettings` documents: the test bundle is
/// hosted in the app, so `.standard` here is the developer's own preferences, and a suite that
/// stores "alert every 10% on every account" would be leaving that switched on for the copy of
/// Threading they are actually using. `UsageAlertCenter` refuses to run under a test bundle as
/// well — one guard for a feature that posts notifications is not enough.
@MainActor
final class CustomLimitSettings {

    // MARK: - Singleton

    static let shared = CustomLimitSettings()

    // MARK: - Stored Shape

    /// Everything app-wide about limits, as one record, so a single decode answers every question
    /// the page and the alert center ask.
    struct Stored: Codable, Equatable {

        /// The master switch for usage alerts.
        ///
        /// Its own switch rather than a case folded into the session-attention family: those
        /// alerts are session-scoped and every one of them is a change the user can act on *in
        /// that session*, while a usage alert is account-scoped and actionable at the account
        /// level — slow down, switch login, change model. Someone who wants to hear about their
        /// quota and nothing else, or the reverse, must be able to say so.
        var alertsEnabled: Bool

        /// Rules that apply to every account that has not answered for itself.
        var defaultLimits: [CustomLimit]

        static let `default` = Stored(alertsEnabled: true, defaultLimits: [])
    }

    // MARK: - Properties

    private let persistence: RecoverableDefaultsStore<Stored>
    private var cached: Stored

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<Stored>(
            defaults: defaults,
            key: Keys.customLimits,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.cached = persistence.load(
            defaultValue: .default,
            validate: Self.validate
        ).value
    }

    // MARK: - Public Methods

    /// Whether usage alerts are posted at all. Off withdraws what was already delivered — an off
    /// switch that leaves its traces behind is not off.
    var alertsEnabled: Bool {
        get { cached.alertsEnabled }
        set {
            guard newValue != cached.alertsEnabled else { return }
            var updated = cached
            updated.alertsEnabled = newValue
            store(updated)
        }
    }

    /// The rules every account inherits until it answers for itself.
    var defaultLimits: [CustomLimit] {
        get { cached.defaultLimits }
        set {
            let bounded = Array(newValue.prefix(CustomLimitDefaults.maximumRulesPerAccount))
            guard bounded != cached.defaultLimits else { return }
            var updated = cached
            updated.defaultLimits = bounded
            store(updated)
        }
    }

    /// The rules actually in force on one account: its own answer when it has given one, the
    /// app-wide defaults otherwise. **Absent means inherit; empty means none** — an account whose
    /// owner cleared its rules keeps having none rather than quietly picking the app default back
    /// up.
    func rules(for accountID: AccountID, store: AccountPreferencesStore? = nil) -> [CustomLimit] {
        let accountStore = store ?? AccountPreferencesStore.shared
        return accountStore.customLimits(for: accountID) ?? cached.defaultLimits
    }

    /// Whether this account is running on the app-wide defaults rather than its own list — what
    /// the settings row says beside an untouched account, and what a Reset button restores.
    func inheritsDefaults(for accountID: AccountID, store: AccountPreferencesStore? = nil) -> Bool {
        (store ?? AccountPreferencesStore.shared).customLimits(for: accountID) == nil
    }

    // MARK: - Editing One Account

    /// Adds a rule to one account, **taking what it was already running with it**.
    ///
    /// An account on the app-wide defaults is answering for itself the moment a line is drawn on
    /// it, so its list has to start as something. It starts as the rules it already had: adding
    /// "tell me at 90% of the 5-hour" to a login that inherited "every 10% of the weekly" leaves
    /// both standing. The other reading — a new rule replacing the inherited ones — is the
    /// surprising one, and it is surprising in the direction that silently stops telling somebody
    /// about their quota.
    func add(_ rule: CustomLimit, for accountID: AccountID, store: AccountPreferencesStore? = nil) {
        let accountStore = store ?? AccountPreferencesStore.shared
        if accountStore.customLimits(for: accountID) == nil {
            accountStore.setCustomLimits(cached.defaultLimits, for: accountID)
        }
        accountStore.appendCustomLimit(rule, for: accountID)
    }

    /// Removes a rule from one account, materializing the inherited list first for the same
    /// reason. Removing an inherited rule has to *work* — a Remove button that does nothing
    /// because the list it was drawn from belongs to another scope is the worst kind of quiet.
    func remove(
        ruleID: UUID,
        for accountID: AccountID,
        store: AccountPreferencesStore? = nil
    ) {
        let accountStore = store ?? AccountPreferencesStore.shared
        let current = accountStore.customLimits(for: accountID) ?? cached.defaultLimits
        accountStore.setCustomLimits(current.filter { $0.id != ruleID }, for: accountID)
    }

    /// Switches whether one rule may move the always-visible pill.
    ///
    /// Goes through the same materializing route as `add` and `remove`, so a rule shown on an
    /// account that is still inheriting can be switched without the switch quietly doing nothing.
    func setShowsInToolbar(
        _ shows: Bool,
        ruleID: UUID,
        for accountID: AccountID,
        store: AccountPreferencesStore? = nil
    ) {
        let accountStore = store ?? AccountPreferencesStore.shared
        let current = accountStore.customLimits(for: accountID) ?? cached.defaultLimits
        accountStore.setCustomLimits(
            current.map { rule in
                guard rule.id == ruleID else { return rule }
                var updated = rule
                updated.showsInToolbar = shows
                return updated
            },
            for: accountID
        )
    }

    // MARK: - Editing The App-Wide Defaults

    func addDefault(_ rule: CustomLimit) {
        guard defaultLimits.count < CustomLimitDefaults.maximumRulesPerAccount else { return }
        defaultLimits = defaultLimits + [rule]
    }

    func removeDefault(ruleID: UUID) {
        defaultLimits = defaultLimits.filter { $0.id != ruleID }
    }

    func setDefaultShowsInToolbar(_ shows: Bool, ruleID: UUID) {
        defaultLimits = defaultLimits.map { rule in
            guard rule.id == ruleID else { return rule }
            var updated = rule
            updated.showsInToolbar = shows
            return updated
        }
    }

    // MARK: - Private Methods

    private func store(_ updated: Stored) {
        do {
            try Self.validate(updated)
        } catch {
            ThreadingLogger.usage.error("Refusing invalid custom-limit settings")
            return
        }
        guard persistence.save(updated) else { return }
        cached = updated
        NotificationCenter.default.post(CustomLimitsDidChange())
    }

    private enum ValidationError: Error {
        case invalidSettings
    }

    /// Refuses a blob a bug or a hand-edited plist could have produced. The bound and threshold
    /// clamps live on `CustomLimit`'s initializer, but a decode does not run one, so the same
    /// ranges are asserted here — a stored rule with a bound of zero is permanently crossed, and
    /// would notify on every reading forever.
    private static func validate(_ settings: Stored) throws {
        guard settings.defaultLimits.count <= CustomLimitDefaults.maximumRulesPerAccount,
              settings.defaultLimits.allSatisfy(Self.isWellFormed) else {
            throw ValidationError.invalidSettings
        }
    }

    static func isWellFormed(_ limit: CustomLimit) -> Bool {
        limit.bound >= CustomLimitDefaults.minimumBound
            && limit.bound <= CustomLimitDefaults.boundThreshold
            && !limit.windowID.isEmpty
            && limit.windowID.utf8.count <= Limits.windowIDBytes
            && !limit.thresholds.isEmpty
            && limit.thresholds.count <= Limits.thresholds
            && limit.thresholds.allSatisfy { $0 > 0 && $0 <= CustomLimitDefaults.boundThreshold }
            && (limit.name?.utf8.count ?? 0) <= Limits.nameBytes
    }

    private enum Limits {
        static let windowIDBytes = 256
        static let nameBytes = 512
        /// "Every 1%" is a hundred lines, which is the most a generator can produce.
        static let thresholds = 100
    }

    private enum Keys {
        static let customLimits = "customLimits"
    }
}
