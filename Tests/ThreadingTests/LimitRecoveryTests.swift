import XCTest
@testable import Threading

/// The tracker's limit park and the recovery policy's storage — the recovery half of
/// `limit-recovery.md`, held to its stated rules.
@MainActor
final class LimitRecoveryTests: XCTestCase {

    // MARK: - The park's two values

    /// A refusal nothing is handling is its own state: not a question the user can answer, and
    /// not work. `awaitingUser` was the first answer and it was wrong twice over — the row's
    /// filled dot promises an approval that does not exist, and the state clears on a glance.
    func testAFlaggedParkReadsLimitReached() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()

        tracker.noteLimitParked(recoveryArmed: false)

        XCTAssertEqual(tracker.activity, .limitReached)
        XCTAssertFalse(
            tracker.activity.hasTurnInFlight,
            "A refused turn is over — there is nothing left for an interruption to cost"
        )
    }

    /// An armed recovery owes the user nothing: the process sits at its prompt, the
    /// continuation is scheduled, and the sidebar says so by saying nothing.
    func testAnArmedParkReadsIdle() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()

        tracker.noteLimitParked(recoveryArmed: true)

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// The park ends the turn the missing `Stop` never closed — the stranded-spinner bug this
    /// subsystem exists to fix.
    func testTheParkEndsAStrandedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteLimitParked(recoveryArmed: false)

        XCTAssertEqual(tracker.activity, .limitReached)
        tracker.noteLimitCleared()
        XCTAssertEqual(
            tracker.activity, .idle,
            "With the park lowered nothing may re-open the refused turn"
        )
    }

    /// Work the refused turn left running cannot wake a limited agent, so the park outranks
    /// `pausedOnOwnWork` — `working` would be a lie the sidebar holds for hours.
    func testAnArmedParkOutranksWorkTheRefusedTurnLeftRunning() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(
            backgroundWork: [BackgroundTask(id: "task-1", kind: .standing)]
        )
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteLimitParked(recoveryArmed: true)

        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - What clears it

    /// A turn beginning is the limit lifting, whoever typed — the scheduled continuation
    /// landing is exactly this edge.
    func testTheParkClearsWhenATurnStarts() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteLimitParked(recoveryArmed: true)

        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .working)
    }

    /// The transcript is what lowers the park: `ObservedUsageLimit` answers nil the moment the
    /// conversation records a newer message, which is the same evidence it was raised on.
    func testTheParkLowersWhenTheRecordNoLongerEndsOnARefusal() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        tracker.noteLimitParked(recoveryArmed: false)

        tracker.noteLimitCleared()

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// Looking at a limited session does not lift its limit. Both of the CLI's own chooser
    /// options leave the account exactly as spent, so a glance that lowered the mark would draw
    /// an ordinary idle row for a session that still cannot run — the reading that started this.
    func testBeingLookedAtDoesNotLowerAFlaggedPark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        tracker.noteLimitParked(recoveryArmed: false)

        tracker.isVisible = true

        XCTAssertEqual(tracker.activity, .limitReached)
    }

    /// Nor does the CLI repainting around its chooser, which is indistinguishable from an agent
    /// carrying on and means the opposite.
    func testAVisibleOutputBurstDoesNotLowerAFlaggedPark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteLimitParked(recoveryArmed: false)
        XCTAssertEqual(tracker.activity, .limitReached)

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .limitReached)
    }

    /// A new process has no limit park; each of the lifecycle resets says so.
    func testTheProcessLifecycleResetsThePark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteLimitParked(recoveryArmed: false)

        tracker.markDormant()
        XCTAssertEqual(tracker.activity, .dormant)

        tracker.markRunning()
        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - The policy's storage

    /// The default is the quiet one: recovery is opted into, never discovered.
    func testTheDefaultPolicyFlagsAndTouchesNothing() {
        XCTAssertEqual(LimitRecoveryPolicy.default, .flagOnly)
    }

    func testThePolicyRoundTripsThroughItsStorage() {
        let original = LimitRecoverySettings.policy
        defer { LimitRecoverySettings.policy = original }

        LimitRecoverySettings.policy = .waitForReset
        XCTAssertEqual(LimitRecoveryPolicy.current, .waitForReset)

        LimitRecoverySettings.policy = .flagOnly
        XCTAssertEqual(LimitRecoveryPolicy.current, .flagOnly)
    }

    /// The hosted bundle must be writing to the scratch suite, or the round-trip above just
    /// changed what the developer's own app does with their sessions.
    func testThePolicyStorageIsRedirectedUnderTheTestHost() {
        XCTAssertTrue(PreferenceStore.isRedirected)
    }
}
