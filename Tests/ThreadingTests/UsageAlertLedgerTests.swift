import XCTest
@testable import Threading

/// What a limit rule has already said, and when it is allowed to say it again.
///
/// The two failures this guards are opposite and equally quiet. Forget too little and a relaunch
/// stays silent about next week's weekly because last week's already crossed the line; forget too
/// much and every launch re-announces a line the user was told about this morning. Neither shows
/// up anywhere but here.
@MainActor
final class UsageAlertLedgerTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var ledger: UsageAlertLedger!

    private let account = AccountID(provider: .claude, handle: .named("claude-work"))
    private let other = AccountID(provider: .claude, handle: .named("claude-personal"))
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UsageAlertLedgerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ledger = UsageAlertLedger(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func evaluation(
        rule: CustomLimit,
        resetsIn: TimeInterval,
        crossed: [Double]
    ) -> CustomLimitEvaluation {
        CustomLimitEvaluation(
            rule: rule,
            instance: CustomLimitWindowInstance(
                windowID: rule.windowID,
                resetsAt: now.addingTimeInterval(resetsIn)
            ),
            consumedOfBound: 1.0,
            windowFraction: rule.bound,
            state: .reached,
            reason: .atBound(consumedOfBound: 1.0),
            crossedThresholds: crossed
        )
    }

    // MARK: - Remembering

    /// A relaunch neither re-fires nor forgets: the record is read back through the same store the
    /// app writes it with.
    func testWhatWasAnnouncedSurvivesARelaunch() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        ledger.record(evaluation(rule: rule, resetsIn: 3 * 86_400, crossed: [1.0]), for: account)

        let reopened = UsageAlertLedger(defaults: defaults)
        let instance = CustomLimitWindowInstance(
            windowID: rule.windowID,
            resetsAt: now.addingTimeInterval(3 * 86_400)
        )
        XCTAssertEqual(
            reopened.fired(for: account)[
                CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: instance)
            ],
            [1.0]
        )
    }

    /// A rule inherited from the app-wide defaults is the *same rule id* on every login. Without
    /// the account in the key, the first account to cross 50% would silence the other four.
    func testOneAccountsCrossingDoesNotSilenceAnother() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        ledger.record(evaluation(rule: rule, resetsIn: 3 * 86_400, crossed: [1.0]), for: account)

        XCTAssertEqual(ledger.fired(for: account).count, 1)
        XCTAssertTrue(
            ledger.fired(for: other).isEmpty,
            "an app-wide rule's crossing on one login was counted against another"
        )
    }

    /// Every line stepped over is written down, not only the one announced — otherwise the line
    /// skipped in a sparse jump arrives one reading late.
    func testEveryLineCrossedIsWrittenDownAndTheyAccumulate() {
        let rule = CustomLimit.everyStep(
            windowID: UsageDefaults.weeklyWindowID,
            step: CustomLimitDefaults.tenPercentStep
        )
        ledger.record(evaluation(rule: rule, resetsIn: 86_400, crossed: [0.1, 0.2]), for: account)
        ledger.record(evaluation(rule: rule, resetsIn: 86_400, crossed: [0.3]), for: account)

        let instance = CustomLimitWindowInstance(
            windowID: rule.windowID,
            resetsAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            ledger.fired(for: account)[
                CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: instance)
            ],
            [0.1, 0.2, 0.3]
        )
    }

    // MARK: - Forgetting

    /// A reset is what re-arms a rule, and pruning is how. The dropped key is returned so the
    /// notification it posted can be withdrawn — a banner about a window that no longer exists is
    /// litter.
    func testARecordIsDroppedWhenItsWindowTurnsOver() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let past = evaluation(rule: rule, resetsIn: -60, crossed: [1.0])
        ledger.record(past, for: account)

        let dropped = ledger.prune(accountID: account, liveRuleIDs: [rule.id], now: now)

        XCTAssertEqual(dropped.count, 1)
        XCTAssertTrue(ledger.fired(for: account).isEmpty)
        XCTAssertEqual(
            dropped.first,
            UsageAlertLedger.key(
                accountID: account.rawValue,
                ruleID: rule.id,
                instance: past.instance
            ),
            "the dropped key must be the notification's own identifier, or nothing is withdrawn"
        )
    }

    /// A window still running keeps its record. Pruning that fired on the live instance would
    /// re-announce every line on the next reading.
    func testALiveWindowKeepsWhatItHasAlreadySaid() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        ledger.record(evaluation(rule: rule, resetsIn: 3 * 86_400, crossed: [1.0]), for: account)

        XCTAssertTrue(ledger.prune(accountID: account, liveRuleIDs: [rule.id], now: now).isEmpty)
        XCTAssertEqual(ledger.fired(for: account).count, 1)
    }

    /// A deleted rule takes its bookkeeping and its banner with it.
    func testDeletingARuleDropsWhatItSaid() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        ledger.record(evaluation(rule: rule, resetsIn: 3 * 86_400, crossed: [1.0]), for: account)

        let dropped = ledger.prune(accountID: account, liveRuleIDs: [], now: now)

        XCTAssertEqual(dropped.count, 1)
        XCTAssertTrue(ledger.fired(for: account).isEmpty)
    }

    // MARK: - The Two Locks

    /// The alert centre refuses to start under a hosted test bundle, and this asserts the refusal
    /// rather than trusting it.
    ///
    /// It is the second of two locks — the stores redirect to a scratch suite, and this stops the
    /// centre acting at all — and the consequence of neither is a suite that posts real
    /// notifications into the developer's own Notification Center and asks them for permission to
    /// do it. A lock nothing asserts on is a lock somebody removes while tidying.
    func testTheAlertCentreWillNotStartUnderATestBundle() {
        let centre = UsageAlertCenter(ledger: ledger)
        centre.start()

        XCTAssertFalse(centre.isStarted, "the alert centre started inside a test run")
    }

    /// And an unstarted centre writes nothing: a test that reached `evaluate` directly must not be
    /// able to leave fired thresholds behind either.
    func testAnUnstartedCentreRecordsNothing() {
        let centre = UsageAlertCenter(ledger: ledger)
        centre.evaluate(accountID: account, now: now)
        centre.evaluateAll(now: now)

        XCTAssertTrue(ledger.keys.isEmpty)
    }

    /// The redirect the other lock rests on, asserted where it is relied upon rather than only
    /// where it is defined.
    func testThePreferenceStoreIsRedirectedInThisProcess() {
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "a limit rule written through the shared stores would land in the developer's own defaults"
        )
    }

    /// Pruning is scoped to the account being evaluated.
    ///
    /// An evaluation knows the rules in force on one login and nothing about the others, so a
    /// global prune against that set had every account delete every other account's bookkeeping
    /// on each reading. The symptom is alerts re-firing at random rather than anything that reads
    /// like a bug in a ledger, which is why it is asserted rather than argued.
    func testPruningOneAccountLeavesAnotherAccountsRecordsAlone() {
        let mine = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let theirs = CustomLimit.alert(windowID: UsageDefaults.fiveHourWindowID, at: 0.9)
        ledger.record(evaluation(rule: mine, resetsIn: 3 * 86_400, crossed: [1.0]), for: account)
        ledger.record(evaluation(rule: theirs, resetsIn: 3_600, crossed: [1.0]), for: other)

        let dropped = ledger.prune(accountID: account, liveRuleIDs: [mine.id], now: now)

        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(
            ledger.fired(for: other).count,
            1,
            "evaluating one login erased another login's fired thresholds"
        )
    }

    /// A window the provider reports without a reset never prunes on time, so the map is bounded
    /// by count as well — otherwise one such window would grow this without limit.
    func testRecordsWithNoResetAreBoundedByCount() {
        let rules = (0..<(UsageAlertLedgerDefaults.maximumRecords + 5)).map { index in
            CustomLimit(windowID: "window-\(index)", bound: 0.5)
        }
        for rule in rules {
            ledger.record(
                CustomLimitEvaluation(
                    rule: rule,
                    instance: CustomLimitWindowInstance(windowID: rule.windowID, resetsAt: nil),
                    consumedOfBound: 1.0,
                    windowFraction: 0.5,
                    state: .reached,
                    reason: .atBound(consumedOfBound: 1.0),
                    crossedThresholds: [1.0]
                ),
                for: account
            )
        }

        ledger.prune(accountID: account, liveRuleIDs: Set(rules.map(\.id)), now: now)

        XCTAssertEqual(ledger.keys.count, UsageAlertLedgerDefaults.maximumRecords)
    }
}
