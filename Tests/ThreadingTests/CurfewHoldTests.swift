import XCTest
@testable import Threading

/// The one decision every curfew consumer asks: is this session past its deadline, and if so
/// what is a due message supposed to do about it.
///
/// All pure. The hold is `now` against a resolved deadline, so it needs no database, no
/// preferences suite and no live session — which is the point: this is the rule that stops the
/// app spending somebody's conversation while they are asleep, and it should be assertable at
/// every instant around the fence rather than only at the one a fixture happens to produce.
@MainActor
final class CurfewHoldTests: XCTestCase {

    // MARK: - Fixture

    /// 04:00 UTC, the case the feature was written for.
    private let deadline = Date(timeIntervalSince1970: 1_775_016_000)
    private let fiveHour = UsageDefaults.fiveHourWindowID

    private func curfew(
        at deadline: Date? = nil,
        origin: CurfewOrigin = .session
    ) -> ResolvedCurfew {
        ResolvedCurfew(
            deadline: deadline ?? self.deadline,
            origin: origin,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )
    }

    private func answer(
        _ curfew: ResolvedCurfew?,
        scope: CurfewScope = .session
    ) -> CurfewResolution.Answer {
        CurfewResolution.Answer(scope: scope, curfew: curfew)
    }

    private func state(origin: CurfewOrigin = .session) -> SessionCurfewState {
        SessionCurfewState(deadline: deadline, origin: origin)
    }

    // MARK: - Before, At, After

    /// A curfew that has not arrived holds nothing. The session is running perfectly normally
    /// right up to the moment it is not, and every surface reads the same answer for it.
    func testNothingIsHeldBeforeTheDeadline() {
        for interval: TimeInterval in [-3_600, -60, -0.001] {
            XCTAssertEqual(
                CurfewHoldPolicy.hold(
                    answer: answer(curfew()),
                    state: nil,
                    at: deadline.addingTimeInterval(interval)
                ),
                .clear,
                "held \(-interval)s early"
            )
        }
    }

    /// Inclusive at the deadline: the moment the user named is the first moment nothing is sent.
    func testTheHoldEngagesAtTheDeadlineAndStays() throws {
        for interval: TimeInterval in [0, 1, 3_600, 12 * 3_600] {
            let hold = CurfewHoldPolicy.hold(
                answer: answer(curfew()),
                state: nil,
                at: deadline.addingTimeInterval(interval)
            )
            XCTAssertTrue(hold.isHolding, "not held \(interval)s after the deadline")
        }
    }

    /// A curfew set on the session has no end but the user's hand — nothing about the passage of
    /// time releases it, which is the difference between "end this session" and "quiet hours".
    func testASessionCurfewNeverReleasesItself() {
        let hold = CurfewHoldPolicy.hold(
            answer: answer(curfew()),
            state: state(),
            at: deadline.addingTimeInterval(30 * 3_600)
        )
        XCTAssertTrue(hold.isHolding)
    }

    // MARK: - The Standing Window

    /// A quiet-hours instance holds for exactly its window: at the start, through the middle,
    /// and not one evaluation past the end. Half-open at the end for `QuietHours.window`'s own
    /// reason — the end is the moment it lifts.
    func testAStandingWindowHoldsInsideItselfAndReleasesAtItsEnd() {
        let endsAt = deadline.addingTimeInterval(4 * 3_600)
        let quiet = curfew(origin: .quietHours(endsAt: endsAt))

        for interval: TimeInterval in [0, 60, 2 * 3_600] {
            XCTAssertTrue(
                CurfewHoldPolicy.hold(
                    answer: answer(quiet, scope: .app),
                    state: nil,
                    at: deadline.addingTimeInterval(interval)
                ).isHolding,
                "not held \(interval)s into the window"
            )
        }

        for moment in [endsAt, endsAt.addingTimeInterval(1)] {
            XCTAssertEqual(
                CurfewHoldPolicy.hold(answer: answer(quiet, scope: .app), state: nil, at: moment),
                .clear,
                "still held at or past the window's end"
            )
        }
    }

    // MARK: - No Curfew At All

