import XCTest
@testable import Threading

/// How a launch decides which mode it is in, and what that mode lets it start.
///
/// Both halves are pure, which is the point: two of the resolver's four inputs are a held modifier
/// key and a crash history, neither of which anybody can stage on demand, and the plan is what
/// twenty call sites in `applicationDidFinishLaunching` read instead of testing the mode
/// themselves. A table is the only place either is ever checked.
final class LaunchModeResolverTests: XCTestCase {

    // MARK: - Fixture

    private let crashLoop = CrashLoopDecision.recommendRecoveryMode(
        consecutive: 2,
        lastCheckpoint: .themeRestored
    )
    private let recoveryDied = CrashLoopDecision.recommendStoppingAutomaticWork(consecutive: 3)

    private func resolve(
        decision: CrashLoopDecision = .launchNormally(.available),
        optionHeld: Bool = false,
        arguments: [String] = ["/Applications/Threading.app/Contents/MacOS/Threading"],
        forceNormalOnce: Bool = false
    ) -> LaunchModeResolution {
        LaunchModeResolver.resolve(
            decision: decision,
            optionHeld: optionHeld,
            arguments: arguments,
            forceNormalOnce: forceNormalOnce
        )
    }

    // MARK: - The Automatic Path

    func testAnOrdinaryHistoryLaunchesNormally() {
        XCTAssertEqual(resolve(), .normalLaunch)
    }

    /// One crash is noted and no more: everything crashes once, and a mode that appeared the first
    /// time anything went wrong would be one nobody trusted the second time.
    func testOneUnexpectedExitDoesNotEnterRecovery() {
        let resolution = resolve(decision: .noteFirstUnexpectedExit(lastCheckpoint: .themeRestored))
        XCTAssertEqual(resolution, .normalLaunch)
    }

    func testARecommendedRecoveryEntersItAndSaysWhy() {
        XCTAssertEqual(
            resolve(decision: crashLoop),
            LaunchModeResolution(mode: .recovery, reason: .crashLoop)
        )
    }

    /// **The harder verdict enters the same mode.** The only thing stronger than recovery is to
    /// start less, and recovery already starts nothing; what changes is the sentence on screen,
    /// which is what the reason carries.
    func testARecoveryLaunchThatDiedEntersRecoveryWithTheHarderReason() {
        XCTAssertEqual(
            resolve(decision: recoveryDied),
            LaunchModeResolution(mode: .recovery, reason: .recoveryLaunchFailed)
        )
    }

    // MARK: - The Manual Paths

    func testTheCommandLineFlagEntersRecovery() {
        XCTAssertEqual(
            resolve(arguments: ["Threading", "--recovery-mode"]),
            LaunchModeResolution(mode: .recovery, reason: .commandLineFlag)
        )
    }

    func testHoldingOptionEntersRecovery() {
        XCTAssertEqual(
            resolve(optionHeld: true),
            LaunchModeResolution(mode: .recovery, reason: .optionKeyHeld)
        )
    }

    /// **Both manual paths work when the ledger cannot be read at all.** That is most of why they
    /// exist: a damaged or newer-format history stands the policy down to `launchNormally`, and
    /// the mode a person asks for out loud must not depend on a file being parseable.
    func testTheManualPathsWorkOnAHistoryThePolicyCouldNotRead() {
        for availability in [HistoryAvailability.unreadable, .partial] {
            let decision = CrashLoopDecision.launchNormally(availability)
            XCTAssertEqual(
                resolve(decision: decision, arguments: ["Threading", "--recovery-mode"]).mode,
                .recovery,
                "the flag stopped working on a \(availability.rawValue) history"
            )
            XCTAssertEqual(
                resolve(decision: decision, optionHeld: true).mode,
                .recovery,
                "Option stopped working on a \(availability.rawValue) history"
            )
        }
    }

    // MARK: - Precedence

    /// **The load-bearing ordering.** Without it, the decision that put the user into recovery
    /// would immediately overrule the button they pressed to leave it, and "Try Normal Launch
    /// Once" would be inert.
    func testTheOneShotBeatsTheCrashLoopDecision() {
        XCTAssertEqual(
            resolve(decision: crashLoop, forceNormalOnce: true),
            LaunchModeResolution(mode: .normal, reason: .forcedNormal)
        )
        XCTAssertEqual(
            resolve(decision: recoveryDied, forceNormalOnce: true),
            LaunchModeResolution(mode: .normal, reason: .forcedNormal)
        )
    }

    /// Somebody is standing there asking. A one-shot armed yesterday does not get to overrule it.
    func testAnExplicitRequestBeatsTheOneShot() {
        XCTAssertEqual(
            resolve(optionHeld: true, forceNormalOnce: true),
            LaunchModeResolution(mode: .recovery, reason: .optionKeyHeld)
        )
        XCTAssertEqual(
            resolve(arguments: ["Threading", "--recovery-mode"], forceNormalOnce: true),
            LaunchModeResolution(mode: .recovery, reason: .commandLineFlag)
        )
    }

