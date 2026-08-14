import Foundation

// MARK: - Usage Alert Record

/// What one rule has already said about one turn of its window.
///
/// Persisted, because the alternative is a relaunch re-firing the 50% alert on a window that is
/// still at 61% — and the alternative to *pruning* it is a relaunch that stays silent about next
/// week's weekly because last week's already crossed the line.
struct UsageAlertRecord: Codable, Equatable {

    /// The account, spelled as `AccountID.rawValue`.
    ///
    /// Part of the key rather than implied by the rule, because a rule inherited from the
    /// app-wide defaults is the *same rule id* on every login. Without this, the first account to
    /// cross 50% would silence the other four.
    let accountID: String

    let ruleID: UUID
    let windowID: String

    /// When this turn of the window ends. Nil for a window the provider reports without a reset,
    /// which therefore never prunes on time — `UsageAlertLedgerDefaults.maximumRecords` is what
    /// bounds those.
    let resetsAt: Date?

    /// Thresholds already announced, as fractions of the rule's bound.
    var thresholds: [Double]

    /// The composite key: account, rule, and the turn of the window.
    var key: String {
        UsageAlertLedger.key(
            accountID: accountID,
            ruleID: ruleID,
            instance: CustomLimitWindowInstance(windowID: windowID, resetsAt: resetsAt)
        )
    }
}

// MARK: - Usage Alert Ledger

/// Remembers which lines have already been announced, and forgets them when their window turns
/// over.
///
/// Kept apart from the center that posts so the bookkeeping is testable without
/// `UNUserNotificationCenter`: this owns "has this been said", the center owns "say it".
///
/// Stored through `PreferenceStore` — not because a fired threshold is a choice, but because the
/// test bundle is hosted in the app and a suite that drove a hundred crossings would otherwise
/// leave them in the developer's own preferences, silencing the alerts on the copy of Threading
/// they are actually using. Its criticality is `rebuildableCache`: an unreadable blob is dropped
/// rather than quarantined, because the worst consequence of forgetting is one duplicate
/// notification, and refusing to write would be a permanent silence instead.
@MainActor
final class UsageAlertLedger {

    // MARK: - Singleton

    static let shared = UsageAlertLedger()

    // MARK: - Properties

    private var records: [String: UsageAlertRecord]
    private let persistence: RecoverableDefaultsStore<[String: UsageAlertRecord]>

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<[String: UsageAlertRecord]>(
            defaults: defaults,
            key: Keys.firedThresholds,
            criticality: .rebuildableCache,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.records = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Public Methods

    /// The thresholds already announced for one account, in the shape the evaluator's input
    /// takes: keyed by rule and window instance, without the account, since an evaluation is
    /// always of one account.
    func fired(for accountID: AccountID) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for record in records.values where record.accountID == accountID.rawValue {
            let instance = CustomLimitWindowInstance(
                windowID: record.windowID,
                resetsAt: record.resetsAt
            )
            result[CustomLimitEvaluator.firedKey(ruleID: record.ruleID, instance: instance)]
                = record.thresholds
        }
        return result
    }

    /// Writes down every line an evaluation just crossed — all of them, not only the one
    /// announced, so the lines stepped over in a sparse jump are not re-announced by the next
    /// reading.
    func record(_ evaluation: CustomLimitEvaluation, for accountID: AccountID) {
        guard !evaluation.crossedThresholds.isEmpty else { return }

        let key = Self.key(
            accountID: accountID.rawValue,
            ruleID: evaluation.rule.id,
            instance: evaluation.instance
        )
        var record = records[key] ?? UsageAlertRecord(
            accountID: accountID.rawValue,
            ruleID: evaluation.rule.id,
            windowID: evaluation.instance.windowID,
            resetsAt: evaluation.instance.resetsAt,
            thresholds: []
        )
        record.thresholds = Array(Set(record.thresholds).union(evaluation.crossedThresholds))
            .sorted()
        records[key] = record
        save()
    }

    /// Drops one account's records whose window has turned over or whose rule is no longer in
    /// force, and returns the keys dropped so the center can withdraw their notifications.
    ///
    /// A reset does both halves of the hygiene rule: it re-arms every threshold *and* takes down
    /// what was delivered. A notification saying the weekly passed 50% is litter once the weekly
    /// is a different weekly.
    ///
    /// **Scoped to one account, and that is load-bearing.** An evaluation knows the rules in force
    /// on the login it is about and nothing about the other four; pruning globally against that
    /// set would have every account delete every other account's bookkeeping on each reading, and
    /// the symptom would be alerts re-firing at random rather than anything that looks like a bug
    /// in a ledger.
    @discardableResult
    func prune(accountID: AccountID, liveRuleIDs: Set<UUID>, now: Date = Date()) -> [String] {
        var dropped: [String] = []

        for (key, record) in records where record.accountID == accountID.rawValue {
            let expired = record.resetsAt.map { $0 <= now } ?? false
            if expired || !liveRuleIDs.contains(record.ruleID) {
                records[key] = nil
                dropped.append(key)
            }
        }

        // A window the provider reports without a reset never prunes on time, so the map is
        // bounded by count as well. Oldest-resetting first, which puts the datable records at the
        // front and the undatable ones at the back — where they are the only thing left to drop.
        if records.count > UsageAlertLedgerDefaults.maximumRecords {
            let ordered = records.sorted {
                ($0.value.resetsAt ?? .distantFuture) < ($1.value.resetsAt ?? .distantFuture)
            }
            for (key, _) in ordered.prefix(records.count - UsageAlertLedgerDefaults.maximumRecords) {
                records[key] = nil
                dropped.append(key)
            }
        }

        if !dropped.isEmpty { save() }
        return dropped
    }

    /// Every key currently held, so the center can withdraw exactly what it delivered.
    var keys: [String] { Array(records.keys) }

    // MARK: - Keys

    /// Pure string building, so it is reachable from `UsageAlertRecord` — which is a value and has
    /// no actor — without hopping to the main one.
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
        static let firedThresholds = "customLimitFiredThresholds"
    }
}

// MARK: - Usage Alert Ledger Defaults

enum UsageAlertLedgerDefaults {

    /// How many fired records the ledger holds before it starts dropping the oldest.
    ///
    /// Ten rules on ten accounts, each with a live window and the one before it: the bound exists
    /// so a provider that reports a window without a reset cannot grow this without limit, not to
    /// ration anybody's rules.
    static let maximumRecords = 400
}
