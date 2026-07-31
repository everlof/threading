import XCTest

@testable import Threading

/// `set_session_name`: the JSON an agent sends, the schema it reads, and what the store does
/// with the name that arrives.
///
/// The tool exists because a session is named after its first message and nothing renames it
/// afterwards — Claude's own `ai-title` is written once and then almost never rewritten, so a
/// conversation keeps the name of whatever it opened with. The agent holding the conversation
/// is the only thing that can name it for the price of a tool call, and these tests pin the
/// two halves that fail silently: an argument that decodes to nil reports as a missing name,
/// and a name the store drops would otherwise be reported to the user as a rename.
@MainActor
final class SessionNameToolTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("SessionNameToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - Decoding

    private func call(_ json: String) throws -> MCPToolCall {
        try JSONDecoder()
            .decode(MCPToolCallParameters.self, from: Data(json.utf8))
            .call
    }

    func testSetSessionNameDecodesItsArgument() throws {
        let call = try call("""
            {"name": "set_session_name", "arguments": {"name": "worktree diff crash"}}
            """)

        guard case .setSessionName(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.name, "worktree diff crash")
    }

    /// A call with no arguments has to decode rather than throw, so that the handler is the one
    /// place deciding what a missing name means — a thrown decode would reach the agent as a
    /// protocol error instead of the sentence telling it what to send.
    func testSetSessionNameDecodesWithNoArgumentsAtAll() throws {
        let call = try call("""
            {"name": "set_session_name"}
            """)

        guard case .setSessionName(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertNil(arguments.name)
    }

    // MARK: - Declaration

    /// `MCPTools.definitions` admits only identities with exactly one schema, so finding the
    /// tool here is what proves the declaration is complete and not duplicated.
    func testTheToolIsDeclaredExactlyOnce() {
        XCTAssertEqual(
            MCPTools.definitions.filter { $0.tool == .setSessionName }.count,
            1
        )
    }

    /// Asserted on the encoded payload rather than the Swift value, because the encoded form is
    /// what the agent actually reads — a required argument that never reaches the wire is a
    /// tool that gets called with no name.
    func testTheDeclaredSchemaRequiresAName() throws {
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.tool == .setSessionName }
        )
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(definition)
        ) as? [String: Any]

        let schema = try XCTUnwrap(encoded?["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["name"])

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let name = try XCTUnwrap(properties["name"] as? [String: Any])
        XCTAssertEqual(name["type"] as? String, "string")
    }

    /// Naming and archiving travel together under one switch on the Tools page: both are the
    /// agent acting on the session record it runs in.
    func testTheToolBelongsToTheSessionGroup() {
        XCTAssertEqual(MCPBuiltInTool.setSessionName.family, .session)
        XCTAssertTrue(
            MCPToolCatalog.session.tools.contains { $0.builtInTool == .setSessionName },
            "the Tools page would not list it"
        )
    }

    /// Renaming is not destructive and asking twice is asking once — an agent reading the
    /// annotations should not treat this as a thing to be careful with.
    func testTheToolIsAnnotatedAsIdempotentAndNotDestructive() throws {
        let annotations = try XCTUnwrap(MCPBuiltInTool.setSessionName.annotations)
        XCTAssertEqual(annotations.idempotentHint, true)
        XCTAssertEqual(annotations.destructiveHint, false)
        XCTAssertEqual(annotations.readOnlyHint, false)
    }

    // MARK: - What the Store Does With the Name

    func testANameAboutTheConversationIsStoredAndReported() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        XCTAssertTrue(store.updateAgentTitle("worktree diff crash", for: session.id))
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "worktree diff crash")
    }

    /// The three names that repeat what the sidebar already shows. Each is refused *and says
    /// so*: the handler turns a false into a failure the agent can act on, where reporting
    /// success would have it tell the user about a rename that never happened.
    func testNamesThatRepeatTheRowAreRefusedRatherThanStored() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        for noise in ["Claude Code", "Claude Code 2", "app"] {
            XCTAssertFalse(
                store.updateAgentTitle(noise, for: session.id),
                "“\(noise)” names the agent or the project, not the conversation"
            )
            XCTAssertNil(store.session(withID: session.id)?.agentTitle, noise)
        }
    }

    /// Setting the same name twice is not a failure. The agent is told the session is called
    /// what it asked for, because it is.
    func testNamingASessionWhatItIsAlreadyCalledSucceeds() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        XCTAssertTrue(store.updateAgentTitle("worktree diff crash", for: session.id))
        XCTAssertTrue(store.updateAgentTitle("worktree diff crash", for: session.id))
    }

    /// The load-bearing one. The tool writes `agentTitle`; a user's own rename lives in
    /// `customTitle` and outranks it in `displayTitle`. An agent writing to `customTitle`
    /// would pin a name the user never chose and switch off every later update including
    /// its own.
    func testTheUsersOwnNameOutranksTheAgentsAndIsNeverOverwritten() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.renameSession(id: session.id, to: "what I called it")

        XCTAssertTrue(store.updateAgentTitle("what the agent called it", for: session.id))

        let stored = try XCTUnwrap(store.session(withID: session.id))
        XCTAssertEqual(stored.customTitle, "what I called it")
        XCTAssertEqual(stored.agentTitle, "what the agent called it")
        XCTAssertEqual(stored.displayTitle, "what I called it")
    }

    func testAMissingSessionIsReportedRatherThanIgnored() throws {
        let store = makeStore()
        XCTAssertFalse(store.updateAgentTitle("worktree diff crash", for: SessionID()))
    }

    // MARK: - When the Menu Offers It

    /// The first of the three gates. A session with no agent running has nothing to ask, so
    /// the item is absent rather than present and inert.
    func testADormantSessionIsNotOfferedTheAgentRename() throws {
        let (_, session) = try makeSessionInProject(named: "app")
        XCTAssertFalse(SessionCoordinator.canAskAgentToRename(session.id))
    }

    // MARK: - The Line That Gets Sent

    /// The request names the tool outright. Asked in prose, an agent answers in prose — both
    /// CLIs have their own `/rename` and their own idea of a title — and the sidebar would
    /// learn nothing.
    func testTheRequestNamesTheToolItWantsCalled() {
        XCTAssertTrue(
            SessionRenameRequest.promptKey.contains(MCPTools.setSessionName),
            SessionRenameRequest.promptKey
        )
    }

    /// Return, not a newline: several TUI composers insert `\n` as a line break and send
    /// nothing, which would leave the request sitting unsent in the agent's prompt.
    func testTheTerminalRequestIsSubmittedWithReturn() {
        XCTAssertEqual(SessionRenameRequest.submitKey, "\r")
    }

    // MARK: - Fixtures

    private func makeStore() -> ProjectStore {
        ProjectStore(stateManager: StateManager(
            appSupportDirectory: testDirectory.appendingPathComponent("state", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        ))
    }

    /// A project whose name is the folder's, so "the project's own name" is a name this test
    /// can hand the store and watch it refuse.
    private func makeSessionInProject(named name: String) throws -> (ProjectStore, AgentSession) {
        let store = makeStore()
        let folder = testDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let project = store.addProject(folderURL: folder)
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        return (store, session)
    }
}
