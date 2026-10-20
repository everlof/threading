import XCTest
import ThreadingController
@testable import Threading

/// The Mac half of Linked Workrooms: what the host captures and refuses, independent of a window.
@MainActor
final class WorkroomHostTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Git context

    func testGitContextRecordsTheBranchAgainstTheDefaultBranch() throws {
        try git("init", "-q", "-b", "main")
        try write("a.txt", "one")
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "Base")
        try git("checkout", "-q", "-b", "feature")
        try write("b.txt", "two")
        try git("add", "b.txt")
        try git("commit", "-q", "-m", "Add the PAH rule")

        guard case .success(let context) = WorkroomGitContextReader.read(directory: directory, base: nil) else {
            return XCTFail("a checkout with a main branch has a context")
        }
        XCTAssertEqual(context.baseRef, "main")
        XCTAssertEqual(context.headRef, "feature")
        XCTAssertEqual(context.changedPaths, ["b.txt"])
        XCTAssertEqual(context.changedPathCount, 1)
        XCTAssertEqual(context.commits.map(\.subject), ["Add the PAH rule"])
        XCTAssertEqual(context.mergeBase, context.baseCommit)
        XCTAssertFalse(context.dirty)

        try write("a.txt", "changed")
        guard case .success(let dirty) = WorkroomGitContextReader.read(directory: directory, base: "main") else {
            return XCTFail("an explicit base resolves")
        }
        XCTAssertTrue(dirty.dirty)
        XCTAssertEqual(WorkroomGitContextReader.read(directory: directory, base: "nope"), .failure(.unknownBase("nope")))
    }

    func testGitContextRefusesAnythingButARepositoryAndOptionShapedRefs() throws {
        XCTAssertEqual(WorkroomGitContextReader.read(directory: directory, base: nil), .failure(.notARepository))
        XCTAssertFalse(WorkroomGitContextReader.isSafeRef("--upload-pack=evil"))
        XCTAssertFalse(WorkroomGitContextReader.isSafeRef("main extra"))
        XCTAssertTrue(WorkroomGitContextReader.isSafeRef("origin/develop"))
    }

    // MARK: - Tunnel

    func testTunnelRecipesReadOnlyTheirOwnAddress() {
        let cloudflare = WorkroomTunnelRecipe.cloudflare()
        XCTAssertEqual(cloudflare.publicURL("INF |  https://quiet-river-1234.trycloudflare.com  |")?.absoluteString,
                       "https://quiet-river-1234.trycloudflare.com")
        XCTAssertNil(cloudflare.publicURL("INF Requesting new quick Tunnel on trycloudflare.com..."))

        let ngrok = WorkroomTunnelRecipe.ngrok(domain: nil, userConfiguration: nil)
        let output = """
            {"lvl":"info","msg":"client session established","url":"https://connect.ngrok-agent.com"}
            {"lvl":"info","msg":"started tunnel","name":"command_line","url":"https://rooms.example.ngrok.app"}
            """
        XCTAssertEqual(ngrok.publicURL(output)?.absoluteString, "https://rooms.example.ngrok.app")
        XCTAssertNil(ngrok.publicURL(#"{"msg":"client session established","url":"https://x.example"}"#))
    }

    func testNgrokRunsWithTheAgentAPIOffFromAPrivateOverlay() throws {
        let user = directory.appendingPathComponent("ngrok.yml")
        try Data("version: \"3\"\n".utf8).write(to: user)
        let arguments = try WorkroomTunnelRecipe.ngrok(domain: "rooms.example.ngrok.app", userConfiguration: user)
            .arguments(4100, directory)
        let overlay = directory.appendingPathComponent("ngrok-overlay.yml")
        XCTAssertTrue(try String(contentsOf: overlay, encoding: .utf8).contains("web_addr: false"))
        let permissions = try FileManager.default.attributesOfItem(atPath: overlay.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(Array(arguments.prefix(2)), ["http", "127.0.0.1:4100"])
        let configs = arguments.indices.filter { arguments[$0] == "--config" }.map { arguments[$0 + 1] }
        XCTAssertEqual(configs, [user.path, overlay.path], "the user's configuration first, the overlay last")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--url", "https://rooms.example.ngrok.app"])
        XCTAssertFalse(arguments.contains { $0.contains("authtoken") })
    }

    func testReservedDomainsAreHostnamesOnly() {
        XCTAssertTrue(WorkroomTunnelRecipe.isValidDomain("rooms.example.ngrok.app"))
        for invalid in ["https://rooms.example", "rooms", "rooms.example/path", "-x.example", "rooms example.app"] {
            XCTAssertFalse(WorkroomTunnelRecipe.isValidDomain(invalid), invalid)
        }
    }

    // MARK: - Portal socket

    func testRepeatedRoutingHeadersAreRefusedBeforeThePortal() {
        func head(_ lines: String) -> Data { Data("GET / HTTP/1.1\r\n\(lines)\r\n".utf8) }
        XCTAssertTrue(WorkroomPortalConnection.repeatsGuardedHeader(head("Host: a.example\r\nHost: b.example\r\n")))
        XCTAssertTrue(WorkroomPortalConnection.repeatsGuardedHeader(head("Cookie: a=1\r\ncookie: b=2\r\n")))
        XCTAssertFalse(WorkroomPortalConnection.repeatsGuardedHeader(head("Host: a.example\r\nAccept: x\r\nAccept: y\r\n")))
    }

    // MARK: - Opening

    func testTheOpeningSheetNamesThePersonTheProviderAndTheAgentsWords() {
        let facts = WorkroomOpeningFacts(
            roomTitle: "Sweep review", projectName: "sonda", personName: "Expert", handle: "expert", language: "sv",
            proposedByAgent: true, openQuestions: 3, provider: .cloudflare, domain: nil, days: 14,
            reason: "Confirm the PAH rule"
        )
        let request = WorkroomOpeningSheet.request(facts)
        XCTAssertEqual(request.prompt, .approveWorkroomOpening)
        guard case .alwaysAsks(.securityGrant) = ConfirmationPrompt.approveWorkroomOpening.policy else {
            return XCTFail("opening a room to the internet is a security grant that always asks")
        }
        XCTAssertTrue(request.title.contains("Sweep review") && request.title.contains("Expert"))
        for fragment in ["proposed by the agent", "can read", "Confirm the PAH rule", "14", "3", "changes whenever"] {
            XCTAssertTrue(request.message.contains(fragment), fragment)
        }
    }

    func testOpeningProposalsAreOneAtATimeAndNotRepeatedAfterANo() {
        let ledger = WorkroomOpeningLedger()
        XCTAssertNil(ledger.admit("room|expert"))
        XCTAssertNotNil(ledger.admit("room|expert"), "one sheet per room and person")
        ledger.finish("room|expert", approved: false)
        XCTAssertNotNil(ledger.admit("room|expert"), "a no is not asked again straight away")
        XCTAssertNil(ledger.admit("room|expert", now: Date().addingTimeInterval(WorkroomToolDefaults.declineCooldown + 1)))
    }

    // MARK: - Tools

    func testTheToolGroupExistsOnlyWhileWorkroomsIsOn() {
        let settings = AppSettings.shared
        let prior = settings.workroomsEnabled
        defer { settings.workroomsEnabled = prior }
        settings.workroomsEnabled = false
        XCTAssertFalse(MCPToolCatalog.isEnabled(MCPToolCatalog.workrooms))
        XCTAssertFalse(MCPToolCatalog.enabledGroups.contains { $0.id == MCPToolCatalog.workroomsGroupID })
        settings.workroomsEnabled = true
        XCTAssertEqual(MCPToolCatalog.isEnabled(MCPToolCatalog.workrooms), settings.isToolGroupEnabled("workrooms"))
        XCTAssertEqual(MCPToolCatalog.workrooms.tools.map(\.name), [
            "workroom_find", "workroom_create", "workroom_context", "workroom_ask", "workroom_questions",
            "workroom_respond", "workroom_request_opening", "workroom_set_language"
        ])
        XCTAssertTrue(MCPBuiltInTool.allCases.filter { $0.family == .workrooms }.allSatisfy { !MCPRemoteSessionToolScope.reaches($0) })
    }

    func testFieldArgumentsUseTheToolsSnakeCaseKinds() throws {
        let field = try WorkroomAgentCommandService.field(WorkroomFieldArgument(
            id: "rule", kind: "single_choice", label: "Regel", help: nil, required: nil,
            options: [WorkroomOptionArgument(id: "a", label: "A", consequence: "Granskas"),
                      WorkroomOptionArgument(id: "b", label: "B", consequence: nil)],
            unit: nil, minimum: nil, maximum: nil))
        XCTAssertEqual(field.kind, .singleChoice)
        XCTAssertTrue(field.required)
        XCTAssertEqual(field.options?.first?.consequence, "Granskas")
        XCTAssertThrowsError(try WorkroomAgentCommandService.field(WorkroomFieldArgument(
            id: "x", kind: "slider", label: "X", help: nil, required: nil, options: nil, unit: nil, minimum: nil, maximum: nil)))
        XCTAssertTrue(WorkroomAgentCommandService.words(for: ControllerError.invalidInput("ask_rate")).contains("an hour"))
    }

    // MARK: - Helpers

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }
}
