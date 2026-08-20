#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import SwiftTerm

final class LocalProcessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        signal(SIGCHLD, SIG_DFL)
    }

    func testForkptyProvidesControllingTerminalPIDWorkingDirectoryAndExitCode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTerm PTY \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputExpectation = expectation(description: "PTY output")
        let terminationExpectation = expectation(description: "process termination")
        let delegate = ProcessDelegate()
        delegate.onOutput = { output in
            if output.contains("CONTROLLING_TTY") {
                outputExpectation.fulfill()
            }
        }
        delegate.onTermination = { _ in
            terminationExpectation.fulfill()
        }

        let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.callback")
        let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)
        process.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "printf '%s\\n' \"$PWD\"; "
                    + "if test -t 0 && test -t 1 && test -t 2; "
                    + "then printf CONTROLLING_TTY; else printf NO_TTY; fi; exit 7"
            ],
            environment: nil,
            execName: "sh",
            currentDirectory: directory.path
        )

        XCTAssertTrue(process.running)
        XCTAssertGreaterThan(process.shellPid, 0)

        wait(for: [outputExpectation, terminationExpectation], timeout: 5)
        callbackQueue.sync {}

        XCTAssertTrue(delegate.output.contains(directory.path))
        XCTAssertTrue(delegate.output.contains("CONTROLLING_TTY"))
        XCTAssertFalse(delegate.output.contains("NO_TTY"))
        XCTAssertEqual(delegate.exitCode, 7)
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.shellPid, 0)
    }

    func testTerminateSignalsAndReapsTheExactChild() {
        let terminationExpectation = expectation(description: "terminated child was reaped")
        let delegate = ProcessDelegate()
        delegate.onTermination = { _ in
            terminationExpectation.fulfill()
        }

        let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.termination")
        let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)
        process.startProcess(
            executable: "/bin/sleep",
            args: ["30"],
            environment: nil,
            execName: "sleep"
        )
        let launchedPID = process.shellPid

        XCTAssertGreaterThan(launchedPID, 0)
        XCTAssertEqual(kill(launchedPID, 0), 0)

        process.terminate()
        wait(for: [terminationExpectation], timeout: 5)

        XCTAssertFalse(process.running)
        XCTAssertEqual(process.shellPid, 0)
        XCTAssertNil(delegate.exitCode)
        XCTAssertEqual(kill(launchedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTerminateBlocksRelaunchUntilExactChildIsReaped() {
        let firstTermination = expectation(description: "first child terminated")
        let secondTermination = expectation(description: "replacement child terminated")
        let delegate = ProcessDelegate()
        var terminationCount = 0
        delegate.onTermination = { _ in
            terminationCount += 1
            if terminationCount == 1 {
                firstTermination.fulfill()
            } else {
                secondTermination.fulfill()
            }
        }

        let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.rapid-relaunch")
        let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)
        process.startProcess(
            executable: "/bin/sleep",
            args: ["30"],
            environment: nil,
            execName: "sleep"
        )
        let terminatingPID = process.shellPid

        process.terminate()
        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true"
        )

        XCTAssertTrue(process.running, "terminating remains an occupied lifecycle state")
        XCTAssertEqual(process.shellPid, terminatingPID, "relaunch must not replace an unreaped PID")

        wait(for: [firstTermination], timeout: 5)
        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true"
        )
        wait(for: [secondTermination], timeout: 5)

        XCTAssertEqual(terminationCount, 2)
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.shellPid, 0)
    }

    func testRepeatedInstantExitCanRelaunchTheSameLocalProcess() {
        let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.instant-exit")
        let delegate = ProcessDelegate()
        let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)

        for iteration in 0..<50 {
            let termination = expectation(description: "instant exit \(iteration)")
            delegate.onTermination = { _ in termination.fulfill() }

            process.startProcess(
                executable: "/bin/sh",
                args: ["-c", "exit \(iteration % 8)"],
                environment: nil,
                execName: "sh"
            )
            wait(for: [termination], timeout: 5)

            XCTAssertFalse(process.running)
            XCTAssertEqual(process.shellPid, 0)
            XCTAssertEqual(delegate.exitCode, Int32(iteration % 8))
        }
    }

    func testRepeatedLaunchTerminateCyclesReapEveryChild() {
        let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.repeated-termination")
        let delegate = ProcessDelegate()
        let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)

        for iteration in 0..<25 {
            let termination = expectation(description: "termination \(iteration)")
            delegate.onTermination = { _ in termination.fulfill() }
            process.startProcess(
                executable: "/bin/sleep",
                args: ["30"],
                environment: nil,
                execName: "sleep"
            )
            let pid = process.shellPid

            process.terminate()
            wait(for: [termination], timeout: 5)

            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testConcurrentProcessesKeepOutputAndExitStateIndependent() {
        let processCount = 8
        var processes: [LocalProcess] = []
        var delegates: [ProcessDelegate] = []
        var callbackQueues: [DispatchQueue] = []
        var expectations: [XCTestExpectation] = []

        for index in 0..<processCount {
            let token = "PROCESS-\(index)"
            let output = expectation(description: "\(token) output")
            let termination = expectation(description: "\(token) termination")
            let delegate = ProcessDelegate()
            delegate.expectedByteCount = token.utf8.count
            delegate.onExpectedByteCount = { output.fulfill() }
            delegate.onTermination = { _ in termination.fulfill() }
            let callbackQueue = DispatchQueue(label: "SwiftTerm.LocalProcessTests.concurrent.\(index)")
            let process = LocalProcess(delegate: delegate, dispatchQueue: callbackQueue)

            delegates.append(delegate)
            callbackQueues.append(callbackQueue)
            processes.append(process)
            expectations.append(contentsOf: [output, termination])

            process.startProcess(
                executable: "/bin/sh",
                args: ["-c", "printf \(token); exit \(index)"],
                environment: nil,
                execName: "sh"
            )
        }

        wait(for: expectations, timeout: 10)
        for queue in callbackQueues {
            queue.sync {}
        }
        for index in 0..<processCount {
            XCTAssertEqual(delegates[index].output, "PROCESS-\(index)")
            XCTAssertEqual(delegates[index].exitCode, Int32(index))
            XCTAssertFalse(processes[index].running)
        }
    }

    func testQueuedOutputIsDiscardedBeforeReplacementGeneration() {
        let replacementOutput = expectation(description: "replacement output")
        let replacementTermination = expectation(description: "replacement terminated")
        let delegate = ProcessDelegate()
        var replacementStarted = false
        var staleOutputAfterReplacement = false
        var process: LocalProcess!

        delegate.onBytes = { bytes in
            if replacementStarted {
                staleOutputAfterReplacement = staleOutputAfterReplacement || bytes.contains(0)
            } else {
                // Make the bounded drain yield with old chunks still queued.
                Thread.sleep(forTimeInterval: 0.001)
            }
            if String(bytes: bytes, encoding: .utf8)?.contains("REPLACEMENT") == true {
                replacementOutput.fulfill()
            }
        }
        delegate.onTermination = { _ in
            if replacementStarted {
                replacementTermination.fulfill()
                return
            }

            replacementStarted = true
            process.startProcess(
                executable: "/usr/bin/printf",
                args: ["REPLACEMENT"],
                environment: nil,
                execName: "printf"
            )
        }
        process = LocalProcess(delegate: delegate)

        let launchAndTerminateWhileHoldingMainQueue = {
            process.startProcess(
                executable: "/usr/bin/head",
                args: ["-c", String(16 * 1024 * 1024), "/dev/zero"],
                environment: nil,
                execName: "head"
            )
            Thread.sleep(forTimeInterval: 0.1)
            process.terminate()
        }

        if Thread.isMainThread {
            launchAndTerminateWhileHoldingMainQueue()
        } else {
            DispatchQueue.main.sync(execute: launchAndTerminateWhileHoldingMainQueue)
        }

        wait(for: [replacementOutput, replacementTermination], timeout: 10)
        XCTAssertFalse(staleOutputAfterReplacement)
    }

    func testDeinitTerminatesAndReapsChild() {
        let delegate = ProcessDelegate()
        weak var releasedProcess: LocalProcess?
        var launchedPID: pid_t = 0

        autoreleasepool {
            let process = LocalProcess(
                delegate: delegate,
                dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessTests.deinit")
            )
            process.startProcess(
                executable: "/bin/sleep",
                args: ["30"],
                environment: nil,
                execName: "sleep"
            )
            launchedPID = process.shellPid
            releasedProcess = process
        }

        XCTAssertNil(releasedProcess)
        XCTAssertGreaterThan(launchedPID, 0)

        let deadline = Date().addingTimeInterval(5)
        while kill(launchedPID, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(launchedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testMainQueueOutputDrainsCompletelyAfterSustainedBackpressure() {
        // Twice the production high-water mark forces a suspend/resume cycle without turning
        // this correctness check into a throughput benchmark on a contended CI host.
        let byteCount = 8 * 1024 * 1024
        let outputExpectation = expectation(description: "all output delivered")
        let terminationExpectation = expectation(description: "producer terminated")
        let delegate = ProcessDelegate()
        delegate.capturesText = false
        delegate.expectedByteCount = byteCount
        delegate.onExpectedByteCount = {
            outputExpectation.fulfill()
        }
        delegate.onTermination = { _ in
            terminationExpectation.fulfill()
        }
        let process = LocalProcess(delegate: delegate)

        let launchWhileHoldingMainQueue = {
            process.startProcess(
                executable: "/usr/bin/head",
                args: ["-c", String(byteCount), "/dev/zero"],
                environment: nil,
                execName: "head"
            )
            // Let the reader reach its high-water mark while AppKit's queue is unavailable.
            Thread.sleep(forTimeInterval: 0.1)
        }

        if Thread.isMainThread {
            launchWhileHoldingMainQueue()
        } else {
            DispatchQueue.main.sync(execute: launchWhileHoldingMainQueue)
        }

        wait(for: [outputExpectation, terminationExpectation], timeout: 60)
        XCTAssertEqual(delegate.outputByteCount, byteCount)
    }
}

private final class ProcessDelegate: LocalProcessDelegate {
    var output = ""
    var outputByteCount = 0
    var expectedByteCount: Int?
    var exitCode: Int32?
    var onOutput: ((String) -> Void)?
    var onBytes: ((ArraySlice<UInt8>) -> Void)?
    var onExpectedByteCount: (() -> Void)?
    var onTermination: ((Int32?) -> Void)?
    var capturesText = true
    private var reportedExpectedByteCount = false

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        self.exitCode = exitCode
        onTermination?(exitCode)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        outputByteCount += slice.count
        onBytes?(slice)
        if capturesText, let text = String(bytes: slice, encoding: .utf8) {
            output += text
            onOutput?(output)
        }
        if let expectedByteCount,
           outputByteCount >= expectedByteCount,
           !reportedExpectedByteCount {
            reportedExpectedByteCount = true
            onExpectedByteCount?()
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 480)
    }
}
#endif
