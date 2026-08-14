import Darwin
import XCTest
@testable import Threading

/// What the info panel's Stop is allowed to signal. The grammar is the post-crash sweep's —
/// exact pid + start identity or nothing, every outcome journalled — narrowed to one pid and
/// SIGTERM: a row must never be able to take the session's whole group down, and SIGKILL stays
/// the sweep's.
final class SessionProcessTerminatorTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!
    private var journal: EventLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionProcessTerminatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Its own directory: the terminator journals, and a test must not append to the
        // developer's own diagnostics.
        journal = EventLog(directory: directory.appendingPathComponent("Logs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        journal = nil
        directory = nil
        try super.tearDownWithError()
    }

    private func spawnSleepFixture() throws -> Process {
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fixture.arguments = ["300"]
        try fixture.run()
        return fixture
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

    // MARK: - The Authorised Kill

    /// A matching pid and start identity is the only thing that authorises the signal — and the
    /// signal is SIGTERM to that one pid, which a real `sleep` answers by exiting.
    func testAnExactIdentityMatchTerminatesTheProcess() throws {
        let fixture = try spawnSleepFixture()
        let identity = try XCTUnwrap(ProcessUtility.startTime(forPid: fixture.processIdentifier))

        let outcome = SessionProcessTerminator.terminate(
            pid: fixture.processIdentifier,
            expectedStart: identity,
            journal: journal
        )

        XCTAssertEqual(outcome, .terminated)
        fixture.waitUntilExit()
        XCTAssertTrue(journalContains(SessionProcessTerminatorDefaults.terminatedMessage))
    }

    // MARK: - Fail Closed

    /// One microsecond apart is a different process — macOS hands pids out again — so the
    /// fixture must survive the refusal untouched.
    func testAMismatchedIdentityIsRefusedAndTheProcessSurvives() throws {
        let fixture = try spawnSleepFixture()
        defer { fixture.terminate() }
        let identity = try XCTUnwrap(ProcessUtility.startTime(forPid: fixture.processIdentifier))
        let wrong = ProcessStartTime(
            seconds: identity.seconds,
            microseconds: identity.microseconds &+ 1
        )

        let outcome = SessionProcessTerminator.terminate(
            pid: fixture.processIdentifier,
            expectedStart: wrong,
            journal: journal
        )

        XCTAssertEqual(outcome, .skipped(.identityMismatch))
        XCTAssertTrue(ProcessUtility.processExists(pid: fixture.processIdentifier))
        XCTAssertTrue(journalContains(SessionProcessTerminatorDefaults.skippedMessage))
        XCTAssertTrue(journalContains(SessionProcessTerminator.SkipReason.identityMismatch.rawValue))
    }

    /// A pid whose identity cannot be read — gone, or a zombie — is the same answer: nothing.
    /// The signal closure asserts the nothing.
    func testAnUnreadableIdentitySignalsNothing() {
        var signalled = false

        let outcome = SessionProcessTerminator.terminate(
            pid: 99999,
            expectedStart: ProcessStartTime(seconds: 1, microseconds: 2),
            journal: journal,
            currentStart: { _ in nil },
            signal: { _ in
                signalled = true
                return 0
            }
        )

        XCTAssertEqual(outcome, .skipped(.identityUnreadable))
        XCTAssertFalse(signalled)
        XCTAssertTrue(journalContains(SessionProcessTerminator.SkipReason.identityUnreadable.rawValue))
    }

    /// A signal the kernel refuses is reported as its own kind of nothing, so the journal can
    /// tell "we chose not to" from "we could not".
    func testARefusedSignalIsItsOwnSkip() {
        let identity = ProcessStartTime(seconds: 1, microseconds: 2)

        let outcome = SessionProcessTerminator.terminate(
            pid: 12345,
            expectedStart: identity,
            journal: journal,
            currentStart: { _ in identity },
            signal: { _ in -1 }
        )

        XCTAssertEqual(outcome, .skipped(.signalFailed))
        XCTAssertTrue(journalContains(SessionProcessTerminator.SkipReason.signalFailed.rawValue))
    }
}