    /// An exemption resolves to *no curfew*, which is a real answer rather than the absence of
    /// one, and it holds nothing at any moment.
    func testAnExemptSessionIsNeverHeld() {
        XCTAssertEqual(
            CurfewHoldPolicy.hold(
                answer: answer(nil),
                state: state(),
                at: deadline.addingTimeInterval(6 * 3_600)
            ),
            .clear
        )
    }

    // MARK: - What The Hold Carries

    /// `since` is the **deadline**, not the moment the hold was first noticed. A hold that
    /// materialized on relaunch at 09:00 is still a hold that began at 04:00, and a sentence
    /// saying otherwise would be describing the app's uptime.
    func testTheHoldDatesItselfFromTheDeadlineAndNotFromTheReading() throws {
        let hold = CurfewHoldPolicy.hold(
            answer: answer(curfew()),
            state: state(),
            at: deadline.addingTimeInterval(5 * 3_600)
        )
        guard case .held(let since, let resolved, let carried) = hold else {
            return XCTFail("the deadline did not hold")
        }
        XCTAssertEqual(since, deadline)
        XCTAssertEqual(resolved.deadline, deadline)
        XCTAssertEqual(carried, state())
    }

    /// The refusal sentence is the user's own line in the user's own terms, and borrows none of
    /// the vocabulary a real rate-limit refusal uses: told "limit", a reader goes looking at a
    /// quota that is fine.
    func testTheHoldSentenceNamesTheCurfewRatherThanTheProvider() {
        let reason = CurfewReceiptWords.holdReason(since: deadline)

        XCTAssertTrue(reason.localizedCaseInsensitiveContains("curfew"), reason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("rate limit"), reason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("quota"), reason)
    }

    // MARK: - A Due Scheduled Send

    private func send(
        purpose: ScheduledMessage.Purpose = .userAuthored,
        target: SessionID = SessionID()
    ) -> ScheduledMessage {
        ScheduledMessage(
            dueAt: deadline.addingTimeInterval(3_600),
            target: .session(target),
            text: "carry on",
            purpose: purpose
        )
    }

    func testAnUnheldSendIsSimplyDelivered() {
        XCTAssertEqual(
            CurfewStandAside.decide(message: send(), hold: .clear, now: deadline),
            .deliver
        )
    }

    /// The wrap-up is the one message a held session still takes: it is what buys an interrupted
    /// agent the single turn it needs to commit what is safe and write its handoff note.
    func testAWrapUpIsExemptFromTheHoldItBelongsTo() {
        let hold = CurfewHoldPolicy.hold(answer: answer(curfew()), state: nil, at: deadline)

        XCTAssertEqual(
            CurfewStandAside.decide(
                message: send(purpose: .curfewWindDown),
                hold: hold,
                now: deadline
            ),
            .deliver
        )
        // …and nothing else is.
        XCTAssertNotEqual(
            CurfewStandAside.decide(message: send(), hold: hold, now: deadline),
            .deliver
        )
    }

    /// A standing window ends at a moment the app can name, so the send is re-armed for it rather
    /// than left waiting on a user who never asked to be involved.
    func testASendHeldByQuietHoursIsReArmedForTheWindowsEnd() {
        let endsAt = deadline.addingTimeInterval(4 * 3_600)
        let hold = CurfewHoldPolicy.hold(
            answer: answer(curfew(origin: .quietHours(endsAt: endsAt)), scope: .app),
            state: nil,
            at: deadline
        )

        XCTAssertEqual(
            CurfewStandAside.decide(message: send(), hold: hold, now: deadline),
            .rescheduleTo(endsAt)
        )
    }

    /// A curfew the user set on the session has no end to re-arm to, so the send waits and says
    /// why — in the curfew's own sentence, so the row the user finds in the morning reads the
    /// same as the strip above it.
    func testASendHeldByASessionCurfewWaitsUntilItIsLifted() throws {
        let hold = CurfewHoldPolicy.hold(answer: answer(curfew()), state: nil, at: deadline)

        guard case .waitUntilLifted(let reason) = CurfewStandAside.decide(
            message: send(),
            hold: hold,
            now: deadline
        ) else { return XCTFail("a session curfew re-armed a send to a moment it does not have") }

        XCTAssertEqual(reason, CurfewReceiptWords.holdReason(since: deadline))
    }

