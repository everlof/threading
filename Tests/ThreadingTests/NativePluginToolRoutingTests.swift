import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

/// The whole path an agent's tool call takes, with the real bundle Threading ships.
///
/// Every piece of this is unit-tested somewhere, and none of that would have caught the failure
/// that matters: the plugin declares tools into one binary and the host reads them out of another,
/// which is precisely where this tier has gone wrong before — two `@objc` protocol declarations in
/// two images are two protocols, and the loader refuses a conformance that plainly exists. So this
/// loads the shipped bundle, registers it the way a pane does, and asks the provider the questions
/// the MCP dispatcher asks.
@MainActor
final class NativePluginToolRoutingTests: HostedStoreTestCase {

    private var controller: NativePluginPaneViewController?

    override func tearDown() {
        if let controller { NativePluginRuntime.shared.deregister(controller) }
        controller = nil
        super.tearDown()
    }

    /// Loads the bundled Device Logs plugin into a pane, exactly as opening the tab does.
    private func openPane(for sessionID: SessionID) async throws -> NativePluginPaneViewController {
        let bundle = try XCTUnwrap(
            NativePluginCatalog.deviceLogsBundle,
            "Threading ships no Device Logs plugin — Contents/PlugIns is empty"
        )
        let pane = NativePluginPaneViewController(bundleURL: bundle, owningSessionID: sessionID)
        await pane.waitForInitialLoad()
        controller = pane
        XCTAssertNil(pane.refusal, "the shipped plugin was refused: \(String(describing: pane.refusal))")
        return pane
    }

