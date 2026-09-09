import AppKit
import XCTest
import ThreadingPluginKit
@testable import DeviceLogsPlugin

/// The tools an agent calls. Their schemas and their refusals are the contract, so both are here.
@MainActor
final class DeviceLogToolsTests: XCTestCase {

    private func loadedPlugin() -> DeviceLogsPlugin {
        let plugin = DeviceLogsPlugin()
        let theme = PluginTheme(
            background: .black, surface: .darkGray, text: .white, secondaryText: .gray,
            accent: .orange, monospacedFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
            rowHeight: 16, isDark: true
        )
        _ = plugin.makePaneView(context: PluginContext(theme: theme, arguments: [:]))
        return plugin
    }

    private func call(_ plugin: DeviceLogsPlugin, _ name: String, _ json: String = "{}")
        -> (text: String, isError: Bool) {
        var answer: (String, Bool)?
        let done = expectation(description: name)
        plugin.invokeTool(named: name, argumentsJSON: json) { text, isError in
            answer = (text, isError)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return answer.map { (text: $0.0, isError: $0.1) } ?? ("no answer", true)
    }

    func testInitialThemeIsAppliedExactlyOnceByTheHostLifecycle() {
        let plugin = DeviceLogsPlugin()
        let theme = PluginTheme(
            background: .black, surface: .darkGray, text: .white, secondaryText: .gray,
            accent: .orange, monospacedFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
            rowHeight: 16, isDark: true
        )

        _ = plugin.makePaneView(context: PluginContext(theme: theme, arguments: [:]))
        XCTAssertEqual(plugin.appliedThemeCount, 0, "the factory must not self-apply the theme")
        plugin.apply(theme: theme)
        XCTAssertEqual(plugin.appliedThemeCount, 1)
    }

    /// Every declared schema has to be JSON an agent's client can read, or the tool is undiscoverable
    /// in a way nothing else would catch — the plugin still loads and the pane still draws.
    func testEveryToolDeclaresReadableJSONSchema() throws {
        let tools = try XCTUnwrap(DeviceLogsPlugin().pluginTools)
        XCTAssertEqual(tools.count, 5)
        for tool in tools {
            let data = Data(tool.inputSchemaJSON.utf8)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["type"] as? String, "object", "\(tool.name) schema is not an object")
            XCTAssertFalse(tool.summary.isEmpty, "\(tool.name) tells the agent nothing")
        }
    }

    func testAnUnknownToolIsRefusedByName() {
        let answer = call(loadedPlugin(), "not_a_tool")
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("not_a_tool"))
    }

    /// A focus with nothing in it would fold nothing and read as having worked, which is worse
    /// than a refusal that says what is missing.
    func testFocusingOnNothingIsRefusedWithAReason() {
        let answer = call(loadedPlugin(), DeviceLogToolNames.focus)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("pattern"), answer.text)
    }

    /// The pane's own controls have to move, because the user has to be able to see what the agent
    /// did to their view and undo it.
    func testFocusingFoldsTheRestAndSaysHowMuch() throws {
        let plugin = loadedPlugin()
        let pane = try XCTUnwrap(plugin.paneForTesting)
        pane.installRowsForTesting((0..<60).map { index in
            DeviceLogRow(
                time: "13:06:00.000",
                level: index == 30 ? "Error" : "Debug",
                process: "apsd",
                subsystem: nil,
                message: index == 30 ? "socket failed" : "routine " + String(index)
            )
        })

        let answer = call(plugin, DeviceLogToolNames.focus, #"{"pattern":"failed"}"#)
        XCTAssertFalse(answer.isError, answer.text)
        XCTAssertTrue(answer.text.contains("folded"), answer.text)
        XCTAssertEqual(pane.focusSummary.shown, 5, "the match and two rows either side")
        XCTAssertEqual(pane.focusSummary.folded, 55)

        let cleared = call(plugin, DeviceLogToolNames.clearFocus)
        XCTAssertFalse(cleared.isError)
        XCTAssertEqual(pane.focusSummary.folded, 0)
    }

    func testVisibleReportsWhatIsOnScreen() throws {
        let plugin = loadedPlugin()
        let pane = try XCTUnwrap(plugin.paneForTesting)
        pane.installRowsForTesting((0..<3).map { index in
            DeviceLogRow(time: "13:06:00.000", level: "Debug", process: "apsd",
                         subsystem: nil, message: "line " + String(index))
        })
        let answer = call(plugin, DeviceLogToolNames.visible)
        XCTAssertFalse(answer.isError)
        XCTAssertTrue(answer.text.contains("line 2"), answer.text)
    }

    /// A malformed range is a refusal that says what shape was expected, not a silent empty answer
    /// that reads as "nothing happened then".
    func testATimeRangeNeedsTwoInstants() {
        let answer = call(loadedPlugin(), DeviceLogToolNames.timeRange, #"{"from":"yesterday"}"#)
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(answer.text.contains("ISO 8601"), answer.text)
    }

    // MARK: What the pane shows about the agent

    /// An agent reading the log used to leave no trace: it could search everything recorded and
    /// the pane looked untouched, so a conclusion arrived about rows the person was never shown.
    func testASearchSaysSoInThePaneAndMarksWhatItFound() throws {
        let plugin = loadedPlugin()
        let pane = try XCTUnwrap(plugin.paneForTesting)
        pane.installRowsForTesting((0..<40).map { index in
            DeviceLogRow(
                time: "13:06:00.000",
                level: "Debug",
                process: "apsd",
                subsystem: nil,
                message: index % 10 == 0 ? "socket failed" : "routine " + String(index)
            )
        })
        XCTAssertNil(pane.agentNoteForTesting)

        pane.noteAgentAction("agent searched \u{201C}failed\u{201D} · 4 matches", searching: "failed")
        XCTAssertEqual(pane.agentNoteForTesting, "agent searched \u{201C}failed\u{201D} · 4 matches")
        XCTAssertEqual(pane.agentHitsForTesting.count, 4, "every matching row is marked")
        XCTAssertTrue(pane.statusTextForTesting.contains("agent searched"), pane.statusTextForTesting)
    }

    /// The note describes what the person is looking at, so it stops as soon as they take the view
    /// back — a stale note is worse than none.
    func testTypingInTheFilterClearsTheAgentsNote() throws {
        let plugin = loadedPlugin()
        let pane = try XCTUnwrap(plugin.paneForTesting)
        pane.noteAgentAction("agent searched something", searching: "x")
        pane.simulateUserFilterEditForTesting("routine")
        XCTAssertNil(pane.agentNoteForTesting)
        XCTAssertTrue(pane.agentHitsForTesting.isEmpty)
    }

    /// Folding is already visible in the controls; it should say who did it too.
    func testFocusingLeavesANoteAndClearingRemovesIt() throws {
        let plugin = loadedPlugin()
        let pane = try XCTUnwrap(plugin.paneForTesting)
        pane.installRowsForTesting([
            DeviceLogRow(time: "13:06:00.000", level: "Error", process: "apsd",
                         subsystem: nil, message: "socket failed")
        ])
        _ = call(plugin, DeviceLogToolNames.focus, #"{"pattern":"failed"}"#)
        XCTAssertEqual(pane.agentNoteForTesting, "agent focused on \u{201C}failed\u{201D}")
        _ = call(plugin, DeviceLogToolNames.clearFocus)
        XCTAssertNil(pane.agentNoteForTesting, "clearing the focus clears the note with it")
    }
}
