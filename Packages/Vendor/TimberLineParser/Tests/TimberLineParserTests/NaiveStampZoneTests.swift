import XCTest
@testable import TimberLineParser

/// A stamp that names no zone is read as UTC, and that is a convention worth a test.
///
/// It used to be read with `TimeZone.current.secondsFromGMT()` cached at load — the offset *now*,
/// not at the stamp's own instant. So a January line parsed during summer time came out an hour
/// adrift, and the same file parsed either side of a DST change, or in two places, produced two
/// different instants for the same line. Nothing in the suite noticed, which is why this exists.
final class NaiveStampZoneTests: XCTestCase {

    private func utc(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return try XCTUnwrap(formatter.date(from: text))
    }

    private func parse(_ line: String) throws -> Date {
        try XCTUnwrap(TimestampParser.tryAllTimestampFormats(bytes: Array(line.utf8)).0)
    }

    /// Winter and summer dates both, because the bug was that the *current* offset was applied
    /// regardless of the stamp's own date — so one season passing proves nothing about the other.
    func testANaiveStampIsReadAsUTCWhateverTheSeason() throws {
        XCTAssertEqual(try parse("2024-01-15 10:30:45.123 something"),
                       try utc("2024-01-15 10:30:45.123"))
        XCTAssertEqual(try parse("2024-07-15 10:30:45.123 something"),
                       try utc("2024-07-15 10:30:45.123"))
    }

    /// The property the convention buys: the instant is the characters, so formatting it back in
    /// UTC returns what the file said. Nothing else recovers a zone a log never wrote down.
    func testTheInstantRoundTripsBackToTheCharactersTheFileWrote() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(formatter.string(from: try parse("2024-01-15 10:30:45.123 x")), "10:30:45.123")
        XCTAssertEqual(formatter.string(from: try parse("[2024-01-15 10:30:45] x")), "10:30:45.000")
    }

    /// A format that *does* name an offset keeps using it — the convention is only for the silence.
    func testAStampThatNamesItsOffsetIsUnaffected() throws {
        XCTAssertEqual(try parse("2024-01-15T12:30:45.000+02:00 x"),
                       try utc("2024-01-15 10:30:45.000"))
    }
}
