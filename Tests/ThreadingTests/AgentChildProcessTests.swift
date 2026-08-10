import Darwin
import XCTest
@testable import Threading

/// The two facts a native agent child has that a `Process` child did not: it leads its own
/// process group, and ending it ends everything it started.
final class AgentChildProcessTests: XCTestCase {

    // MARK: - Fixtures

    private var ledgerDirectory: URL!
    private var ledger: AgentChildLedger!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChildProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: ledgerDirectory,
            withIntermediateDirectories: true
        )
        ledger = AgentChildLedger(
            url: ledgerDirectory.appendingPathComponent(AgentChildLedgerDefaults.fileName)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ledgerDirectory)
        ledger = nil
        ledgerDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Process Group

    func testASpawnedChildLeadsItsOwnProcessGroup() throws {
        let child = try ChildProcessSpawn.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            workingDirectory: nil,
            descriptors: nullStandardStreams()
        )
        defer {
            child.kill()
            _ = waitUntilReaped(child)
        }

        let group = getpgid(child.processIdentifier)
        XCTAssertEqual(
            group,
            child.processIdentifier,
            "the child's group id must be its own pid, which is what makes kill(-pid) reach it"
        )
        XCTAssertNotEqual(
            group,
            getpgid(getpid()),
            "a child sharing the app's group is the leak this change exists to close"
        )
    }

    func testEndingTheGroupEndsAGrandchildTheChildBackgrounded() throws {
        let output = Pipe()
        // The shell backgrounds a sleep, reports its pid, then waits: the grandchild is in the
        // group but is not the child we signal, which is the case a per-pid SIGTERM misses.
        let child = try ChildProcessSpawn.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 30 & printf '%s\\n' \"$!\"; wait"],
            environment: [:],
            workingDirectory: nil,
            descriptors: [
                0: .nullDevice,
                1: .inherited(output.fileHandleForWriting.fileDescriptor),
                2: .nullDevice
            ]
        )
        try output.fileHandleForWriting.close()

        // Read to the newline rather than taking the first chunk: a pid split across two reads
        // would fail this test for a reason that has nothing to do with process groups.
        var reported = ""
        while !reported.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            reported += String(decoding: chunk, as: UTF8.self)
        }
        let trimmed = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(pid_t(trimmed), "grandchild pid: \(trimmed)")
        XCTAssertTrue(isAlive(grandchild))

        child.terminate()

        XCTAssertTrue(waitUntilReaped(child), "the group leader was not reaped")
        XCTAssertTrue(
            waitUntilGone(grandchild),
            "the backgrounded grandchild outlived a group signal"
        )
    }

    func testSpawnRefusesTruncatedArgumentsEnvironmentsAndAliasedDescriptors() {
        func assertSpawnError(
            _ expected: (ChildSpawnError) -> Bool,
            arguments: [String] = [],
            environment: [String: String] = [:],
            descriptors: [Int32: ChildDescriptorSource] = [:]
        ) {
            XCTAssertThrowsError(try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: arguments,
                environment: environment,
                workingDirectory: nil,
                descriptors: descriptors
            )) { error in
                guard let spawnError = error as? ChildSpawnError, expected(spawnError) else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        assertSpawnError({ if case .invalidArgument = $0 { return true }; return false },
                         arguments: ["before\0after"])
        assertSpawnError({ if case .invalidEnvironment = $0 { return true }; return false },
                         environment: ["BAD=NAME": "value"])
        assertSpawnError({ if case .invalidEnvironment = $0 { return true }; return false },
                         environment: ["OK": "before\0after"])
        assertSpawnError({ if case .invalidDescriptorMap = $0 { return true }; return false },
                         descriptors: [0: .inherited(1), 1: .inherited(0)])
    }

    func testDescriptorActionsPreserveAReusedStandardDescriptorBeforeOverwritingIt() throws {
        let actions = try XCTUnwrap(ChildProcessSpawn.orderedDescriptorActions([
            0: 4,
            1: 0,
            2: 0,
            4: 5
        ]))

        let targets = actions.map(\.target)
        XCTAssertLessThan(try XCTUnwrap(targets.firstIndex(of: 1)),
                          try XCTUnwrap(targets.firstIndex(of: 0)))
        XCTAssertLessThan(try XCTUnwrap(targets.firstIndex(of: 2)),
                          try XCTUnwrap(targets.firstIndex(of: 0)))
        XCTAssertLessThan(try XCTUnwrap(targets.firstIndex(of: 0)),
                          try XCTUnwrap(targets.firstIndex(of: 4)))
    }

    // MARK: - Ledger Round Trip

    func testALaunchedChildIsRecordedWhileItRunsAndForgottenWhenItIsReaped() throws {
        let exited = expectation(description: "child exit")
        let sessionID = SessionID()
        let status = ExitStatusBox()

        let child = try AgentChildProcess.launch(
            executable: "/bin/cat",
            arguments: [],
            environment: [:],
            sessionID: sessionID,
            ledger: ledger
        ) { code in
            status.value = code
            exited.fulfill()
        }

        let recorded = try XCTUnwrap(ledger.currentRecords.first)
        XCTAssertEqual(ledger.currentRecords.count, 1)
        XCTAssertEqual(recorded.pid, child.processIdentifier)
        XCTAssertEqual(recorded.sessionID, sessionID.uuidString)
        XCTAssertEqual(recorded.executable, "cat")
        XCTAssertEqual(
            recorded.startTime,
            ProcessUtility.startTime(forPid: child.processIdentifier),
            "the recorded identity must be the kernel's own, or the sweep cannot verify it"
        )

        try child.standardInput.write(contentsOf: Data("hello\n".utf8))
        XCTAssertEqual(
            String(decoding: child.standardOutput.availableData, as: UTF8.self),
            "hello\n",
            "stdio must survive the move off Process"
        )

        try child.standardInput.close()
        wait(for: [exited], timeout: 5)

        XCTAssertEqual(status.value, 0)
        XCTAssertTrue(
            ledger.currentRecords.isEmpty,
            "a reaped pid is the kernel's to hand out again; the record must not outlive it"
        )
    }

    func testAChildThatCannotStartThrowsRatherThanRecordingAnything() {
        XCTAssertThrowsError(try AgentChildProcess.launch(
            executable: "/does/not/exist/agent",
            arguments: [],
            environment: [:],
            sessionID: SessionID(),
            ledger: ledger
        ) { _ in }) { error in
            guard case .spawnFailed = error as? ChildSpawnError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(ledger.currentRecords.isEmpty)
    }

    /// Starting the executable is not enough: without the durable ownership record, a crash
    /// leaves the CLI reparented to launchd with no pid identity for the next launch to verify.
    func testAChildWhoseLedgerCannotBeWrittenIsEndedAndRefused() throws {
        let blockingFile = ledgerDirectory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let unwritableLedger = AgentChildLedger(
            url: blockingFile.appendingPathComponent("agent-children.json")
        )

        let rejectedPID: pid_t
        do {
            _ = try AgentChildProcess.launch(
                executable: "/bin/sleep",
                arguments: ["30"],
                environment: [:],
                sessionID: SessionID(),
                ledger: unwritableLedger
            ) { _ in }
            return XCTFail("an untracked child was allowed to run")
        } catch let error as AgentChildLaunchError {
            guard case .ledgerWriteFailed = error else {
                return XCTFail("unexpected enrollment error: \(error)")
            }
            rejectedPID = error.processIdentifier
        }

        XCTAssertTrue(unwritableLedger.currentRecords.isEmpty)
        XCTAssertTrue(
            waitUntilGone(rejectedPID),
            "the refused child outlived the launch transaction"
        )
    }

    func testStandardErrorStaysASeparateStreamFromStandardOutput() throws {
        let exited = expectation(description: "child exit")
        let child = try AgentChildProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'out'; printf 'err' >&2"],
            environment: [:],
            sessionID: SessionID(),
            ledger: ledger
        ) { _ in exited.fulfill() }

        let out = String(decoding: child.standardOutput.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: child.standardError.readDataToEndOfFile(), as: UTF8.self)
        wait(for: [exited], timeout: 5)

        // Merged, a diagnostic would land inside a JSON line and corrupt the turn it fell into.
        XCTAssertEqual(out, "out")
        XCTAssertEqual(err, "err")
    }

    // MARK: - Bounded One-Shot Children

    func testBoundedChildMergesOutputAndReportsANormalExit() throws {
        let result = try BoundedChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'out'; printf 'err' >&2; exit 7"],
            timeout: 5
        )

        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "outerr")
        XCTAssertFalse(result.outputWasTruncated)
        XCTAssertEqual(result.termination, .exited(7))
    }

    func testBoundedChildDoesNotMisreportAChildCrashAsItsOwnTimeout() throws {
        let result = try BoundedChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "kill -SEGV $$"],
            timeout: 5
        )

        XCTAssertEqual(result.termination, .exited(128 + SIGSEGV))
    }

    func testBoundedChildCapsRunawayOutputAndEscalatesPastIgnoredTerm() throws {
        let started = Date()
        let result = try BoundedChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do printf '0123456789'; done"],
            timeout: 0.05,
            terminationGrace: 0.05,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertEqual(result.output.count, 1_024)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: - Helpers

    private func nullStandardStreams() -> [Int32: ChildDescriptorSource] {
        [
            0: .nullDevice,
            1: .nullDevice,
            2: .nullDevice
        ]
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Polled rather than `waitUntilExit()`: blocking the user-interactive test thread on the
    /// child's reap queue is a priority inversion the performance checker reports.
    private func waitUntilReaped(
        _ child: SpawnedChildProcess,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard child.isRunning else { return true }
            usleep(20_000)
        }
        return !child.isRunning
    }

    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isAlive(pid) else { return true }
            usleep(20_000)
        }
        return !isAlive(pid)
    }
}

/// The exit status, carried out of a `@Sendable` handler that runs on the child's reap queue.
private final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32?

    var value: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
