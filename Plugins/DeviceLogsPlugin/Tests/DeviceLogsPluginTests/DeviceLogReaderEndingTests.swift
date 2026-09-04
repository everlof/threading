import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// A reader that has died looks exactly like a device that has gone quiet.
///
/// The pane had no way to tell them apart, because nothing told it: `DeviceLogLineReader` read
/// until end of file and returned, and the child's own diagnostics went to `/dev/null`. So a
/// locked device, an app that was not installed and a launch that simply failed all arrived as
/// silence under a pane that looked like it was listening.
final class DeviceLogReaderEndingTests: XCTestCase {

    /// The reason comes from the child rather than from us, so it says the useful thing.
    func testAFailingCommandReportsItsOwnDiagnosticRatherThanGoingQuiet() {
        let reader = DeviceLogLineReader(label: "test-failure")
        let ended = expectation(description: "ended")
        var reason = ""

        reader.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'Device is locked.' >&2; exit 3"],
            onLine: { _ in },
            onEnd: { text in
                reason = text
                ended.fulfill()
            }
        )

        wait(for: [ended], timeout: 10)
        XCTAssertEqual(reason, "Device is locked.")
    }

    /// With nothing on stderr there is still an ending, and it still has to be reported — a clean
    /// exit is the case where the pane most looks alive and is not.
    func testASilentExitIsStillReported() {
        let reader = DeviceLogLineReader(label: "test-silent")
        let ended = expectation(description: "ended")
        var reason = ""

        reader.run(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            onLine: { _ in },
            onEnd: { text in
                reason = text
                ended.fulfill()
            }
        )

        wait(for: [ended], timeout: 10)
        XCTAssertTrue(reason.contains("status 0"), "got \(reason)")
    }

    /// A stop the pane asked for is not an ending worth reporting. Without this the status line
    /// would accuse the source of dying every time someone switched tabs.
    func testAStopWeAskedForIsNotReportedAsAnEnding() {
        let reader = DeviceLogLineReader(label: "test-stop")
        let ended = expectation(description: "should not end")
        ended.isInverted = true

        reader.run(
            executable: "/bin/sh",
            arguments: ["-c", "while true; do sleep 1; done"],
            onLine: { _ in },
            onEnd: { _ in ended.fulfill() }
        )
        reader.stop()

        wait(for: [ended], timeout: 2)
    }

    /// The diagnostic tail is bounded: it exists to carry one sentence into a status line, not to
    /// mirror a second stream into memory.
    func testTheRetainedDiagnosticIsBounded() {
        let reader = DeviceLogLineReader(label: "test-bounded")
        let ended = expectation(description: "ended")
        var reason = ""

        reader.run(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 4000); do echo 'noisy diagnostic line' >&2; done; exit 1"],
            onLine: { _ in },
            onEnd: { text in
                reason = text
                ended.fulfill()
            }
        )

        wait(for: [ended], timeout: 20)
        XCTAssertLessThanOrEqual(
            reason.utf8.count, DeviceLogLineReader.retainedErrorBytes,
            "the whole of a chatty tool's stderr reached the status line"
        )
        XCTAssertFalse(reason.isEmpty)
    }
}
