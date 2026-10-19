import XCTest
@testable import Threading

/// The answering `PostToolUseFailure` hook that tells an agent the disk is short when a tool call
/// fails. It must stay silent on a healthy disk, say so once rather than on every failure of a
/// full one, and recognise the errors Xcode prints for a full disk without saying so.
@MainActor
final class DiskPressureNoticeTests: XCTestCase {

    // MARK: - Fixtures

    private let gigabyte: Int64 = 1_000_000_000

    private var full: DiskSpace.Reading {
        DiskSpace.Reading(available: 3 * gigabyte, capacity: 1_000 * gigabyte)
    }

    private var roomy: DiskSpace.Reading {
        DiskSpace.Reading(available: 400 * gigabyte, capacity: 1_000 * gigabyte)
    }

    private func failure(_ error: String?, interrupt: Bool = false) -> DiskPressureFailure {
        DiskPressureFailure(error: error, isInterrupt: interrupt)
    }

    /// The decision with eligibility granted, so no test reaches the project store.
    private func decide(
        _ session: SessionID,
        failure: DiskPressureFailure,
        reading: DiskSpace.Reading?,
        now: Date = Date()
    ) -> [String: Any]? {
        DiskPressureNotice.decide(session, failure: failure, reading: reading, now: now) { _ in true }
    }

    private func context(_ reply: [String: Any]?) -> String? {
        (reply?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
    }

    override func setUp() async throws {
        try await super.setUp()
        DiskPressureNotice.reset()
    }

    override func tearDown() async throws {
        DiskPressureNotice.reset()
        try await super.tearDown()
    }

    // MARK: - Deciding

    func testAHealthyDiskWithAnOrdinaryFailureIsSilent() {
        let reply = decide(SessionID(), failure: failure("error: cannot find 'x' in scope"), reading: roomy)

        XCTAssertNil(reply)
    }

    func testAShortDiskAnswersWithTheReadingAndTheTools() throws {
        let reply = decide(SessionID(), failure: failure("linker command failed"), reading: full)
        let output = try XCTUnwrap(reply?["hookSpecificOutput"] as? [String: Any])
        let text = try XCTUnwrap(output["additionalContext"] as? String)

        XCTAssertEqual(output["hookEventName"] as? String, "PostToolUseFailure")
        XCTAssertTrue(text.contains("3 GB free"), text)
        XCTAssertTrue(text.contains("list_reclaimable_storage"), text)
        XCTAssertTrue(text.contains("propose_storage_cleanup"), text)
    }

    /// A full disk fails every command after the first; one notice per session per interval.
    func testASessionIsToldOncePerInterval() {
        let session = SessionID()
        let start = Date()

        XCTAssertNotNil(decide(session, failure: failure(nil), reading: full, now: start))
        XCTAssertNil(decide(session, failure: failure(nil), reading: full, now: start.addingTimeInterval(60)))
        XCTAssertNotNil(decide(
            session,
            failure: failure(nil),
            reading: full,
            now: start.addingTimeInterval(DiskPressureNoticeDefaults.repeatInterval + 1)
        ))
        XCTAssertNotNil(
            decide(SessionID(), failure: failure(nil), reading: full, now: start.addingTimeInterval(60)),
            "another session has not been told"
        )
    }

    func testAnIneligibleSessionIsNeverAnswered() {
        let reply = DiskPressureNotice.decide(SessionID(), failure: failure(nil), reading: full) { _ in false }

        XCTAssertNil(reply)
    }

    func testAnInterruptIsNeverAnswered() {
        XCTAssertNil(decide(SessionID(), failure: failure(nil, interrupt: true), reading: full))
    }

    /// The disk can have room again by the time the hook runs; an explicit message still
    /// deserves a pointer, worded as what it is.
    func testAnExplicitMessageOnARoomyDiskStillAnswers() throws {
        let reply = decide(
            SessionID(),
            failure: failure("cp: write error: No space left on device"),
            reading: roomy
        )
        let text = try XCTUnwrap(context(reply))

        XCTAssertTrue(text.contains("reads like a full disk"), text)
        XCTAssertTrue(text.contains("400 GB free"), text)
    }

    // MARK: - Signatures

    /// The disguises happen on a healthy disk too, so they are evidence only beside a short one.
    func testXcodeDisguisesCountOnlyWhenTheDiskIsShort() {
        let module = "error: module file '/x/Foundation.pcm' has been modified since the module file was built"

        XCTAssertNil(decide(SessionID(), failure: failure(module), reading: roomy))
        XCTAssertEqual(
            DiskPressureNotice.signature(in: module, includingDisguises: true),
            "has been modified since the module file"
        )
        XCTAssertNil(DiskPressureNotice.signature(in: module, includingDisguises: false))
    }

    func testTheCauseAtTheEndOfALongLogIsFound() {
        let log = String(repeating: "error: unexpected incomplete target\n", count: 23)
            + "error: database or disk is full"

        XCTAssertEqual(
            DiskPressureNotice.signature(in: log, includingDisguises: false),
            "database or disk is full"
        )
    }

    func testThePayloadIsReadDefensively() {
        let parsed = DiskPressureFailure(["error": "boom", "is_interrupt": true])

        XCTAssertEqual(parsed, DiskPressureFailure(error: "boom", isInterrupt: true))
        XCTAssertEqual(DiskPressureFailure([:]), DiskPressureFailure(error: nil, isInterrupt: false))
    }

    // MARK: - Registration

    func testClaudeSettingsCarryTheNoticeOnFailureOnly() throws {
        let settings = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: SessionID(UUID()),
            brokersPermissions: false,
            reportsLifecycle: true
        ))
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        func commands(_ name: String) -> [String] {
            (hooks[name] as? [[String: Any]] ?? []).flatMap { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            }
        }

        XCTAssertEqual(commands("PostToolUseFailure").filter { $0.contains("/disk-notice/") }.count, 1)
        XCTAssertFalse(commands("PostToolUse").contains { $0.contains("/disk-notice/") })
        XCTAssertTrue(try XCTUnwrap(commands("PostToolUseFailure").first { $0.contains("/disk-notice/") }).hasSuffix("|| true"))
    }
}
