import XCTest
@testable import Threading

/// What a build says about itself, and the two rules that are easy to get wrong: a reading nobody
/// can take is dropped rather than filled in, and the channel is never repeated as a row.
final class BuildDetailsTests: XCTestCase {

    // MARK: - Entries

    func testTheEntriesAreTheBuildInReadingOrder() {
        let details = fixture()

        XCTAssertEqual(
            details.entries.map(\.value),
            ["Debug", "17 Aug 2026 at 10:12", "macOS 26.1", "arm64"]
        )
        XCTAssertEqual(
            details.entries.map(\.label),
            ["Configuration", "Built", "System", "Architecture"]
        )
    }

    /// A build date the filesystem would not give up is one fewer line — not a line saying
    /// Unknown, which is a reading that reads like a fault.
    func testAnUnreadableBuildDateDropsItsLineRatherThanSayingUnknown() {
        let details = fixture(built: nil)

        XCTAssertEqual(details.entries.map(\.label), ["Configuration", "System", "Architecture"])
        XCTAssertFalse(details.helpTag.lowercased().contains("unknown"))
    }

    func testAnEmptyBuildDateIsTreatedAsNoDateAtAll() {
        XCTAssertEqual(
            fixture(built: "").entries.map(\.label),
            ["Configuration", "System", "Architecture"]
        )
    }

    // MARK: - Help Tag

    func testTheHelpTagOpensWithTheSentenceThenListsEveryReading() {
        XCTAssertEqual(
            fixture().helpTag,
            """
            Development build

            Version: 1.4.0 (212)
            Configuration: Debug
            Built: 17 Aug 2026 at 10:12
            System: macOS 26.1
            Architecture: arm64
            """
        )
    }

    /// A release build wears no mark, so it has no sentence to open with — and the lines are still
    /// the whole answer for whichever surface asked.
    func testAReleaseBuildsHelpTagIsTheReadingsWithNoHeadline() {
        let details = fixture(channel: .release)

        XCTAssertNil(details.channel.spokenName)
        XCTAssertTrue(
            details.helpTag.hasPrefix("Version: 1.4.0 (212)"),
            "a release build's Help Tag opens with \(details.helpTag.prefix(40))"
        )
        XCTAssertFalse(details.helpTag.hasPrefix("\n"))
    }

    // MARK: - Readings

    /// The pair every report spells the same way. `EventLog`, the issue submitters and
    /// `BuildFingerprint` each built this string themselves before it had one name.
    func testTheVersionSummaryIsTheOnePairSpelling() {
        XCTAssertEqual(AppInfo.versionSummary, "\(AppInfo.marketingVersion) (\(AppInfo.buildNumber))")
        XCTAssertEqual(BuildFingerprint.current.build, AppInfo.versionSummary)
    }

    /// The test host is a plain `xcodebuild` product, so neither version was stamped — the same
    /// tell `BuildChannelTests` reads for the channel.
    func testAnUnstampedBuildReportsThePlaceholderVersionPair() {
        XCTAssertEqual(AppInfo.marketingVersion, AppInfoDefaults.unknownVersion)
        XCTAssertEqual(AppInfo.buildNumber, AppInfoDefaults.unknownVersion)
    }

    func testTheSystemVersionIsComposedWithoutTheWordVersion() {
        XCTAssertTrue(BuildDetails.systemVersion.hasPrefix("macOS "))
        XCTAssertFalse(
            BuildDetails.systemVersion.contains("Version"),
            "the row's label already says System: \(BuildDetails.systemVersion)"
        )
    }

    /// Untranslated on purpose: these are the build system's own names, read against Xcode rather
    /// than against the reader's locale.
    func testTheConfigurationIsAnXcodeConfigurationName() {
        XCTAssertTrue(["Debug", "Release"].contains(BuildDetails.configuration))
#if DEBUG
        XCTAssertEqual(BuildDetails.configuration, "Debug")
#endif
    }

    func testTheArchitectureIsTheSliceThisBinaryWasCompiledFor() {
        XCTAssertTrue(["arm64", "x86_64"].contains(BuildDetails.architecture))
    }

    /// The build date is the executable's own modification time, for `BuildFingerprint`'s reason:
    /// on a build nobody stamped it is the only reading that moves between builds.
    func testTheBuildDateIsTheExecutablesModificationTime() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let stamped = try XCTUnwrap(
            try executable.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        )
        let read = try XCTUnwrap(BuildDetails.executableModifiedAt())

        XCTAssertEqual(read.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(BuildDetails.formatted(read), stamped.formatted(date: .abbreviated, time: .shortened))
        XCTAssertNil(BuildDetails.formatted(nil))
    }

    /// Read from the running process rather than written down, which is the whole point of the
    /// type: nothing here is a constant somebody has to remember to bump.
    func testTheCurrentBuildFillsEveryLineItCanTake() throws {
        let details = BuildDetails.current

        XCTAssertEqual(details.channel, AppInfo.buildChannel)
        XCTAssertEqual(details.versionSummary, AppInfo.versionSummary)
        XCTAssertTrue(details.entries.allSatisfy { !$0.label.isEmpty && !$0.value.isEmpty })
        XCTAssertEqual(
            details.entries.map(\.label),
            ["Configuration", "Built", "System", "Architecture"],
            "the test host's own executable should be stat-able"
        )
    }

    // MARK: - Helpers

    private func fixture(
        channel: BuildChannel = .dev,
        built: String? = "17 Aug 2026 at 10:12"
    ) -> BuildDetails {
        BuildDetails(
            channel: channel,
            versionSummary: "1.4.0 (212)",
            configuration: "Debug",
            built: built,
            system: "macOS 26.1",
            architecture: "arm64"
        )
    }
}
