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
    private func openPane(for sessionID: SessionID) throws -> NativePluginPaneViewController {
        let bundle = try XCTUnwrap(
            NativePluginCatalog.deviceLogsBundle,
            "Threading ships no Device Logs plugin — Contents/PlugIns is empty"
        )
        let pane = NativePluginPaneViewController(bundleURL: bundle, owningSessionID: sessionID)
        _ = pane.view                        // loadView is what loads and registers the plugin
        controller = pane
        XCTAssertNil(pane.refusal, "the shipped plugin was refused: \(String(describing: pane.refusal))")
        return pane
    }

    func testTheShippedPluginsToolsReachTheProvider() throws {
        _ = try openPane(for: SessionID())
        let groups = NativePluginMCPToolProvider().groups
        let devicelogs = try XCTUnwrap(
            groups.first { $0.id == "codes.threading.plugin.devicelogs" },
            "the plugin's tools did not reach the provider; groups: \(groups.map(\.id))"
        )
        XCTAssertEqual(devicelogs.tools.count, 5)
        let names = Set(devicelogs.tools.map(\.name))
        XCTAssertTrue(names.contains("plugin__devicelogs__search"), "found \(names.sorted())")
        XCTAssertTrue(names.contains("plugin__devicelogs__focus"))
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

    func testACallReachesThePluginAndComesBack() throws {
        let sessionID = SessionID()
        _ = try openPane(for: sessionID)

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
        wait(for: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertFalse(answer.isError, answer.text)
        XCTAssertTrue(answer.text.contains("rows are shown"), answer.text)
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
    func testACallForAChatWithNoPaneOpenExplainsItself() throws {
        _ = try openPane(for: SessionID())          // a pane, but for a different chat

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
        wait(for: [answered], timeout: 10)
        let answer = try XCTUnwrap(response)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("pane is open"), answer.text)
    }

    /// Closing the pane takes its tools with it: they act on a stream and a view that are gone.
    func testTheToolsGoAwayWithThePane() throws {
        let pane = try openPane(for: SessionID())
        XCTAssertFalse(NativePluginMCPToolProvider().groups.isEmpty)
        NativePluginRuntime.shared.deregister(pane)
        controller = nil
        XCTAssertTrue(
            NativePluginMCPToolProvider().groups.isEmpty,
            "a closed pane still advertises tools that have nothing to act on"
        )
    }
}
