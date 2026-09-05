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
            tracker.runtimeSnapshot.hasOpenTurn,
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

    /// Work the refused turn left running leaves the prompt ready, then the park outranks that
    /// background continuation — a foreground `working` spinner would be a lie held for hours.
    func testAnArmedParkOutranksWorkTheRefusedTurnLeftRunning() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(
            backgroundWork: [BackgroundTask(id: "task-1", kind: .standing)]
        )
        XCTAssertEqual(tracker.activity, .readyWithBackgroundWork)

        tracker.noteLimitParked(recoveryArmed: true)

        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - What clears it

    /// A loop and a scheduled continuation both submit locally before the provider decides.
    /// Their turn-start hook may not turn a standing 429 into a working row.
    func testATurnStartDoesNotClearTheParkWithoutTranscriptEvidence() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteLimitParked(recoveryArmed: true)

        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .idle)

        tracker.noteLimitCleared()

        XCTAssertEqual(
            tracker.activity,
            .working,
            "Once the transcript moves, the already-started turn becomes visible"
        )
    }

    /// The loud park obeys the same authority boundary as an armed one. A local retry that is
    /// immediately refused must stay visibly limited rather than flash Loading.
    func testATurnStartDoesNotClearAFlaggedPark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteLimitParked(recoveryArmed: false)

        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .limitReached)
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

    // MARK: - Scoping

    /// The Settings choice is now the *last* word rather than the only one, so the global switch
    /// stays where it was for anybody who never set a chat: `current` is what the chain lands on
    /// when neither narrower scope answered.
    func testTheAppPolicyIsWhatAnUnsetChatResolvesTo() {
        withAppLimitRecovery(.waitForReset) {
            XCTAssertEqual(
                LimitRecoveryResolution.resolve(
                    session: nil, project: nil, app: LimitRecoveryPolicy.current
                ).policy,
                .waitForReset
            )
        }
    }

    /// One chat armed while the app default stays quiet — the narrow opt-in this exists for.
    func testOneChatCanBeArmedWithoutArmingTheRest() {
        withAppLimitRecovery(.flagOnly) {
            let armed = LimitRecoveryResolution.resolve(
                session: .waitForReset, project: nil, app: LimitRecoveryPolicy.current
            )
            let untouched = LimitRecoveryResolution.resolve(
                session: nil, project: nil, app: LimitRecoveryPolicy.current
            )

            XCTAssertEqual(armed.policy, .waitForReset)
            XCTAssertEqual(armed.scope, .session)
            XCTAssertEqual(untouched.policy, .flagOnly)
            XCTAssertEqual(untouched.scope, .app)
        }
    }

    // MARK: - Arming By Hand

    /// The press is refused where nothing is standing, and says so rather than typing into a
    /// session that never stopped. Reachable without an agent because the guard is the first
    /// thing the entry point does.
    func testArmingByHandWithNoRefusalStandingDoesNothing() {
        let store = LimitEscapeSuggestionStore.shared
        let sessionID = SessionID()
        XCTAssertFalse(store.hasStandingRefusal(for: sessionID))

        LimitRecoveryCoordinator.shared.armWaitForReset(for: sessionID)

        XCTAssertNil(store.offer(for: sessionID))
    }

    /// Migration is a stronger account-scope boundary than a transcript update: the copied
    /// destination is intentionally seeded nil-to-nil, so the coordinator must clear the old
    /// login's in-memory offer explicitly rather than waiting for a callback that will not fire.
    func testAccountMigrationExplicitlyClearsTheOldLoginsOffer() {
        let store = LimitEscapeSuggestionStore.shared
        let sessionID = SessionID()
        store.record(LimitEscapeSuggestion(
            sessionID: sessionID,
            resetHint: "9:40pm (Europe/Rome)",
            model: nil
        ))
        defer { store.refusalCleared(for: sessionID) }

        LimitRecoveryCoordinator.shared.accountWasMigrated(for: sessionID)

        XCTAssertNil(store.offer(for: sessionID))
    }

    /// The button's presence and the arm's own guard read one predicate, so the strip cannot
    /// offer something the code behind it would decline. A session with nothing scheduled has
    /// nothing owed.
    func testASessionWithNothingScheduledOwesNoContinuation() {
        XCTAssertFalse(
            LimitRecoveryCoordinator.hasOwedContinuation(for: SessionID())
        )
    }

    /// A reset preset the user authored is not an automatic recovery, and a recovery for one
    /// refusal cannot suppress a later refusal just because the provider repeated its words.
    func testOnlyTheSameRefusalsAutomaticContinuationCountsAsAlreadyArmed() {
        let sessionID = SessionID()
        let userPreset = ScheduledMessage(
            dueAt: Date().addingTimeInterval(3_600),
            target: .session(sessionID),
            text: "Do the next task",
            anchor: .usageWindowReset(windowID: "7d")
        )
        let recovery = ScheduledMessage(
            dueAt: Date().addingTimeInterval(3_600),
            target: .session(sessionID),
            text: "continue",
            anchor: .usageWindowReset(windowID: "7d"),
            purpose: .limitRecovery,
            limitRecoveryRecordID: "refusal-one"
        )

        XCTAssertFalse(
            LimitRecoveryCoordinator.recoveryContinuationAlreadyArmed(
                in: [userPreset],
                forRefusalRecordID: "refusal-one"
            )
        )
        XCTAssertTrue(
            LimitRecoveryCoordinator.recoveryContinuationAlreadyArmed(
                in: [userPreset, recovery],
                forRefusalRecordID: "refusal-one"
            )
        )
        XCTAssertFalse(
            LimitRecoveryCoordinator.recoveryContinuationAlreadyArmed(
                in: [userPreset, recovery],
                forRefusalRecordID: "refusal-two"
            )
        )
    }

    /// The usage service keeps a last-good value for the dashboard after a fetch failure. That is
    /// good display state and unsafe scheduling state: recovery must not turn it into another
    /// overnight continuation against the wrong window.
    func testRecoveryRefusesAStaleUsageReading() {
        let usage = AccountUsage(
            windows: [],
            planLabel: nil,
            observedAt: Date(),
            source: .api
        )

        XCTAssertEqual(
            LimitRecoveryCoordinator.settledUsageForRecovery(from: .current(usage)),
            usage
        )
        XCTAssertNil(
            LimitRecoveryCoordinator.settledUsageForRecovery(
                from: .stale(usage, error: .network("offline"))
            )
        )
        XCTAssertNil(
            LimitRecoveryCoordinator.settledUsageForRecovery(
                from: .failed(.network("offline"))
            )
        )
    }

    /// Seeds the app-scope answer without announcing a settings change.
    ///
    /// Written straight to the preference rather than through `LimitRecoverySettings.policy`,
    /// whose setter posts `AppSettingsDidChange` into whatever observers the test host has live —
    /// `SidebarTreeBuilderTests` writes `UserDefaults` directly for exactly this reason, and a
    /// sidebar controller left alive by an earlier case will act on the broadcast.
    private func withAppLimitRecovery(
        _ policy: LimitRecoveryPolicy,
        run: () throws -> Void
    ) rethrows {
        PreferenceStore.shared.set(policy.rawValue, forKey: LimitRecoverySettings.storageKey)
        defer { PreferenceStore.shared.removeObject(forKey: LimitRecoverySettings.storageKey) }
        try run()
    }
}
