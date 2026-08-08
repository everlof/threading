import Foundation

// MARK: - History Availability

/// How much of the history the decision was made on.
///
/// Attached to every "nothing to do" answer, because "the app has been fine" and "the app cannot
/// read its own record of whether it has been fine" are the same recommendation for opposite
/// reasons, and a support report that cannot tell them apart is the one that gets sent.
enum HistoryAvailability: String, Equatable, Sendable {
    case available
    /// The ledger was damaged and has been moved aside.
    case unreadable
    /// The ledger holds records from a later Threading, so this build can see only part of it.
    case partial
}

// MARK: - Crash Loop Decision

/// What the launch history says this launch should do about itself.
///
/// Phase 1 has three consumers and none of them changes what the app *does*: the journal records
/// it, the support report carries it, and the unclean-exit notice picks its wording from it.
/// Recovery Mode is Phase 2's, and this type is the thing it will be handed.
enum CrashLoopDecision: Equatable, Sendable {

    /// Nothing in the history to act on.
    case launchNormally(HistoryAvailability)

    /// One unexpected exit. Noted and no more: everything crashes once, and a mode that appeared
    /// the first time anything went wrong would be a mode nobody trusted the second time.
    case noteFirstUnexpectedExit(lastCheckpoint: StartupCheckpoint?)

    /// Two or more, close enough together to be the same problem. Phase 2 offers Recovery Mode
    /// here; Phase 1 only says so.
    case recommendRecoveryMode(consecutive: Int, lastCheckpoint: StartupCheckpoint?)

    /// The recovery launch died too. Nothing automatic should be started at all.
    case recommendStoppingAutomaticWork(consecutive: Int)

    /// How many consecutive unexpected exits the decision rests on.
    var consecutiveUnexpectedExits: Int {
        switch self {
        case .launchNormally: return 0
        case .noteFirstUnexpectedExit: return 1
        case .recommendRecoveryMode(let consecutive, _),
                .recommendStoppingAutomaticWork(let consecutive):
            return consecutive
        }
    }

    /// Machine-stable, for the journal and the support report. Never localized: both are read by
    /// whoever is helping, whose language need not match the reporter's.
    var token: String {
        switch self {
        case .launchNormally(let availability):
            return availability == .available
                ? CrashLoopDefaults.normalToken
                : "\(CrashLoopDefaults.normalToken) history=\(availability.rawValue)"
        case .noteFirstUnexpectedExit:
            return CrashLoopDefaults.firstExitToken
        case .recommendRecoveryMode(let consecutive, _):
            return "\(CrashLoopDefaults.recoveryToken) consecutive=\(consecutive)"
        case .recommendStoppingAutomaticWork(let consecutive):
            return "\(CrashLoopDefaults.stopAutomaticToken) consecutive=\(consecutive)"
        }
    }

    /// The checkpoint the newest unexpected launch reached, when there was one. The single most
    /// useful line in a report of this kind, and an enum case name by construction.
    var lastReachedCheckpoint: StartupCheckpoint? {
        switch self {
        case .noteFirstUnexpectedExit(let checkpoint),
                .recommendRecoveryMode(_, let checkpoint):
            return checkpoint
        case .launchNormally, .recommendStoppingAutomaticWork:
            return nil
        }
    }
}

// MARK: - Crash Loop Policy

/// The whole rule, as a function of what is on disk.
///
/// Pure and table-testable on purpose. Every interesting input here — a second crash four minutes
/// after the first, a clock that moved backwards between them, a reboot in the middle — is a
/// situation nobody can stage on demand, so the only way this is ever checked is as a table.
enum CrashLoopPolicy {

    /// Walks the history backwards from the newest launch.
    ///
    /// Three things stop the walk, and each is a claim that whatever is further back is a
    /// different story: a launch made by a **different build** (a new build starts a fresh
    /// counter and keeps the history), a launch that reached **stability** (ten interactive
    /// minutes is the app saying it works), and a pair of counted exits that fall **outside the
    /// window**.
    ///
    /// Everything that is never counted — a clean quit, a logout, a reset relaunch, an `end`
    /// this build cannot name — is **skipped transparently**: it neither increments the count nor
    /// stops the walk. "Never counted" is not "resets the counter"; a quit thirty seconds into a
    /// launch is not evidence that anything was fixed, and only `stable` is.
    ///
    /// **Stability is checked before the ending is, so a launch that ran for ten minutes and then
    /// crashed clears rather than counts.** It is the conservative reading and it is chosen, not
    /// incidental: ten interactive minutes is the app demonstrating it works, and a crash after
    /// that is the first of whatever comes next rather than the second of what came before — the
    /// *next* launch's walk starts that streak at one. Nothing is hidden by it, because the crash
    /// is still the marker's to report and the notice still goes up; all that is withheld is the
    /// escalation, which is the direction that under-reports.
    static func decide(
        _ read: LaunchLedgerRead,
        build: BuildFingerprint = .current
    ) -> CrashLoopDecision {
        switch read {
        case .missing:
            return .launchNormally(.available)
        case .corrupt:
            return .launchNormally(.unreadable)
        case .unsupportedVersion:
            // Never escalate on a view known to be partial. Missing a loop costs the user the
            // status quo; inventing one puts a mode on screen that nothing justifies.
            return .launchNormally(.partial)
        case .valid(let history):
            return decide(history, build: build)
        }
    }

