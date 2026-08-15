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

        XCTAssertEqual(store.updateAgentTitle("worktree diff crash", for: session.id), .accepted)
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "worktree diff crash")
    }

    /// The three names that repeat what the sidebar already shows. Each is refused *and says
    /// so*: the handler turns a false into a failure the agent can act on, where reporting
    /// success would have it tell the user about a rename that never happened.
    func testNamesThatRepeatTheRowAreRefusedRatherThanStored() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        for noise in ["Claude Code", "Claude Code 2", "app"] {
            XCTAssertEqual(
                store.updateAgentTitle(noise, for: session.id),
                .refusedAsNoise,
                "“\(noise)” names the agent or the project, not the conversation"
            )
            XCTAssertNil(store.session(withID: session.id)?.agentTitle, noise)
        }
    }

    /// Setting the same name twice is not a failure. The agent is told the session is called
    /// what it asked for, because it is.
    func testNamingASessionWhatItIsAlreadyCalledSucceeds() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        XCTAssertEqual(store.updateAgentTitle("worktree diff crash", for: session.id), .accepted)
        XCTAssertEqual(store.updateAgentTitle("worktree diff crash", for: session.id), .accepted)
    }

    /// The load-bearing one. The tool writes `agentTitle`; a user's own rename lives in
    /// `customTitle` and outranks it in `displayTitle`. An agent writing to `customTitle`
    /// would pin a name the user never chose and switch off every later update including
    /// its own.
    func testTheUsersOwnNameOutranksTheAgentsAndIsNeverOverwritten() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.renameSession(id: session.id, to: "what I called it")

        XCTAssertEqual(store.updateAgentTitle("what the agent called it", for: session.id), .accepted)

        let stored = try XCTUnwrap(store.session(withID: session.id))
        XCTAssertEqual(stored.customTitle, "what I called it")
        XCTAssertEqual(stored.agentTitle, "what the agent called it")
        XCTAssertEqual(stored.displayTitle, "what I called it")
    }

    func testAMissingSessionIsReportedRatherThanIgnored() throws {
        let store = makeStore()
        XCTAssertEqual(
            store.updateAgentTitle("worktree diff crash", for: SessionID()),
            .sessionNotFound
        )
    }

    // MARK: - Chosen Over Reported

    /// The clobber this distinction exists for. A PTY-attached Claude re-asserts its own
    /// `ai-title` through the terminal title within seconds of the tool call, and the
    /// turn-end transcript read re-reads the same record — so without the source rule, the
    /// rename the user just asked for was silently put back before they looked up.
    func testAChosenNameSurvivesWhatTheTransportsKeepReporting() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.updateAgentTitle("Explore integration options", for: session.id)

        XCTAssertEqual(
            store.updateAgentTitle(
                "Chrome sessions and passwords", for: session.id, source: .chosen
            ),
            .accepted
        )

        // The terminal title, then the transcript read: both re-report the old name.
        XCTAssertEqual(
            store.updateAgentTitle("✻ Explore integration options", for: session.id),
            .protectedByStrongerSource
        )
        XCTAssertEqual(
            store.updateAgentTitle("Explore integration options", for: session.id),
            .protectedByStrongerSource
        )
        XCTAssertEqual(
            store.session(withID: session.id)?.agentTitle,
            "Chrome sessions and passwords"
        )
    }

    /// Asking again is the one thing that moves a chosen name — the tool's own description
    /// tells the agent to call it when the work has moved on.
    func testANewChosenNameReplacesTheOldChosenOne() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        XCTAssertEqual(
            store.updateAgentTitle("first chosen name", for: session.id, source: .chosen),
            .accepted
        )
        XCTAssertEqual(
            store.updateAgentTitle("second chosen name", for: session.id, source: .chosen),
            .accepted
        )
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "second chosen name")
    }

    /// While nothing was chosen, the transports keep doing what they always did: the last
    /// report wins, which is what lets a name arrive at all before anyone asks for one.
    func testAReportedTitleStillFollowsWhileNothingWasChosen() throws {
        let (store, session) = try makeSessionInProject(named: "app")

        XCTAssertEqual(store.updateAgentTitle("what it opened with", for: session.id), .accepted)
        XCTAssertEqual(store.updateAgentTitle("what it became", for: session.id), .accepted)
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "what it became")
    }

    /// Codex's persisted thread name is the conversation's canonical provider metadata. Its
    /// TUI may continue emitting an older OSC caption after `/rename`; that transient report
    /// must not put the old words back in either title surface.
    func testAProviderNameSurvivesWhatTheTerminalKeepsReporting() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.updateAgentTitle("Action Required | app", for: session.id)

        XCTAssertEqual(
            store.updateAgentTitle(
                "WINAMP",
                for: session.id,
                source: .provider
            ),
            .accepted
        )

        XCTAssertEqual(
            store.updateAgentTitle("Action Required | app", for: session.id),
            .protectedByStrongerSource
        )
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "WINAMP")
        XCTAssertEqual(store.session(withID: session.id)?.agentTitleSource, .provider)
    }

    /// The provider's own metadata is stronger than presentation output, but it is still not
    /// stronger than a name deliberately selected through Threading's rename tool.
    func testAThreadingChosenNameSurvivesProviderMetadata() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.updateAgentTitle("Threading's name", for: session.id, source: .chosen)

        XCTAssertEqual(
            store.updateAgentTitle(
                "Provider's name",
                for: session.id,
                source: .provider
            ),
            .protectedByStrongerSource
        )
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "Threading's name")
        XCTAssertEqual(store.session(withID: session.id)?.agentTitleSource, .chosen)
    }

    /// Choosing the words a transport already reported must still pin them: the store answers
    /// "already so" either way, but only the pin stops the next report from moving the name.
    func testChoosingTheNameATransportAlreadyReportedStillPinsIt() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.updateAgentTitle("worktree diff crash", for: session.id)

        XCTAssertEqual(
            store.updateAgentTitle(
                "worktree diff crash", for: session.id, source: .chosen
            ),
            .accepted
        )

        XCTAssertEqual(
            store.updateAgentTitle("something reported later", for: session.id),
            .protectedByStrongerSource
        )
        XCTAssertEqual(store.session(withID: session.id)?.agentTitle, "worktree diff crash")
    }

    /// A tool result is an acknowledgement, not an optimistic UI update. Recovery mode is a
    /// deterministic refused-write fixture for the same path a disk or database failure takes:
    /// the chosen title must report that refusal and the standing persisted title must remain.
    func testAChosenNameIsAcknowledgedOnlyAfterItsWriteCommits() throws {
        let (seed, session) = try makeSessionInProject(named: "app")
        XCTAssertEqual(
            seed.updateAgentTitle("standing persisted name", for: session.id),
            .accepted
        )
        seed.flushPendingSave()

        let refusingStore = ProjectStore(
            stateManager: StateManager(
                appSupportDirectory: testDirectory.appendingPathComponent(
                    "state",
                    isDirectory: true
                )
            ),
            refusesWrites: true
        )
        XCTAssertEqual(
            refusingStore.updateAgentTitle(
                "optimistic ghost name",
                for: session.id,
                source: .chosen
            ),
            .persistenceRefused
        )
        XCTAssertEqual(
            refusingStore.session(withID: session.id)?.agentTitle,
            "standing persisted name"
        )

        let reopened = makeStore()
        XCTAssertEqual(reopened.session(withID: session.id)?.agentTitle, "standing persisted name")
        XCTAssertEqual(reopened.session(withID: session.id)?.agentTitleSource, .reported)
    }

    /// The pin is part of the record: a chosen name that survived to the next launch must
    /// keep outranking the transports, which resume re-reporting the moment the CLI is back.
    func testTheChosenSourceSurvivesEncoding() throws {
        let (store, session) = try makeSessionInProject(named: "app")
        store.updateAgentTitle("Chrome sessions and passwords", for: session.id, source: .chosen)

        let stored = try XCTUnwrap(store.session(withID: session.id))
        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONEncoder().encode(stored)
        )

        XCTAssertEqual(decoded.agentTitle, "Chrome sessions and passwords")
        XCTAssertEqual(decoded.agentTitleSource, .chosen)
    }

    // MARK: - When the Menu Offers It

    /// The first of the three gates. A session with no agent running has nothing to ask, so
    /// the item is absent rather than present and inert.
    func testADormantSessionIsNotOfferedTheAgentRename() throws {
        let (_, session) = try makeSessionInProject(named: "app")
        XCTAssertFalse(SessionCoordinator.canAskAgentToRename(
            session.id,
            agentRuntime: AgentRuntime(
                currentSessionProjection: CurrentSessionProjection { _ in nil }
            )
        ))
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

    /// And in its own write, later. Bundled with the text, the return arrives inside the
    /// chunk the CLI's paste heuristic classifies as pasted content — Claude Code inserts it
    /// as a line break and the request sits unsent until the user presses Return themselves,
    /// which is exactly how this shipped broken. The delay is what makes it a keypress.
    func testTheReturnFollowsTheTextRatherThanSharingItsWrite() {
        XCTAssertGreaterThan(SessionRenameRequest.submitDelay, 0)
        XCTAssertFalse(SessionRenameRequest.promptKey.contains(SessionRenameRequest.submitKey))
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

        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        return (store, session)
    }
}
