import AppKit
import XCTest
@testable import DeviceLogsPlugin

/// The level menu decides what a system log reader is asked for, not only what the table shows.
/// A phone's Debug stream was 78% of what it sent, all of it parsed, buffered and recorded only to
/// be hidden by the default "Info and above".
@MainActor
final class DeviceLogCaptureLevelTests: XCTestCase {
    private let phone = DeviceLogSourceOption.Machine(id: "phone", title: "Test iPhone", isSimulator: false)

    func testTheSimulatorStreamIsAskedForTheLevel() {
        XCTAssertTrue(SimulatorLogRowSource(udid: "SIM", predicate: nil, minimumSeverity: 0).arguments.contains("--level=debug"))
        XCTAssertTrue(SimulatorLogRowSource(udid: "SIM", predicate: nil, minimumSeverity: 1).arguments.contains("--level=info"))
        XCTAssertTrue(SimulatorLogRowSource(udid: "SIM", predicate: nil, minimumSeverity: 3).arguments.contains("--level=default"))
    }

    func testTheStructuredRouteClearsOnlyTheStreamsBelowTheLevel() {
        XCTAssertEqual(StructuredPairedDeviceLogRowSource.levelArguments(atLeast: 0), [])
        XCTAssertEqual(StructuredPairedDeviceLogRowSource.levelArguments(atLeast: 1), ["--no-debug"])
        XCTAssertEqual(StructuredPairedDeviceLogRowSource.levelArguments(atLeast: 3), ["--no-debug", "--no-info"])
    }

    func testOnlySystemLogsAreReadAtALevel() throws {
        let simulator = DeviceLogSourceOption(
            machine: .init(id: "SIM", title: "iPhone 17", isSimulator: true), title: "System log", kind: .simulator(udid: "SIM")
        )
        let reader = try XCTUnwrap(simulator.makeSource(predicate: nil, minimumSeverity: 1) as? SimulatorLogRowSource)
        XCTAssertTrue(reader.arguments.contains("--level=info"))
        let structured = DeviceLogSourceOption(
            machine: phone, title: "System log (USB)",
            kind: .structuredDevice(udid: "phone", overNetwork: false, toolPath: "/usr/bin/true", fallbackToolPath: nil)
        )
        let device = try XCTUnwrap(structured.makeSource(predicate: nil, minimumSeverity: 1) as? StructuredPairedDeviceLogRowSource)
        XCTAssertTrue(device.structuredArguments.contains("--no-debug"))
        let bluetooth = DeviceLogSourceOption(
            machine: phone, title: "Bluetooth (USB)", kind: .bluetooth(udid: "phone", overNetwork: false, toolPath: nil)
        )
        XCTAssertFalse(bluetooth.readsAtLevel, "Packets have no level to leave unread")
        XCTAssertFalse(DeviceLogSourceOption(
            machine: phone, title: "MyApp", kind: .app(deviceID: "phone", bundleID: "com.example", appName: "MyApp")
        ).readsAtLevel)
    }

    func testTheLevelMenuRereadsTheSameSourceAndKeepsItsRows() {
        var readers: [BufferedDeviceLogSource] = []
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .regular)
        pane.captureManagedByWorkspace = true
        pane.sourceFactory = { _, _, _ in
            let reader = BufferedDeviceLogSource()
            readers.append(reader)
            return reader
        }
        _ = pane.view
        pane.acceptSources([.init(machine: phone, title: "System log (USB)", kind: .device(udid: phone.id, overNetwork: false))])
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        XCTAssertEqual(readers.count, 1)
        XCTAssertEqual(pane.captureSeverityForTesting, 1, "Info and above is what is read, not only what is shown")

        readers[0].enqueue([DeviceLogRow(time: "12:47:28", level: "Notice", process: "kernel", subsystem: nil, message: "kept")])
        pane.drain()
        pane.selectLevelForTesting(0)
        XCTAssertEqual(readers.count, 2, "Debug rows were never read, so they have to be asked for")
        XCTAssertEqual(pane.captureSeverityForTesting, 0)
        XCTAssertEqual(pane.focusSummary.total, 1, "The same source at another level keeps what it already read")

        pane.applyFocus(pattern: "", minimumSeverity: 3)
        XCTAssertEqual(readers.count, 2, "An agent's focus changes what is shown, not what is read")
        pane.selectLevelForTesting(0)
        XCTAssertEqual(readers.count, 2, "An unchanged level leaves the running reader alone")
    }
}