    /// The flag outranks the key, so a machine that reproduces the mode on demand cannot be
    /// defeated by something resting on a keyboard.
    func testTheCommandLineFlagOutranksAHeldOptionKey() {
        XCTAssertEqual(
            resolve(optionHeld: true, arguments: ["Threading", "--recovery-mode"]).reason,
            .commandLineFlag
        )
    }

    // MARK: - The Plan

    private func plan(
        _ resolution: LaunchModeResolution,
        decision: CrashLoopDecision = .launchNormally(.available),
        extensionsDisabledOnce: Bool = false,
        needsOnboarding: Bool = false
    ) -> LaunchPlan {
        LaunchPlan(
            resolution: resolution,
            decision: decision,
            extensionsDisabledOnce: extensionsDisabledOnce,
            needsOnboarding: needsOnboarding
        )
    }

    func testANormalLaunchStartsEverything() {
        let plan = plan(.normalLaunch, needsOnboarding: true)

        XCTAssertTrue(plan.runsLegacyMigration)
        XCTAssertTrue(plan.startsExtensions)
        XCTAssertTrue(plan.startsMCPListener)
        XCTAssertTrue(plan.startsBackgroundServices)
        XCTAssertTrue(plan.showsOnboarding)
        XCTAssertTrue(plan.restoresWorkspace)
        XCTAssertTrue(plan.armsStabilityCheckpoint)
        XCTAssertTrue(plan.allowsStateWrites)
        XCTAssertTrue(plan.recordsRunningSessionsOnQuit)
    }

    func testARecoveryLaunchStartsNoneOfIt() {
        let plan = plan(
            LaunchModeResolution(mode: .recovery, reason: .crashLoop),
            decision: crashLoop,
            needsOnboarding: true
        )

        XCTAssertFalse(plan.startsExtensions)
        XCTAssertFalse(plan.startsMCPListener)
        XCTAssertFalse(plan.startsBackgroundServices)
        XCTAssertFalse(plan.restoresWorkspace)
        XCTAssertFalse(plan.allowsStateWrites)
        XCTAssertTrue(plan.isRecovery)
    }

    /// Recovery wins over a first launch. The completion flag is untouched, so the walkthrough
    /// returns on the next normal launch rather than being lost to a crash loop.
    func testRecoveryDoesNotRunTheWalkthrough() {
        let plan = plan(
            LaunchModeResolution(mode: .recovery, reason: .crashLoop),
            decision: crashLoop,
            needsOnboarding: true
        )
        XCTAssertFalse(plan.showsOnboarding)
    }

    /// `stable` is a claim that the app works, and a launch that started nothing has not made it.
    /// Arming it would mean ten minutes in recovery erases the count that put the user there.
    func testRecoveryDoesNotArmTheStabilityCheckpoint() {
        let plan = plan(
            LaunchModeResolution(mode: .recovery, reason: .crashLoop),
            decision: crashLoop
        )
        XCTAssertFalse(plan.armsStabilityCheckpoint)
    }

    /// **The migration is weighed, not refused.** An empty sidebar after the rename reads as data
    /// loss, which is the worst possible message on a crash screen — so it runs unless the ledger
    /// says the launches that died never reached `migrationDone`, which is the one shape of
    /// evidence that makes the adoption itself the suspect.
    func testRecoveryRunsTheMigrationUnlessTheLaunchesDiedBeforeIt() {
        let recovery = LaunchModeResolution(mode: .recovery, reason: .crashLoop)

        XCTAssertTrue(
            plan(recovery, decision: crashLoop).runsLegacyMigration,
            "a launch that recorded a checkpoint got past the adoption"
        )
        XCTAssertFalse(
            plan(
                recovery,
                decision: .recommendRecoveryMode(consecutive: 2, lastCheckpoint: nil)
            ).runsLegacyMigration,
            "a launch that recorded nothing at all never reached the adoption"
        )
        XCTAssertTrue(
            plan(.normalLaunch, decision: .recommendRecoveryMode(consecutive: 2, lastCheckpoint: nil))
                .runsLegacyMigration,
            "only recovery ever declines the adoption"
        )
    }

    /// The second one-shot, and the only plan difference between it and an ordinary launch.
    func testTheExtensionsOneShotOnlyStopsExtensions() {
        let plan = plan(.normalLaunch, extensionsDisabledOnce: true)

        XCTAssertFalse(plan.startsExtensions)
        XCTAssertTrue(plan.startsMCPListener)
        XCTAssertTrue(plan.startsBackgroundServices)
        XCTAssertTrue(plan.restoresWorkspace)
        XCTAssertTrue(plan.allowsStateWrites)
    }
}
