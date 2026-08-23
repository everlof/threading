import XCTest
@testable import Threading

/// The file that tells the next launch what this one was running. Missing, readable and
/// unreadable are three different answers here, because a ledger read as "no children" is a
/// sweep that silently does nothing.
final class AgentChildLedgerTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChildLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(AgentChildLedgerDefaults.fileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        url = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Round Trip

    func testARecordSurvivesTheProcessThatWroteIt() {
        let record = makeRecord(pid: 4321)
        XCTAssertTrue(AgentChildLedger(url: url).record(record))

        let outcome = AgentChildLedger(url: url).consumeInheritedRecords()
        guard case .loaded(let records) = outcome else {
            return XCTFail("expected a readable ledger, got \(outcome)")
        }
        XCTAssertEqual(records, [record])
    }

    func testAnInfrastructureChildRoundTripsWithoutInventingASession() {
        let record = AgentChildRecord(
            pid: 4322,
            startTime: ProcessStartTime(seconds: 1_700_000_000, microseconds: 123_456),
            sessionID: nil,
            executable: "tailscale",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(AgentChildLedger(url: url).record(record))

        guard case .loaded(let records) = AgentChildLedger(url: url).consumeInheritedRecords()
        else { return XCTFail("expected a readable ledger") }
        XCTAssertEqual(records, [record])
        XCTAssertNil(records.first?.sessionID)
    }

    // MARK: - Who Owns the Ending

    func testAHostHeldChildRoundTripsWithItsOwner() {
        let record = makeRecord(pid: 4323, owner: .ptyHost)
        XCTAssertTrue(AgentChildLedger(url: url).record(record))

        guard case .loaded(let records) = AgentChildLedger(url: url).consumeInheritedRecords()
        else { return XCTFail("expected a readable ledger") }
        XCTAssertEqual(records, [record])
        XCTAssertEqual(records.first?.resolvedOwner, .ptyHost)
    }

    /// The migration property, from the writing end: an app-owned record writes no owner key at
    /// all, so this build's file is byte-identical in shape to every file already on disk and
    /// there is exactly one spelling of "the app owns it" for the sweep to agree about.
    func testAnAppOwnedRecordWritesNoOwnerKeyAtAll() throws {
        XCTAssertTrue(AgentChildLedger(url: url).record(makeRecord(pid: 4324)))

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("owner"), "a nil owner is an absent key, not a default")
    }

    /// And from the reading end: a record written before the field existed still means what it
    /// meant, which is the only thing standing between this change and a launch that stops
    /// sweeping real orphans.
    func testARecordWrittenBeforeTheOwnerFieldExistedReadsAsTheApps() throws {
        try Data(
            """
            {
              "formatVersion" : 1,
              "value" : [
                {
                  "pid" : 4325,
                  "startTime" : { "seconds" : 1700000000, "microseconds" : 123456 },
                  "sessionID" : "A1B2C3D4",
                  "executable" : "claude",
                  "recordedAt" : "2023-11-14T22:13:20Z"
                }
              ]
            }
            """.utf8
        ).write(to: url)

        guard case .loaded(let records) = AgentChildLedger(url: url).consumeInheritedRecords()
        else { return XCTFail("an older ledger must still be readable") }
        XCTAssertNil(records.first?.owner)
        XCTAssertEqual(records.first?.resolvedOwner, .app)
    }

    func testClearingARecordEmptiesTheLedgerForTheNextLaunch() {
        let ledger = AgentChildLedger(url: url)
        ledger.record(makeRecord(pid: 11))
        ledger.record(makeRecord(pid: 12))
        ledger.clear(pid: 11)

        XCTAssertEqual(ledger.currentRecords.map(\.pid), [12])

        guard case .loaded(let records) = AgentChildLedger(url: url).consumeInheritedRecords()
        else { return XCTFail("expected a readable ledger") }
        XCTAssertEqual(records.map(\.pid), [12])
    }

    func testConsumingTheLedgerLeavesNothingForASecondSweep() {
        AgentChildLedger(url: url).record(makeRecord(pid: 99))

        _ = AgentChildLedger(url: url).consumeInheritedRecords()

        // Consumed on read, the same discipline as EventLog's launch marker: a list that
        // outlived the launch which acted on it would sweep this launch's own children.
        guard case .loaded(let records) = AgentChildLedger(url: url).consumeInheritedRecords()
        else { return XCTFail("expected a readable ledger") }
        XCTAssertTrue(records.isEmpty)
    }

    func testAnAbsentLedgerIsMissingRatherThanEmpty() {
        let outcome = AgentChildLedger(url: url).consumeInheritedRecords()
        guard case .missing(let records) = outcome else {
            return XCTFail("expected a missing ledger, got \(outcome)")
        }
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - Corrupt Data

    func testAnUnreadableLedgerIsReportedRatherThanReadAsNoChildren() throws {
        try Data("this is not the ledger you are looking for".utf8).write(to: url)

        let outcome = AgentChildLedger(url: url).consumeInheritedRecords()
        guard case .unreadable(let fallback, _) = outcome else {
            return XCTFail("expected an unreadable ledger, got \(outcome)")
        }
        XCTAssertTrue(fallback.isEmpty)
    }

    func testALedgerWrittenByANewerBuildIsNotDecodedAsThisOne() throws {
        try Data(#"{"formatVersion":99,"value":[]}"#.utf8).write(to: url)

        let outcome = AgentChildLedger(url: url).consumeInheritedRecords()
        guard case .unreadable = outcome else {
            return XCTFail("expected a version refusal, got \(outcome)")
        }
    }

    // MARK: - Budget

    func testTheLedgerRefusesToGrowPastItsRecordBudget() {
        let ledger = AgentChildLedger(url: url)
        let overflow = AgentChildLedgerDefaults.maximumRecords + 8
        for pid in 1...overflow {
            ledger.record(makeRecord(pid: Int32(pid)))
        }

        let records = ledger.currentRecords
        XCTAssertEqual(records.count, AgentChildLedgerDefaults.maximumRecords)
        XCTAssertEqual(
            records.last?.pid,
            Int32(overflow),
            "the newest child is the one most likely still alive"
        )
        XCTAssertFalse(
            records.contains { $0.pid == 1 },
            "the oldest record is evicted, not the newest refused"
        )
    }

    func testRecordingTheSamePidTwiceReplacesRatherThanDuplicates() {
        let ledger = AgentChildLedger(url: url)
        ledger.record(makeRecord(pid: 7, executable: "claude"))
        ledger.record(makeRecord(pid: 7, executable: "codex"))

        XCTAssertEqual(ledger.currentRecords.count, 1)
        XCTAssertEqual(ledger.currentRecords.first?.executable, "codex")
    }

    // MARK: - Failed Writes Stay Transactional

    func testAFailedRecordDoesNotBecomeCurrentOnlyInMemory() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let ledger = AgentChildLedger(url: blocker.appendingPathComponent("children.json"))

        XCTAssertFalse(ledger.record(makeRecord(pid: 17)))
        XCTAssertTrue(
            ledger.currentRecords.isEmpty,
            "memory claimed enrollment even though no crash-recovery record reached disk"
        )
    }

    func testAFailedClearKeepsTheRecordCurrentForARetry() throws {
        let ledger = AgentChildLedger(url: url)
        XCTAssertTrue(ledger.record(makeRecord(pid: 18)))

        // Turn the ledger's parent path into a regular file so the next atomic replacement
        // fails. The current state must remain the last state that actually reached disk.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)

        ledger.clear(pid: 18)
        XCTAssertEqual(ledger.currentRecords.map(\.pid), [18])
    }

    // MARK: - Helpers

    private func makeRecord(
        pid: Int32,
        executable: String = "claude",
        owner: AgentChildOwner? = nil
    ) -> AgentChildRecord {
        AgentChildRecord(
            pid: pid,
            startTime: ProcessStartTime(seconds: 1_700_000_000, microseconds: 123_456),
            sessionID: UUID().uuidString,
            executable: executable,
            // Whole seconds: the store round-trips through ISO 8601, which carries no more.
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            owner: owner
        )
    }
}