    func testTheShippedPluginsToolsReachTheProvider() async throws {
        _ = try await openPane(for: SessionID())
        let groups = NativePluginMCPToolProvider().groups
        let devicelogs = try XCTUnwrap(
            groups.first { $0.id == "codes.threading.plugin.devicelogs" },
            "the plugin's tools did not reach the provider; groups: \(groups.map(\.id))"
        )
        XCTAssertEqual(devicelogs.tools.count, 18)
        let names = Set(devicelogs.tools.map(\.name))
        XCTAssertTrue(names.contains("plugin__devicelogs__search"), "found \(names.sorted())")
        XCTAssertTrue(names.contains("plugin__devicelogs__focus"))
        XCTAssertTrue(names.contains("plugin__devicelogs__bluetooth"))
        XCTAssertTrue(names.contains("plugin__devicelogs__linked"))
        XCTAssertTrue(names.contains("plugin__devicelogs__timelines"))
        for name in ["state", "configure", "read", "wait", "reveal"] {
            XCTAssertTrue(names.contains("plugin__devicelogs__" + name))
            XCTAssertTrue(names.contains("plugin__devicelogs__bluetooth_" + name))
        }
        for tool in devicelogs.tools {
            // A schema that did not survive the JSON crossing leaves a tool the agent cannot call
            // while everything else still works.
            guard case .object(let schema) = tool.inputSchema else {
                return XCTFail("\(tool.name) lost its schema crossing the boundary")
            }
            XCTAssertEqual(schema["type"], .string("object"), "\(tool.name)")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) tells the agent nothing")
        }
    }

    func testStableDeviceLogsSchemaCoversEverySharedPluginParameter() async throws {
        let pane = try await openPane(for: SessionID())
        let tools = try XCTUnwrap(pane.loaded?.pluginTools)
        let actions: Set<String> = ["state", "configure", "read", "wait", "reveal"]
        var parameterTypes: [String: String] = [:]
        for tool in tools where actions.contains(tool.name) || actions.contains(String(tool.name.dropFirst("bluetooth_".count))) {
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            for (name, value) in properties { parameterTypes[name] = try XCTUnwrap(value["type"] as? String) }
        }
        let advertised = DeviceLogsToolDefinition.properties.filter { !["action", "stream"].contains($0.key) }
        XCTAssertEqual(Set(advertised.keys), Set(parameterTypes.keys))
        for (name, property) in advertised {
            let type = try JSONDecoder().decode(String.self, from: JSONEncoder().encode(property.type))
            XCTAssertEqual(type, parameterTypes[name], name)
        }
    }

    func testStableDeviceLogsRouteJoinsColdLoadAndUsesTheVisibleSharedPanel() async throws {
        let sessionID = SessionID()
        let bundle = try XCTUnwrap(NativePluginCatalog.deviceLogsBundle)
        let pane = NativePluginPaneViewController(bundleURL: bundle, owningSessionID: sessionID)
        controller = pane
        var sections: [String] = []
        pane.onRevealSection = { sections.append($0); return true }

        func call(_ json: String) async throws -> [String: Any] {
            let arguments = try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(json.utf8))
            let answered = expectation(description: json)
            var response: MCPToolResult?
            DeviceLogPanelToolRouter.invoke(arguments, for: sessionID, in: pane) {
                response = $0
                answered.fulfill()
            }
            await fulfillment(of: [answered], timeout: 10)
            let result = try XCTUnwrap(response)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any], result.text)
        }

        XCTAssertNil(pane.loaded)
        let cold = try await call(#"{"action":"state"}"#)
        XCTAssertNotNil(pane.loaded)
        XCTAssertEqual(cold["stream"] as? String, "regular")
        let plugin = try XCTUnwrap(pane.loaded as? NSObject)
        plugin.perform(NSSelectorFromString("installSharedDeviceLogsForTesting"))
        let configured = try await call(#"{"action":"configure","clear_filter":true,"bundle_id":"com.example.chameleon","text":"AirLab","follow":false}"#)
        let revision = try XCTUnwrap(configured["revision"] as? Int)
        let read = try await call("{\"action\":\"read\",\"expected_revision\":\(revision)}")
        XCTAssertEqual((read["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
                       ["shared-log-tx-ns", "shared-log-rx-cp", "shared-log-tx-ds"])
        let revealed = try await call(#"{"action":"reveal","row_id":"shared-log-rx-cp"}"#)
        XCTAssertEqual(revealed["status"] as? String, "ok")
        let changed = try await call(#"{"action":"configure","text":"ANCS"}"#)
        let stale = try await call("{\"action\":\"configure\",\"text\":\"overwrite\",\"expected_revision\":\(revision)}")
        XCTAssertEqual(stale["status"] as? String, "stale_revision")
        XCTAssertEqual(stale["revision"] as? Int, changed["revision"] as? Int)
        let rejected = try await call(#"{"action":"read","text":"hidden filter"}"#)
        XCTAssertEqual(rejected["status"] as? String, "invalid_arguments")
        let bluetooth = try await call(#"{"action":"state","stream":"bluetooth"}"#)
        XCTAssertEqual(bluetooth["stream"] as? String, "bluetooth")
        XCTAssertEqual(sections.last, "bluetooth")
        XCTAssertTrue(sections.dropLast().allSatisfy { $0 == "regular" })
        let regular = try await call(#"{"action":"read"}"#)
        XCTAssertEqual(regular["stream"] as? String, "regular")
        XCTAssertEqual((regular["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["shared-log-rx-cp"])
        let cursor = try XCTUnwrap(regular["cursor"] as? String)
        let waiting = try await call("{\"action\":\"wait\",\"cursor\":\"\(cursor)\",\"timeout_seconds\":0}")
        XCTAssertNil(waiting["error"])
        XCTAssertEqual(waiting["count"] as? Int, 0)
        XCTAssertEqual(waiting["stream"] as? String, "regular")
        XCTAssertEqual(sections.last, "regular")
    }

    func testStableDeviceLogsRouteCannotBypassDisabledPluginTools() async throws {
        let sessionID = SessionID()
        let pane = NativePluginPaneViewController(
            bundleURL: try XCTUnwrap(NativePluginCatalog.deviceLogsBundle), owningSessionID: sessionID
        )
        let group = NativePluginManagedOffer.deviceLogs.identifier
        let wasEnabled = AppSettings.shared.isToolGroupEnabled(group)
        AppSettings.shared.setToolGroup(group, enabled: false)
        defer { AppSettings.shared.setToolGroup(group, enabled: wasEnabled) }
        let args = try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(#"{"action":"state"}"#.utf8))
        var response: MCPToolResult?
        DeviceLogPanelToolRouter.invoke(args, for: sessionID, in: pane) { response = $0 }
        XCTAssertTrue(try XCTUnwrap(response).isError)
        XCTAssertFalse(pane.isViewLoaded, "a disabled group must not open or load its pane")
    }

    func testStableDeviceLogsRouteKeepsTheExactOwnerAcrossWindows() async throws {
        let sessionID = SessionID()
        let first = try await openPane(for: sessionID)
        let second = NativePluginPaneViewController(bundleURL: first.bundleURL, owningSessionID: sessionID)
        await second.waitForInitialLoad()
        defer { NativePluginRuntime.shared.deregister(second) }
        for pane in [first, second] {
            let plugin = try XCTUnwrap(pane.loaded as? NSObject)
            plugin.perform(NSSelectorFromString("installSharedDeviceLogsForTesting"))
            pane.onRevealSection = { _ in true }
        }
        func call(_ json: String, in pane: NativePluginPaneViewController) async throws -> [String: Any] {
            let args = try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(json.utf8))
            let answered = expectation(description: json)
            var response: MCPToolResult?
            DeviceLogPanelToolRouter.invoke(args, for: sessionID, in: pane) { response = $0; answered.fulfill() }
            await fulfillment(of: [answered], timeout: 10)
            let result = try XCTUnwrap(response)
            XCTAssertFalse(result.isError, result.text)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        }
        _ = try await call(#"{"action":"configure","clear_filter":true,"text":"ANCS"}"#, in: first)
        _ = try await call(#"{"action":"configure","clear_filter":true,"text":"AirLab"}"#, in: second)
        let firstRead = try await call(#"{"action":"read"}"#, in: first)
        let secondRead = try await call(#"{"action":"read"}"#, in: second)
        XCTAssertEqual((firstRead["rows"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((secondRead["rows"] as? [[String: Any]])?.count, 3)
    }

    func testStableDeviceLogsRouteReportsLoadFailureAndRejectsAnotherSessionsPane() async throws {
        let sessionID = SessionID()
        let pane = NativePluginPaneViewController(
            bundleURL: URL(fileURLWithPath: "/tmp/device-log-refused-fixture.bundle"),
            owningSessionID: sessionID, resolveStore: { nil },
            loadPlugin: { _ in .failure(.wrongProtocol) }
        )
        let args = try JSONDecoder().decode(DeviceLogsArguments.self, from: Data(#"{"action":"configure","text":"needle"}"#.utf8))
        var wrongSession: MCPToolResult?
        DeviceLogPanelToolRouter.invoke(args, for: SessionID(), in: pane) { wrongSession = $0 }
        XCTAssertTrue(try XCTUnwrap(wrongSession).isError)
        XCTAssertFalse(pane.isViewLoaded)

        let answered = expectation(description: "load refusal")
        var failure: MCPToolResult?
        DeviceLogPanelToolRouter.invoke(args, for: sessionID, in: pane) {
            failure = $0
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        let result = try XCTUnwrap(failure)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("No panel parameters were applied"), result.text)
        XCTAssertNil(pane.loaded)
    }

    func testACallReachesThePluginAndComesBack() async throws {
        let sessionID = SessionID()
        _ = try await openPane(for: sessionID)

        let answered = expectation(description: "answered")
        var response: MCPExternalToolResponse?
        let owned = NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__clear_focus",
            arguments: .emptyObject,
            for: sessionID
        ) { result in
            response = result
            answered.fulfill()
        }
        XCTAssertTrue(owned, "the provider did not claim a name that is plainly its own")
        await fulfillment(of: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertFalse(answer.isError, answer.text)
        XCTAssertTrue(answer.text.contains("rows are shown"), answer.text)
    }

    /// The client has already connected when the person opens a pane. Its live HTTP channel
    /// must announce the newly loaded plugin, and the next tools/list must contain its tools.
    func testOpeningBluetoothAfterClientConnectsPublishesToolsOnTheLiveChannel() async throws {
        let registry = MCPExternalToolRegistry.shared
        let previousProviders = registry.providers
        registry.replaceProviders(with: [NativePluginMCPToolProvider()])
        defer { registry.replaceProviders(with: previousProviders) }
        let group = "codes.threading.plugin.devicelogs"
        let wasEnabled = AppSettings.shared.isToolGroupEnabled(group)
        AppSettings.shared.setToolGroup(group, enabled: true)
        defer { AppSettings.shared.setToolGroup(group, enabled: wasEnabled) }

        let server = MCPServer(socketPath: "/tmp/tbt-\(UUID().uuidString.prefix(8)).sock")
        let started = expectation(description: "MCP listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 10)
        defer { server.stop() }
        let sessionID = SessionID()
        defer { MCPSessionRegistry.remove(sessionID: sessionID) }
        let token = MCPSessionRegistry.token(for: sessionID)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(server.port))/mcp/\(token)"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }

        func names() async throws -> Set<String> {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
            let (data, _) = try await client.data(for: request)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return Set(tools.compactMap { $0["name"] as? String })
        }
        let tool = "plugin__devicelogs__bluetooth_state"
        let initial = try await names()
        XCTAssertFalse(initial.contains(tool))
        var subscribe = URLRequest(url: url)
        subscribe.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await client.bytes(for: subscribe)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var events = bytes.lines.makeAsyncIterator()

        _ = try await openPane(for: sessionID)
        var announced = false
        while let line = try await events.next() {
            if line.contains("notifications/tools/list_changed") { announced = true; break }
        }
        XCTAssertTrue(announced)
        let loaded = try await names()
        XCTAssertTrue(loaded.contains(tool))

        AppSettings.shared.setToolGroup(group, enabled: false)
        announced = false
        while let line = try await events.next() {
            if line.contains("notifications/tools/list_changed") { announced = true; break }
        }
        XCTAssertTrue(announced)
        let disabled = try await names()
        XCTAssertFalse(disabled.contains(tool), "removing the startup filter must not bypass live Settings admission")
    }

    func testSharedPanelToolsRouteToTheCallingSessionsExistingPane() async throws {
        let sessionID = SessionID()
        let pane = try await openPane(for: sessionID)
        let plugin = try XCTUnwrap(pane.loaded as? NSObject)
        let fixture = NSSelectorFromString("installSharedDeviceLogsForTesting")
        XCTAssertTrue(plugin.responds(to: fixture))
        plugin.perform(fixture)
        var sections: [String] = []
        pane.onRevealSection = { sections.append($0); return true }

        func call(_ name: String, _ arguments: [String: MCPJSONValue] = [:]) async throws -> MCPExternalToolResponse {
            let answered = expectation(description: name)
            var response: MCPExternalToolResponse?
            XCTAssertTrue(NativePluginMCPToolProvider().invokeTool(
                named: "plugin__devicelogs__" + name, arguments: .object(arguments), for: sessionID
            ) { response = $0; answered.fulfill() })
            await fulfillment(of: [answered], timeout: 10)
            return try XCTUnwrap(response)
        }
        func object(_ response: MCPExternalToolResponse) throws -> [String: Any] {
            XCTAssertFalse(response.isError, response.text)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        }

        let configured = try object(await call("configure", [
            "device_id": .string("device-logs-fixture"), "bundle_id": .string("com.example.chameleon"),
            "text": .string("AirLab"), "follow": .bool(false),
        ]))
        let read = try object(await call("read", ["limit": .integer(50)]))
        XCTAssertEqual(read["revision"] as? Int, configured["revision"] as? Int)
        let rows = try XCTUnwrap(read["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["shared-log-tx-ns", "shared-log-rx-cp", "shared-log-tx-ds"])
        XCTAssertEqual(rows.compactMap { $0["process"] as? String }, ["Ananke", "Ananke", "Ananke"])
        let configuredState = try XCTUnwrap(configured["state"] as? [String: Any])
        let catalog = try XCTUnwrap(configuredState["sources"] as? [[String: Any]])
        XCTAssertEqual(catalog.first { $0["title"] as? String == "Chameleon" }?["process"] as? String, "Ananke")
        let first = try XCTUnwrap(rows.first?["id"] as? String)
        let last = try XCTUnwrap(rows.last?["id"] as? String)
        _ = try object(await call("reveal", ["row_id": .string(first), "through_row_id": .string(last)]))
        XCTAssertEqual(sections, ["regular", "regular", "regular"])

        let answered = expectation(description: "other session refused")
        var missingResponse: MCPExternalToolResponse?
        XCTAssertTrue(NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__read", arguments: .emptyObject, for: SessionID()
        ) { missingResponse = $0; answered.fulfill() })
        await fulfillment(of: [answered], timeout: 10)
        let missing = try XCTUnwrap(missingResponse)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No devicelogs pane is open"), missing.text)
    }

    func testToolDeclaredPaneSectionIsRevealedInItsOwningPaneBeforeInvocation() async throws {
        let sessionID = SessionID()
        let pane = try await openPane(for: sessionID)
        let otherSession = SessionID()
        let otherPane = NativePluginPaneViewController(
            bundleURL: pane.bundleURL, owningSessionID: otherSession
        )
        _ = otherPane.view
        for _ in 0..<200 where otherPane.loaded == nil && otherPane.refusal == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { NativePluginRuntime.shared.deregister(otherPane) }
        XCTAssertNotNil(otherPane.loaded)
        let bluetooth = try XCTUnwrap(pane.loaded?.pluginTools?.first {
            $0.name == "bluetooth"
        })
        XCTAssertEqual(bluetooth.paneSectionToReveal, "bluetooth")

        var revealed: String?
        var otherPaneRevealed = false
        pane.onRevealSection = { revealed = $0; return true }
        otherPane.onRevealSection = { _ in otherPaneRevealed = true; return true }

        let answered = expectation(description: "invalid Bluetooth request answered")
        var response: MCPExternalToolResponse?
        XCTAssertTrue(NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__bluetooth",
            arguments: .emptyObject,
            for: sessionID
        ) { result in
            response = result
            answered.fulfill()
        })
        XCTAssertEqual(revealed, "bluetooth")
        XCTAssertFalse(otherPaneRevealed)
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(response).isError)
    }

    func testSectionToolRefusesWhenNoPaneHostCanRevealIt() async throws {
        let sessionID = SessionID()
        _ = try await openPane(for: sessionID)
        let answered = expectation(description: "unrevealed tool refused")
        var response: MCPExternalToolResponse?
        XCTAssertTrue(NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__bluetooth",
            arguments: .emptyObject,
            for: sessionID
        ) { result in
            response = result
            answered.fulfill()
        })
        await fulfillment(of: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("cannot reveal"), answer.text)
    }

    func testUndeclaredPluginToolIsRefused() async throws {
        let sessionID = SessionID()
        _ = try await openPane(for: sessionID)

        let answered = expectation(description: "unknown plugin tool answered")
        var response: MCPExternalToolResponse?
        XCTAssertTrue(NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__invented",
            arguments: .emptyObject,
            for: sessionID
        ) { result in
            response = result
            answered.fulfill()
        })
        await fulfillment(of: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("does not declare"), answer.text)
    }

    /// A name the provider does not own must be declined rather than answered, or it would swallow
    /// every other provider's tools — the extension tier's included.
    func testAToolFromSomewhereElseIsDeclined() {
        let claimed = NativePluginMCPToolProvider().invokeTool(
            named: "ext__codes__threading__marketeer__list-apps",
            arguments: .emptyObject,
            for: SessionID()
        ) { _ in XCTFail("answered a tool it does not own") }
        XCTAssertFalse(claimed)
    }

    /// The tools belong to a pane, so a call for a chat with no pane open is a reason the agent can
    /// act on rather than a missing tool that reads as the feature not existing.
    func testACallForAChatWithNoPaneOpenExplainsItself() async throws {
        _ = try await openPane(for: SessionID())          // a pane, but for a different chat

        let answered = expectation(description: "answered")
        var response: MCPExternalToolResponse?
        let owned = NativePluginMCPToolProvider().invokeTool(
            named: "plugin__devicelogs__clear_focus",
            arguments: .emptyObject,
            for: SessionID()
        ) { result in
            response = result
            answered.fulfill()
        }
        XCTAssertTrue(owned, "the name is ours, so answering it is ours too")
        await fulfillment(of: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("pane is open"), answer.text)
    }

    /// Closing the pane takes its tools with it: they act on a stream and a view that are gone.
    func testTheToolsGoAwayWithThePane() async throws {
        let pane = try await openPane(for: SessionID())
        XCTAssertFalse(NativePluginMCPToolProvider().groups.isEmpty)
        NativePluginRuntime.shared.deregister(pane)
        controller = nil
        XCTAssertTrue(
            NativePluginMCPToolProvider().groups.isEmpty,
            "a closed pane still advertises tools that have nothing to act on"
        )
    }
}
