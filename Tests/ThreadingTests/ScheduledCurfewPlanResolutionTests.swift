import XCTest

@testable import Threading

/// What the end a draft chose means at the moment its session finally starts.
///
/// The one piece of arming that is worth asserting on its own: everything else about a start is
/// about creating a session, and this is the question of whether the rule it carries still names
/// a moment. It is pure on purpose — no coordinator, no window, no store — because the two
/// answers that matter are both about a plan whose world moved while it waited: a wall-clock end
/// that is now behind it, and a standing window that has since been switched off.
final class ScheduledCurfewPlanResolutionTests: XCTestCase {

    // MARK: - Fixture

    /// Fixed rather than `.current`: every answer below is a wall-clock reading, and a suite that
    /// resolved them against whatever zone the machine is in would be asserting on the machine.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        return calendar
    }()

    private func moment(
        day: Int = 14,
        hour: Int,
        minute: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 4, day: day, hour: hour, minute: minute
        )))
    }

    private func preferences(quietHours: QuietHours) -> CurfewPreferences {
        var preferences = CurfewPreferences.default
        preferences.quietHours = quietHours
        return preferences
    }

    private func outcome(
        _ plan: ScheduledCurfewPlan?,
        quietHours: QuietHours = QuietHours(isEnabled: false),
        now: Date
    ) -> ScheduledCurfewPlanResolution.Outcome {
        ScheduledCurfewPlanResolution.deadline(
            for: plan,
            preferences: preferences(quietHours: quietHours),
            now: now,
            calendar: calendar
        )
    }

    // MARK: - No Plan

    /// The ordinary start. A session with no chosen end has to arm nothing at all, rather than
    /// arming something harmless — every armed curfew is a row somebody can be held by.
    func testAStartCarryingNoEndArmsNothing() throws {
        XCTAssertEqual(outcome(nil, now: try moment(hour: 22)), .noCurfew)
    }

    // MARK: - A Moment Somebody Named

    func testAWallClockEndStillAheadIsArmedExactlyAsItWasWritten() throws {
        let now = try moment(hour: 22)
        let deadline = try moment(day: 15, hour: 4)

        XCTAssertEqual(outcome(.at(deadline), now: now), .arm(deadline))
    }

    /// The missed overnight case: the start fired late — the Mac was asleep, the app was not
    /// running — and the end it was carrying is already behind it. Arming it would hold the
    /// session from its first breath, which is the opposite of what "end it at four" asked for,
    /// so the plan is skipped and the reason is what the journal prints.
    func testAWallClockEndThatHasAlreadyPassedIsSkippedRatherThanArmedInThePast() throws {
        let now = try moment(day: 15, hour: 9)
        let deadline = try moment(day: 15, hour: 4)

        XCTAssertEqual(
            outcome(.at(deadline), now: now),
            .skipped(.deadlineAlreadyPassed)
        )
    }

    /// The boundary belongs to the past: a deadline landing on the very moment the session starts
    /// has nothing left to bound.
    func testAnEndAtTheExactMomentOfTheStartIsAlreadyPast() throws {
        let now = try moment(hour: 4)

        XCTAssertEqual(outcome(.at(now), now: now), .skipped(.deadlineAlreadyPassed))
    }

    func testAUsageResetEndArmsOnlyItsNamedWindow() throws {
        let now = try moment(hour: 22)
        let expectedAt = try moment(day: 18, hour: 4)

        XCTAssertEqual(
            outcome(
                .untilUsageReset(
                    expectedAt: expectedAt,
                    windowID: UsageDefaults.weeklyWindowID
                ),
                now: now
            ),
            .armUsageReset(
                expectedAt: expectedAt,
                windowID: UsageDefaults.weeklyWindowID
            )
        )
    }

    // MARK: - Whenever Quiet Hours Next Begin

    /// The whole reason the choice is stored rather than the moment. The plan was written days
    /// ago; the window it resolves against is the one configured *now*.
    func testQuietHoursResolveToTheNextWindowAtTheMomentTheStartFires() throws {
        let now = try moment(hour: 22)

        XCTAssertEqual(
            outcome(
                .atQuietHours,
                quietHours: QuietHours(isEnabled: true, startMinute: 4 * 60, endMinute: 8 * 60),
                now: now
            ),
            .arm(try moment(day: 15, hour: 4))
        )
    }

    /// A start that fires *inside* tonight's window still gets tomorrow's start, never the one it
    /// is standing in. The deadline is always ahead of the session it bounds — and it is the same
    /// moment `CurfewMenu` named when the plan was chosen, which is the half the user read.
    func testAStartInsideAWindowTakesTheNextOneRatherThanAMomentBehindIt() throws {
        let now = try moment(day: 15, hour: 5)

        XCTAssertEqual(
            outcome(
                .atQuietHours,
                quietHours: QuietHours(isEnabled: true, startMinute: 4 * 60, endMinute: 8 * 60),
                now: now
            ),
            .arm(try moment(day: 16, hour: 4))
        )
    }

    /// The window was switched off between choosing the plan and firing it. The choice is not
    /// reinterpreted as some other end — it simply names nothing, and says so.
    func testQuietHoursSwitchedOffBetweenChoosingAndFiringArmNothing() throws {
        let now = try moment(hour: 22)

        XCTAssertEqual(
            outcome(
                .atQuietHours,
                quietHours: QuietHours(isEnabled: false, startMinute: 4 * 60, endMinute: 8 * 60),
                now: now
            ),
            .skipped(.quietHoursNotConfigured)
        )
    }

    // MARK: - What The Journal Prints

    /// The skipped reasons are what the next morning's *why did this session have no curfew* is
    /// answered with, so their spellings are part of the record rather than an implementation
    /// detail.
    func testEachSkippedReasonHasAStableWordForTheJournal() {
        XCTAssertEqual(
            ScheduledCurfewPlanResolution.Reason.deadlineAlreadyPassed.rawValue,
            "deadlineAlreadyPassed"
        )
        XCTAssertEqual(
            ScheduledCurfewPlanResolution.Reason.quietHoursNotConfigured.rawValue,
            "quietHoursNotConfigured"
        )
    }
}
