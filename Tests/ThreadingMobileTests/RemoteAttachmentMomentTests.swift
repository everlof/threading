import Foundation
import XCTest
@testable import ThreadingMobile

final class RemoteAttachmentMomentTests: XCTestCase {
    func testDescriptionAlwaysIncludesLocalizedDateYearAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: 9,
            hour: 19,
            minute: 50
        )))

        XCTAssertEqual(
            MobileAttachmentMoment.description(
                of: date,
                calendar: calendar,
                locale: Locale(identifier: "sv_SE")
            ),
            "2026-09-09 19:50"
        )
    }
}
