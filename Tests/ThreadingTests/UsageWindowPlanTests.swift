import XCTest
@testable import Threading

/// The arithmetic behind opening a usage window on purpose, and every rule that declines to.
///
/// The planner is pure precisely so this file can exist: a feature that spends someone's rate
/// limit on a schedule cannot be checked by running it and seeing what happens.
final class UsageWindowPlanTests: XCTestCase {

    // MARK: - Fixtures

    /// UTC, so a test does not pass in Stockholm and fail in a CI container.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let windowLength = UsageDefaults.fiveHourSeconds
    private let burn: TimeInterval = 3 * 3600

    /// Monday 3 August 2026, at the given local hour.
    private func date(hour: Int, minute: Int = 0, day: Int = 3) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        )) ?? Date()
    }

    private var workday: DateInterval {
        DateInterval(start: date(hour: 9), end: date(hour: 18))
    }

    private func schedule(
        enabled: Bool = true,
        start: Int = 9 * 60,
        end: Int = 18 * 60,
        onDayOf reference: Date? = nil
    ) -> UsageWindowSchedule {
        let day = reference ?? date(hour: 12)
        return UsageWindowSchedule(
            isEnabled: enabled,
            startMinute: start,
            endMinute: end,
            weekdays: [calendar.component(.weekday, from: day)],
            accountIDs: [Self.accountID]
        )
    }

    /// A window with a reset in the future is open; one whose reset has passed is not.
    private func window(resetsAt: Date?, fraction: Double? = 0.2) -> AccountUsage.Window {
        AccountUsage.Window(
            id: UsageDefaults.fiveHourWindowID,
            label: UsageDefaults.fiveHourLabel,
            fraction: fraction,
            resetsAt: resetsAt,
            windowDuration: windowLength
        )
    }

    private func weekly(spent: Double, elapsed: Double, now: Date) -> AccountUsage.Window {
        // `elapsedFraction` is derived from the reset and the length, so the sample is built
        // backwards from the position it should report.
        AccountUsage.Window(
            id: UsageDefaults.weeklyWindowID,
            label: UsageDefaults.weeklyLabel,
            fraction: spent,
            resetsAt: now.addingTimeInterval(UsageDefaults.sevenDaySeconds * (1 - elapsed)),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
    }

    private static let accountID = "claude:default"

    private func input(
        now: Date,
        schedule: UsageWindowSchedule? = nil,
        burn: TimeInterval? = 3 * 3600,
        shortWindow: AccountUsage.Window?,
        weeklyWindow: AccountUsage.Window? = nil,
        isWorking: Bool = false,
        pokesToday: Int = 0
    ) -> UsageWindowPlan.Input {
        UsageWindowPlan.Input(
            now: now,
            schedule: schedule ?? self.schedule(onDayOf: now),
            accountID: Self.accountID,
            burn: burn,
            shortWindow: shortWindow,
            weeklyWindow: weeklyWindow,
            isWorking: isWorking,
            pokesToday: pokesToday,
            calendar: calendar
        )
    }

    // MARK: - Lead

    /// The lead is the window minus the burn, which is what makes it derived rather than typed
    /// into a box. Opening exactly `burn` before the day starts means the window is drained at
    /// the moment it resets: nothing wasted in front of it, no wait behind it.
    func testLeadIsTheWindowLessTheBurn() {
        XCTAssertEqual(
            UsageWindowPlan.lead(burn: burn, windowLength: windowLength),
            2 * 3600,
            accuracy: 1
        )
    }

    /// Without a measurement there is no honest lead, so the documented assumption is used and
    /// the page says so. Inventing a precise-looking one is worse: nobody re-checks a number
    /// that looks measured.
    func testAnUnmeasuredBurnFallsBackToTheStatedAssumption() {
        XCTAssertEqual(
            UsageWindowPlan.lead(burn: nil, windowLength: windowLength),
            UsageWindowDefaults.assumedLead
        )
    }

    /// The lead stays inside the window at both ends. A burn longer than the window leaves no
    /// lead to take, and a very fast burn cannot ask for more than a whole window's head start,
    /// which would open one that expires before anybody arrives.
    func testALeadStaysWithinTheWindow() {
        XCTAssertEqual(
            UsageWindowPlan.lead(burn: 60, windowLength: windowLength),
            windowLength - 60,
            accuracy: 1
        )
        XCTAssertEqual(
            UsageWindowPlan.lead(burn: windowLength * 2, windowLength: windowLength),
            0
        )
    }

    /// A burn of zero is not a measurement of an infinitely fast account; it is the absence of
    /// one, and `UsageWindowBurn` never produces it. Treating it as data would ask for a lead of
    /// a whole window, which is the one value guaranteed to gain nothing.
    func testAZeroBurnIsTreatedAsNoMeasurement() {
        XCTAssertEqual(
            UsageWindowPlan.lead(burn: 0, windowLength: windowLength),
            UsageWindowDefaults.assumedLead
        )
    }

    // MARK: - The Claim

    /// The headline: on a nine-hour day spent three hours to a window, opening early pulls a
    /// third window's boundary inside the day and buys an hour of work that was otherwise spent
    /// waiting.
    ///
    /// This is the number the settings diagram draws, and the reason the feature exists. If it
    /// ever stops being true — a different window length, a different day — the picture is
    /// making a promise the arithmetic no longer keeps.
    func testOpeningEarlyPullsAnExtraWindowIntoTheWorkingDay() {
        let comparison = UsageWindowPlan.comparison(
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )

        XCTAssertEqual(comparison.unpoked.productiveTime, 6 * 3600, accuracy: 1)
        XCTAssertEqual(comparison.poked.productiveTime, 7 * 3600, accuracy: 1)

        XCTAssertEqual(comparison.unpoked.windows.filter { $0.productive != nil }.count, 2)
        XCTAssertEqual(comparison.poked.windows.filter { $0.productive != nil }.count, 3)

        // And the hour gained is an hour that was being spent waiting, not an hour invented.
        XCTAssertLessThan(comparison.poked.cappedTime, comparison.unpoked.cappedTime)
    }

    /// A lead of a whole window is the same as no poke at all: the primed window expires before
    /// the first message, and the day's first real window opens exactly where it would have.
    /// This is the failure the derived lead exists to avoid, so it is worth stating.
    func testALeadOfAWholeWindowGainsNothing() {
        let wasted = UsageWindowPlan.outlook(
            anchor: workday.start.addingTimeInterval(-windowLength),
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )
        let unpoked = UsageWindowPlan.outlook(
            anchor: workday.start,
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )

        XCTAssertEqual(wasted.productiveTime, unpoked.productiveTime, accuracy: 1)
    }

    /// Every window drawn falls inside the day it claims to describe, and each one's productive
    /// stretch is inside the window it belongs to. The diagram reads these directly, so a lane
    /// that measured past its own day would draw a block over the axis.
    func testAnOutlookNeverClaimsTimeOutsideItsOwnWindowOrDay() {
        let outlook = UsageWindowPlan.outlook(
            anchor: workday.start.addingTimeInterval(-2 * 3600),
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )

        for window in outlook.windows {
            if let productive = window.productive {
                XCTAssertGreaterThanOrEqual(productive.start, window.interval.start)
                XCTAssertLessThanOrEqual(productive.end, window.interval.end)
                XCTAssertGreaterThanOrEqual(productive.start, workday.start)
                XCTAssertLessThanOrEqual(productive.end, workday.end)
                XCTAssertLessThanOrEqual(productive.duration, burn)
            }
            if let capped = window.capped {
                XCTAssertLessThanOrEqual(capped.end, workday.end)
            }
        }
    }

    // MARK: - Firing

    /// The happy path: a scheduled morning, no window open, nobody working.
    func testItPokesAtThePlannedTimeOnAScheduledDay() {
        let now = date(hour: 7)
        let decision = UsageWindowPlan.decide(input(
            now: now,
            shortWindow: window(resetsAt: date(hour: 3))
        ))

        XCTAssertEqual(decision, .poke)
    }

    /// And not before it. Poking at six on a day that starts at nine opens a window that has
    /// expired again by the time anyone sends anything.
    func testItWaitsUntilThePlannedTime() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 6),
            shortWindow: window(resetsAt: date(hour: 3))
        ))

        XCTAssertEqual(decision, .hold(.beforePokeTime(date(hour: 7))))
    }

    /// A window expiring while nobody is at the keyboard is the case worth reopening: without
    /// it the grid slides by however long lunch took, and the day's last reset lands after
    /// everyone has stopped. It falls out of the same rules rather than being a rule of its own.
    func testAWindowThatExpiresDuringAQuietLunchIsReopened() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 12, minute: 30),
            shortWindow: window(resetsAt: date(hour: 12))
        ))

        XCTAssertEqual(decision, .poke)
    }

    // MARK: - Holding

    /// Nothing is opened while something is open. A second message does not start a second
    /// window, so this is the rule that separates a poke from a cron line.
    func testAnOpenWindowHoldsThePoke() {
        let resetsAt = date(hour: 12)
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 9),
            shortWindow: window(resetsAt: resetsAt)
        ))

        XCTAssertEqual(decision, .hold(.windowOpen(resetsAt: resetsAt)))
    }

    /// A busy account opens its own window with whatever it sends next. Paying for that is the
    /// waste this rule prevents, and it is also what keeps the reopen above from firing at every
    /// boundary of a working day.
    func testABusyAccountHoldsThePoke() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 12, minute: 30),
            shortWindow: window(resetsAt: date(hour: 12)),
            isWorking: true
        ))

        XCTAssertEqual(decision, .hold(.working))
    }

    /// Without a reading, whether a window is open is a guess. Poking on a guess is wasteful
    /// exactly half the time, which is the entire argument for the reading.
    func testNoReadingHoldsThePoke() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 7),
            shortWindow: nil
        ))

        XCTAssertEqual(decision, .hold(.usageUnknown))
    }

    /// The backstop. Not a tuning knob: it is what keeps a defect in any rule above from turning
    /// a once-a-morning feature into a poller.
    func testTheDailyLimitHoldsThePoke() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 7),
            shortWindow: window(resetsAt: date(hour: 3)),
            pokesToday: UsageWindowDefaults.dailyLimit
        ))

        XCTAssertEqual(decision, .hold(.dailyLimitReached(UsageWindowDefaults.dailyLimit)))
    }

    /// Somebody who never reaches the short limit gains nothing from moving it, and would pay
    /// for the poke out of the weekly one. Saying so beats firing daily and claiming credit.
    func testAnAccountThatNeverExhaustsIsRefused() {
        let decision = UsageWindowPlan.decide(input(
            now: date(hour: 7),
            burn: windowLength + 1,
            shortWindow: window(resetsAt: date(hour: 3))
        ))

        XCTAssertEqual(decision, .hold(.neverExhausts))
    }

    /// A window opened at half past five buys half an hour and expires overnight. The bar is the
    /// burn: enough working day left to drain what is being opened.
    func testAnEveningWindowIsRefused() {
        let now = date(hour: 17)
        let decision = UsageWindowPlan.decide(input(
            now: now,
            shortWindow: window(resetsAt: date(hour: 16))
        ))

        XCTAssertEqual(decision, .hold(.tailTooShort(remaining: 3600)))
    }

    /// The honest half of the feature. Pulling an extra window into the day is a week spent
    /// faster, so when the weekly limit is already ahead of the clock the poke stands down.
    func testAWeeklyLimitAheadOfTheClockHoldsThePoke() {
        let now = date(hour: 7)
        let decision = UsageWindowPlan.decide(input(
            now: now,
            shortWindow: window(resetsAt: date(hour: 3)),
            weeklyWindow: weekly(spent: 0.8, elapsed: 0.5, now: now)
        ))

        XCTAssertEqual(decision, .hold(.weeklyAheadOfPace(fraction: 0.8)))
    }

    /// And a week running on pace does not stand in the way.
    func testAWeeklyLimitOnPaceDoesNotHoldThePoke() {
        let now = date(hour: 7)
        let decision = UsageWindowPlan.decide(input(
            now: now,
            shortWindow: window(resetsAt: date(hour: 3)),
            weeklyWindow: weekly(spent: 0.5, elapsed: 0.5, now: now)
        ))

        XCTAssertEqual(decision, .poke)
    }

    /// Off is off, and an account nobody opted in is off too. The schedule is global and the
    /// consent is per login.
    func testAnUnenabledAccountHolds() {
        var unopted = schedule()
        unopted.accountIDs = []

        XCTAssertEqual(
            UsageWindowPlan.decide(input(
                now: date(hour: 7),
                schedule: unopted,
                shortWindow: window(resetsAt: date(hour: 3))
            )),
            .hold(.disabled)
        )

        XCTAssertEqual(
            UsageWindowPlan.decide(input(
                now: date(hour: 7),
                schedule: schedule(enabled: false),
                shortWindow: window(resetsAt: date(hour: 3))
            )),
            .hold(.disabled)
        )
    }

    /// A Saturday on a weekdays-only schedule is not a day to spend anything on.
    func testAnUnscheduledDayHolds() {
        var weekdaysOnly = schedule()
        weekdaysOnly.weekdays = []

        XCTAssertEqual(
            UsageWindowPlan.decide(input(
                now: date(hour: 7),
                schedule: weekdaysOnly,
                shortWindow: window(resetsAt: date(hour: 3))
            )),
            .hold(.notScheduledToday)
        )
    }

    /// A half-entered schedule describes no day, and the planner says so rather than working out
    /// a poke time from an interval that runs backwards.
    func testAnEndBeforeAStartDescribesNoWorkingDay() {
        let broken = schedule(start: 18 * 60, end: 9 * 60)

        XCTAssertNil(broken.workday(containing: date(hour: 12), calendar: calendar))
        XCTAssertEqual(
            UsageWindowPlan.decide(input(
                now: date(hour: 7),
                schedule: broken,
                shortWindow: window(resetsAt: date(hour: 3))
            )),
            .hold(.notScheduledToday)
        )
    }
}
