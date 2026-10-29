import XCTest
@testable import DeviceLogsPlugin

/// The app console route launches the app the way Xcode's Run does, so its own `os_log` lines
/// arrive mirrored on `stderr`, unredacted, and read like the same line in the system log.
final class DeviceConsoleLogSourceTests: XCTestCase {
    private let source = DeviceConsoleLogSource(deviceID: "phone", bundleID: "com.festina.chameleon", appName: "Ananke")

    private func decode(_ text: String) -> DeviceLogRow? { source.decode(Array(text.utf8)[...]) }

    func testTheLaunchAsksForOSLogOnStderrAsXcodeDoes() throws {
        let environment = try JSONSerialization.jsonObject(with: Data(DeviceConsoleLogSource.environment.utf8)) as? [String: String]
        XCTAssertEqual(environment, ["OS_ACTIVITY_DT_MODE": "enable"])
    }

    func testAMirroredLogLineKeepsItsTimeAndSubsystem() throws {
        let row = try XCTUnwrap(decode("2026-10-14 08:14:08.201345+0200 Ananke[423:9a1f3] [com.festina.chameleon:bluetooth] Pairing failed: peer removed pairing information"))
        XCTAssertEqual(row.time, "08:14:08.201")
        XCTAssertEqual(row.subsystem, "com.festina.chameleon")
        XCTAssertEqual(row.category, "bluetooth")
        XCTAssertEqual(row.subsystemLabel, "com.festina.chameleon / bluetooth")
        XCTAssertEqual(row.message, "Pairing failed: peer removed pairing information")
        XCTAssertEqual(row.process, "Ananke")
        XCTAssertEqual(row.pid, 423)
        XCTAssertEqual(row.bundleID, "com.festina.chameleon")
        XCTAssertEqual(row.deviceID, "phone")
        XCTAssertEqual(row.source, .stderr)
        XCTAssertNotNil(row.timestamp)
    }

    func testAMirroredLineWithoutASubsystemAndPlainPrintsStillRead() throws {
        let untagged = try XCTUnwrap(decode("2026-10-14 08:14:08.201345+0200 Ananke[423:0x9a1f3] scanning"))
        XCTAssertNil(untagged.subsystem)
        XCTAssertEqual(untagged.message, "scanning")
        let printed = try XCTUnwrap(decode("error: could not open file"))
        XCTAssertEqual(printed.message, "error: could not open file")
        XCTAssertEqual(printed.level, "Error")
        XCTAssertEqual(printed.source, .console, "the merged console cannot prove which descriptor produced a plain print")
        XCTAssertNil(decode("Acquired tunnel connection to device."))
    }
}
