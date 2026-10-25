import XCTest
@testable import Threading

final class DeviceLogAgentCommandServiceTests: XCTestCase {
    func testPreparationDistinguishesCaptureRoutesAndDoesNotPromiseAConnectedReader() {
        let built = DeviceLogTap.Built(path: URL(fileURLWithPath: "/tmp/logtap.a"), platform: .device)
        let result = DeviceLogAgentCommandService.preparationResult(for: built)
        XCTAssertFalse(result.isError)
        for phrase in ["does not prove", "merged console", "redact private values", "rebuild/reinstall", "do not upgrade automatically",
                       "plugin__devicelogs__state", "plugin__devicelogs__configure", "plugin__devicelogs__wait"] {
            XCTAssertTrue(result.text.contains(phrase), "missing \(phrase)")
        }
        XCTAssertTrue(result.text.contains("OTHER_LDFLAGS='$(inherited)"))
    }

    func testRefusedTapDoesNotClaimOutputIsAlreadyStreaming() {
        let result = DeviceLogAgentCommandService.refusedResult()
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Do not link the tap"))
        XCTAssertTrue(result.text.contains("capture status"))
        XCTAssertFalse(result.text.contains("open and streaming"))
    }

    func testSimulatorPreparationRemainsALaunchSetting() {
        let built = DeviceLogTap.Built(path: URL(fileURLWithPath: "/tmp/logtap.dylib"), platform: .simulator)
        XCTAssertTrue(DeviceLogAgentCommandService.guidance(for: built).contains("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="))
        if case .rejected(let result) = DeviceLogAgentCommandService.platform(from: .init(platform: "other")) {
            XCTAssertTrue(result.isError)
        } else { XCTFail("invalid platform accepted") }
    }
}
