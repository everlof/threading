import XCTest
@testable import ThreadingRemoteKit

final class UsageLimitChartFormTests: XCTestCase {
    private let day = 86_400.0
    private let hour = 3_600.0

    /// A weekly window is a line at every range. A five-hour window is a line at none of them,
    /// and its column bucket grows with the range: the window itself over a week, whole days
    /// over a month, three-day spans over a quarter. Without a stated window length the
    /// observed cycles decide.
    func testFormFollowsWindowDensity() {
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 7 * day, windowDuration: 7 * day, observedCycles: 1),
            .line
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 90 * day, windowDuration: 7 * day, observedCycles: 13),
            .line
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 7 * day, windowDuration: 5 * hour, observedCycles: 1),
            .peaks(bucket: 5 * hour)
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 30 * day, windowDuration: 5 * hour, observedCycles: 1),
            .peaks(bucket: day)
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 90 * day, windowDuration: 5 * hour, observedCycles: 1),
            .peaks(bucket: 3 * day)
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 30 * day, windowDuration: nil, observedCycles: 40),
            .peaks(bucket: day)
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 30 * day, windowDuration: nil, observedCycles: 3),
            .line
        )
        XCTAssertEqual(
            UsageLimitChartForm.resolve(span: 0, windowDuration: 5 * hour, observedCycles: 100),
            .line
        )
        XCTAssertNil(UsageLimitChartForm.bucketDays(5 * hour))
        XCTAssertEqual(UsageLimitChartForm.bucketDays(day), 1)
        XCTAssertEqual(UsageLimitChartForm.bucketDays(3 * day), 3)
    }

    /// A column is the highest reading inside its bucket, a day-sized bucket starts on the
    /// calendar day rather than at the range's own hour, a reading at the ceiling names the
    /// limit, and a point outside the range is not a column.
    func testPeaksKeepTheHighestReadingPerBucketAndNameTheLimit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = 1_800_000_000.0
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970
        XCTAssertLessThan(startOfDay, start, "the fixture must begin inside a day, not on its edge")
        let end = start + 3 * day
        let observations = [
            UsageLimitChartObservation(at: start, fraction: 0.2),
            UsageLimitChartObservation(at: start + hour, fraction: 0.9),
            UsageLimitChartObservation(at: start + 4 * hour, fraction: 0.05),
            UsageLimitChartObservation(at: start + day, fraction: 1),
            UsageLimitChartObservation(at: start + 2 * day + hour, fraction: 0.4),
            UsageLimitChartObservation(at: end + 10, fraction: 0.99),
        ]

        let daily = UsageLimitChartForm.peaks(
            observations,
            start: start,
            end: end,
            bucket: day,
            calendar: calendar
        )
        XCTAssertEqual(daily.map(\.start), [startOfDay, startOfDay + day, startOfDay + 2 * day])
        XCTAssertEqual(daily.map(\.fraction), [0.9, 1, 0.4])
        XCTAssertEqual(daily.map(\.observations), [3, 1, 1])
        XCTAssertEqual(daily.map(\.reachedLimit), [false, true, false])

        let perWindow = UsageLimitChartForm.peaks(
            observations,
            start: start,
            end: end,
            bucket: 5 * hour,
            calendar: calendar
        )
        XCTAssertEqual(perWindow.first?.start, start, "a window-sized bucket starts with the range")
        XCTAssertEqual(perWindow.first?.fraction, 0.9)

        XCTAssertEqual(
            UsageLimitChartForm.peaks(observations, start: start, end: end, bucket: 0, calendar: calendar),
            []
        )
    }
}
