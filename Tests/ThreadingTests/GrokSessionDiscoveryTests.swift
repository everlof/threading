import XCTest
@testable import Threading

final class GrokSessionDiscoveryTests: XCTestCase {

    func testFindsExactSessionIDInHumanReadableListing() {
        let expected = TranscriptID("01935b8d-8f29-7abc-9def-0123456789ab")
        let output = """
        ID                                    TITLE                  UPDATED
        01935b8d-8f29-7abc-9def-0123456789ab  Inspect session state  just now
        """

        XCTAssertTrue(GrokSessionDiscovery.contains(expected, in: output))
    }

    func testMatchingIsCaseInsensitiveAndSurvivesTableDecoration() {
        let expected = TranscriptID("01935b8d-8f29-7abc-9def-0123456789ab")
        let output = "\u{001B}[36m│ 01935B8D-8F29-7ABC-9DEF-0123456789AB │ active │\u{001B}[0m"

        XCTAssertTrue(GrokSessionDiscovery.contains(expected, in: output))
    }

    func testRejectsDifferentAndEmbeddedIdentifiers() {
        let expected = TranscriptID("01935b8d-8f29-7abc-9def-0123456789ab")

        XCTAssertFalse(GrokSessionDiscovery.contains(
            expected,
            in: "01935b8d-8f29-7abc-9def-0123456789ac"
        ))
        XCTAssertFalse(GrokSessionDiscovery.contains(
            expected,
            in: "prefixa01935b8d-8f29-7abc-9def-0123456789abf"
        ))
        XCTAssertFalse(GrokSessionDiscovery.contains(expected, in: "No sessions found."))
    }
}