    static func decide(
        _ history: LaunchLedgerHistory,
        build: BuildFingerprint = .current
    ) -> CrashLoopDecision {
        var consecutive = 0
        var newerCounted: LaunchLedgerLaunch?
        var lastCheckpoint: StartupCheckpoint?
        var recoveryDied = false

        for launch in history.launches.reversed() {
            guard launch.fingerprint == build.token else { break }
            guard !launch.reachedStability else { break }
            guard launch.endedUnexpectedly else { continue }

            if let newerCounted, !isWithinWindow(older: launch, newer: newerCounted) { break }

            if consecutive == 0 {
                lastCheckpoint = launch.lastCheckpoint
                recoveryDied = launch.mode == .recovery
            }
            consecutive += 1
            newerCounted = launch
        }

        if recoveryDied {
            return .recommendStoppingAutomaticWork(consecutive: consecutive)
        }
        if consecutive >= CrashLoopDefaults.recoveryThreshold {
            return .recommendRecoveryMode(
                consecutive: consecutive,
                lastCheckpoint: lastCheckpoint
            )
        }
        if consecutive == 1 {
            return .noteFirstUnexpectedExit(lastCheckpoint: lastCheckpoint)
        }
        return .launchNormally(.available)
    }

    // MARK: - The Window

    /// Whether two counted exits are close enough together to be one problem.
    ///
    /// **The five minutes bound only the pairs that both reached readiness.** A launch that died
    /// before its first window was on screen cannot have been anything the user did, so two of
    /// those are a loop however far apart they are — an app that cannot start is not more
    /// startable for having been left alone overnight. Weighting such an exit numerically was the
    /// alternative and it fails in the wrong direction: it lets one crash recommend a mode.
    static func isWithinWindow(older: LaunchLedgerLaunch, newer: LaunchLedgerLaunch) -> Bool {
        guard older.reachedReadiness, newer.reachedReadiness else { return true }
        guard let elapsed = elapsed(from: older, to: newer) else { return false }
        guard elapsed >= 0 else { return false }
        return elapsed <= CrashLoopDefaults.consecutiveWindow
    }

    /// How long passed between two launches starting.
    ///
    /// Uptime within one boot session: it advances across sleep — which is what "five minutes of
    /// the user's time" has to mean, since a lid closed between two attempts is not a loop — and
    /// it is immune to the clock being set. Across a reboot it is meaningless (it restarts at
    /// zero), so the wall clock is the only answer there. An unknowable or negative interval is
    /// treated as **outside** the window: a clock that moved backwards must not be able to
    /// manufacture an escalation.
    static func elapsed(
        from older: LaunchLedgerLaunch,
        to newer: LaunchLedgerLaunch
    ) -> TimeInterval? {
        if !older.bootID.isEmpty, older.bootID == newer.bootID {
            return newer.uptime - older.uptime
        }
        guard let start = older.startedAt, let end = newer.startedAt else { return nil }
        return end.timeIntervalSince(start)
    }
}

// MARK: - Crash Loop Defaults

enum CrashLoopDefaults {

    /// Two launches that both died, started within this of each other, are one problem rather
    /// than two afternoons.
    static let consecutiveWindow: TimeInterval = 5 * 60

    /// The second unexpected exit is the one that means something. The first is noted.
    static let recoveryThreshold = 2

    static let normalToken = "normal"
    static let firstExitToken = "first-unexpected-exit"
    static let recoveryToken = "recovery-recommended"
    static let stopAutomaticToken = "stop-automatic-work"

    /// What the journal calls the record. One spelling, because a test reads it too.
    static let decisionMessage = "Crash-loop decision"
    static let decisionField = "decision"
    static let ledgerField = "ledger"
    static let checkpointField = "lastCheckpoint"
}
