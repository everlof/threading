import Darwin
import XCTest
@testable import Threading

/// The lock file's owner card: what it says, and everything it must survive saying nothing.
///
/// Every case runs against a temporary path rather than the real lock. A hosted test bundle
/// never reaches `SingleInstanceLock.acquire()` — `applicationDidFinishLaunching` returns above
/// it on `XCTestCase` — so taking the process descriptor here costs the app nothing, and
/// `relinquish()` in teardown keeps one case from carrying its lock into the next.
@MainActor
final class SingleInstanceLockTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SingleInstanceLock.relinquish()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private var lockURL: URL { directory.appendingPathComponent("threading.lock") }

    // MARK: - Writing

    func testAcquireWritesACardNamingThisProcessAndThisBundle() throws {
        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))

        let card = try XCTUnwrap(SingleInstanceLock.readOwnerCard(at: lockURL))
        XCTAssertEqual(card.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(card.bundlePath, Bundle.main.bundlePath)
        XCTAssertEqual(card.startTime, ProcessUtility.startTime(forPid: card.pid))
        XCTAssertFalse(card.version.isEmpty)
        XCTAssertFalse(card.writtenAt.isEmpty)
    }

    /// The identity pair is the whole point of the card: a pid alone would let a recycled number
    /// stand in for the owner, which is the mistake the orphan sweep exists to avoid.
    func testTheCardsIdentityIsAcceptedByTheSameGuardTheSweepUses() throws {
        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))
        let card = try XCTUnwrap(SingleInstanceLock.readOwnerCard(at: lockURL))

        XCTAssertEqual(SingleInstanceTriage.identity(of: card), .confirmed)
    }

    /// A shorter card written over a longer one must not leave the old tail behind.
    func testASecondCardReplacesTheFirstRatherThanOverwritingPartOfIt() throws {
        let padded = SingleInstanceOwnerCard(
            pid: 4_242,
            startTime: ProcessStartTime(seconds: 1, microseconds: 2),
            bundlePath: String(repeating: "/very-long-path", count: 40),
            version: "9.9.9 (9999)",
            writtenAt: "2026-01-01T00:00:00Z"
        )
        try JSONEncoder().encode(padded).write(to: lockURL)

        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))

        let card = try XCTUnwrap(SingleInstanceLock.readOwnerCard(at: lockURL))
        XCTAssertEqual(card.pid, ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - Not handing the lock to the children

    /// The overnight lockout, in one assertion.
    ///
    /// An `flock` lives on the open file description and is held while any duplicate of it
    /// exists. Without close-on-exec every `forkpty` agent child inherits one, so a Threading
    /// that *died* went on holding its own lock through ten orphaned `claude` and `node`
    /// processes — measured on a live instance, all of them on fd 6 — and every relaunch was
    /// refused with nothing running to switch to.
    func testTheLockDescriptorIsClosedWhenAChildExecs() throws {
        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))

        let descriptor = SingleInstanceLock.heldDescriptor
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let flags = fcntl(descriptor, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(
            flags & FD_CLOEXEC,
            FD_CLOEXEC,
            "an agent child would inherit this lock and hold it after the app died"
        )
    }

    /// A real child, to prove the flag means what the assertion above says it means.
    ///
    /// `/bin/sleep` is given the held descriptor as its standard input — which `dup2` clears
    /// `FD_CLOEXEC` on, so it *does* inherit that one deliberately — while the lock's own
    /// descriptor number must not survive its `exec`. Ending the parent's copy therefore has to
    /// leave the lock free while the child is still alive.
    func testAChildDoesNotKeepTheLockAliveAfterTheOwnerLetsItGo() throws {
        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        SingleInstanceLock.relinquish()

        let probe = open(lockURL.path, O_RDWR)
        defer { close(probe) }
        XCTAssertEqual(
            flock(probe, LOCK_EX | LOCK_NB),
            0,
            "a live child is still holding a copy of the released lock"
        )
        XCTAssertEqual(flock(probe, LOCK_UN), 0)
    }

    // MARK: - Reading

    func testAnAbsentFileReadsAsNoCard() {
        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    /// The state every lock file was in before this mechanism existed: `open(O_CREAT)` and
    /// nothing written.
    func testAnEmptyFileReadsAsNoCard() throws {
        try Data().write(to: lockURL)
        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    func testGarbageReadsAsNoCard() throws {
        try Data("not json at all".utf8).write(to: lockURL)
        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    /// A write that was interrupted half way. Valid JSON is not the same question as a valid
    /// card, and neither is a prefix of one.
    func testATornCardReadsAsNoCard() throws {
        let card = SingleInstanceOwnerCard(
            pid: 99,
            startTime: ProcessStartTime(seconds: 5, microseconds: 6),
            bundlePath: "/Applications/Threading.app",
            version: "1.0 (1)",
            writtenAt: "2026-01-01T00:00:00Z"
        )
        let encoded = try JSONEncoder().encode(card)
        try encoded.prefix(encoded.count / 2).write(to: lockURL)

        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    /// The cap is a refusal boundary, not an allocation size: anything that big is not a card.
    func testAFileLargerThanTheCapReadsAsNoCard() throws {
        let filler = Data(repeating: UInt8(ascii: "x"),
                          count: SingleInstanceDefaults.maximumOwnerCardBytes + 1)
        try filler.write(to: lockURL)
        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    /// Reading must cost the owner nothing, or the question could not be put by the very
    /// process the owner has locked out.
    func testReadingTheCardDoesNotDisturbTheHeldLock() throws {
        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertNotNil(SingleInstanceLock.readOwnerCard(at: lockURL))

        let probe = open(lockURL.path, O_RDWR)
        defer { close(probe) }
        XCTAssertNotEqual(flock(probe, LOCK_EX | LOCK_NB), 0,
                          "the lock was released by somebody reading the card")
    }

    // MARK: - Failing open

    /// The card is information; the lock is the mechanism. A descriptor the card cannot be
    /// written through must not take the acquire down with it.
    func testACardThatCannotBeWrittenIsNotAnAcquireFailure() throws {
        try Data().write(to: lockURL)
        let readOnly = open(lockURL.path, O_RDONLY)
        defer { close(readOnly) }
        XCTAssertGreaterThanOrEqual(readOnly, 0)

        SingleInstanceLock.writeOwnerCard(into: readOnly)

        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL),
                     "a refused write must leave nothing behind to be believed")
    }

    /// The fail-open semantics, unchanged: a lock file that cannot even be opened lets the
    /// launch through rather than bricking the app.
    func testALockFileThatCannotBeOpenedStillLetsTheLaunchThrough() throws {
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        XCTAssertTrue(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertNil(SingleInstanceLock.readOwnerCard(at: lockURL))
    }

    /// And the refusal itself, which is what everything above is protecting.
    func testASecondAcquireOfALockAnotherDescriptorHoldsIsRefused() throws {
        let held = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)

        XCTAssertFalse(SingleInstanceLock.acquire(at: lockURL))
    }
}
