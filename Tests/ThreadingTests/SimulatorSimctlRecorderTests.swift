import Foundation
import XCTest
@testable import Threading

@MainActor
final class SimulatorSimctlRecorderTests: XCTestCase {
    func testArgumentsRecordVideoToTheGivenPath() {
        let url = URL(fileURLWithPath: "/tmp/Threading/iPhone 17 Pro.mov")
        let args = SimulatorSimctlRecorder.arguments(
            deviceID: "4111208A-4B29-40E1-8C66-1B8AE2A1BF1F", output: url
        )
        XCTAssertEqual(args, [
            "simctl", "io", "4111208A-4B29-40E1-8C66-1B8AE2A1BF1F",
            "recordVideo", "--codec", "h264", "--force", url.path,
        ])
    }

    func testAFreshRecorderIsNotRecording() {
        XCTAssertFalse(SimulatorSimctlRecorder().isRecording)
    }
}
