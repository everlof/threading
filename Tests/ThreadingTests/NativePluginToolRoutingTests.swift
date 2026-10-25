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
final class NativePluginToolRoutingTests: XCTestCase {

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
        _ = pane.view                        // loadView is what loads and registers the plugin
        for _ in 0..<200 where pane.loaded == nil && pane.refusal == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
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
