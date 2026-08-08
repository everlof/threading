import Foundation

// MARK: - Launch Mode Reason

/// Why this launch came up in the mode it did.
///
/// Machine-stable tokens, never localized: they go into the journal and the support report, which
/// are read by whoever is helping and whose language need not match the reporter's.
///
/// The reason is carried beside the mode rather than folded into it, because the recovery surface
/// has to say which of four quite different things put it on screen — a crash loop, a recovery
/// launch that died too, a held Option key, a command-line flag — and "recovery" alone cannot.
enum LaunchModeReason: String, Equatable, Sendable {

    /// Nothing asked for anything.
    case normal

    /// A one-shot "Try Normal Launch Once", armed by a recovery launch and spent by this one.
    case forcedNormal = "forced-normal"

    /// Option was held while the app started.
    case optionKeyHeld = "option-key"

    /// `--recovery-mode` on the command line.
    case commandLineFlag = "command-line"

    /// The history says this is at least the second unexpected exit in a row.
    case crashLoop = "crash-loop"

    /// The recovery launch did not come back either.
    case recoveryLaunchFailed = "recovery-launch-failed"
}

// MARK: - Launch Mode Resolution

/// The mode this launch runs in, and the one fact that explains it.
struct LaunchModeResolution: Equatable, Sendable {

    let mode: LaunchMode
    let reason: LaunchModeReason

    static let normalLaunch = LaunchModeResolution(mode: .normal, reason: .normal)

    var isRecovery: Bool { mode == .recovery }

    /// For the journal and the support report. Never localized, for the reason above.
    var token: String { "\(mode.rawValue) reason=\(reason.rawValue)" }
}

// MARK: - Launch Mode Resolver

/// The whole entry rule, as a function of what the launch was told.
///
/// Pure and table-testable on purpose, `CrashLoopPolicy`'s reason exactly: two of its four inputs
/// (a held modifier key, a crash history) are situations nobody can stage on demand, so a table is
/// the only way this is ever checked.
enum LaunchModeResolver {

    /// **The order below is the decision, not a formality.**
    ///
    /// The two explicit requests come first because somebody is standing there asking, and a
    /// stale one-shot must never overrule them. `forceNormalOnce` then beats the crash-loop
    /// decision, which is the load-bearing one: the user pressed a button in this app's own
    /// recovery surface saying "try normal once", and without this the decision that put them
    /// there would immediately overrule the button and the action would be inert.
    ///
    /// `forceNormalOnce` is spent by the caller **before** this is asked, whichever branch wins,
    /// so a one-shot that was outranked is still one-shot.
    static func resolve(
        decision: CrashLoopDecision,
        optionHeld: Bool,
        arguments: [String],
        forceNormalOnce: Bool
    ) -> LaunchModeResolution {
        if arguments.contains(LaunchModeDefaults.recoveryArgument) {
            return LaunchModeResolution(mode: .recovery, reason: .commandLineFlag)
        }
        if optionHeld {
            return LaunchModeResolution(mode: .recovery, reason: .optionKeyHeld)
        }
        if forceNormalOnce {
            return LaunchModeResolution(mode: .normal, reason: .forcedNormal)
        }

        switch decision {
        case .recommendRecoveryMode:
            return LaunchModeResolution(mode: .recovery, reason: .crashLoop)
        case .recommendStoppingAutomaticWork:
            // Recovery too, and deliberately not a third mode. The only thing stronger than
            // recovery is to start less, and recovery already starts nothing; a third mode would
            // be one nobody tested, and `CrashLoopPolicy` reads `launch.mode == .recovery` on a
            // two-valued enum. The surface says the harder sentence instead.
            return LaunchModeResolution(mode: .recovery, reason: .recoveryLaunchFailed)
        case .launchNormally, .noteFirstUnexpectedExit:
            return .normalLaunch
        }
    }
}

// MARK: - Launch Plan

/// What this launch is allowed to start, decided once and read at each step.
///
/// A value rather than an `if RecoveryMode.isActive` at twenty call sites. Two things come from
/// that: the whole rule is one table a test can assert without an application, a window or a
/// store, and each site in `applicationDidFinishLaunching` names the *reason* it is skipping
/// rather than restating the mode.
struct LaunchPlan: Equatable, Sendable {

    let mode: LaunchMode
    let reason: LaunchModeReason

    /// The pre-rename Application Support adoption.
    let runsLegacyMigration: Bool

    /// The extension host, the appearance contributions, and the enabled packages.
    let startsExtensions: Bool

    /// The MCP listener. Also the gate on everything hanging off its start callback.
    let startsMCPListener: Bool

    /// Icon discovery, branch following, usage prefetch and poking, limit recovery, remote
    /// access, the artifact and code-stats sweeps, legacy name backfill, attention alerts.
    let startsBackgroundServices: Bool

    let showsOnboarding: Bool

    /// The selected session, the sessions from the last quit, the detached browser windows.
    let restoresWorkspace: Bool

    /// Whether ten interactive minutes under this launch may clear a crash-loop count.
    let armsStabilityCheckpoint: Bool

    /// Whether `ProjectStore` may write.
    let allowsStateWrites: Bool

    /// Whether the quit path records what was running, for the next launch to bring back.
    let recordsRunningSessionsOnQuit: Bool

    var isRecovery: Bool { mode == .recovery }

    init(
        resolution: LaunchModeResolution,
        decision: CrashLoopDecision,
        extensionsDisabledOnce: Bool,
        needsOnboarding: Bool
    ) {
        let recovery = resolution.isRecovery
        mode = resolution.mode
        reason = resolution.reason

        // **The migration is the one launch step recovery still weighs rather than refuses.**
        // Skipping it after the rename would open on an empty sidebar, which reads as data loss
        // and is the worst possible message here — but it is also the one part of a launch that
        // moves someone's database around. So the ledger decides: a counted launch that recorded
        // no checkpoint at all never reached `migrationDone`, which makes the migration the prime
        // suspect and the only case worth refusing.
        runsLegacyMigration = !recovery || decision.lastReachedCheckpoint != nil

        startsExtensions = !recovery && !extensionsDisabledOnce
        startsMCPListener = !recovery
        startsBackgroundServices = !recovery
        // Recovery wins over a first launch that crash-loops. The completion flag is untouched,
        // so the walkthrough returns on the next normal launch rather than being lost.
        showsOnboarding = !recovery && needsOnboarding
        restoresWorkspace = !recovery
        // `stable` is a claim that the app works. A launch that started nothing has not made it,
        // and letting it clear the count would mean sitting in recovery for ten minutes erases
        // the evidence of the loop.
        armsStabilityCheckpoint = !recovery
        allowsStateWrites = !recovery
        recordsRunningSessionsOnQuit = !recovery
    }
}

// MARK: - Launch Mode Defaults

enum LaunchModeDefaults {

    /// `open -a Threading --args --recovery-mode`.
    static let recoveryArgument = "--recovery-mode"

    /// What the journal calls the record. One spelling, because a test reads it too.
    static let resolutionMessage = "Launch mode"
    static let resolutionField = "mode"
    static let reasonField = "reason"
    static let flagsField = "flags"
}
