import Darwin
import XCTest
@testable import Threading

/// What a confirmed takeover actually does, step by step, and everything it refuses.
///
/// The mechanics run behind injected closures so no real process is signalled — except in the
/// last case, which stages a disposable `/bin/sleep` holding a real `flock` and drives the real
/// escalation against it. Both matter: the closures pin the decisions, the child pins that the
/// decisions are about the machine and not about a model of it.
@MainActor
final class SingleInstanceTakeoverTests: XCTestCase {

    private let owner = SingleInstanceOwnerCard(
        pid: 4_242,
        startTime: ProcessStartTime(seconds: 1_700, microseconds: 42),
        bundlePath: "/Applications/Threading.app",
        version: "1.0 (1)",
        writtenAt: "2026-01-01T00:00:00Z"
    )

    private struct SentSignal: Equatable {
        let pid: pid_t
        let number: Int32
    }

    /// Everything a run touched, so a refusal can be shown to have signalled nothing.
    private final class Recorder {
        var signals: [SentSignal] = []
        var lockAttempts: [TimeInterval] = []
        var waited = false
    }

    private func actions(
        recorder: Recorder,
        ageAfterWait: TimeInterval?,
        probe: @escaping (pid_t) -> AgentChildProbe,
        lockFreesAfter: Int
    ) -> SingleInstanceTakeover.Actions {
        SingleInstanceTakeover.Actions(
            heartbeatAge: { ageAfterWait },
            waitForReprobe: { recorder.waited = true },
            probe: probe,
            signal: { recorder.signals.append(SentSignal(pid: $0, number: $1)) },
            acquireLock: { seconds in
                recorder.lockAttempts.append(seconds)
                return recorder.lockAttempts.count >= lockFreesAfter
            }
        )
    }

    private func matchingProbe(_ card: SingleInstanceOwnerCard) -> (pid_t) -> AgentChildProbe {
        { _ in .running(card.startTime) }
    }

    // MARK: - Refusing

