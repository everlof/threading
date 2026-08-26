import XCTest
@testable import ThreadingPTYHostKit

final class PTYHostGenerationTests: XCTestCase {

    func testAReleaseGenerationUsesTheTwoBundleVersions() {
        XCTAssertEqual(
            PTYHostGeneration.string(
                shortVersion: "1.4.0",
                bundleVersion: "104",
                sourceRevision: nil
            ),
            "1.4.0 (104)"
        )
    }

    func testAnAutoinstallGenerationIncludesItsSourceRevision() {
        XCTAssertEqual(
            PTYHostGeneration.string(
                shortVersion: "0.0.0",
                bundleVersion: "0.0.0",
                sourceRevision: " 1552f778 "
            ),
            "0.0.0 (0.0.0) @1552f778"
        )
    }

    func testMissingAndEmptyValuesHaveOneCanonicalSpelling() {
        XCTAssertEqual(
            PTYHostGeneration.string(
                shortVersion: nil,
                bundleVersion: " ",
                sourceRevision: "\n"
            ),
            "? (?)"
        )
    }
}
