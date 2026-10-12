import AppKit
import XCTest
@testable import DeviceLogsPlugin

@MainActor
final class DeviceLogWorkspaceTests: XCTestCase {
    private final class Reader: BufferedDeviceLogSource {
        var starts = 0
        var stops = 0
        override func start() { starts += 1 }
        override func stop() { stops += 1 }
    }

    private func sources() -> [DeviceLogSourceOption] {
        let phone = DeviceLogSourceOption.Machine(id: "fixture-phone", title: "Test iPhone", isSimulator: false)
        return [
            .init(machine: phone, title: "System log (USB)", kind: .device(udid: phone.id, overNetwork: false)),
            .init(machine: phone, title: "Bluetooth (USB)", kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil)),
        ]
    }

    private func workspace(regular: Reader, bluetooth: Reader) -> DeviceLogWorkspaceViewController {
        let workspace = DeviceLogWorkspaceViewController(sessionID: UUID().uuidString, toolPath: nil, preferredMachineID: "fixture-phone")
        let options = sources()
        workspace.discover = { $0(options) }
        workspace.sourceFactory = { option, _, _ in
            DeviceLogPaneViewController.Stream.bluetooth.includes(option) ? bluetooth : regular
        }
        _ = workspace.view
        return workspace
    }

    func testTabSwitchKeepsBothReadersAndHidingWorkspaceStopsBoth() async throws {
        let regular = Reader(), bluetooth = Reader()
        let workspace = workspace(regular: regular, bluetooth: bluetooth)
        defer { workspace.setPresented(false) }
        XCTAssertEqual(workspace.panes.count, 1, "Bluetooth must be lazy")
        XCTAssertEqual(regular.starts, 0)
        workspace.setPresented(true)
        XCTAssertEqual(regular.starts, 1)
        XCTAssertEqual(bluetooth.starts, 0)

        let logs = try XCTUnwrap(workspace.selectedPane)
        logs.simulateUserFilterEditForTesting("keep")
        XCTAssertFalse(logs.runningSourceTitleForTesting?.contains("Bluetooth") ?? true)
        workspace.selectStream(.bluetooth)
        let packets = try XCTUnwrap(workspace.selectedPane)
        XCTAssertTrue(packets.runningSourceTitleForTesting?.contains("Bluetooth") ?? false)
        XCTAssertEqual(regular.stops, 0)
        XCTAssertEqual(bluetooth.starts, 1)

        regular.enqueue([row("keep regular"), row("other regular")])
        bluetooth.enqueue([row("packet")])
        let hiddenUpdates = logs.presentationUpdateCount
        logs.drain()
        packets.drain()
        XCTAssertEqual(logs.presentationUpdateCount, hiddenUpdates)
        XCTAssertEqual(logs.focusSummary.total, 2)
        XCTAssertEqual(packets.visibleRowsForTools(limit: 10).map(\.message), ["packet"])
        let recordedLogs = try await count(logs.recorder)
        let recordedPackets = try await count(packets.recorder)
        XCTAssertEqual(recordedLogs, 2)
        XCTAssertEqual(recordedPackets, 1, "stream histories must not share a store")

        workspace.selectStream(.regular)
        try await settleProjection(logs)
        XCTAssertEqual(logs.focusSummary.total, 2)
        XCTAssertEqual(logs.visibleRowsForTools(limit: 10).map(\.message), ["keep regular"],
                       "the regular tab must retain its own filter")
        XCTAssertEqual(logs.agentNoteForTesting, nil)
        XCTAssertEqual(regular.starts, 1, "switching tabs must not restart a reader")
        XCTAssertEqual(bluetooth.stops, 0)

        workspace.setPresented(false)
        XCTAssertEqual(regular.stops, 1)
        XCTAssertEqual(bluetooth.stops, 1)
        XCTAssertFalse(logs.isVisibleForCapture)
        XCTAssertFalse(packets.isVisibleForCapture)
        workspace.setPresented(true)
        XCTAssertEqual(regular.starts, 2)
        XCTAssertEqual(bluetooth.starts, 2)
        XCTAssertEqual(logs.focusSummary.total, 2, "reappearing keeps both rings")
    }

    func testLateDiscoveryCannotRestartHiddenWorkspace() {
        let regular = Reader(), bluetooth = Reader()
        let workspace = workspace(regular: regular, bluetooth: bluetooth)
        var pending: (([DeviceLogSourceOption]) -> Void)?
        workspace.discover = { pending = $0 }
        workspace.setPresented(true)
        workspace.setPresented(false)
        pending?(sources())
        XCTAssertEqual(regular.starts, 0)
        XCTAssertEqual(bluetooth.starts, 0)
    }

    func testRescanIsSharedAndDoesNotRestartUnchangedReaders() {
        let regular = Reader(), bluetooth = Reader()
        let workspace = workspace(regular: regular, bluetooth: bluetooth)
        defer { workspace.setPresented(false) }
        let options = sources()
        var discoveries = 0
        workspace.discover = { completion in
            discoveries += 1
            completion(options)
        }
        workspace.setPresented(true)
        workspace.selectStream(.bluetooth)
        workspace.selectStream(.regular)
        XCTAssertEqual(discoveries, 1, "tab changes reuse the discovered devices")
        workspace.selectedPane?.requestDiscovery?()
        XCTAssertEqual(discoveries, 2, "Rescan discovers once for both tabs")
        XCTAssertEqual(regular.starts, 1)
        XCTAssertEqual(bluetooth.starts, 1)
        XCTAssertEqual(regular.stops, 0)
        XCTAssertEqual(bluetooth.stops, 0)
    }

    func testFirstBluetoothSelectionFollowsTheRegularTabsCurrentPhone() throws {
        let regular = Reader(), bluetooth = Reader()
        let workspace = workspace(regular: regular, bluetooth: bluetooth)
        defer { workspace.setPresented(false) }
        let secondPhone = DeviceLogSourceOption.Machine(id: "second-phone", title: "Second iPhone", isSimulator: false)
        let options = sources() + [
            .init(machine: secondPhone, title: "System log (USB)", kind: .device(udid: secondPhone.id, overNetwork: false)),
            .init(machine: secondPhone, title: "Bluetooth (USB)", kind: .bluetooth(udid: secondPhone.id, overNetwork: false, toolPath: nil)),
        ]
        workspace.discover = { $0(options) }
        workspace.setPresented(true)
        let logs = try XCTUnwrap(workspace.selectedPane)
        logs.selectMachine(id: secondPhone.id)
        workspace.selectStream(.bluetooth)
        let packets = try XCTUnwrap(workspace.selectedPane)
        XCTAssertEqual(packets.selectedDeviceID, secondPhone.id)
        packets.selectMachine(id: "fixture-phone")
        workspace.selectStream(.regular)
        XCTAssertEqual(logs.selectedDeviceID, secondPhone.id, "subsequent selections are independent")
    }

    func testConcurrentCaptureBoundsRingsWithoutProjectingInactiveRows() async throws {
        let regular = Reader(), bluetooth = Reader()
        let workspace = workspace(regular: regular, bluetooth: bluetooth)
        defer { workspace.setPresented(false) }
        workspace.setPresented(true)
        let logs = try XCTUnwrap(workspace.selectedPane)
        workspace.selectStream(.bluetooth)
        let packets = try XCTUnwrap(workspace.selectedPane)
        let batch = (0..<1_000).map { row("line \($0)") }
        let batches = ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_DUAL_STRESS"] == "1" ? 100 : 2
        let hiddenUpdates = logs.presentationUpdateCount
        var ticks: [TimeInterval] = []
        for _ in 0..<batches {
            regular.enqueue(batch)
            bluetooth.enqueue(batch)
            let start = Date()
            logs.drain()
            packets.drain()
            ticks.append(Date().timeIntervalSince(start))
        }
        let retained = min(batches * batch.count, DeviceLogLimits.ringCapacity)
        XCTAssertEqual(logs.focusSummary.total, retained)
        XCTAssertEqual(packets.focusSummary.total, retained)
        XCTAssertEqual(logs.presentationUpdateCount, hiddenUpdates)
        let recordedLogs = try await count(logs.recorder)
        let recordedPackets = try await count(packets.recorder)
        XCTAssertEqual(recordedLogs, batches * batch.count)
        XCTAssertEqual(recordedPackets, batches * batch.count)
        workspace.selectStream(.regular)
        try await settleProjection(logs)
        XCTAssertEqual(logs.focusSummary.shown, retained)
        ticks.sort()
        print("Dual logs: \(batches * batch.count) rows per stream; median tick \(ticks[ticks.count / 2] * 1_000) ms; max \(ticks.last! * 1_000) ms; hidden updates \(logs.presentationUpdateCount - hiddenUpdates)")
    }

    private func row(_ message: String) -> DeviceLogRow {
        .init(time: "12:00:00", level: "Info", process: "Test", subsystem: nil, message: message)
    }

    private func settleProjection(_ pane: DeviceLogPaneViewController) async throws {
        for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(pane.isProjectingForTesting)
    }

    private func count(_ recorder: DeviceLogRecorder?) async throws -> Int {
        let recorder = try XCTUnwrap(recorder)
        return try await withCheckedThrowingContinuation { continuation in
            recorder.read({ try $0.count() }) { continuation.resume(with: $0) }
        }
    }
}
