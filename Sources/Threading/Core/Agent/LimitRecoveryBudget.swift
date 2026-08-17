import Foundation

// MARK: - Limit Recovery Budget

/// How many times an unattended policy may move one conversation between logins before it stops
/// trying — the floor under `LimitRecoveryPolicy.resumeOnBestAccount` and `resumeVia`.
///
/// **It is a backstop, not a quota.** `limit-recovery.md` states it as the third guard of the
/// automatic design, and its whole reason is that everything above it can be wrong: the migrated
/// transcript carries the source account's refusal at its tail, and if
/// `ObservedUsageLimit.transcriptWasMigrated`'s byte boundary ever failed to hold, detection
/// would read that copied record afresh and move the conversation again — a login-hopping loop
/// that spends every window the user has, silently, while they are asleep. The interactive escape
/// needs nothing like this, because a loop there would be somebody pressing a button once per hop.
///
/// **A rolling window rather than a lifetime count**, because the two failures look nothing alike.
/// A defect loops in seconds and trips any small count; a legitimate long-running chat may
/// genuinely exhaust several logins over a week, and a lifetime count would spend itself on that
/// and leave the feature switched off with no way to notice. Time is the axis that tells them
/// apart.
///
/// **Spent at the attempt, not at the success.** A recovery that fails and is re-read is exactly
/// as much of a loop as one that succeeds, and the failing shape is the more likely defect.
///
/// A value type holding only dates: the rule is assertable with no coordinator, no clock and no
/// agent, which is the same reason `LimitEscapeRanking` takes values.
struct LimitRecoveryBudget {

    // MARK: - Properties

    /// When each session's automatic migrations were attempted, newest last.
    private var attempts: [SessionID: [Date]] = [:]

    private let allowance: Int
    private let window: TimeInterval

    // MARK: - Initialization

    init(
        allowance: Int = LimitRecoveryDefaults.automaticMigrationAllowance,
        window: TimeInterval = LimitRecoveryDefaults.automaticMigrationWindow
    ) {
        self.allowance = allowance
        self.window = window
    }

    // MARK: - Public Methods

    /// Spends one migration for this session, answering whether the policy may go ahead.
    ///
    /// Prunes on the way through — of every session, not only this one, since a set keyed by
    /// sessions that have hit their limit would otherwise keep an entry per session for the life
    /// of the app run. The work is proportional to that same tiny set and happens minutes apart.
    mutating func admitMigration(for sessionID: SessionID, at now: Date = Date()) -> Bool {
        prune(before: now.addingTimeInterval(-window))

        let spent = attempts[sessionID]?.count ?? 0
        guard spent < allowance else { return false }

        attempts[sessionID, default: []].append(now)
        return true
    }

    /// How many migrations this session has spent inside the window.
    func spent(for sessionID: SessionID, at now: Date = Date()) -> Int {
        (attempts[sessionID] ?? []).filter { $0 > now.addingTimeInterval(-window) }.count
    }

    // MARK: - Private Methods

    private mutating func prune(before cutoff: Date) {
        for (sessionID, dates) in attempts {
            let kept = dates.filter { $0 > cutoff }
            if kept.isEmpty {
                attempts.removeValue(forKey: sessionID)
            } else if kept.count != dates.count {
                attempts[sessionID] = kept
            }
        }
    }
}
