import XCTest
@testable import Threading

final class DeviceLogsToolTests: XCTestCase {
    func testStableEntryPointDecodesRoutingAndPreservesPanelParameters() throws {
        let data = Data(#"{"action":"configure","stream":"bluetooth","device_id":"phone","packets":"app","expected_revision":12}"#.utf8)
        let arguments = try JSONDecoder().decode(DeviceLogsArguments.self, from: data)
        XCTAssertEqual(arguments.pluginToolName, "plugin__devicelogs__bluetooth_configure")
        XCTAssertEqual(arguments.parameters, .object([
            "device_id": .string("phone"), "packets": .string("app"), "expected_revision": .integer(12)
        ]))
        let regular = try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(#"{"action":"state"}"#.utf8))
        XCTAssertEqual(regular.pluginToolName, "plugin__devicelogs__state")
        XCTAssertEqual(regular.parameters, .emptyObject)
    }

    func testUnknownRoutingRefusesInsteadOfSelectingAnotherStreamOrOperation() {
        for json in [#"{}"#, #"{"action":"search"}"#, #"{"action":"state","stream":"other"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(json.utf8)))
        }
    }

    @MainActor
    func testStableToolIsInTheBuiltInCatalogWithoutAnOpenPlugin() throws {
        let descriptor = try XCTUnwrap(MCPBuiltInToolRegistry.descriptor(named: "device_logs"))
        XCTAssertEqual(descriptor.tool, .deviceLogs)
        XCTAssertEqual(descriptor.definition.builtInGroupID, "device-log")
        XCTAssertTrue(MCPTools.definitions.contains { $0.name == "device_logs" })
        XCTAssertFalse(MCPRemoteSessionToolScope.reaches(.deviceLogs))
        let payload = Data(#"{"name":"device_logs","arguments":{"action":"state"}}"#.utf8)
        let call = try JSONDecoder().decode(MCPToolCallParameters.self, from: payload).call
        XCTAssertEqual(call.builtInTool, .deviceLogs)
    }
}
