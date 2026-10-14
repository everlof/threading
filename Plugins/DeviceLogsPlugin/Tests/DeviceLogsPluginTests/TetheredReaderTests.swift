import Darwin
import XCTest
@testable import DeviceLogsPlugin

/// A reader must never outlive the Threading that started it: an orphaned `idevicebtlogger` kept
/// the phone's Bluetooth relay after an update, and the next capture received nothing.
final class TetheredReaderTests: XCTestCase {
    /// Starts a tethered reader that prints its own pid and then sleeps, and returns that pid.
    private func launch(_ task: Process, script: String = "echo $$; exec /bin/sleep 30") throws -> (FileHandle, pid_t) {
        let tether = TetheredReader.configure(task, executable: "/bin/sh", arguments: ["-c", script])
        let output = Pipe()
        task.standardOutput = output
        try task.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let pid = try XCTUnwrap(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(pid, task.processIdentifier, "the reader runs under the tether, not as it")
        return (tether, pid)
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntilGone(_ pid: pid_t, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(50_000)
        }
        return !isAlive(pid)
    }

    func testTheReaderEndsWhenThreadingsEndOfTheTetherCloses() throws {
        // What the kernel does for us when Threading quits, crashes or is killed.
        let task = Process()
        let (tether, reader) = try launch(task)
        XCTAssertTrue(isAlive(reader))
        try tether.close()
        XCTAssertTrue(waitUntilGone(reader), "the reader outlived its tether")
        task.waitUntilExit()
    }

    func testStoppingTheTetherEndsTheReader() throws {
        let task = Process()
        let (tether, reader) = try launch(task)
        task.terminate()
        task.waitUntilExit()
        XCTAssertTrue(waitUntilGone(reader), "terminating the tether left its reader running")
        try? tether.close()
    }

    func testAKilledTetherStillTakesItsReaderOnceTheEndCloses() throws {
        // A wedged tether is SIGKILLed after a second; it cannot clean up, its watcher can.
        let task = Process()
        let (tether, reader) = try launch(task)
        kill(task.processIdentifier, SIGKILL)
        task.waitUntilExit()
        XCTAssertTrue(isAlive(reader))
        try tether.close()
        XCTAssertTrue(waitUntilGone(reader))
    }

    func testTheReadersOwnExitStatusPassesThrough() throws {
        let task = Process()
        let tether = TetheredReader.configure(task, executable: "/bin/sh", arguments: ["-c", "exit 3"])
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 3)
        try? tether.close()
    }

    func testThreadingsEndIsNotInheritedByLaterChildren() throws {
        let task = Process()
        let tether = TetheredReader.configure(task, executable: "/bin/sh", arguments: ["-c", "exit 0"])
        XCTAssertEqual(fcntl(tether.fileDescriptor, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
        try task.run()
        task.waitUntilExit()
        try? tether.close()
    }
}
