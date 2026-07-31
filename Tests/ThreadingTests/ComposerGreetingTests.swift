import Foundation
import XCTest
@testable import Threading

/// The greeting generator: deterministic under a seeded generator, honest about its clock
/// boundaries, and only special on the days that are actually special.
final class ComposerGreetingTests: XCTestCase {

    /// SplitMix64 — a tiny deterministic generator, so a test names its seed and the pick is a
    /// fact rather than a flake.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: 30
        ))!
    }

    // MARK: - Determinism

    func testSameSeedAndDateProduceTheSameMessage() {
        let moment = date(2026, 3, 10, 14)
        var first = SeededGenerator(state: 7)
        var second = SeededGenerator(state: 7)
        XCTAssertEqual(
            ComposerGreeting.message(on: moment, calendar: calendar, using: &first),
            ComposerGreeting.message(on: moment, calendar: calendar, using: &second)
        )
    }

    func testMessageIsAlwaysDrawnFromTheMomentsOwnCandidates() {
        let moments = [
            date(2026, 3, 10, 14),   // ordinary Tuesday afternoon
            date(2026, 7, 31, 20),   // Friday evening
            date(2026, 12, 31, 23),  // New Year's Eve, late
            date(2026, 3, 14, 8)     // Saturday morning
        ]
        for moment in moments {
            let candidates = ComposerGreeting.candidates(for: moment, calendar: calendar)
            let all = Set(candidates.plain + candidates.daypart + candidates.special)
            for seed in UInt64(0)..<40 {
                var generator = SeededGenerator(state: seed)
                let message = ComposerGreeting.message(
                    on: moment, calendar: calendar, using: &generator
                )
                XCTAssertTrue(all.contains(message), "\(message) is not a candidate for \(moment)")
            }
        }
    }

    // MARK: - Clock boundaries

    func testDaypartBoundaries() {
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 4), .lateNight)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 5), .morning)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 11), .morning)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 12), .afternoon)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 16), .afternoon)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 17), .evening)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 22), .evening)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 23), .lateNight)
        XCTAssertEqual(ComposerGreeting.Daypart.of(hour: 0), .lateNight)
    }

    // MARK: - Specials

    func testAnOrdinaryTuesdayOffersNoSpecials() {
        let tuesday = date(2026, 3, 10, 14)
        XCTAssertEqual(calendar.component(.weekday, from: tuesday), 3, "Fixture must be a Tuesday")
        let candidates = ComposerGreeting.candidates(for: tuesday, calendar: calendar)
        XCTAssertTrue(candidates.special.isEmpty)
        XCTAssertFalse(candidates.plain.isEmpty)
        XCTAssertFalse(candidates.daypart.isEmpty)
    }

    func testDateSpecialsFireOnTheirDatesAndNotOffThem() {
        let halloween = ComposerGreeting.candidates(
            for: date(2026, 10, 31, 12), calendar: calendar
        )
        XCTAssertTrue(halloween.special.contains { $0.contains("Spooky") })

        let dayAfter = ComposerGreeting.candidates(
            for: date(2026, 11, 2, 12), calendar: calendar
        )
        XCTAssertFalse(dayAfter.special.contains { $0.contains("Spooky") })

        let midsummer = ComposerGreeting.candidates(
            for: date(2026, 6, 22, 12), calendar: calendar
        )
        XCTAssertTrue(midsummer.special.contains { $0.contains("Midsummer") })

        let newYear = ComposerGreeting.candidates(
            for: date(2026, 1, 1, 10), calendar: calendar
        )
        XCTAssertTrue(newYear.special.contains { $0.contains("New year") })
    }

    func testFridayKnowsItIsFriday() {
        let friday = date(2026, 7, 31, 10)
        XCTAssertEqual(calendar.component(.weekday, from: friday), 6, "Fixture must be a Friday")
        let candidates = ComposerGreeting.candidates(for: friday, calendar: calendar)
        XCTAssertTrue(candidates.special.contains { $0.contains("Friday") })
    }

    func testCombinedEntriesNeedBothConditions() {
        let fridayEvening = ComposerGreeting.candidates(
            for: date(2026, 7, 31, 20), calendar: calendar
        )
        XCTAssertTrue(fridayEvening.special.contains { $0.contains("Friday evening") })

        let fridayMorning = ComposerGreeting.candidates(
            for: date(2026, 7, 31, 9), calendar: calendar
        )
        XCTAssertFalse(fridayMorning.special.contains { $0.contains("Friday evening") })

        let saturdayMorning = date(2026, 3, 14, 8)
        XCTAssertEqual(calendar.component(.weekday, from: saturdayMorning), 7, "Fixture must be a Saturday")
        let weekendMorning = ComposerGreeting.candidates(for: saturdayMorning, calendar: calendar)
        XCTAssertTrue(weekendMorning.special.contains { $0.contains("weekend morning") })

        let saturdayNight = ComposerGreeting.candidates(
            for: date(2026, 3, 14, 23), calendar: calendar
        )
        XCTAssertFalse(saturdayNight.special.contains { $0.contains("weekend morning") })

        let lastHours = ComposerGreeting.candidates(
            for: date(2026, 12, 31, 23), calendar: calendar
        )
        XCTAssertTrue(lastHours.special.contains { $0.contains("Seeing the year out") })
        let newYearsEveMorning = ComposerGreeting.candidates(
            for: date(2026, 12, 31, 9), calendar: calendar
        )
        XCTAssertFalse(newYearsEveMorning.special.contains { $0.contains("Seeing the year out") })
    }

    // MARK: - Pool hygiene

    func testEveryPoolIsPopulatedAndFitsAHeading() {
        let moments = [
            date(2026, 3, 10, 8), date(2026, 3, 10, 14),
            date(2026, 3, 10, 20), date(2026, 3, 10, 2),
            date(2026, 12, 31, 23), date(2026, 3, 14, 8)
        ]
        for moment in moments {
            let candidates = ComposerGreeting.candidates(for: moment, calendar: calendar)
            XCTAssertFalse(candidates.plain.isEmpty)
            XCTAssertFalse(candidates.daypart.isEmpty)
            for greeting in candidates.plain + candidates.daypart + candidates.special {
                XCTAssertFalse(greeting.isEmpty)
                XCTAssertLessThanOrEqual(
                    greeting.count, 60,
                    "\(greeting) is a paragraph, not a greeting"
                )
            }
        }
    }
}
