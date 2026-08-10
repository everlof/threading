import XCTest
@testable import Threading

/// The one-shot answers a recovery launch leaves for the next one.
///
/// Every case here is about the same worry: a one-shot that cannot be cleared is a permanent
/// setting, and a permanent "always launch normally" would defeat the crash-loop protection
/// outright while looking exactly like an app that had recovered.
final class LaunchFlagsStoreTests: XCTestCase {

    // MARK: - Fixture

    private var directory = URL(fileURLWithPath: "/")
    private var flagsURL: URL { directory.appendingPathComponent("launch-flags.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LaunchFlagsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func store(_ fileManager: FileManager = .default) -> LaunchFlagsStore {
        LaunchFlagsStore(url: flagsURL, fileManager: fileManager)
    }

    private func record() throws -> [String: Any] {
        let data = try Data(contentsOf: flagsURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Reading

    /// Nothing on disk is nothing armed, and asking must not create a file: a launch that never
    /// visited recovery should leave the directory exactly as it found it.
    func testNoFileMeansNoFlagsAndWritesNothing() {
        XCTAssertEqual(store().read(), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagsURL.path))
    }

    /// The ledger's posture, for its reason: the cost of being wrong about a newer build is that
    /// build's own state, and the cost of standing down is one launch that ignores a one-shot.
    func testARecordFromALaterBuildIsIgnoredAndLeftExactlyAsFound() throws {
        let raw = Data(#"{"version":99,"forceNormalNextLaunch":true,"disableExtensionsNextLaunch":true}"#.utf8)
        try raw.write(to: flagsURL)

        let store = store()
        XCTAssertEqual(store.read(), .none)
        XCTAssertFalse(store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1"))
        XCTAssertEqual(try Data(contentsOf: flagsURL), raw)
    }

    func testDamageIsReadAsNoFlagsRatherThanCrashing() throws {
        let raw = Data("{not json".utf8)
        try raw.write(to: flagsURL)
        let store = store()
        XCTAssertEqual(store.read(), .none)
        XCTAssertFalse(store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1"))
        XCTAssertEqual(
            try Data(contentsOf: flagsURL),
            raw,
            "arming a flag replaced the only copy of an unreadable shared record"
        )
    }

    func testOversizedFlagsAreIgnoredAndPreserved() throws {
        let raw = Data(repeating: 0x61, count: LaunchFlagsDefaults.maximumFileBytes + 1)
        try raw.write(to: flagsURL)
        let store = store()

        XCTAssertEqual(store.read(), .none)
        XCTAssertFalse(store.set(.disableExtensionsNextLaunch, armed: true, launchID: "launch-1"))
        XCTAssertEqual(try Data(contentsOf: flagsURL), raw)
    }

    // MARK: - Arming

    func testArmingOneFlagLeavesTheOtherAlone() {
        let store = store()
        store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1")

        let flags = store.read()
        XCTAssertTrue(flags.forceNormalNextLaunch)
        XCTAssertFalse(flags.disableExtensionsNextLaunch)
        XCTAssertEqual(flags.armedByLaunch, "launch-1")
        XCTAssertNotNil(flags.armedAt)
    }

    /// Pressing the button again disarms it. The surface's title is a state rather than a command
    /// for exactly this reason: a flag nobody can take back is a setting.
    func testArmingIsReversible() {
        let store = store()
        store.set(.disableExtensionsNextLaunch, armed: true, launchID: "launch-1")
        store.set(.disableExtensionsNextLaunch, armed: false, launchID: "launch-1")

        XCTAssertFalse(store.read().disableExtensionsNextLaunch)
        XCTAssertFalse(store.read().isArmed)
    }

    // MARK: - Consuming

    func testConsumingReturnsWhatWasArmedAndClearsIt() {
        let store = store()
        store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1")

        let consumed = store.consume(launchID: "launch-2")
        XCTAssertTrue(consumed.forceNormalNextLaunch)
        XCTAssertFalse(store.read().forceNormalNextLaunch, "the flag survived its own launch")
    }

    /// **Cleared by rewriting, never by deleting.** There is no "cleared versus never set"
    /// question to answer here; what the positive record buys is a support report that can say a
    /// forced-normal launch was armed by one launch and spent by another, which is the whole
    /// "and then *that* one crashed too" story.
    func testConsumingLeavesAPositiveRecordOfWhoSpentIt() throws {
        let store = store()
        store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1")
        _ = store.consume(launchID: "launch-2")

        let record = try record()
        XCTAssertEqual(record["forceNormalNextLaunch"] as? Bool, false)
        XCTAssertEqual(record["disableExtensionsNextLaunch"] as? Bool, false)
        XCTAssertEqual(record["armedByLaunch"] as? String, "launch-1")
        XCTAssertEqual(record["consumedByLaunch"] as? String, "launch-2")
    }

    /// Consuming nothing writes nothing. Most launches never visit recovery, and none of them
    /// should be touching this file on the way up.
    func testConsumingWhenNothingIsArmedWritesNothing() {
        XCTAssertEqual(store().consume(launchID: "launch-1"), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagsURL.path))
    }

    /// **Fail closed.** A clear that cannot land makes the flag permanent, and a permanent
    /// "always launch normally" is the crash-loop protection switched off with nothing on screen
    /// to say so. Ignoring it costs one more crash and one more press of a button.
    func testAFlagThatCannotBeClearedIsNotHonoured() {
        let store = store()
        store.set(.forceNormalNextLaunch, armed: true, launchID: "launch-1")
        XCTAssertTrue(store.read().forceNormalNextLaunch)

        let refusing = LaunchFlagsStore(url: flagsURL, fileManager: RefusingWriteFileManager())
        XCTAssertEqual(
            refusing.consume(launchID: "launch-2"),
            .none,
            "a one-shot that could not be cleared was acted on anyway"
        )
    }

    // MARK: - Where It Lives

    /// Beside the ledger, in the directory that already redirects under a hosted test bundle — so
    /// a test that arms a flag cannot decide what the developer's own next launch does.
    func testTheDefaultLocationSitsBesideTheLedgerAndRedirectsUnderTests() {
        XCTAssertEqual(
            LaunchFlagsDefaults.defaultURL.deletingLastPathComponent(),
            LaunchLedgerDefaults.defaultURL.deletingLastPathComponent()
        )
        XCTAssertTrue(
            LaunchFlagsDefaults.defaultURL.path
                .contains(LaunchLedgerDefaults.hostedTestDirectoryName),
            "a hosted test would have armed the developer's own next launch"
        )
    }
}

// MARK: - Refusing Write File Manager

/// A file system that will not let the directory be created, which is how a write is made to fail
/// without depending on permissions the test host may or may not have.
private final class RefusingWriteFileManager: FileManager, @unchecked Sendable {

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
