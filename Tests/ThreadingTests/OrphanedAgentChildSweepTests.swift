import Darwin
import XCTest
@testable import Threading

/// What the sweep is allowed to kill. Every case here is a way a pid can stop meaning what the
/// ledger thought it meant, and the answer to all but one of them is to do nothing and say so.
final class OrphanedAgentChildSweepTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!
    private var ledger: AgentChildLedger!
    private var journal: EventLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanedAgentChildSweepTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = AgentChildLedger(
            url: directory.appendingPathComponent(AgentChildLedgerDefaults.fileName)
        )
        // Its own directory: the sweep journals, and a test must not append to the developer's
        // own diagnostics.
        journal = EventLog(directory: directory.appendingPathComponent("Logs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        journal = nil
        ledger = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The Decision

    func testAMatchingPidAndStartTimeIsTheOnlyThingThatAuthorisesAKill() {
        let record = makeRecord(pid: 500, seconds: 100, microseconds: 200)
        XCTAssertEqual(
            OrphanedAgentChildSweep.verdict(
                for: record,
                probe: .running(ProcessStartTime(seconds: 100, microseconds: 200))
            ),
            .kill
        )
    }

    func testAReusedPidIsRefusedRatherThanKilled() {
        let record = makeRecord(pid: 500, seconds: 100, microseconds: 200)
        XCTAssertEqual(
            OrphanedAgentChildSweep.verdict(
                for: record,
                probe: .running(ProcessStartTime(seconds: 100, microseconds: 201))
            ),
            .skip(.startTimeMismatch),
            "one microsecond apart is a different process, and macOS hands pids out again"
        )
    }

    func testAProcessThatHasAlreadyGoneIsNotSignalled() {
        XCTAssertEqual(
            OrphanedAgentChildSweep.verdict(for: makeRecord(pid: 500), probe: .absent),
            .skip(.processGone)
        )
    }

    func testAnUnreadableIdentityFailsClosed() {
        XCTAssertEqual(
            OrphanedAgentChildSweep.verdict(for: makeRecord(pid: 500), probe: .unreadable),
            .skip(.identityUnreadable),
            "not being able to check is a reason to do nothing, never a reason to guess"
        )
    }

    // MARK: - The Sweep

    func testTheSweepKillsOnlyTheRecordsItCouldVerify() {
        let survivor = makeRecord(pid: 601, seconds: 10, microseconds: 1)
        let orphan = makeRecord(pid: 602, seconds: 20, microseconds: 2)
        let departed = makeRecord(pid: 603, seconds: 30, microseconds: 3)
        ledger.record(survivor)
        ledger.record(orphan)
        ledger.record(departed)

        var signalled: [pid_t] = []
        let summary = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { pid in
                switch pid {
                case 601: return .running(ProcessStartTime(seconds: 999, microseconds: 999))
                case 602: return .running(ProcessStartTime(seconds: 20, microseconds: 2))
                default: return .absent
                }
            },
            signalGroup: { signalled.append($0) },
            journal: journal
        )

        XCTAssertEqual(signalled, [602])
        XCTAssertEqual(summary.inspected, 3)
        XCTAssertEqual(summary.killed, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertFalse(summary.ledgerWasUnreadable)
    }

    func testTheSweepEmptiesTheLedgerSoTheNextLaunchStartsFromNothing() {
        ledger.record(makeRecord(pid: 700))

        OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { _ in .absent },
            signalGroup: { _ in XCTFail("nothing should be signalled") },
            journal: journal
        )

        let second = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { _ in .absent },
            signalGroup: { _ in XCTFail("nothing should be signalled") },
            journal: journal
        )
        XCTAssertEqual(second.inspected, 0)
    }

    func testAnUnreadableLedgerStopsTheSweepRatherThanReadingAsNothingToDo() throws {
        try Data("corrupt".utf8).write(
            to: directory.appendingPathComponent(AgentChildLedgerDefaults.fileName)
        )

        let summary = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { _ in
                XCTFail("an unreadable ledger names no pid to probe")
                return .absent
            },
            signalGroup: { _ in
                XCTFail("nothing may be signalled from data nobody could read")
            },
            journal: journal
        )

        XCTAssertTrue(summary.ledgerWasUnreadable)
        XCTAssertEqual(summary.inspected, 0)
        XCTAssertTrue(
            journalContains(OrphanedAgentChildSweepDefaults.unreadableLedgerMessage),
            "a sweep that gave up must say so, or it is indistinguishable from a clean one"
        )
    }

    func testEveryKillAndEverySkipReachesTheJournal() {
        ledger.record(makeRecord(pid: 801, seconds: 1, microseconds: 1))
        ledger.record(makeRecord(pid: 802, seconds: 2, microseconds: 2))

        OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { pid in
                pid == 801
                    ? .running(ProcessStartTime(seconds: 1, microseconds: 1))
                    : .unreadable
            },
            signalGroup: { _ in },
            journal: journal
        )

        XCTAssertTrue(journalContains(OrphanedAgentChildSweepDefaults.killedMessage))
        XCTAssertTrue(journalContains(OrphanedAgentChildSweepDefaults.skippedMessage))
        XCTAssertTrue(journalContains(OrphanedAgentChildSweep.SkipReason.identityUnreadable.rawValue))
        XCTAssertTrue(journalContains(OrphanedAgentChildSweepDefaults.summaryMessage))
    }

    // MARK: - The Live Probe

    func testTheLiveProbeReportsThisProcessAsRunningWithItsOwnStartTime() {
        guard case .running(let startTime) = OrphanedAgentChildSweep.liveProbe(of: getpid())
        else { return XCTFail("this process is running") }
        XCTAssertEqual(startTime, ProcessUtility.startTime(forPid: getpid()))
    }

    func testTheLiveProbeReportsAPidNothingHoldsAsAbsent() {
        // Above `kern.maxproc`'s ceiling on every supported machine, so nothing can hold it.
        XCTAssertEqual(OrphanedAgentChildSweep.liveProbe(of: 900_000), .absent)
    }

    // MARK: - Helpers

    private func makeRecord(
        pid: Int32,
        seconds: UInt64 = 1,
        microseconds: UInt64 = 1
    ) -> AgentChildRecord {
        AgentChildRecord(
            pid: pid,
            startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
            sessionID: UUID().uuidString,
            executable: "claude",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func journalContains(_ needle: String) -> Bool {
        let logs = directory.appendingPathComponent("Logs", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: logs,
            includingPropertiesForKeys: nil
        ) else { return false }

        return contents.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(needle)
        }
    }
}
