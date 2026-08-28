import XCTest
@testable import Threading

/// The whole crash-loop rule, as a table.
///
/// Every input here is a situation nobody can stage on demand — a second crash four minutes after
/// the first, a clock stepped backwards between them, a reboot in the middle — so a table is not a
/// convenience, it is the only way any of this is ever checked. The policy takes a history and a
/// build and touches no clock and no disk, which is what makes that possible.
final class CrashLoopPolicyTests: XCTestCase {

    // MARK: - Fixture

    private let build = BuildFingerprint(build: "1.0 (1)", token: "build-a")
    private let otherBuild = "build-b"

    /// Minutes into one boot session, which is how the fixtures spell "four minutes apart".
    private func launch(
        _ id: String,
        minute: Double,
        fingerprint: String? = nil,
        boot: String = "boot-1",
        mode: LaunchMode = .normal,
        checkpoints: [StartupCheckpoint] = [.firstWindowVisible],
        ending: LaunchDisposition? = nil,
        systemInitiated: Bool = false
    ) -> LaunchLedgerLaunch {
        LaunchLedgerLaunch(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000_000 + minute * 60),
            uptime: minute * 60,
            bootID: boot,
            fingerprint: fingerprint ?? build.token,
            mode: mode,
            checkpoints: checkpoints,
            ending: ending.map { LaunchEnding(disposition: $0, systemInitiated: systemInitiated) }
        )
    }

    private func decide(_ launches: [LaunchLedgerLaunch]) -> CrashLoopDecision {
        CrashLoopPolicy.decide(LaunchLedgerHistory(launches: launches), build: build)
    }

    // MARK: - The Read Outcomes

    func testNoLedgerAtAllIsAnOrdinaryLaunch() {
        XCTAssertEqual(CrashLoopPolicy.decide(.missing, build: build), .launchNormally(.available))
    }

    /// Damage and health recommend the same thing and mean opposite things, so the availability
    /// rides along rather than being flattened into "normal".
    func testADamagedLedgerLaunchesNormallyAndSaysItCouldNotBeRead() {
        XCTAssertEqual(
            CrashLoopPolicy.decide(.corrupt(quarantinedAt: nil), build: build),
            .launchNormally(.unreadable)
        )
    }

    /// Never escalate on a view known to be partial. Missing a loop costs the user the status quo;
    /// inventing one puts a mode on screen that nothing justifies.
    func testALedgerFromALaterBuildNeverRecommendsAnything() {
        XCTAssertEqual(
            CrashLoopPolicy.decide(.unsupportedVersion(newestFormatSeen: 2), build: build),
            .launchNormally(.partial)
        )
    }

    // MARK: - Counting

    func testOneUnexpectedExitIsNotedAndNoMore() {
        let decision = decide([
            launch("a", minute: 0, checkpoints: [.firstWindowVisible], ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .noteFirstUnexpectedExit(lastCheckpoint: .firstWindowVisible),
            "everything crashes once, and a mode nobody trusts is one that appeared the first time"
        )
    }

    func testTwoUnexpectedExitsInsideTheWindowRecommendRecovery() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 4, ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .firstWindowVisible)
        )
    }

    func testTwoUnexpectedExitsFurtherApartThanTheWindowAreTwoAfternoons() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 6, ending: .unclean)
        ])

        XCTAssertEqual(decision.consecutiveUnexpectedExits, 1)
    }

    /// **The window bounds only the pairs that both got up.** A launch that died before its first
    /// window cannot have been anything the user did, and an app that cannot start is not more
    /// startable for having been left alone overnight.
    func testTwoExitsBeforeReadinessCountHoweverFarApartTheyAre() {
        let decision = decide([
            launch("a", minute: 0, checkpoints: [.themeRestored], ending: .unclean),
            launch("b", minute: 6 * 60, checkpoints: [.themeRestored], ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .themeRestored)
        )
    }

    // MARK: - What Stops The Walk

    func testANewBuildStartsAFreshCounterAndKeepsTheHistory() {
        let decision = decide([
            launch("a", minute: 0, fingerprint: otherBuild, ending: .unclean),
            launch("b", minute: 1, fingerprint: otherBuild, ending: .unclean),
            launch("c", minute: 2, ending: .unclean)
        ])

        XCTAssertEqual(decision.consecutiveUnexpectedExits, 1)
    }

    /// **Stability is checked before the ending is, so a launch that ran its ten minutes and then
    /// crashed clears rather than counts.** The order is a choice, not a consequence of how the
    /// loop happens to be written: ten interactive minutes is the app demonstrating it works, and
    /// a crash after that is the first of whatever comes next rather than the second of what came
    /// before. The next launch's own walk starts that streak at one. Nothing is hidden by it —
    /// the crash is still the marker's to report and the notice still goes up — and all that is
    /// withheld is the escalation, which is the direction that under-reports.
    func testALaunchThatCrashedAfterEarningItsStabilityIsNotCounted() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch(
                "b",
                minute: 1,
                checkpoints: [.firstWindowVisible, .stable],
                ending: .unclean
            )
        ])

        XCTAssertEqual(decision, .launchNormally(.available))
    }

    /// Ten interactive minutes is the app saying it works, and it is the only thing that says so.
    func testALaunchThatReachedStabilityClearsWhateverCameBeforeIt() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, checkpoints: [.firstWindowVisible, .stable], ending: .clean),
            launch("c", minute: 12, ending: .unclean)
        ])

        XCTAssertEqual(decision.consecutiveUnexpectedExits, 1)
    }

    // MARK: - Never Counted

    /// **Never counted is not "resets the counter".** A quit thirty seconds into a launch is not
    /// evidence that anything was fixed, so a clean quit is skipped *through* rather than treated
    /// as a clean bill of health — only `stable` is that.
    func testACleanQuitBetweenTwoCrashesIsSkippedRatherThanClearing() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, ending: .clean),
            launch("c", minute: 2, ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .firstWindowVisible)
        )
    }

    func testALogoutIsACleanEndingAndIsNeverCounted() {
        let decision = decide([
            launch("a", minute: 0, ending: .clean, systemInitiated: true),
            launch("b", minute: 1, ending: .unclean)
        ])

        XCTAssertEqual(decision.consecutiveUnexpectedExits, 1)
    }

    /// The reset relaunch. It leaves without the quit path on purpose, and counting it would make
    /// pressing Reset twice look like a crash loop.
    func testAResetRelaunchIsNeverCounted() {
        let decision = decide([
            launch("a", minute: 0, ending: .intentional(.reset)),
            launch("b", minute: 1, ending: .intentional(.reset)),
            launch("c", minute: 2, ending: .intentional(.reset))
        ])

        XCTAssertEqual(decision, .launchNormally(.available))
    }

    /// An `end` this build cannot name still means the process wrote something down on its way
    /// out, which a crash by definition did not.
    func testAnEndingThisBuildCannotNameIsNotACrash() {
        let decision = decide([
            launch("a", minute: 0, ending: .endedForUnknownReason),
            launch("b", minute: 1, ending: .endedForUnknownReason)
        ])

        XCTAssertEqual(decision, .launchNormally(.available))
    }

    /// **Skipped *through*, not stopped at.** The test above cannot tell those apart — a walk that
    /// halted on the unknown ending would answer `.launchNormally` too, for the opposite reason.
    /// This one can: a build meeting a disposition from a later Threading must not lose sight of
    /// the two crashes on either side of it.
    func testAnEndingThisBuildCannotNameDoesNotStopTheWalk() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, ending: .endedForUnknownReason),
            launch("c", minute: 2, ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .firstWindowVisible)
        )
    }

    // MARK: - Belt And Braces

    /// **A `begin` with neither an `end` nor an `outcome` is an unexpected exit.** Ordinarily the
    /// next launch tombstones it — but a successor that itself died before it could write anything
    /// leaves none, and a crash a missing record could hide is the crash worth catching.
    func testAnUntombstonedLaunchStillCountsAsACrash() {
        let decision = decide([
            launch("a", minute: 0, ending: nil),
            launch("b", minute: 1, ending: nil)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .firstWindowVisible)
        )
    }

    // MARK: - Recovery Itself

    func testARecoveryLaunchThatDiedStopsEverythingAutomatic() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, ending: .unclean),
            launch("c", minute: 2, mode: .recovery, ending: .unclean)
        ])

        XCTAssertEqual(decision, .recommendStoppingAutomaticWork(consecutive: 3))
    }

    func testARecoveryCrashStillStopsAutomaticWorkAfterAForcedNormalCrash() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, ending: .unclean),
            launch("c", minute: 2, mode: .recovery, ending: nil),
            launch("d", minute: 3, mode: .recovery, ending: .intentional(.recoveryRelaunch)),
            launch("e", minute: 4, ending: .unclean)
        ])

        XCTAssertEqual(decision, .recommendStoppingAutomaticWork(consecutive: 4))
    }

    /// **A recovery launch the user left on purpose is skipped, not counted.** Pressing "Try
    /// Normal Launch Once" ends recovery deliberately, so the forced-normal launch that follows
    /// is an ordinary launch: if *it* dies, the streak is three crashes and the answer is recovery
    /// again — never `stopAutomaticWork`, because the newest counted launch was not the recovery
    /// one. Getting this backwards would strand a user in the harder mode for a launch that
    /// behaved exactly as they asked.
    func testAForcedNormalLaunchThatDiesReadsAsAnOrdinaryCrashRatherThanRecoveryFailing() {
        let decision = decide([
            launch("a", minute: 0, ending: .unclean),
            launch("b", minute: 1, ending: .unclean),
            launch("c", minute: 2, mode: .recovery, ending: .intentional(.recoveryRelaunch)),
            launch("d", minute: 3, ending: .unclean)
        ])

        XCTAssertEqual(
            decision,
            .recommendRecoveryMode(consecutive: 3, lastCheckpoint: .firstWindowVisible)
        )
    }

    /// **`recoverySurfaceShown` is not the readiness line.** Readiness is keyed from
    /// `firstWindowVisible` alone, so a trail carrying the recovery checkpoint without it is a
    /// launch whose window never proved itself — and two of those are a loop however far apart
    /// they are, which is what `isWithinWindow` exempts. A checkpoint that also claimed readiness
    /// would make the window rule depend on which record a reader happened to look at.
    func testTheRecoveryCheckpointDoesNotClaimReadinessOnItsOwn() {
        XCTAssertFalse(StartupCheckpoint.recoverySurfaceShown.isReadiness)

        let trail: [StartupCheckpoint] = [
            .migrationDone, .themeRestored, .mainWindowConstructed, .recoverySurfaceShown
        ]
        let older = launch("a", minute: 0, checkpoints: trail, ending: .unclean)
        let newer = launch("b", minute: 90, checkpoints: trail, ending: .unclean)

        XCTAssertFalse(older.reachedReadiness)
        XCTAssertTrue(
            CrashLoopPolicy.isWithinWindow(older: older, newer: newer),
            "an hour and a half apart, and still one problem: neither launch got a window up"
        )
        XCTAssertEqual(
            decide([older, newer]),
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .recoverySurfaceShown)
        )
    }

    // MARK: - Clocks

    /// Uptime is only comparable inside one boot session, so across a reboot the wall clock is the
    /// only answer there is.
    func testTwoCrashesAcrossARebootAreComparedByTheWallClock() {
        let older = launch("a", minute: 0, boot: "boot-1", ending: .unclean)
        let newer = launch("b", minute: 2, boot: "boot-2", ending: .unclean)

        XCTAssertEqual(CrashLoopPolicy.elapsed(from: older, to: newer), 120)
        XCTAssertEqual(
            decide([older, newer]),
            .recommendRecoveryMode(consecutive: 2, lastCheckpoint: .firstWindowVisible)
        )
    }

    /// A clock stepped backwards must not be able to manufacture an escalation out of two crashes
    /// that were nowhere near each other.
    func testAClockThatMovedBackwardsIsOutsideTheWindowRatherThanInsideIt() {
        let older = launch("a", minute: 10, boot: "boot-1", ending: .unclean)
        let newer = launch("b", minute: 0, boot: "boot-2", ending: .unclean)

        XCTAssertFalse(CrashLoopPolicy.isWithinWindow(older: older, newer: newer))
        XCTAssertEqual(decide([older, newer]).consecutiveUnexpectedExits, 1)
    }

    /// A launch whose timestamp could not be parsed leaves the interval unknowable, and unknowable
    /// is treated as outside — the direction that under-reports.
    func testAnUnknowableIntervalIsOutsideTheWindow() {
        var older = launch("a", minute: 0, boot: "", ending: .unclean)
        older = LaunchLedgerLaunch(
            id: older.id,
            startedAt: nil,
            uptime: older.uptime,
            bootID: "",
            fingerprint: older.fingerprint,
            mode: .normal,
            checkpoints: older.checkpoints,
            ending: older.ending
        )
        let newer = launch("b", minute: 1, boot: "", ending: .unclean)

        XCTAssertNil(CrashLoopPolicy.elapsed(from: older, to: newer))
        XCTAssertFalse(CrashLoopPolicy.isWithinWindow(older: older, newer: newer))
    }

    // MARK: - Tokens

    /// Machine-stable and never localized: a support report is read by whoever is helping, whose
    /// language need not match the reporter's.
    func testEveryDecisionHasAStableToken() {
        XCTAssertEqual(CrashLoopDecision.launchNormally(.available).token, "normal")
        XCTAssertEqual(
            CrashLoopDecision.launchNormally(.unreadable).token,
            "normal history=unreadable"
        )
        XCTAssertEqual(
            CrashLoopDecision.noteFirstUnexpectedExit(lastCheckpoint: nil).token,
            "first-unexpected-exit"
        )
        XCTAssertEqual(
            CrashLoopDecision.recommendRecoveryMode(consecutive: 2, lastCheckpoint: nil).token,
            "recovery-recommended consecutive=2"
        )
        XCTAssertEqual(
            CrashLoopDecision.recommendStoppingAutomaticWork(consecutive: 3).token,
            "stop-automatic-work consecutive=3"
        )
    }
}
