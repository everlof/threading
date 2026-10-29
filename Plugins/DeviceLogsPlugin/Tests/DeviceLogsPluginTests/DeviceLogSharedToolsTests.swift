import AppKit
import XCTest
import ThreadingPluginKit
@testable import DeviceLogsPlugin

@MainActor
final class DeviceLogSharedToolsTests: XCTestCase {
    private func plugin() -> DeviceLogsPlugin {
        let plugin = DeviceLogsPlugin()
        let theme = PluginTheme(
            background: .black, surface: .darkGray, text: .white, secondaryText: .gray,
            accent: .orange, monospacedFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
            rowHeight: 16, isDark: true
        )
        _ = plugin.makePaneView(context: PluginContext(theme: theme, arguments: [:]))
        plugin.installSharedDeviceLogsForTesting()
        return plugin
    }

    private func call(_ plugin: DeviceLogsPlugin, _ name: String, _ json: String = "{}") async throws
        -> (json: [String: Any], isError: Bool) {
        let answered = expectation(description: name)
        var response: (String, Bool)?
        plugin.invokeTool(named: name, argumentsJSON: json) { text, isError in
            response = (text, isError)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        let answer = try XCTUnwrap(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.0.utf8)) as? [String: Any], answer.0)
        for key in ["status", "revision", "cursor", "count", "has_more", "history", "cursor_truncated", "output_truncated", "pending"] {
            XCTAssertNotNil(object[key], "Every response must include \(key): \(answer.0)")
        }
        return (object, answer.1)
    }

    private func state(_ response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(response["state"] as? [String: Any])
    }

    func testSharedToolsDeclareRegularSectionAndDoNotAcceptRepeatedReadFilters() throws {
        let tools = try XCTUnwrap(DeviceLogsPlugin().pluginTools)
        for name in ["state", "configure", "read", "wait", "reveal"] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            XCTAssertEqual(tool.paneSectionToReveal, "regular")
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            if ["read", "wait"].contains(name) {
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                for key in ["device_id", "bundle_id", "process", "text", "levels"] { XCTAssertNil(properties[key]) }
            }
        }
    }

    func testConfigureReadAndManualEditUseTheSameRegularPanel() async throws {
        let plugin = plugin()
        let configured = try await call(plugin, "configure", #"{"device_id":"device-logs-fixture","bundle_id":"com.example.chameleon","text":"AirLab","follow":false}"#)
        XCTAssertFalse(configured.isError)
        let configuredState = try state(configured.json)
        let revision = try XCTUnwrap(configuredState["revision"] as? Int)
        let filter = try XCTUnwrap(configuredState["filter"] as? [String: Any])
        XCTAssertEqual(filter["text"] as? String, "AirLab")
        XCTAssertEqual(filter["bundle_id"] as? String, "com.example.chameleon")
        let catalog = try XCTUnwrap(configuredState["sources"] as? [[String: Any]])
        XCTAssertEqual(catalog.first { $0["title"] as? String == "Chameleon" }?["process"] as? String, "Ananke")

        let read = try await call(plugin, "read", #"{"limit":50}"#)
        XCTAssertFalse(read.isError)
        let rows = try XCTUnwrap(read.json["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["shared-log-tx-ns", "shared-log-rx-cp", "shared-log-tx-ds"])
        XCTAssertEqual(rows.compactMap { $0["source"] as? String }, ["stdout", "stdout", "stderr"])
        XCTAssertEqual(rows.compactMap { $0["process"] as? String }, ["Ananke", "Ananke", "Ananke"])
        XCTAssertEqual(rows.first?["device_id"] as? String, "device-logs-fixture")

        let pane = try XCTUnwrap(plugin.workspaceForTesting?.panes[.regular])
        pane.simulateUserFilterEditForTesting("ANCS")
        let edited = try await call(plugin, "state")
        let editedState = try state(edited.json)
        XCTAssertGreaterThan(try XCTUnwrap(editedState["revision"] as? Int), revision)
        XCTAssertEqual((editedState["filter"] as? [String: Any])?["text"] as? String, "ANCS")
        let afterEdit = try await call(plugin, "read")
        XCTAssertEqual((afterEdit.json["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["shared-log-rx-cp"])
    }

    func testStaleConfigurationRefusesAtomicallyAndReportsCurrentState() async throws {
        let plugin = plugin()
        let initial = try await call(plugin, "state")
        let initialState = try state(initial.json)
        let revision = try XCTUnwrap(initialState["revision"] as? Int)
        let pane = try XCTUnwrap(plugin.workspaceForTesting?.panes[.regular])
        pane.simulateUserFilterEditForTesting("ANCS")
        let refused = try await call(plugin, "configure", "{\"expected_revision\":\(revision),\"text\":\"lost edit\",\"follow\":false}")
        XCTAssertTrue(refused.isError)
        let current = try state(refused.json)
        XCTAssertEqual((current["filter"] as? [String: Any])?["text"] as? String, "ANCS")
        XCTAssertEqual(current["following"] as? Bool, initialState["following"] as? Bool)
        XCTAssertNotNil(refused.json["error"])
    }

    func testCursorPagesStableIdentitiesAndRevealSelectsThoseRows() async throws {
        let plugin = plugin()
        _ = try await call(plugin, "configure", #"{"text":"AirLab","bundle_id":"com.example.chameleon"}"#)
        let first = try await call(plugin, "read", #"{"limit":1}"#)
        let cursor = try XCTUnwrap(first.json["cursor"] as? String)
        XCTAssertEqual(first.json["has_more"] as? Bool, true)
        XCTAssertEqual(first.json["count"] as? Int, 1)
        let request = try JSONSerialization.data(withJSONObject: ["limit": 2, "cursor": cursor])
        let second = try await call(plugin, "read", String(decoding: request, as: UTF8.self))
        XCTAssertEqual((second.json["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["shared-log-rx-cp", "shared-log-tx-ds"])
        XCTAssertEqual(second.json["has_more"] as? Bool, false)
        let revealed = try await call(plugin, "reveal", #"{"row_id":"shared-log-tx-ns","through_row_id":"shared-log-tx-ds"}"#)
        XCTAssertFalse(revealed.isError)
        let pane = try XCTUnwrap(plugin.workspaceForTesting?.panes[.regular])
        XCTAssertEqual(pane.selectedRowIDsForTesting, ["shared-log-tx-ns", "shared-log-rx-cp", "shared-log-tx-ds"],
                       "the exact evidence must be selected in the visible panel")
        let missing = try await call(plugin, "reveal", #"{"row_id":"missing-row"}"#)
        XCTAssertTrue(missing.isError)
    }

    func testMalformedAndOutOfBoundsArgumentsReturnStructuredRefusalsWithoutMutating() async throws {
        let plugin = plugin()
        let initial = try await call(plugin, "state")
        let revision = initial.json["revision"] as? Int
        let invalid: [(String, String)] = [
            ("configure", #"{"text":"AirLab","proces":"Ananke"}"#),
            ("read", #"{"text":"AirLab"}"#), ("read", #"{"limit":-1}"#),
            ("read", #"{"limit":0}"#), ("read", #"{"limit":51}"#),
            ("read", #"{"limit":1.5}"#), ("read", #"{"limit":true}"#),
            ("wait", #"{"timeout_seconds":31}"#), ("wait", #"{"timeout_seconds":-1}"#),
            ("configure", #"{"expected_revision":-1}"#),
            ("configure", #"{"expected_revision":18446744073709551616}"#),
            ("reveal", #"{"row_id":""}"#), ("state", "[]"), ("state", "{broken"),
        ]
        for (name, arguments) in invalid {
            let answer = try await call(plugin, name, arguments)
            XCTAssertTrue(answer.isError, "\(name) \(arguments)")
            XCTAssertEqual(answer.json["revision"] as? Int, revision, "a refusal must leave the shared state untouched")
        }
    }

    func testWaitTimeoutAndFilterChangeAreExplicit() async throws {
        let plugin = plugin()
        let timedOut = try await call(plugin, "wait", #"{"timeout_seconds":0.01}"#)
        XCTAssertFalse(timedOut.isError)
        XCTAssertEqual(timedOut.json["status"] as? String, "timeout")
        XCTAssertEqual(timedOut.json["count"] as? Int, 0)

        let waiting = Task { try await call(plugin, "wait", #"{"timeout_seconds":2}"#) }
        try await Task.sleep(for: .milliseconds(50))
        plugin.workspaceForTesting?.panes[.regular]?.simulateUserFilterEditForTesting("ANCS")
        let changed = try await waiting.value
        XCTAssertTrue(changed.isError || changed.json["changed"] as? Bool == true,
                      "a shared filter change must end a wait explicitly")
    }

    func testSharedReadsStayOnRegularLogsWhenBluetoothIsSelected() async throws {
        let plugin = plugin()
        plugin.workspaceForTesting?.selectStream(.bluetooth)
        let read = try await call(plugin, "read")
        XCTAssertFalse(read.isError)
        XCTAssertEqual(read.json["stream"] as? String, "regular")
        XCTAssertTrue((read.json["rows"] as? [[String: Any]])?.contains { $0["id"] as? String == "shared-log-tx-ns" } == true)
    }

    func testStateRefreshUsesTheExistingDiscoveryAndReportsPendingCatalog() async throws {
        let plugin = plugin()
        let workspace = try XCTUnwrap(plugin.workspaceForTesting)
        var completeDiscovery: (([DeviceLogSourceOption]) -> Void)?
        var scans = 0
        workspace.discover = { completion in scans += 1; completeDiscovery = completion }
        let refreshing = try await call(plugin, "state", #"{"refresh":true}"#)
        XCTAssertFalse(refreshing.isError)
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(refreshing.json["status"] as? String, "discovery_pending")
        XCTAssertEqual(try state(refreshing.json)["source_catalog_pending"] as? Bool, true)
        let machine = DeviceLogSourceOption.Machine(id: "new-phone", title: "New iPhone", isSimulator: false)
        completeDiscovery?([.init(machine: machine, title: "System log (USB)", kind: .device(udid: machine.id, overNetwork: false))])
        let ready = try await call(plugin, "state")
        let readyState = try state(ready.json)
        XCTAssertEqual(ready.json["status"] as? String, "ok")
        XCTAssertEqual(readyState["source_catalog_pending"] as? Bool, false)
        XCTAssertNotNil(readyState["source_catalog_updated_at"])
        XCTAssertTrue((readyState["devices"] as? [[String: Any]])?.contains { $0["id"] as? String == "new-phone" } == true)
        XCTAssertEqual(scans, 1, "reading state must not start another discovery")
    }
}
