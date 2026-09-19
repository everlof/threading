import XCTest

@testable import Threading

/// The curfew's model, its stored shapes, its window arithmetic and the chain that decides which
/// of them governs one conversation.
///
/// All of it pure, which is the point of these types being separate from the engine that drives
/// them: this is the rule that stops Threading spending somebody's session and, past the grace,
/// types into it. It should be assertable with no home directory, no database and no live agent —
/// and the two nights a year that break wall-clock arithmetic should be a test rather than a
/// support thread from somebody whose 04:00 curfew fired at 03:00.
@MainActor
final class SessionCurfewModelTests: XCTestCase {

    // MARK: - Fixture

    /// One scratch suite for the whole class, cleared at both ends.
    ///
    /// A fresh suite per test *method* is the obvious shape and the wrong one: each is a real
    /// preferences domain the daemon then holds, and `scripts/test.sh` sweeps them afterwards
    /// precisely because they accumulate. Clearing in `setUp` as well as `tearDown` buys the
    /// same isolation — a crashed test's leftovers are gone before the next one reads
    /// anything — at one domain instead of a dozen.
    private var suiteName = ""
    private var defaults: UserDefaults!

    /// A fixed clock convention, so an assertion reads the same on a machine set to Swedish and
    /// on one set to English. The expectations are composed through the same helper the code
    /// uses, which is also what keeps them honest about the reader's own time zone.
    private let locale = Locale(identifier: "en_US_POSIX")

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SessionCurfewModelTests"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func calendar(_ timeZone: String = "Europe/Stockholm") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func preferences(
        quietHours: QuietHours = .default,
        windDownMargin: TimeInterval? = CurfewDefaults.windDownMargin,
        grace: TimeInterval? = CurfewDefaults.grace
    ) -> CurfewPreferences {
        CurfewPreferences(
            windDownMargin: windDownMargin,
            grace: grace,
            windDownText: CurfewDefaults.windDownText,
            quietHours: quietHours
        )
    }

    private func nightly(from startMinute: Int, to endMinute: Int) -> QuietHours {
        QuietHours(isEnabled: true, startMinute: startMinute, endMinute: endMinute)
    }

    private func time(_ date: Date) -> String {
        ScheduledTimePresets.time(date, locale: locale)
    }

    // MARK: - The Rule On Disk

    func testARuleRoundTripsThroughItsStoredForm() throws {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let accountID = AccountID(provider: .codex, handle: .standard)

        for rule in [
            CurfewRule.exempt,
            CurfewRule.atUsage(percent: 73, armedAt: deadline, accountID: accountID, windowID: "7d"),
            CurfewRule.until(deadline),
            CurfewRule.untilUsageReset(
                expectedAt: deadline,
                armedAt: deadline.addingTimeInterval(-3_600),
                accountID: accountID,
                windowID: UsageDefaults.weeklyWindowID
            ),
        ] {
            let data = try JSONEncoder().encode(rule)
            XCTAssertEqual(try JSONDecoder().decode(CurfewRule.self, from: data), rule)
        }
    }

    func testAStoredKindThisBuildDoesNotKnowReadsAsNeverChose() {
        XCTAssertNil(
            CurfewRule(stored: CurfewRule.Stored(kind: "hibernate", deadline: nil)),
            "an unreadable kind must read as inherit, never throw the record away"
        )
    }

    func testAnUntilWithNoDeadlineIsUnreadableRatherThanForever() {
        XCTAssertNil(CurfewRule(stored: CurfewRule.Stored(kind: "until", deadline: nil)))
    }

    func testTheStoredFormNamesItsKindAsAReadableString() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)

        XCTAssertEqual(CurfewRule.exempt.stored.kind, CurfewRule.Kind.exempt.rawValue)
        XCTAssertNil(CurfewRule.exempt.stored.deadline)
        XCTAssertEqual(CurfewRule.until(deadline).stored.deadline, deadline)
        XCTAssertEqual(CurfewRule.until(deadline).deadline, deadline)
    }

    // MARK: - Receipts

    func testAReceiptWithAnUnknownEventIsDroppedAndTheRestOfTheLogSurvives() throws {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        var state = SessionCurfewState(deadline: deadline, origin: .session)
        state.record(.held, at: deadline)
        state.record(.lifted, at: deadline.addingTimeInterval(60))

        // Written through the real encoder, then one entry a later build might have written is
        // spliced in: the point is a log this build reads *around*, not a fixture of its own.
        let encoded = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var receipts = try XCTUnwrap(object["receipts"] as? [[String: Any]])
        let unknown: [String: Any] = ["event": "teleported", "at": receipts[0]["at"] ?? 0]
        receipts.insert(unknown, at: 1)
        object["receipts"] = receipts

        let decoded = try JSONDecoder().decode(
            SessionCurfewState.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(
            decoded.receipts.map(\.event),
            [.held, .lifted],
            "one unreadable line must not cost the whole log, and with it the fence"
        )
        XCTAssertEqual(decoded.deadline, state.deadline)
    }

    func testTheReceiptLogDropsTheOldestOnceItIsFull() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        var state = SessionCurfewState(deadline: deadline, origin: .session)

        for index in 0 ... CurfewDefaults.maximumReceipts {
            state.record(
                index == 0 ? .windDownSent : .held,
                at: deadline.addingTimeInterval(TimeInterval(index))
            )
        }

        XCTAssertEqual(state.receipts.count, CurfewDefaults.maximumReceipts)
        XCTAssertFalse(
            state.has(.windDownSent),
            "the cap drops the oldest — the strip is asking what happened most recently"
        )
        XCTAssertEqual(state.receipts.first?.at, deadline.addingTimeInterval(1))
    }

    func testAnInterruptReceiptCarriesItsMomentIntoTheStateTheSpacingGateReads() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        var state = SessionCurfewState(deadline: deadline, origin: .session)
        let interruptedAt = deadline.addingTimeInterval(CurfewDefaults.grace)

        state.record(.held, at: deadline)
        XCTAssertNil(state.lastInterruptAt)

        state.record(.interrupted, at: interruptedAt)

        XCTAssertEqual(state.lastInterruptAt, interruptedAt)
        XCTAssertTrue(state.has(.interrupted))
        XCTAssertEqual(state.momentOf(.held), deadline)
    }

    // MARK: - Quiet Hours: The Window Containing Now

    func testAWindowContainsTheMomentsInsideItAndNotTheOnesOutside() {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)

        let inside = date(2026, 8, 10, 5, 0, in: calendar)
        let window = hours.window(containing: inside, calendar: calendar)

        XCTAssertEqual(window?.start, date(2026, 8, 10, 4, 0, in: calendar))
        XCTAssertEqual(window?.end, date(2026, 8, 10, 8, 0, in: calendar))
        XCTAssertNil(hours.window(containing: date(2026, 8, 10, 9, 0, in: calendar), calendar: calendar))
        XCTAssertNil(hours.window(containing: date(2026, 8, 10, 2, 0, in: calendar), calendar: calendar))
    }

    /// Half-open, and deliberately: the end is the moment the curfew lifts, so a session that is
    /// still inside it at 08:00 would be held one evaluation longer than its owner asked for,
    /// every single night.
    func testTheWindowHoldsAtItsStartAndIsAlreadyOverAtItsEnd() {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)

        XCTAssertNotNil(
            hours.window(containing: date(2026, 8, 10, 4, 0, in: calendar), calendar: calendar)
        )
        XCTAssertNil(
            hours.window(containing: date(2026, 8, 10, 8, 0, in: calendar), calendar: calendar)
        )
    }

    func testAWindowThatCrossesMidnightIsOneWindowFromBothSidesOfIt() {
        let calendar = calendar()
        let hours = nightly(from: 23 * 60, to: 7 * 60)
        let start = date(2026, 8, 10, 23, 0, in: calendar)
        let end = date(2026, 8, 11, 7, 0, in: calendar)

        let beforeMidnight = hours.window(
            containing: date(2026, 8, 10, 23, 30, in: calendar),
            calendar: calendar
        )
        let afterMidnight = hours.window(
            containing: date(2026, 8, 11, 2, 0, in: calendar),
            calendar: calendar
        )

        XCTAssertEqual(beforeMidnight?.start, start)
        XCTAssertEqual(beforeMidnight?.end, end)
        XCTAssertEqual(
            afterMidnight,
            beforeMidnight,
            "02:00 belongs to the window that began yesterday, not to tonight's"
        )
    }

    func testADisabledWindowAnswersNothingAtAll() {
        let calendar = calendar()
        let hours = QuietHours(isEnabled: false, startMinute: 4 * 60, endMinute: 8 * 60)
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        XCTAssertNil(hours.window(containing: now, calendar: calendar))
        XCTAssertNil(hours.nextWindow(after: now, calendar: calendar))
    }

    // MARK: - Quiet Hours: Daylight Saving

    /// 29 March 2026 is when Europe/Stockholm loses an hour. A window built by adding 86,400
    /// seconds — or 480 minutes — to yesterday's start ends at 08:00 instead of 07:00, on
    /// exactly the night somebody set an overnight curfew for.
    func testAWindowAcrossTheSpringForwardNightKeepsItsWallClockEnds() throws {
        let calendar = calendar()
        let hours = nightly(from: 23 * 60, to: 7 * 60)
        let now = date(2026, 3, 29, 3, 30, in: calendar)

        let window = try XCTUnwrap(hours.window(containing: now, calendar: calendar))

        XCTAssertEqual(window.start, date(2026, 3, 28, 23, 0, in: calendar))
        XCTAssertEqual(window.end, date(2026, 3, 29, 7, 0, in: calendar))
        XCTAssertEqual(
            window.duration,
            7 * 60 * 60,
            accuracy: 1,
            "the night is an hour short — the clock is what the rule is written in"
        )
    }

    /// 25 October 2026: the day Stockholm gains an hour, and the same window is nine hours long.
    func testAWindowAcrossTheFallBackNightKeepsItsWallClockEnds() throws {
        let calendar = calendar()
        let hours = nightly(from: 23 * 60, to: 7 * 60)
        let now = date(2026, 10, 25, 6, 0, in: calendar)

        let window = try XCTUnwrap(hours.window(containing: now, calendar: calendar))

        XCTAssertEqual(window.start, date(2026, 10, 24, 23, 0, in: calendar))
        XCTAssertEqual(window.end, date(2026, 10, 25, 7, 0, in: calendar))
        XCTAssertEqual(window.duration, 9 * 60 * 60, accuracy: 1)
    }

    /// A start the clock skips over. `matchingPolicy: .nextTime` answers with the first moment
    /// that does exist rather than losing the night, which is what `date(from:)` on a missing
    /// component is entitled to do.
    func testAWindowWhoseStartDoesNotExistThatNightStillOpens() throws {
        let calendar = calendar()
        let hours = nightly(from: 2 * 60 + 30, to: 8 * 60)
        let now = date(2026, 3, 29, 5, 0, in: calendar)

        let window = try XCTUnwrap(hours.window(containing: now, calendar: calendar))

        XCTAssertTrue(calendar.isDate(window.start, inSameDayAs: now))
        XCTAssertGreaterThanOrEqual(window.start, date(2026, 3, 29, 3, 0, in: calendar))
        XCTAssertEqual(window.end, date(2026, 3, 29, 8, 0, in: calendar))
    }

    /// Both readings are in Stockholm's missing hour. Foundation resolves each to 03:00; that
    /// collision must shorten neither the configured half hour nor the list of nightly windows.
    func testAWindowWhoseTwoEndsCollapseInTheSpringForwardGapKeepsItsSpan() throws {
        let calendar = calendar()
        let hours = nightly(from: 2 * 60, to: 2 * 60 + 30)
        let before = date(2026, 3, 29, 0, 30, in: calendar)
        let inside = date(2026, 3, 29, 3, 15, in: calendar)

        let standing = try XCTUnwrap(hours.window(containing: inside, calendar: calendar))

        XCTAssertEqual(standing.start, date(2026, 3, 29, 3, 0, in: calendar))
        XCTAssertEqual(standing.end, date(2026, 3, 29, 3, 30, in: calendar))
        XCTAssertEqual(standing.duration, 30 * 60, accuracy: 1)
        XCTAssertEqual(
            hours.nextWindow(after: before, calendar: calendar),
            standing,
            "the transition-night window must remain armable before it opens"
        )
    }

    // MARK: - Quiet Hours: The Next Window

    func testTheNextWindowIsTodaysWhileItIsStillAhead() {
        let calendar = calendar()
        let hours = nightly(from: 23 * 60, to: 7 * 60)

        let next = hours.nextWindow(
            after: date(2026, 8, 10, 12, 0, in: calendar),
            calendar: calendar
        )

        XCTAssertEqual(next?.start, date(2026, 8, 10, 23, 0, in: calendar))
        XCTAssertEqual(next?.end, date(2026, 8, 11, 7, 0, in: calendar))
    }

    func testTheNextWindowIsTomorrowsOnceTodaysHasOpened() {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)

        let next = hours.nextWindow(
            after: date(2026, 8, 10, 9, 0, in: calendar),
            calendar: calendar
        )

        XCTAssertEqual(next?.start, date(2026, 8, 11, 4, 0, in: calendar))
    }

    func testTheNextWindowIsNeverTheOneAlreadyStanding() {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)
        let inside = date(2026, 8, 10, 5, 0, in: calendar)

        XCTAssertEqual(
            hours.nextWindow(after: inside, calendar: calendar)?.start,
            date(2026, 8, 11, 4, 0, in: calendar),
            "a caller that got nothing from window(containing:) wants one to arm for"
        )
    }

    // MARK: - The Resolution Chain

    func testASessionsExemptionBeatsItsProjectAndTheStandingWindow() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: .exempt,
            project: .exempt,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            state: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(answer.scope, .session)
        XCTAssertNil(answer.curfew)
    }

    func testASessionsOwnDeadlineBeatsEverythingElse() throws {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)
        let deadline = date(2026, 8, 10, 22, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: .until(deadline),
            project: .exempt,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            state: nil,
            now: now,
            calendar: calendar
        )

        let curfew = try XCTUnwrap(answer.curfew)
        XCTAssertEqual(answer.scope, .session)
        XCTAssertEqual(curfew.deadline, deadline)
        XCTAssertEqual(curfew.origin, .session)
        XCTAssertNil(curfew.endsAt, "a curfew the user set is lifted explicitly or not at all")
    }

    func testAUsageResetRuleKeepsItsSelectedWindowAndMovesOnlyForMatchingEvidence() throws {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)
        let expectedAt = date(2026, 8, 15, 4, 0, in: calendar)
        let armedAt = date(2026, 8, 10, 4, 30, in: calendar)
        let detectedAt = date(2026, 8, 11, 2, 0, in: calendar)
        let accountID = AccountID(provider: .codex, handle: .standard)
        let rule = CurfewRule.untilUsageReset(
            expectedAt: expectedAt,
            armedAt: armedAt,
            accountID: accountID,
            windowID: UsageDefaults.weeklyWindowID
        )

        let waiting = CurfewResolution.resolve(
            session: rule,
            project: nil,
            preferences: preferences(),
            state: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(waiting.curfew?.deadline, expectedAt)
        XCTAssertEqual(
            waiting.condition,
            .usageReset(
                expectedAt: expectedAt,
                armedAt: armedAt,
                accountID: accountID,
                windowID: UsageDefaults.weeklyWindowID
            )
        )

        let sparkState = SessionCurfewState(
            deadline: detectedAt,
            origin: .usageReset(
                armedAt: armedAt,
                accountID: accountID,
                windowID: UsageDefaults.fiveHourWindowID
            )
        )
        let afterSpark = CurfewResolution.resolve(
            session: rule,
            project: nil,
            preferences: preferences(),
            state: sparkState,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(
            afterSpark.curfew?.deadline,
            expectedAt,
            "5h/Spark evidence moved a rule armed for the 7d window"
        )

        let weeklyState = SessionCurfewState(
            deadline: detectedAt,
            origin: .usageReset(
                armedAt: armedAt,
                accountID: accountID,
                windowID: UsageDefaults.weeklyWindowID
            )
        )
        let afterWeekly = CurfewResolution.resolve(
            session: rule,
            project: nil,
            preferences: preferences(),
            state: weeklyState,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(afterWeekly.curfew?.deadline, detectedAt)
        XCTAssertNil(
            afterWeekly.curfew?.windDownAt,
            "detecting the reset must not spend newly restored usage on a wrap-up"
        )
    }

    func testAProjectsExemptionBeatsTheStandingWindow() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: nil,
            project: .exempt,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            state: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(answer.scope, .project)
        XCTAssertNil(answer.curfew)
    }

    func testNobodyHasAnsweredAndTheWindowIsOffMeansNoCurfewAtAll() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(),
            state: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(answer.scope, .app)
        XCTAssertNil(answer.curfew)
    }

    func testInsideTheStandingWindowTheAppScopeAnswersWithItsOwnStartAndEnd() throws {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            state: nil,
            now: now,
            calendar: calendar
        )

        let curfew = try XCTUnwrap(answer.curfew)
        XCTAssertEqual(answer.scope, .app)
        XCTAssertEqual(curfew.deadline, date(2026, 8, 10, 4, 0, in: calendar))
        XCTAssertEqual(curfew.origin, .quietHours(endsAt: date(2026, 8, 10, 8, 0, in: calendar)))
        XCTAssertEqual(curfew.endsAt, date(2026, 8, 10, 8, 0, in: calendar))
    }

    func testOutsideTheStandingWindowTheAnswerIsTheNextOne() throws {
        let calendar = calendar()
        let now = date(2026, 8, 10, 12, 0, in: calendar)

        let answer = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            state: nil,
            now: now,
            calendar: calendar
        )

        let curfew = try XCTUnwrap(answer.curfew)
        XCTAssertEqual(curfew.deadline, date(2026, 8, 11, 4, 0, in: calendar))
        XCTAssertEqual(curfew.endsAt, date(2026, 8, 11, 8, 0, in: calendar))
    }

    // MARK: - Lifting Tonight's Window

    func testALiftedQuietHoursInstanceStaysLiftedUntilItsWindowCloses() {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)
        let start = date(2026, 8, 10, 4, 0, in: calendar)
        var state = SessionCurfewState(
            deadline: start,
            origin: .quietHours(endsAt: date(2026, 8, 10, 8, 0, in: calendar))
        )
        state.liftedAt = date(2026, 8, 10, 4, 30, in: calendar)
        state.record(.lifted, at: date(2026, 8, 10, 4, 30, in: calendar))

        let answer = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(quietHours: hours),
            state: state,
            now: date(2026, 8, 10, 5, 0, in: calendar),
            calendar: calendar
        )

        XCTAssertNil(answer.curfew)
        XCTAssertEqual(answer.scope, .app)
    }

    func testALiftedInstanceDoesNotExemptTheNightAfterIt() throws {
        let calendar = calendar()
        let hours = nightly(from: 4 * 60, to: 8 * 60)
        let start = date(2026, 8, 10, 4, 0, in: calendar)
        var state = SessionCurfewState(
            deadline: start,
            origin: .quietHours(endsAt: date(2026, 8, 10, 8, 0, in: calendar))
        )
        state.liftedAt = date(2026, 8, 10, 4, 30, in: calendar)

        let sameMorning = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(quietHours: hours),
            state: state,
            now: date(2026, 8, 10, 9, 0, in: calendar),
            calendar: calendar
        )
        let nextNight = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences(quietHours: hours),
            state: state,
            now: date(2026, 8, 11, 5, 0, in: calendar),
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(sameMorning.curfew).deadline,
            date(2026, 8, 11, 4, 0, in: calendar),
            "once the window has closed the session is arming for the next one"
        )
        XCTAssertEqual(
            try XCTUnwrap(nextNight.curfew).deadline,
            date(2026, 8, 11, 4, 0, in: calendar),
            "\"not tonight\" is not \"never\""
        )
    }

    // MARK: - What A Deadline Implies

    func testTheThreeMomentsFollowFromTheDeadlineAndTheMargins() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .quietHours(endsAt: date(2026, 8, 10, 8, 0, in: calendar)),
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )

        XCTAssertEqual(curfew.windDownAt, date(2026, 8, 10, 3, 50, in: calendar))
        XCTAssertEqual(curfew.interruptAt, date(2026, 8, 10, 4, 5, in: calendar))
        XCTAssertEqual(curfew.windDownDeliverableUntil, date(2026, 8, 10, 4, 15, in: calendar))
        XCTAssertEqual(curfew.endsAt, date(2026, 8, 10, 8, 0, in: calendar))
    }

    func testNoGraceMeansNothingIsEverTypedAndTheWrapUpWindowShrinksToIt() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: nil,
            windDownText: CurfewDefaults.windDownText
        )

        XCTAssertNil(curfew.interruptAt)
        XCTAssertEqual(curfew.windDownAt, date(2026, 8, 10, 3, 50, in: calendar))
        XCTAssertEqual(curfew.windDownDeliverableUntil, date(2026, 8, 10, 4, 10, in: calendar))
    }

    func testNoWindDownMarginMeansNoWrapUpAndNoWindowPastTheGrace() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: nil,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )

        XCTAssertNil(curfew.windDownAt)
        XCTAssertEqual(curfew.interruptAt, date(2026, 8, 10, 4, 5, in: calendar))
        XCTAssertEqual(curfew.windDownDeliverableUntil, date(2026, 8, 10, 4, 5, in: calendar))
    }

    // MARK: - What A Record Would Follow

    func testWhatASessionWouldFollowIsResolutionWithItsOwnLevelRemoved() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)
        let standing = preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60))

        for project in [CurfewRule.exempt, nil] {
            XCTAssertEqual(
                CurfewResolution.inherited(
                    beyond: .session,
                    project: project,
                    preferences: standing,
                    now: now,
                    calendar: calendar
                ),
                CurfewResolution.resolve(
                    session: nil,
                    project: project,
                    preferences: standing,
                    state: nil,
                    now: now,
                    calendar: calendar
                ).curfew,
                "the menu's Inherit label and the writer that compares against it are one rule"
            )
        }
    }

    func testWhatAProjectWouldFollowIgnoresItsOwnAnswer() throws {
        let calendar = calendar()
        let now = date(2026, 8, 10, 5, 0, in: calendar)

        let inherited = CurfewResolution.inherited(
            beyond: .project,
            project: .exempt,
            preferences: preferences(quietHours: nightly(from: 4 * 60, to: 8 * 60)),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(inherited).deadline,
            date(2026, 8, 10, 4, 0, in: calendar)
        )
    }

    // MARK: - Settings

    func testPreferencesPersistThroughTheirOwnStore() throws {
        let settings = CurfewSettings(defaults: defaults)
        var updated = settings.preferences
        updated.windDownMargin = 30 * 60
        updated.grace = nil
        updated.quietHours = nightly(from: 23 * 60, to: 7 * 60)

        settings.preferences = updated

        let reopened = CurfewSettings(defaults: defaults)
        XCTAssertEqual(reopened.preferences, updated)
        XCTAssertEqual(reopened.preferences.grace, nil, "never-interrupt is a choice, not a gap")
    }

    func testTheDefaultsAreTheLadderTheFeatureWasDesignedAround() {
        let settings = CurfewSettings(defaults: defaults)

        XCTAssertEqual(settings.preferences.windDownMargin, CurfewDefaults.windDownMargin)
        XCTAssertEqual(settings.preferences.grace, CurfewDefaults.grace)
        XCTAssertFalse(settings.preferences.quietHours.isEnabled)
        XCTAssertEqual(
            settings.preferences.quietHours.startMinute,
            CurfewDefaults.quietHoursStartMinute
        )
        XCTAssertTrue(
            settings.preferences.windDownText.contains(CurfewDefaults.timePlaceholder),
            "a template with no placeholder is a wrap-up that never names the time"
        )
    }

    /// Refused rather than clamped. A margin quietly rounded to the nearest offered choice would
    /// be a setting that does not say what it does, and this one decides when the app stops
    /// spending somebody's session.
    func testAnInvalidPreferenceIsRefusedAndLeavesTheStoredOneStanding() {
        let settings = CurfewSettings(defaults: defaults)
        let original = settings.preferences

        var offScale = original
        offScale.windDownMargin = 7
        settings.preferences = offScale
        XCTAssertEqual(settings.preferences, original)

        var noText = original
        noText.windDownText = "   "
        settings.preferences = noText
        XCTAssertEqual(settings.preferences, original)

        var hugeText = original
        hugeText.windDownText = String(
            repeating: "x",
            count: CurfewDefaults.maximumWindDownTextBytes + 1
        )
        settings.preferences = hugeText
        XCTAssertEqual(settings.preferences, original)

        var impossibleHour = original
        impossibleHour.quietHours = QuietHours(
            isEnabled: true,
            startMinute: CurfewDefaults.minutesPerDay,
            endMinute: 8 * 60
        )
        settings.preferences = impossibleHour
        XCTAssertEqual(settings.preferences, original)

        var unofferedGrace = original
        unofferedGrace.grace = 42
        settings.preferences = unofferedGrace
        XCTAssertEqual(settings.preferences, original)
    }

    func testAStoredChangeAnnouncesItselfOnce() {
        let settings = CurfewSettings(defaults: defaults)
        let announced = expectation(
            forNotification: CurfewSettingsDidChange.name,
            object: nil,
            handler: nil
        )

        var updated = settings.preferences
        updated.quietHours = nightly(from: 4 * 60, to: 8 * 60)
        settings.preferences = updated

        wait(for: [announced], timeout: 1)
    }

    // MARK: - Words

    func testTheWrapUpNamesTheCurfewsOwnTime() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)

        let text = CurfewReceiptWords.windDownText(
            template: CurfewDefaults.windDownText,
            deadline: deadline,
            locale: locale
        )

        XCTAssertFalse(text.contains(CurfewDefaults.timePlaceholder))
        XCTAssertTrue(text.contains(time(deadline)))
    }

    func testAWrapUpTemplateCarryingAPercentIsSubstitutedRatherThanFormatted() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)

        let text = CurfewReceiptWords.windDownText(
            template: "Stop at {time}; you are at 80% of the window.",
            deadline: deadline,
            locale: locale
        )

        XCTAssertEqual(text, "Stop at \(time(deadline)); you are at 80% of the window.")
    }

    func testTheStripReadsAsALedgerOfWhatTheCurfewDid() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .quietHours(endsAt: date(2026, 8, 10, 8, 0, in: calendar)),
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )
        let windDownAt = date(2026, 8, 10, 3, 50, in: calendar)
        let interruptedAt = date(2026, 8, 10, 4, 5, in: calendar)
        var state = SessionCurfewState(deadline: deadline, origin: curfew.origin)

        let held = CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: true,
            locale: locale,
            now: date(2026, 8, 10, 4, 30, in: calendar)
        )
        XCTAssertEqual(held, L10n.format("Curfew since %@", time(deadline), locale: locale))

        state.record(.windDownSent, at: windDownAt)
        let wrapped = CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: true,
            locale: locale,
            now: date(2026, 8, 10, 4, 30, in: calendar)
        )
        XCTAssertEqual(
            wrapped,
            [
                L10n.format("Curfew since %@", time(deadline), locale: locale),
                L10n.format("wrap-up sent %@", time(windDownAt), locale: locale)
            ].joined(separator: CurfewDefaults.receiptSeparator)
        )

        state.record(.interrupted, at: interruptedAt)
        state.interruptCount = 2
        let interrupted = CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: true,
            locale: locale,
            now: date(2026, 8, 10, 4, 30, in: calendar)
        )
        XCTAssertTrue(
            interrupted.hasSuffix(
                L10n.format("interrupted %1$@ ×%2$lld", time(interruptedAt), Int64(2), locale: locale)
            ),
            interrupted
        )
    }

    /// The honest half: where Threading cannot see whether a turn is running, the line says so
    /// rather than implying a fence that is not there.
    func testTheStripSaysSoWhenThreadingCannotTellWhetherTheSessionIsWorking() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )

        let sentence = CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: nil,
            canTellWorking: false,
            locale: locale,
            now: date(2026, 8, 10, 4, 30, in: calendar)
        )

        XCTAssertTrue(
            sentence.hasSuffix(
                L10n.string(
                    "Threading cannot tell whether this session is working, so it only stops delivering messages."
                )
            ),
            sentence
        )
    }

    func testTheStripSaysPlainlyWhenTheCurfewGaveUp() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )
        var state = SessionCurfewState(deadline: deadline, origin: .session)
        state.interruptCount = CurfewDefaults.maximumInterrupts
        state.lastInterruptAt = date(2026, 8, 10, 4, 6, in: calendar)
        state.gaveUpAt = date(2026, 8, 10, 4, 7, in: calendar)

        let sentence = CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: true,
            locale: locale,
            now: date(2026, 8, 10, 4, 30, in: calendar)
        )

        XCTAssertTrue(
            sentence.hasSuffix(
                L10n.format(
                    "kept working after %lld interrupts",
                    Int64(CurfewDefaults.maximumInterrupts),
                    locale: locale
                )
            ),
            sentence
        )
        XCTAssertEqual(
            CurfewReceiptWords.gaveUpAlertBody(count: CurfewDefaults.maximumInterrupts),
            L10n.format("Kept working after %lld interrupts", Int64(CurfewDefaults.maximumInterrupts))
        )
    }

    /// A row has one line, and a held session looks idle. The hold is what the reader is owed
    /// first; an exemption is worth a line only where a standing window would otherwise apply.
    func testTheRowsLineLeadsWithTheHoldAndNamesAnExemptionOnlyWhenOneMatters() {
        let calendar = calendar()
        let deadline = date(2026, 8, 10, 4, 0, in: calendar)
        let curfew = ResolvedCurfew(
            deadline: deadline,
            origin: .session,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )

        XCTAssertEqual(
            CurfewReceiptWords.conductStatement(
                curfew: curfew,
                isExempt: false,
                now: date(2026, 8, 10, 3, 0, in: calendar),
                locale: locale
            ),
            L10n.format("Curfew at %@", time(deadline), locale: locale)
        )
        XCTAssertEqual(
            CurfewReceiptWords.conductStatement(
                curfew: curfew,
                isExempt: false,
                now: date(2026, 8, 10, 4, 30, in: calendar),
                locale: locale
            ),
            L10n.format("Held by curfew since %@", time(deadline), locale: locale)
        )
        XCTAssertEqual(
            CurfewReceiptWords.conductStatement(
                curfew: nil,
                isExempt: true,
                now: date(2026, 8, 10, 4, 30, in: calendar),
                locale: locale
            ),
            L10n.string("Exempt from quiet hours")
        )
        XCTAssertNil(
            CurfewReceiptWords.conductStatement(
                curfew: nil,
                isExempt: false,
                now: date(2026, 8, 10, 4, 30, in: calendar),
                locale: locale
            )
        )
    }

    func testAHoldExplainsItselfInTermsOfADecisionTheReaderMade() {
        let calendar = calendar()
        let since = date(2026, 8, 10, 4, 0, in: calendar)

        XCTAssertEqual(
            CurfewReceiptWords.holdReason(since: since, locale: locale),
            L10n.format(
                "This session has been under a curfew since %@, so Threading is not spending it on its own.",
                time(since),
                locale: locale
            )
        )
        XCTAssertEqual(
            CurfewReceiptWords.windDownFailureReason,
            L10n.string("Its curfew passed before the session was free.")
        )
        XCTAssertEqual(
            CurfewReceiptWords.notRunningFailureReason,
            L10n.string("Threading was not running.")
        )
    }
}
