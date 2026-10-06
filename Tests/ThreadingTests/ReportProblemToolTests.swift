import AppKit
import XCTest
@testable import Threading

@MainActor
final class ReportProblemToolTests: HostedStoreTestCase {
    func testLiveMCPServerAdvertisesRoutesAndRefusesTheDisabledTool() async throws {
        let directory = URL(fileURLWithPath: "/tmp/report-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex))
        let pane = DisplayPaneController()
        let coordinator = AgentToolCoordinator(displayPaneController: pane, visibleSessionID: { nil }, setPaneVisible: { _ in XCTFail("report moved the panel") }, windowProvider: { nil })
        let outbox = MacIssueReportOutbox(directory: directory.appendingPathComponent("reports"), environment: [:], infoDictionary: nil)
        coordinator.problemReporter = AgentProblemReportService(submitter: MacIssueReportSubmitter(diagnosticsProvider: { throw MacIssueReportError.invalidPackage }, outbox: outbox))
        let server = MCPServer(socketPath: directory.appendingPathComponent("mcp.sock").path)
        server.handler = coordinator
        await withCheckedContinuation { continuation in server.start { continuation.resume() } }
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let token = MCPSessionRegistry.token(for: session.id)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp/\(token)"))
        let group = MCPToolCatalog.issueReporting
        let enabled = MCPToolCatalog.isEnabled(group)
        defer { AppSettings.shared.setToolGroup(group.id, enabled: enabled) }
        AppSettings.shared.setToolGroup(group.id, enabled: true)

        let listed = try await post(#"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#, to: url)
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.filter { $0["name"] as? String == "report_problem" }.count, 1)

        let body = #"{"jsonrpc":"2.0","id":"report","method":"tools/call","params":{"name":"report_problem","arguments":{"title":"Live MCP failure","description":"A Threading tool failed."}}}"#
        let reply = try await post(body, to: url)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let receipt = try JSONDecoder().decode(AgentProblemReportReceipt.self, from: Data(text.utf8))
        XCTAssertEqual(receipt.status, .saved)
        XCTAssertNotNil(receipt.recordPath)

        AppSettings.shared.setToolGroup(group.id, enabled: false)
        let refused = try await post(body, to: url)
        let refusal = try XCTUnwrap(refused["result"] as? [String: Any])
        XCTAssertEqual(refusal["isError"] as? Bool, true)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("reports/Outbox"), includingPropertiesForKeys: nil)
        XCTAssertEqual(records.count, 1)
    }

    func testWireArgumentsDeclarationAndDisabledGroupShareOneIdentity() throws {
        let command = try JSONDecoder().decode(MCPToolCallParameters.self, from: Data(#"{"name":"report_problem","arguments":{"title":"Broken tool","description":"Snapshot failed","reproduction_steps":"Call browser_snapshot","expected_behavior":"A page","actual_behavior":"Error","evidence":"unavailable","image_paths":["/tmp/approved.png"]}}"#.utf8)).call
        let arguments: ReportProblemArguments = try requireToolArguments(command, tool: .reportProblem)
        XCTAssertEqual(arguments.reproductionSteps, "Call browser_snapshot")
        XCTAssertEqual(arguments.expectedBehavior, "A page")
        XCTAssertEqual(arguments.actualBehavior, "Error")
        XCTAssertEqual(arguments.imagePaths, ["/tmp/approved.png"])
        let definition = try XCTUnwrap(MCPTools.definition(for: .reportProblem))
        XCTAssertEqual(definition.annotations?.openWorldHint, true)
        XCTAssertEqual(definition.annotations?.readOnlyHint, false)
        XCTAssertEqual(definition.annotations?.idempotentHint, true)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        let schema = try XCTUnwrap(wire["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["title", "description"])
        XCTAssertEqual(MCPToolCatalog.issueReporting.tools.map(\.name), ["report_problem"])
        XCTAssertTrue(MCPRemoteSessionToolScope.reaches(.reportProblem))

        let group = MCPToolCatalog.issueReporting
        let enabled = MCPToolCatalog.isEnabled(group)
        defer { AppSettings.shared.setToolGroup(group.id, enabled: enabled) }
        AppSettings.shared.setToolGroup(group.id, enabled: true)
        XCTAssertTrue(MCPToolCatalog.admits(command))
        XCTAssertTrue(MCPToolCatalog.instructions.contains("Issue reporting:"))
        AppSettings.shared.setToolGroup(group.id, enabled: false)
        XCTAssertFalse(MCPToolCatalog.admits(command))
        XCTAssertFalse(MCPToolCatalog.enabledDefinitions.contains { $0.name == "report_problem" })
        XCTAssertFalse(MCPToolCatalog.instructions.contains("Issue reporting:"))
    }

    func testMissingArgumentsDecodeForAnActionableRefusal() throws {
        let command = try JSONDecoder().decode(MCPToolCallParameters.self, from: Data(#"{"name":"report_problem"}"#.utf8)).call
        let arguments: ReportProblemArguments = try requireToolArguments(command, tool: .reportProblem)
        XCTAssertNil(arguments.title)
        XCTAssertNil(arguments.description)
    }

    func testTypedExecutionFilesForTheCallingSessionWithoutChangingThePanel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("report-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex))
        let pane = DisplayPaneController()
        pane.showSession(session.id)
        pane.showCurrentTheme()
        var reveals = 0
        let coordinator = AgentToolCoordinator(displayPaneController: pane, visibleSessionID: { nil }, setPaneVisible: { _ in reveals += 1 }, windowProvider: { nil })
        let outbox = MacIssueReportOutbox(directory: directory.appendingPathComponent("reports"), environment: [:], infoDictionary: nil)
        coordinator.problemReporter = AgentProblemReportService(submitter: MacIssueReportSubmitter(diagnosticsProvider: { throw MacIssueReportError.invalidPackage }, outbox: outbox))
        let command = try JSONDecoder().decode(MCPToolCallParameters.self, from: Data(#"{"name":"report_problem","arguments":{"title":"Broken snapshot","description":"A Threading tool failed."}}"#.utf8)).call
        let result = await execute(command, with: coordinator, for: session.id)
        XCTAssertFalse(result.isError, result.text)
        let receipt = try JSONDecoder().decode(AgentProblemReportReceipt.self, from: Data(result.text.utf8))
        XCTAssertEqual(receipt.status, .saved)
        XCTAssertNotNil(receipt.recordPath)
        XCTAssertEqual(reveals, 0)
        XCTAssertTrue(pane.isShowingCurrentTheme)

        let unavailable = await execute(command, with: coordinator, for: SessionID())
        XCTAssertTrue(unavailable.isError)
        XCTAssertTrue(unavailable.text.contains("session is no longer available"))

        XCTAssertEqual(ProjectStore.shared.setExecutionHost(ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/user/project"), forProjectID: project.id), .applied)
        let imageCommand = AgentCommand.reportProblem(ReportProblemArguments(title: "Broken image", description: "A tool failed.", imagePaths: ["/tmp/approved.png"]))
        let refused = await execute(imageCommand, with: coordinator, for: session.id)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("remote-host"))
    }

    private func execute(_ command: AgentCommand, with coordinator: AgentToolCoordinator, for sessionID: SessionID) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.executeBuiltIn(command, for: sessionID) { continuation.resume(returning: $0) }
        }
    }

    private func post(_ body: String, to url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
