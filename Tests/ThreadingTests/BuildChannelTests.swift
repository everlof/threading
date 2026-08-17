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

            // The drawn title is shouted; what VoiceOver reads is the spelled-out name, so the
            // mark never relies on an abbreviation alone.
            let spoken = try XCTUnwrap(BuildChannelBadge.spokenName(for: channel))
            XCTAssertEqual(badge.accessibilityLabel(), spoken)
            XCTAssertNotEqual(spoken, badge.stringValue)
        }
    }

    func testTheBadgeTitlesAreDistinctSoAScreenshotSaysWhichBuild() {
        let titles = [BuildChannel.dev, .nightly, .beta].compactMap(BuildChannelBadge.title(for:))
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    // MARK: - Help Tag

    /// Hovering the mark is the one gesture that asks what this copy of the app is, and it used
    /// to answer with a synonym for the three letters already on screen. The Help Tag opens with
    /// that sentence and then keeps going.
    func testTheBadgeHelpTagCarriesTheWholeBuildRatherThanJustTheSentence() throws {
        let details = BuildDetails(
            channel: .dev,
            versionSummary: "1.4.0 (212)",
            configuration: "Debug",
            built: "17 Aug 2026 at 10:12",
            system: "macOS 26.1",
            architecture: "arm64"
        )
        let badge = try XCTUnwrap(BuildChannelBadge.make(details))
        let helpTag = try XCTUnwrap(badge.toolTip)
        let spoken = try XCTUnwrap(BuildChannelBadge.spokenName(for: .dev))

        XCTAssertTrue(
            helpTag.hasPrefix(spoken),
            "the Help Tag no longer opens with what the mark means: \(helpTag)"
        )
        for reading in ["1.4.0 (212)", "Debug", "17 Aug 2026 at 10:12", "macOS 26.1", "arm64"] {
            XCTAssertTrue(helpTag.contains(reading), "the Help Tag dropped \(reading)")
        }
        // The same answer for whoever never sees a Help Tag — on `accessibilityHelp`, so the
        // mark still announces as itself rather than reciting a build.
        XCTAssertEqual(badge.accessibilityHelp(), helpTag)
        XCTAssertEqual(badge.accessibilityLabel(), spoken)
    }

    /// The mark's own name is not repeated as a row: a Channel line would say the thing twice,
    /// and on a release build it would name the channel whose design is to go unmarked.
    func testTheHelpTagDoesNotRepeatTheChannelAsARow() {
        let details = BuildDetails(
            channel: .dev,
            versionSummary: "1.4.0 (212)",
            configuration: "Debug",
            built: nil,
            system: "macOS 26.1",
            architecture: "arm64"
        )
        XCTAssertFalse(
            details.entries.contains { $0.value == BuildChannel.dev.spokenName },
            "the channel came back as a detail row"
        )
        XCTAssertEqual(
            details.helpTag.components(separatedBy: "Development build").count - 1, 1,
            "the channel is stated twice in one Help Tag"
        )
    }
}
