import Foundation
import XCTest
@testable import ThreadingDomain

final class AutomationScheduleTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func date(_ text: String) -> Date { iso.date(from: text)! }

    /// Stockholm repeats 02:00–03:00 on 2026-10-25: 02:30 is 00:30Z, then 01:30Z. A sweep that
    /// fired on the first copy recomputes from a moment just after it, and must not land on the
    /// second copy of the same wall-clock time.
    func testRepeatedHourFiresOnceAfterTheFirstCopy() throws {
        let schedule = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30)
        XCTAssertEqual(try schedule.next(after: date("2026-10-25T00:00:00Z")), date("2026-10-25T00:30:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-10-25T00:30:00Z")), date("2026-10-26T01:30:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-10-25T00:30:01Z")), date("2026-10-26T01:30:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-10-25T00:30:15Z")), date("2026-10-26T01:30:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-10-25T01:30:00Z")), date("2026-10-26T01:30:00Z"))
    }

    func testWeeklyRepeatedHourFiresOnce() throws {
        // New York repeats 01:00–02:00 on Sunday 2026-11-01: 01:30 is 05:30Z, then 06:30Z.
        let schedule = AutomationSchedule(kind: .weekly, timeZone: "America/New_York", hour: 1, minute: 30, days: [1])
        XCTAssertEqual(try schedule.next(after: date("2026-10-31T12:00:00Z")), date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-11-01T05:30:01Z")), date("2026-11-08T06:30:00Z"))
    }

    func testNonexistentHourAdvancesWithinItsDay() throws {
        let schedule = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30)
        // 02:30 does not exist on 2026-03-29; the run moves to 03:00 CEST (01:00Z) that day.
        XCTAssertEqual(try schedule.next(after: date("2026-03-29T00:00:00Z")), date("2026-03-29T01:00:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-03-29T01:00:00Z")), date("2026-03-30T00:30:00Z"))
    }

    func testSelectedWeekdaysChooseTheEarliestDay() throws {
        let schedule = AutomationSchedule(kind: .weekdays, timeZone: "UTC", hour: 9, minute: 0, days: [2, 6])
        // 2026-10-27 is a Tuesday: the next Friday (6) comes before the next Monday (2).
        XCTAssertEqual(try schedule.next(after: date("2026-10-27T10:00:00Z")), date("2026-10-30T09:00:00Z"))
        XCTAssertEqual(try schedule.next(after: date("2026-10-30T09:00:00Z")), date("2026-11-02T09:00:00Z"))
    }

    func testLatestOccurrenceLabelsACatchUp() throws {
        let daily = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 9, minute: 0)
        XCTAssertEqual(try daily.latest(onOrBefore: date("2026-10-28T12:00:00Z")), date("2026-10-28T08:00:00Z"))
        XCTAssertEqual(try daily.latest(onOrBefore: date("2026-10-28T07:59:59Z")), date("2026-10-27T08:00:00Z"))
        XCTAssertEqual(try daily.latest(onOrBefore: date("2026-10-28T08:00:00Z")), date("2026-10-28T08:00:00Z"))

        let monday = AutomationSchedule(kind: .weekly, timeZone: "UTC", hour: 9, minute: 0, days: [2])
        XCTAssertEqual(try monday.latest(onOrBefore: date("2026-11-01T12:00:00Z")), date("2026-10-26T09:00:00Z"))

        let repeated = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30)
        XCTAssertEqual(try repeated.latest(onOrBefore: date("2026-10-25T01:45:00Z")), date("2026-10-25T00:30:00Z"))

        let interval = AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 60,
                                          anchor: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try interval.latest(onOrBefore: Date(timeIntervalSince1970: 3_650))?.timeIntervalSince1970, 3_600)
        XCTAssertNil(try AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 60,
                                            anchor: Date(timeIntervalSince1970: 7_200))
            .latest(onOrBefore: Date(timeIntervalSince1970: 3_650)))
    }

    func testAnchorSurvivesOneRoundTrip() throws {
        let schedule = AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 5,
                                          anchor: Date(timeIntervalSince1970: 1_000.75))
        XCTAssertEqual(schedule.anchor.timeIntervalSince1970, 1_000)
        let decoded = try JSONDecoder().decode(AutomationSchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(decoded, schedule)
        XCTAssertEqual(AutomationSchedule(kind: .daily, timeZone: "UTC").anchor.timeIntervalSince1970, 0)
    }
}
