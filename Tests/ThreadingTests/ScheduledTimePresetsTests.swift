import XCTest

@testable import Threading

/// The moments the schedule menu offers, and the arithmetic behind them.
///
/// All of it pure, which is the point of `ScheduledTimePresets` being its own type: "tomorrow at
/// nine" across a daylight-saving boundary is the kind of rule that is either tested here or
/// found by a user whose Sunday-night schedule fired an hour early.
@MainActor
final class ScheduledTimePresetsTests: XCTestCase {

    // MARK: - Fixture

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

    private func preset(
        _ presets: [ScheduledTimePreset],
        _ id: String
    ) -> ScheduledTimePreset? {
        presets.first { $0.id == id }
    }

    // MARK: - Tomorrow

    func testTomorrowLandsOnTheNextMorningAtNine() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 14, 30, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        guard let tomorrow = preset(presets, PresetDefaults.tomorrowID) else {
            return XCTFail("Tomorrow should always be offered")
        }
        XCTAssertEqual(calendar.component(.hour, from: tomorrow.date), 9)
        XCTAssertEqual(calendar.component(.day, from: tomorrow.date), 11)
    }

    func testTomorrowIsStillNineOClockAcrossTheSpringForwardBoundary() {
        let calendar = calendar()
        // 29 March 2026 is when Europe/Stockholm loses an hour. A preset built by adding 86,400
        // seconds to Saturday afternoon lands at 10:00, not 09:00.
        let now = date(2026, 3, 28, 14, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        guard let tomorrow = preset(presets, PresetDefaults.tomorrowID) else {
            return XCTFail("Tomorrow should always be offered")
        }
        XCTAssertEqual(
            calendar.component(.hour, from: tomorrow.date),
            9,
            "Calendar arithmetic, never + 86_400 — this is the day that tells the difference"
        )
        XCTAssertEqual(calendar.component(.day, from: tomorrow.date), 29)
    }

    func testTomorrowIsStillNineOClockAcrossTheFallBackBoundary() {
        let calendar = calendar()
        // 25 October 2026: the day Stockholm gains an hour.
        let now = date(2026, 10, 24, 14, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        XCTAssertEqual(
            calendar.component(.hour, from: preset(presets, PresetDefaults.tomorrowID)!.date),
            9
        )
    }

    // MARK: - Monday

    func testMondayIsOfferedMidweek() {
        let calendar = calendar()
        // Wednesday.
        let now = date(2026, 8, 12, 11, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        guard let monday = preset(presets, PresetDefaults.mondayID) else {
            return XCTFail("Monday should be offered from midweek")
        }
        XCTAssertEqual(calendar.component(.weekday, from: monday.date), PresetDefaults.mondayWeekday)
        XCTAssertEqual(calendar.component(.hour, from: monday.date), 9)
    }

    func testMondayIsSuppressedOnSundayWhereItWouldNameTomorrowTwice() {
        let calendar = calendar()
        // Sunday: "Monday at 9:00" and "Tomorrow at 9:00" are the same moment.
        let now = date(2026, 8, 16, 11, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        XCTAssertNil(
            preset(presets, PresetDefaults.mondayID),
            "One moment under two names is a bug in the menu, not a choice"
        )
        XCTAssertNotNil(preset(presets, PresetDefaults.tomorrowID))
    }

    func testMondayIsOfferedOnMondayItselfBecauseItMeansNextMonday() {
        let calendar = calendar()
        let now = date(2026, 8, 17, 11, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        guard let monday = preset(presets, PresetDefaults.mondayID) else {
            return XCTFail("Monday means the next one, which is a week away")
        }
        XCTAssertEqual(calendar.component(.day, from: monday.date), 24)
    }

    // MARK: - In An Hour

    func testInAnHourRoundsUpToATimeWorthOffering() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 12, 3, in: calendar)

        let presets = ScheduledTimePresets.wallClock(now: now, calendar: calendar)

        guard let hour = preset(presets, PresetDefaults.inAnHourID) else {
            return XCTFail("An hour ahead is always offerable")
        }
        XCTAssertEqual(calendar.component(.minute, from: hour.date) % 5, 0)
        XCTAssertEqual(calendar.component(.hour, from: hour.date), 13)
        XCTAssertGreaterThan(hour.date, now)
    }

    func testEveryPresetIsInTheFuture() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 8, 58, in: calendar)

        for preset in ScheduledTimePresets.wallClock(now: now, calendar: calendar) {
            XCTAssertGreaterThan(preset.date, now, "\(preset.id) is offering a moment already gone")
        }
    }

    // MARK: - Locale

    func testATwentyFourHourLocaleNeverReadsAmOrPm() {
        let calendar = calendar()
        let now = date(2026, 8, 10, 14, 0, in: calendar)

        let presets = ScheduledTimePresets.wallClock(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "sv_SE")
        )

        let titles = presets.map(\.title).joined()
        XCTAssertFalse(titles.contains("AM"))
        XCTAssertFalse(titles.contains("PM"))
        XCTAssertTrue(titles.contains("09:00"), "A Swedish morning is 09:00, not 9:00 AM")
    }

    // MARK: - Usage Resets

    private func usage(
        windows: [AccountUsage.Window],
        modelWindows: [AccountUsage.Window] = []
    ) -> AccountUsage {
        var usage = AccountUsage(
            windows: windows,
            planLabel: "Max",
            observedAt: Date(timeIntervalSince1970: 1_775_000_000),
            source: .api
        )
        usage.modelWindows = modelWindows
        return usage
    }

    private func window(
        id: String,
        resetsIn seconds: TimeInterval?,
        from now: Date,
        duration: TimeInterval,
        scope: String? = nil
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: 0.9,
            resetsAt: seconds.map { now.addingTimeInterval($0) },
            windowDuration: duration,
            scopeName: scope
        )
    }

    func testOffersBothTheShortAndTheWeeklyWindow() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let usage = usage(windows: [
            window(id: UsageDefaults.fiveHourWindowID, resetsIn: 3_600, from: now, duration: 18_000),
            window(id: UsageDefaults.weeklyWindowID, resetsIn: 200_000, from: now, duration: 604_800),
        ])

        let presets = ScheduledTimePresets.usageResets(usage: usage, metering: nil, now: now)

        XCTAssertEqual(presets.count, 2)
        XCTAssertTrue(presets.allSatisfy { $0.anchor.usageWindowID != nil })
        XCTAssertNotNil(presets.first?.detail, "The reading is the whole reason to offer this")
    }

    func testAWindowWithNoResetIsAbsentRatherThanOffered() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let usage = usage(windows: [
            window(id: UsageDefaults.fiveHourWindowID, resetsIn: nil, from: now, duration: 18_000)
        ])

        XCTAssertTrue(
            ScheduledTimePresets.usageResets(usage: usage, metering: nil, now: now).isEmpty,
            "The same silence every other usage surface keeps when there is nothing to report"
        )
    }

    func testAnExpiredWindowIsNotOffered() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let usage = usage(windows: [
            window(id: UsageDefaults.fiveHourWindowID, resetsIn: -60, from: now, duration: 18_000)
        ])

        XCTAssertTrue(ScheduledTimePresets.usageResets(usage: usage, metering: nil, now: now).isEmpty)
    }

    func testAModelScopedWindowIsOfferedWhenItMetersWhatTheSessionWillRun() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let usage = usage(
            windows: [
                window(id: UsageDefaults.weeklyWindowID, resetsIn: 200_000, from: now, duration: 604_800)
            ],
            modelWindows: [
                window(
                    id: "fable-weekly",
                    resetsIn: 90_000,
                    from: now,
                    duration: 604_800,
                    scope: "Fable"
                )
            ]
        )

        let metered = ScheduledTimePresets.usageResets(
            usage: usage,
            metering: "claude-fable-5",
            now: now
        )
        let unmetered = ScheduledTimePresets.usageResets(
            usage: usage,
            metering: "claude-opus-5",
            now: now
        )

        XCTAssertEqual(
            metered.count, 2,
            "The window that actually gates this session is the one worth aiming at"
        )
        XCTAssertEqual(
            unmetered.count, 1,
            "Another model's window is not this session's clock and must not be offered as one"
        )
    }

    func testAResetPresetAimsJustPastTheBoundaryRatherThanAtIt() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let resetsAt = now.addingTimeInterval(3_600)
        let usage = usage(windows: [
            window(id: UsageDefaults.fiveHourWindowID, resetsIn: 3_600, from: now, duration: 18_000)
        ])

        let preset = ScheduledTimePresets.usageResets(usage: usage, metering: nil, now: now).first

        XCTAssertEqual(
            preset?.date,
            resetsAt.addingTimeInterval(PresetDefaults.resetPadding),
            "Landing on the same second the provider rolls its counter is a send racing it"
        )
    }

    func testNoUsageReadingOffersNothingRatherThanGuessing() {
        XCTAssertTrue(
            ScheduledTimePresets.usageResets(
                usage: nil,
                metering: nil,
                now: Date(timeIntervalSince1970: 1_775_000_000)
            ).isEmpty
        )
    }
}