    /// The whole reason the wait exists. The alert was on screen for as long as the user took to
    /// read it, which is long enough for a paused debugger or a disk stall to come back.
    func testAHeartbeatThatTickedWhileWeWaitedEndsTheTakeoverWithoutASignal() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: 1,
            probe: matchingProbe(owner),
            lockFreesAfter: 1
        ))

        XCTAssertEqual(outcome, .ownerRecovered)
        XCTAssertTrue(recorder.waited)
        XCTAssertTrue(recorder.signals.isEmpty)
        XCTAssertTrue(recorder.lockAttempts.isEmpty)
    }

    /// The wait is itself a window in which the owner can exit and its pid be handed on, so the
    /// identity is checked again on the far side of it.
    func testAPidThatNoLongerMeansTheOwnerIsNeverSignalled() {
        let probes: [(pid_t) -> AgentChildProbe] = [
            { _ in .running(ProcessStartTime(seconds: 9, microseconds: 9)) },
            { _ in .unreadable }
        ]
        for probe in probes {
            let recorder = Recorder()
            let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
                recorder: recorder,
                ageAfterWait: 900,
                probe: probe,
                lockFreesAfter: 1
            ))

            XCTAssertEqual(outcome, .identityUnverified)
            XCTAssertTrue(recorder.signals.isEmpty)
        }
    }

    /// An owner that has already gone needs no signal, and signalling its pid is exactly the
    /// mistake this whole design exists to avoid.
    func testAnOwnerThatHasAlreadyGoneIsNotSignalledAndTheLockIsSimplyTaken() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: 900,
            probe: { _ in .absent },
            lockFreesAfter: 1
        ))

        XCTAssertEqual(outcome, .acquired(escalated: false))
        XCTAssertTrue(recorder.signals.isEmpty)
    }

    /// Fail closed: a process that took both signals and still holds the lock leaves the launch
    /// exactly where it started, rather than earning a third escalation.
    func testAnOwnerThatSurvivesBothSignalsRefusesTheLaunchRatherThanEscalatingAgain() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: 900,
            probe: matchingProbe(owner),
            lockFreesAfter: .max
        ))

        XCTAssertEqual(outcome, .lockStillHeld)
        XCTAssertEqual(recorder.signals.map(\.number), [SIGTERM, SIGKILL])
        XCTAssertEqual(recorder.lockAttempts.count, 2)
    }

    // MARK: - Taking over

    func testATermThatFreesTheLockNeverReachesTheKill() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: 900,
            probe: matchingProbe(owner),
            lockFreesAfter: 1
        ))

        XCTAssertEqual(outcome, .acquired(escalated: false))
        XCTAssertEqual(recorder.signals, [SentSignal(pid: owner.pid, number: SIGTERM)])
    }

    func testATermThatIsIgnoredEscalatesOnceAndSaysSo() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: 900,
            probe: matchingProbe(owner),
            lockFreesAfter: 2
        ))

        XCTAssertEqual(outcome, .acquired(escalated: true))
        XCTAssertEqual(recorder.signals.map(\.number), [SIGTERM, SIGKILL])
        XCTAssertEqual(recorder.lockAttempts, [
            SingleInstanceTakeoverDefaults.terminateGrace,
            SingleInstanceTakeoverDefaults.killGrace
        ])
    }

    /// A heartbeat that has become unreadable is not evidence of death, so the run stops
    /// short of signalling anything. Fail closed lands on the living here, exactly as it does
    /// in the triage that offered this in the first place.
    func testAHeartbeatThatBecameUnreadableStopsTheTakeoverWithoutASignal() {
        let recorder = Recorder()
        let outcome = SingleInstanceTakeover.run(owner: owner, actions: actions(
            recorder: recorder,
            ageAfterWait: nil,
            probe: matchingProbe(owner),
            lockFreesAfter: 1
        ))

        XCTAssertEqual(outcome, .ownerRecovered,
                       "an unreadable heartbeat must fail closed onto the living")
        XCTAssertTrue(recorder.signals.isEmpty)
    }

    // MARK: - Releasing a lock the owner's children inherited

    private func childRecord(pid: Int32, executable: String = "claude") -> AgentChildRecord {
        AgentChildRecord(
            pid: pid,
            startTime: ProcessStartTime(seconds: UInt64(pid), microseconds: 1),
            sessionID: nil,
            executable: executable,
            recordedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func ledgerProbe(
        alive: Set<Int32>
    ) -> (pid_t) -> AgentChildProbe {
        { pid in
            alive.contains(Int32(pid))
                ? .running(ProcessStartTime(seconds: UInt64(pid), microseconds: 1))
                : .absent
        }
    }

    /// The overnight lockout's way out: end the dead owner's leftover children, and the lock they
    /// inherited goes with them.
    func testEndingTheVerifiedLeftoversFreesTheLock() {
        let recorder = Recorder()
        let records = [childRecord(pid: 11), childRecord(pid: 12, executable: "node")]

        let outcome = SingleInstanceTakeover.releaseOrphanedLock(
            records: records,
            probe: ledgerProbe(alive: [11, 12]),
            signalGroup: { recorder.signals.append(SentSignal(pid: $0, number: SIGKILL)) },
            acquireLock: { seconds in
                recorder.lockAttempts.append(seconds)
                return true
            }
        )

        XCTAssertEqual(outcome, .acquired(ended: 2))
        XCTAssertEqual(recorder.signals.map(\.pid).sorted(), [11, 12])
    }

    /// The sweep's guard, unchanged: a pid from a crash hours ago may name anything now, so a
    /// record whose start time has moved is never signalled.
    func testALeftoverWhoseIdentityMovedIsNeverSignalled() {
        let recorder = Recorder()

        let outcome = SingleInstanceTakeover.releaseOrphanedLock(
            records: [childRecord(pid: 11)],
            probe: { _ in .running(ProcessStartTime(seconds: 999, microseconds: 999)) },
            signalGroup: { recorder.signals.append(SentSignal(pid: $0, number: SIGKILL)) },
            acquireLock: { _ in true }
        )

        XCTAssertEqual(outcome, .nothingToEnd)
        XCTAssertTrue(recorder.signals.isEmpty)
    }

    /// Nothing in the ledger still checks out. The lock is held by something this launch cannot
    /// name, so it names nothing and ends nothing.
    func testAnEmptyOrAllStaleLedgerEndsNothingAndTakesNothing() {
        let recorder = Recorder()

        let outcome = SingleInstanceTakeover.releaseOrphanedLock(
            records: [],
            probe: { _ in .absent },
            signalGroup: { recorder.signals.append(SentSignal(pid: $0, number: SIGKILL)) },
            acquireLock: { seconds in
                recorder.lockAttempts.append(seconds)
                return true
            }
        )

        XCTAssertEqual(outcome, .nothingToEnd)
        XCTAssertTrue(recorder.lockAttempts.isEmpty,
                      "nothing was ended, so nothing changed and the lock must not be claimed")
    }

    /// Fail closed: something else is holding it too, and this launch stops rather than guessing.
    func testALockStillHeldAfterTheLeftoversAreGoneRefusesTheLaunch() {
        let outcome = SingleInstanceTakeover.releaseOrphanedLock(
            records: [childRecord(pid: 11)],
            probe: ledgerProbe(alive: [11]),
            signalGroup: { _ in },
            acquireLock: { _ in false }
        )

        XCTAssertEqual(outcome, .lockStillHeld(ended: 1))
    }

    func testTheHoldersOfferedAreExactlyTheOnesThatStillCheckOut() {
        let records = [
            childRecord(pid: 11),
            childRecord(pid: 12, executable: "node"),
            childRecord(pid: 13, executable: "codex")
        ]

        let holders = SingleInstanceTakeover.verifiedHolders(
            in: records,
            probe: ledgerProbe(alive: [11, 13])
        )

        XCTAssertEqual(holders.map(\.pid), [11, 13])
    }

    // MARK: - What is left behind

    /// The only durable trace of a Threading that was ended. The launch that ends one has no
    /// window to say so in, and its own alert is gone by the time anything is running.
    func testTheRecordCarriesWhoWasEndedHowDeadItLookedAndWhetherTheKillWasNeeded() {
        let detail = SingleInstanceTakeoverRecord(
            pid: 4_242,
            bundlePath: "/Users/somebody/DerivedData/Threading.app",
            staleness: 612.6,
            escalated: true
        ).journalDetail

        XCTAssertEqual(detail[SingleInstanceDefaults.ownerPIDField], "4242")
        XCTAssertEqual(
            detail[SingleInstanceDefaults.ownerPathField],
            "/Users/somebody/DerivedData/Threading.app"
        )
        XCTAssertEqual(detail[SingleInstanceDefaults.stalenessField], "613")
        XCTAssertEqual(detail[SingleInstanceDefaults.escalatedField], "yes")
        XCTAssertEqual(detail[SingleInstanceDefaults.endedChildrenField], "0")
    }

    /// The other shape the record takes: nothing wedged, an owner already dead, and a count of
    /// the leftovers that had to go for the lock to come free.
    func testARecordOfAnInheritedLockReleaseCountsTheChildrenItEnded() {
        let detail = SingleInstanceTakeoverRecord(
            pid: 900,
            bundlePath: "/Applications/Threading.app",
            staleness: 0,
            escalated: true,
            endedChildren: 10
        ).journalDetail

        XCTAssertEqual(detail[SingleInstanceDefaults.endedChildrenField], "10")
        XCTAssertEqual(detail[SingleInstanceDefaults.stalenessField], "0")
    }

    func testARecordOfATermThatWorkedSaysTheKillWasNotNeeded() {
        let detail = SingleInstanceTakeoverRecord(
            pid: 7,
            bundlePath: "/Applications/Threading.app",
            staleness: 31,
            escalated: false
        ).journalDetail

        XCTAssertEqual(detail[SingleInstanceDefaults.escalatedField], "no")
    }

    // MARK: - Against a real process

    /// The real escalation, against a real `flock`, over a real signal.
    ///
    /// The child is `/bin/sleep` with the already-locked descriptor handed to it as its standard
    /// input: `flock` belongs to the open file description, so the duplicate the child inherits
    /// keeps the lock after this process closes its own copy. That is the whole staging — no
    /// interpreter, no helper binary, and the child dies with the first signal it is sent.
    func testARealChildHoldingARealLockIsEndedAndTheLockIsTaken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-takeover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            SingleInstanceLock.relinquish()
            try? FileManager.default.removeItem(at: directory)
        }
        let lockURL = directory.appendingPathComponent(SingleInstanceDefaults.lockFileName)

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["120"]
        child.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try child.run()
        close(descriptor)

        XCTAssertFalse(SingleInstanceLock.acquire(at: lockURL),
                       "the child did not inherit the lock, so the rest proves nothing")

        let pid = child.processIdentifier
        let startTime = try XCTUnwrap(ProcessUtility.startTime(forPid: pid))
        let card = SingleInstanceOwnerCard(
            pid: pid,
            startTime: startTime,
            bundlePath: "/bin/sleep",
            version: "0",
            writtenAt: "2026-01-01T00:00:00Z"
        )

        let outcome = SingleInstanceTakeover.run(owner: card, actions: SingleInstanceTakeover.Actions(
            heartbeatAge: { 900 },
            waitForReprobe: {},
            probe: OrphanedAgentChildSweep.liveProbe(of:),
            signal: { pid, number in Darwin.kill(pid, number) },
            acquireLock: { SingleInstanceTakeover.pollForLock(at: lockURL, upTo: $0) }
        ))

        XCTAssertEqual(outcome, .acquired(escalated: false),
                       "sleep takes SIGTERM, so no escalation should have been needed")
        child.waitUntilExit()
        XCTAssertNotNil(SingleInstanceLock.readOwnerCard(at: lockURL),
                        "a takeover leaves this process's own card behind")
    }
}
