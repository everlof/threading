import AppKit
import XCTest
import ThreadingPluginKit
@testable import DeviceLogsPlugin

@MainActor
final class BluetoothSharedToolsTests: XCTestCase {
    private func fixture() throws -> (DeviceLogsPlugin, DeviceLogWorkspaceViewController, DeviceLogPaneViewController) {
        let plugin = DeviceLogsPlugin()
        let theme = PluginTheme(
            background: .black, surface: .darkGray, text: .white, secondaryText: .gray,
            accent: .orange, monospacedFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
            rowHeight: 16, isDark: true
        )
        _ = plugin.makePaneView(context: PluginContext(theme: theme, arguments: [
            "hostPaneSections": "true", "checkoutPath": "/nonexistent-threading-bluetooth-fixture",
        ]))
        _ = plugin.makePaneSectionView(identifier: "bluetooth")
        let workspace = try XCTUnwrap(plugin.workspaceForTesting)
        let bluetooth = try XCTUnwrap(workspace.panes[.bluetooth])
        let phone = DeviceLogSourceOption.Machine(id: "phone", title: "Test iPhone", isSimulator: false)
        bluetooth.installSourcesForTesting([
            .init(machine: phone, title: "Bluetooth (USB)", kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil)),
        ])
        bluetooth.installRowsForTesting([
            .init(time: "09:41:00", level: "Info", process: "Watch", subsystem: "App", message: "ANCS TX NS", id: "ns"),
            .init(time: "09:41:01", level: "Warning", process: "Watch", subsystem: "App", message: "ANCS RX CP ⚠ misfit", id: "cp"),
            .init(time: "09:41:02", level: "Info", process: "Controller", subsystem: "HCI", message: "Connection complete", id: "hci"),
        ])
        workspace.panes[.regular]?.installRowsForTesting([
            .init(time: "09:41:00", level: "Info", process: "Ananke", subsystem: nil, message: "App log", id: "regular"),
        ])
        bluetooth.applyDefinitionStatusForTesting(.missing(expected: URL(fileURLWithPath: "/project/.threading/bluetooth.yaml")))
        workspace.selectStream(.regular)
        return (plugin, workspace, bluetooth)
    }

    private func call(_ plugin: DeviceLogsPlugin, _ name: String, _ args: [String: Any] = [:], fails: Bool = false) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args)
        let answer: (String, Bool) = await withCheckedContinuation { continuation in
            plugin.invokeTool(named: name, argumentsJSON: String(decoding: data, as: UTF8.self)) {
                continuation.resume(returning: ($0, $1))
            }
        }
        XCTAssertEqual(answer.1, fails, answer.0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.0.utf8)) as? [String: Any])
    }

    func testExplicitStreamSurvivesTabSwitchesAndSharesPacketFilters() async throws {
        let (plugin, workspace, bluetooth) = try fixture()
        let configured = try await call(plugin, "bluetooth_configure", ["device_id": "phone", "packets": "app", "text": "ANCS", "follow": false])
        XCTAssertEqual(configured["stream"] as? String, "bluetooth")
        XCTAssertEqual(bluetooth.packetFilter, .app)
        XCTAssertEqual(bluetooth.panelState().filter.text, "ANCS")
        XCTAssertEqual(workspace.panes[.regular]?.panelState().filter.text, "")
        let origin = bluetooth.scrollOriginForTesting
        workspace.selectStream(.regular)
        let read = try await call(plugin, "bluetooth_read")
        XCTAssertEqual((read["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["ns", "cp"])
        XCTAssertEqual(bluetooth.scrollOriginForTesting, origin)
        XCTAssertTrue(bluetooth.selectedRowIDsForTesting.isEmpty)
        let state = try XCTUnwrap(read["state"] as? [String: Any])
        let packetState = try XCTUnwrap(state["bluetooth"] as? [String: Any])
        XCTAssertEqual(packetState["packets"] as? String, "app")
        XCTAssertEqual((packetState["definitions"] as? [String: Any])?["status"] as? String, "missing")
        XCTAssertEqual(state["capture_state"] as? String, "stopped", "retained rows do not prove a live capture")

        bluetooth.setPacketFilter(.complete)
        let changed = try await call(plugin, "bluetooth_read", ["cursor": try XCTUnwrap(read["cursor"] as? String)])
        XCTAssertEqual(changed["changed"] as? Bool, true)
        XCTAssertEqual((changed["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["ns"])
        _ = try await call(plugin, "bluetooth_reveal", ["row_id": "ns"])
        XCTAssertEqual(bluetooth.selectedRowIDsForTesting, ["ns"])
        _ = try await call(plugin, "bluetooth_reveal", ["row_id": "regular"], fails: true)
        workspace.selectStream(.bluetooth)
        let regular = try await call(plugin, "read")
        XCTAssertEqual(regular["stream"] as? String, "regular")
        XCTAssertEqual((regular["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["regular"])
    }

    func testManualFilterEditsStaleRefusalsAndClearUseTheBluetoothPanel() async throws {
        let (plugin, _, bluetooth) = try fixture()
        let configured = try await call(plugin, "bluetooth_configure", ["packets": "app", "text": "ANCS"])
        let revision = try XCTUnwrap(configured["revision"] as? Int)
        bluetooth.simulateUserFilterEditForTesting("RX CP")
        _ = try await call(plugin, "bluetooth_configure", ["expected_revision": revision, "packets": "all", "text": "lost"], fails: true)
        XCTAssertEqual(bluetooth.packetFilter, .app)
        XCTAssertEqual(bluetooth.panelState().filter.text, "RX CP")
        let read = try await call(plugin, "bluetooth_read")
        XCTAssertEqual((read["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["cp"])
        for arguments: [String: Any] in [["packets": "unknown", "text": "lost"], ["process": "Ananke", "text": "lost"], ["bundle_id": "app"]] {
            _ = try await call(plugin, "bluetooth_configure", arguments, fails: true)
            XCTAssertEqual(bluetooth.panelState().filter.text, "RX CP")
        }
        _ = try await call(plugin, "bluetooth_configure", ["clear_filter": true])
        XCTAssertEqual(bluetooth.packetFilter, .all)
        XCTAssertEqual(bluetooth.panelState().filter.text, "")
        let all = try await call(plugin, "bluetooth_read")
        XCTAssertEqual(all["count"] as? Int, 3)
        _ = try await call(plugin, "bluetooth_configure", ["packets": "app", "subsystem": "HCI"])
        let intersection = try await call(plugin, "bluetooth_read")
        XCTAssertEqual(intersection["count"] as? Int, 0, "packet mode must not silently replace the visible subsystem filter")
    }

    func testWaitReportsManualChangesAndEveryToolRevealsBluetooth() async throws {
        let (plugin, _, bluetooth) = try fixture()
        bluetooth.sourceFactory = { _, _, _ in BufferedDeviceLogSource() }
        bluetooth.startCapture(discover: false)
        defer { bluetooth.stopCapture() }
        for name in ["state", "configure", "read", "wait", "reveal"] {
            let definition = try XCTUnwrap(plugin.pluginTools.first { $0.name == "bluetooth_" + name })
            XCTAssertEqual(definition.paneSectionToReveal, "bluetooth")
        }
        let read = try await call(plugin, "bluetooth_read")
        let cursor = try XCTUnwrap(read["cursor"] as? String)
        let changing = Task {
            try await Task.sleep(for: .milliseconds(40))
            bluetooth.setPacketFilter(.app)
        }
        let result = try await call(plugin, "bluetooth_wait", ["cursor": cursor, "timeout_seconds": 1])
        try await changing.value
        XCTAssertEqual(result["stream"] as? String, "bluetooth")
        XCTAssertEqual(result["changed"] as? Bool, true)
    }
}
