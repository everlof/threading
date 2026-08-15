import Foundation

// MARK: - Custom Limit Override

/// One **Continue Anyway**: the user standing their own rule down for this turn of its window.
///
/// The rule is theirs, so overriding it is legitimate — that is the difference between a park and
/// a provider refusal, and it is the difference the whole tier rests on. What an override must not
/// be is a quiet off switch: it is scoped to the window instance it was given in and expires with
/// it, so one late-night exception does not disable the rule forever.
struct CustomLimitOverride: Codable, Equatable {

    let accountID: String
    let ruleID: UUID
    let windowID: String

    /// The turn of the window this permission belongs to. When the window resets this record is
    /// pruned and the rule is back in force, without the user having to remember to re-arm it.
    let resetsAt: Date?

    /// When it was given. Kept for the receipt — "you continued past this at 14:12" is a more
    /// useful line than "this rule is off".
    let grantedAt: Date

    var key: String {
        CustomLimitOverrideStore.key(
            accountID: accountID,
            ruleID: ruleID,
            instance: CustomLimitWindowInstance(windowID: windowID, resetsAt: resetsAt)
        )
    }
}

// MARK: - Custom Limit Override Store

/// Remembers which parks the user has walked through, and forgets them when the window turns over.
///
/// Deliberately the same shape as `UsageAlertLedger` — keyed by account, rule and window instance,
/// pruned on the reset — because they are the same kind of fact about the same object, and two
/// different spellings of "this belongs to this turn of this window" is how the two come to
/// disagree about when a rule re-arms.
///
/// Stored through `PreferenceStore` at `preference` criticality rather than `rebuildableCache`:
/// losing a fired *alert* costs one duplicate notification, while losing an *override* silently
/// re-parks a session the user has already answered for, which is the failure this tier can least
/// afford.
@MainActor
final class CustomLimitOverrideStore {

    // MARK: - Singleton

    static let shared = CustomLimitOverrideStore()

    // MARK: - Properties

    private var records: [String: CustomLimitOverride]
    private let persistence: RecoverableDefaultsStore<[String: CustomLimitOverride]>

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<[String: CustomLimitOverride]>(
            defaults: defaults,
            key: Keys.overrides,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.records = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Public Methods

    /// The overrides in force on one account, as the keys a park decision reads.
    func granted(for accountID: AccountID, at now: Date = Date()) -> Set<String> {
        var result: Set<String> = []
        for record in records.values where record.accountID == accountID.rawValue {
            // An expired instance is not an override any more, whether or not the prune has run.
            // Reading it as one would be the store deciding a rule is off because nobody has
            // swept yet.
            if let resetsAt = record.resetsAt, resetsAt <= now { continue }
            result.insert(CustomLimitEvaluator.firedKey(
                ruleID: record.ruleID,
                instance: CustomLimitWindowInstance(
                    windowID: record.windowID,
                    resetsAt: record.resetsAt
                )
            ))
        }
        return result
    }

    /// Records a Continue Anyway for one rule's current window instance.
    func grant(
        rule: CustomLimit,
        window: AccountUsage.Window?,
        for accountID: AccountID,
        at now: Date = Date()
    ) {
        let record = CustomLimitOverride(
            accountID: accountID.rawValue,
            ruleID: rule.id,
            windowID: rule.windowID,
            resetsAt: window?.resetsAt,
            grantedAt: now
        )
        records[record.key] = record
        save()
    }

    /// Drops overrides whose window has turned over, plus any belonging to a rule that is gone.
    @discardableResult
    func prune(accountID: AccountID, liveRuleIDs: Set<UUID>, now: Date = Date()) -> Int {
        let before = records.count
        for (key, record) in records where record.accountID == accountID.rawValue {
            let expired = record.resetsAt.map { $0 <= now } ?? false
            if expired || !liveRuleIDs.contains(record.ruleID) {
                records[key] = nil
            }
        }
        if records.count > CustomLimitOverrideDefaults.maximumRecords {
            let ordered = records.sorted {
                ($0.value.resetsAt ?? .distantFuture) < ($1.value.resetsAt ?? .distantFuture)
            }
            for (key, _) in ordered.prefix(records.count - CustomLimitOverrideDefaults.maximumRecords) {
                records[key] = nil
            }
        }
        let dropped = before - records.count
        if dropped > 0 { save() }
        return dropped
    }

    var count: Int { records.count }

    // MARK: - Keys

    nonisolated static func key(
        accountID: String,
        ruleID: UUID,
        instance: CustomLimitWindowInstance
    ) -> String {
        "\(accountID)\(CustomLimitEvaluatorDefaults.keySeparator)"
            + CustomLimitEvaluator.firedKey(ruleID: ruleID, instance: instance)
    }

    // MARK: - Private Methods

    private func save() {
        persistence.save(records)
    }

    private enum Keys {
        static let overrides = "customLimitOverrides"
    }
}

// MARK: - Custom Limit Override Defaults

enum CustomLimitOverrideDefaults {
    /// The same backstop the alert ledger keeps, for the same reason: a window the provider
    /// reports without a reset never prunes on time.
    static let maximumRecords = 200
}