    /// A finish-triggered send has no clock to move: `rescheduled(to:)` answers with the record
    /// unchanged, so re-arming it would look like a deferral while leaving the send pinned to an
    /// edge that may never come again. It waits instead.
    func testAFinishTriggeredSendWaitsRatherThanBeingReArmed() throws {
        let endsAt = deadline.addingTimeInterval(4 * 3_600)
        let hold = CurfewHoldPolicy.hold(
            answer: answer(curfew(origin: .quietHours(endsAt: endsAt)), scope: .app),
            state: nil,
            at: deadline
        )
        let watched = ScheduledMessage(
            whenSessionFinishes: SessionID(),
            target: .session(SessionID()),
            text: "when that one is done"
        )

        guard case .waitUntilLifted = CurfewStandAside.decide(
            message: watched,
            hold: hold,
            now: deadline
        ) else { return XCTFail("a finish-triggered send was re-armed to a wall-clock moment") }
    }

    // MARK: - The Poke's Guard Row

    /// Quiet hours are a curfew drawn over every account at once, and the poke spends a message.
    /// Opening a usage window inside the window would spend the one thing it is for — a message
    /// sent while its owner is asleep — on a boundary they asked nothing about.
    func testThePokeStandsDownInsideQuietHours() throws {
        var input = pokeInput()
        XCTAssertEqual(UsageWindowPlan.decide(input), .poke)

        let until = input.now.addingTimeInterval(2 * 3_600)
        input.quietHoursUntil = until

        XCTAssertEqual(UsageWindowPlan.decide(input), .hold(.quietHours(until: until)))
    }

    /// It is the **last** guard. The account's own line is the narrower fact and the one the user
    /// can change today; the standing window holds every login they have.
    func testTheAccountsOwnLineIsNamedBeforeTheStandingWindow() throws {
        var input = pokeInput()
        input.quietHoursUntil = input.now.addingTimeInterval(2 * 3_600)
        input.customLimitHold = .overLine(
            rule: CustomLimit(windowID: fiveHour, bound: 0.5, tier: .hold),
            windowName: UsageDefaults.fiveHourLabel
        )

        guard case .hold(.customLimitReached) = UsageWindowPlan.decide(input) else {
            return XCTFail("quiet hours answered ahead of the user's own limit")
        }
    }

    private func pokeInput() -> UsageWindowPlan.Input {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // A Wednesday at 10:00 UTC, inside the default working day.
        let day = calendar.date(from: DateComponents(year: 2026, month: 2, day: 4, hour: 10))!

        return UsageWindowPlan.Input(
            now: day,
            schedule: UsageWindowSchedule(
                isEnabled: true,
                startMinute: 9 * 60,
                endMinute: 18 * 60,
                weekdays: Set(1...7),
                accountIDs: ["claude:work"]
            ),
            accountID: "claude:work",
            burn: 3 * 3_600,
            shortWindow: AccountUsage.Window(
                id: fiveHour,
                label: UsageDefaults.fiveHourLabel,
                fraction: 0.2,
                resetsAt: day.addingTimeInterval(-60),
                windowDuration: UsageDefaults.fiveHourSeconds
            ),
            weeklyWindow: nil,
            isWorking: false,
            pokesToday: 0,
            calendar: calendar
        )
    }

    // MARK: - The Refusal

    /// The plane's refusal keeps the curfew apart from a limit, because the remedies differ: a
    /// caller refused by a curfew may legitimately try a sibling session on the same account,
    /// and a caller refused by a limit may not.
    func testTheControlPlanesCurfewRefusalIsNotItsLimitRefusal() throws {
        let reason = CurfewReceiptWords.holdReason(since: deadline)
        let words = ControlRefusal.targetHeldByCurfew(reason: reason).toolWords

        XCTAssertTrue(words.hasPrefix(reason), words)
        XCTAssertTrue(words.localizedCaseInsensitiveContains("curfew"), words)
        XCTAssertNotEqual(
            words,
            ControlRefusal.targetHeldByOwnLimit(reason: reason).toolWords
        )
    }
}
