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

    // MARK: - Ownership

    /// The gate is inside `verdict`, ahead of the probe, which is what makes the exception reach
    /// the launch sweep, a recovery launch and the single-instance takeover at once.
    func testAChildTheHostHoldsIsSkippedBeforeAnythingIsAskedAboutItsPid() {
        let counter = ProbeCounter()
        let verdict = OrphanedAgentChildSweep.verdict(
            for: makeRecord(pid: 500, seconds: 1, microseconds: 1, owner: .ptyHost),
            probe: counted(counter, .running(ProcessStartTime(seconds: 1, microseconds: 1)))
        )

        XCTAssertEqual(verdict, .skip(.heldByHost))
        XCTAssertEqual(
            counter.count,
            0,
            "a host-held child is not this app's pid to look up, let alone to signal"
        )
    }

    func testAnAppOwnedRecordStillReachesTheProbe() {
        let counter = ProbeCounter()
        let verdict = OrphanedAgentChildSweep.verdict(
            for: makeRecord(pid: 500, seconds: 1, microseconds: 1, owner: .app),
            probe: counted(counter, .running(ProcessStartTime(seconds: 1, microseconds: 1)))
        )

        XCTAssertEqual(verdict, .kill)
        XCTAssertEqual(counter.count, 1)
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

    // MARK: - The Sweep and the Background Host

    /// The whole point of the owner field: a live child the host is holding survives a launch
    /// that would otherwise have every reason to end it.
    func testTheSweepLeavesAHostHeldChildAloneAndSaysWhy() {
        ledger.record(makeRecord(pid: 901, seconds: 90, microseconds: 1, owner: .ptyHost))

        let summary = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { pid in
                XCTFail("pid \(pid) belongs to the host and must not be probed")
                return .running(ProcessStartTime(seconds: 90, microseconds: 1))
            },
            signalGroup: { _ in XCTFail("a host-held child must never be signalled") },
            journal: journal
        )

        XCTAssertEqual(summary.inspected, 1)
        XCTAssertEqual(summary.killed, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertTrue(
            journalContains(OrphanedAgentChildSweep.SkipReason.heldByHost.rawValue),
            "a process that survived a sweep has to say which rule spared it"
        )
    }

    /// The same pid, the same live start time, ended — because this record says the app owns it.
    /// The difference between the two outcomes is the field and nothing else.
    func testTheSameLiveChildIsEndedWhenTheAppOwnsIt() {
        ledger.record(makeRecord(pid: 901, seconds: 90, microseconds: 1, owner: .app))

        var signalled: [pid_t] = []
        let summary = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { _ in .running(ProcessStartTime(seconds: 90, microseconds: 1)) },
            signalGroup: { signalled.append($0) },
            journal: journal
        )

        XCTAssertEqual(signalled, [901])
        XCTAssertEqual(summary.killed, 1)
    }

    /// The migration property. Every record on disk today was written without the field, and a
    /// launch that read one as anything other than the app's own would stop sweeping the orphans
    /// the sweep exists for.
    func testARecordWrittenBeforeTheOwnerFieldExistedIsSweptAsTheAppsOwn() throws {
        try Data(
            """
            {
              "formatVersion" : 1,
              "value" : [
                {
                  "pid" : 902,
                  "startTime" : { "seconds" : 91, "microseconds" : 2 },
                  "sessionID" : "9E1B2C3D",
                  "executable" : "claude",
                  "recordedAt" : "2023-11-14T22:13:20Z"
                }
              ]
            }
            """.utf8
        ).write(to: directory.appendingPathComponent(AgentChildLedgerDefaults.fileName))

        var signalled: [pid_t] = []
        let summary = OrphanedAgentChildSweep.run(
            ledger: ledger,
            probe: { _ in .running(ProcessStartTime(seconds: 91, microseconds: 2)) },
            signalGroup: { signalled.append($0) },
            journal: journal
        )

        XCTAssertFalse(summary.ledgerWasUnreadable, "the new field must not break an old file")
        XCTAssertEqual(signalled, [902], "no owner key means the app's own child, as it always did")
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
        microseconds: UInt64 = 1,
        owner: AgentChildOwner? = nil
    ) -> AgentChildRecord {
        AgentChildRecord(
            pid: pid,
            startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
            sessionID: UUID().uuidString,
            executable: "claude",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            owner: owner
        )
    }

    /// Counts what the probe was asked, from inside an `@autoclosure` argument — which is the
    /// only way to observe that a probe was *not* evaluated.
    private final class ProbeCounter {
        var count = 0
    }

    private func counted(_ counter: ProbeCounter, _ answer: AgentChildProbe) -> AgentChildProbe {
        counter.count += 1
        return answer
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
