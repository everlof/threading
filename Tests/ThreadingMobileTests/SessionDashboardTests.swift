import XCTest
@testable import ThreadingMobile

final class SessionDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// The age is one narrow unit, and never a signed quantity: `RelativeDateTimeFormatter`'s
    /// abbreviated Swedish wrote yesterday as `−1 d`, which is what a duration can never do.
    func testSwedishAgeIsOneNarrowUnitWithoutAMinusSign() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "sv_SE")
        )

        // Swedish sets the unit off with a narrow no-break space; the digits and the unit are
        // the assertion, not which space stands between them.
        XCTAssertEqual(age.filter { !$0.isWhitespace }, "1d")
        XCTAssertFalse(age.contains("−"), age)
        XCTAssertFalse(age.contains("-"), age)
    }

    func testEnglishAgeIsOneNarrowUnitWithoutADirectionWord() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-6 * 60), relativeTo: now, locale: english
            ),
            "6m"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-3 * 60 * 60), relativeTo: now, locale: english
            ),
            "3h"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-24 * 60 * 60), relativeTo: now, locale: english
            ),
            "1d"
        )
    }

    /// Past a week the age stops counting and names the day, in the reader's own calendar order.
    func testAWeekOldSessionShowsItsDate() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-8 * 24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertFalse(age.contains("d"), age)
        XCTAssertTrue(age.contains("Jan"), age)
    }

    func testFutureClockSkewDoesNotProduceANegativeAge() {
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(60 * 60),
                relativeTo: now,
                locale: Locale(identifier: "sv_SE")
            ),
            MobileL10n.string("now")
        )
    }

    func testRootNavigationTitleNamesTheConnectedMac() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: nil,
                activeHostName: "David’s MacBook Pro"
            ),
            "David’s MacBook Pro"
        )
    }

    func testProjectNavigationTitleNamesTheProject() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: "AnotherTerminal",
                activeHostName: "David’s MacBook Pro"
            ),
            "AnotherTerminal"
        )
    }

    func testConnectedNavigationStatusIncludesTheActiveRoute() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .online,
                connectionLabel: "Tailscale"
            ),
            MobileL10n.string("Connected · %@", "Tailscale")
        )
    }

    func testOfflineNavigationStatusDoesNotPutATransportErrorInTheTitleBar() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .offline("The operation timed out after 60 seconds"),
                connectionLabel: "Relay"
            ),
            MobileL10n.string("Not connected")
        )
    }
}
