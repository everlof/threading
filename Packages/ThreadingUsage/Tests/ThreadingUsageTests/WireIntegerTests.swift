import Foundation
import XCTest
@testable import ThreadingUsage

/// `WireInteger`'s own contract. Why it exists, and what Foundation does with an oversized JSON
/// integer on macOS, is measured in the app's `WireIntegerTests`.
final class WireIntegerTests: XCTestCase {
    // MARK: - WireInteger

    func testExactKeepsWhatInt64HoldsAndRefusesTheRest() throws {
        XCTAssertNil(WireInteger.exact(try wireNumber("12345678901234567890")))
        XCTAssertNil(WireInteger.exact(try wireNumber("9223372036854775808")))
        XCTAssertNil(WireInteger.exact(try wireNumber("-12345678901234567890")))
        XCTAssertNil(WireInteger.exact(try wireNumber("18446744073709551615")))
        XCTAssertNil(WireInteger.exact(try wireNumber("1e30")))

        XCTAssertEqual(WireInteger.exact(try wireNumber("9223372036854775807")), 9223372036854775807)
        XCTAssertEqual(
            WireInteger.exact(try wireNumber("-9223372036854775808")), -9223372036854775808
        )
        XCTAssertEqual(WireInteger.exact(try wireNumber("2.0")), 2, "an integral double is an integer")
        XCTAssertEqual(WireInteger.exact(try wireNumber("0")), 0)
        XCTAssertEqual(WireInteger.exact(try wireNumber("1")), 1)
        XCTAssertNil(WireInteger.exact(try wireNumber("1.5")), "not a whole number")
    }

    func testWholeTruncatesTheWayInt64ValueDoesAndStillRefusesTheOversized() throws {
        XCTAssertEqual(WireInteger.whole(try wireNumber("1.5")), 1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("100.4")), 100)
        XCTAssertEqual(WireInteger.whole(try wireNumber("100.6")), 100, "toward zero, not nearest")
        XCTAssertEqual(WireInteger.whole(try wireNumber("-1.5")), -1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("9223372036854775807")), 9223372036854775807)

        XCTAssertNil(WireInteger.whole(try wireNumber("12345678901234567890")))
        XCTAssertNil(WireInteger.whole(try wireNumber("9223372036854775808")))
        XCTAssertNil(WireInteger.whole(try wireNumber("-12345678901234567890")))
        XCTAssertNil(WireInteger.whole(try wireNumber("1e30")), "int64Value would saturate here")

        // A boolean is a number to `NSNumber`, and the two readers that reach `whole` were
        // already counting one as a token. That behaviour is preserved deliberately.
        XCTAssertEqual(WireInteger.whole(try wireNumber("true")), 1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("false")), 0)
    }

    private func wireNumber(_ text: String) throws -> NSNumber {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
        )
        return try XCTUnwrap(object["v"] as? NSNumber)
    }
}
