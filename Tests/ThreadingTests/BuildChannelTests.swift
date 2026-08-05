import AppKit
import XCTest
@testable import Threading

/// The channel a build was stamped with, and the badge that shows it.
///
/// The parsing rule under test is fail-closed: anything that is not a value the release
/// pipeline deliberately wrote — absent, empty, or foreign — is a dev build, for the same
/// reason the version placeholder is 0.0.0. A build must not be able to claim it is a release
/// by accident.
@MainActor
final class BuildChannelTests: XCTestCase {

    // MARK: - Parsing

    func testAnAbsentEmptyOrForeignChannelValueIsADevBuild() {
        XCTAssertEqual(BuildChannel(infoValue: nil), .dev)
        XCTAssertEqual(BuildChannel(infoValue: ""), .dev)
        XCTAssertEqual(BuildChannel(infoValue: "canary"), .dev)
        XCTAssertEqual(BuildChannel(infoValue: "Release"), .dev, "the stamp is exact, not fuzzy")
        XCTAssertEqual(BuildChannel(infoValue: 7), .dev)
    }

    func testEveryStampedChannelParsesToItself() {
        for channel in BuildChannel.allCases {
            XCTAssertEqual(BuildChannel(infoValue: channel.rawValue), channel)
        }
    }

    /// The test host is a plain `xcodebuild` product, so `$(THREADING_CHANNEL)` expanded to
    /// the empty string. If this fails, the placeholder mechanics in Info.plist changed.
    func testTheTestHostIsADevBuild() {
        XCTAssertEqual(AppInfo.buildChannel, .dev)
    }

    // MARK: - Badge

    func testAReleaseBuildWearsNoBadge() {
        XCTAssertNil(BuildChannelBadge.make(for: .release))
        XCTAssertNil(BuildChannelBadge.title(for: .release))
        XCTAssertNil(BuildChannelBadge.spokenName(for: .release))
    }

    func testEveryOtherChannelNamesItselfOnTheBadge() throws {
        for channel in [BuildChannel.dev, .nightly, .beta] {
            let badge = try XCTUnwrap(BuildChannelBadge.make(for: channel))
            XCTAssertFalse(badge.stringValue.isEmpty)

            // The drawn title is shouted; what VoiceOver reads and the tooltip explains is
            // the spelled-out name, so the mark never relies on an abbreviation alone.
            let spoken = try XCTUnwrap(BuildChannelBadge.spokenName(for: channel))
            XCTAssertEqual(badge.accessibilityLabel(), spoken)
            XCTAssertEqual(badge.toolTip, spoken)
            XCTAssertNotEqual(spoken, badge.stringValue)
        }
    }

    func testTheBadgeTitlesAreDistinctSoAScreenshotSaysWhichBuild() {
        let titles = [BuildChannel.dev, .nightly, .beta].compactMap(BuildChannelBadge.title(for:))
        XCTAssertEqual(Set(titles).count, titles.count)
    }
}
