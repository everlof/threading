import XCTest
@testable import Threading

/// What is Cursor's after the ACP runtime was made provider-neutral: its profile, its launch
/// line, its capability rows, and an end-to-end handshake built from the shapes measured on the
/// wire in `docs/CURSOR_ACP_FINDINGS.md`.
///
/// The fakes here quote §10 rather than inventing plausible JSON. That is the point of the whole
/// exercise: the second ACP provider ships because those bytes were seen, so a test that made up
/// friendlier ones would be asserting against a Cursor nobody has met.
final class CursorACPProfileTests: XCTestCase {

    // MARK: - Profile

    func testProfileNamesCursorEverywhereAUserOrALogReadsIt() {
        let cursor = ACPProviderProfile.cursor

        XCTAssertEqual(cursor.displayName, "Cursor")
        XCTAssertEqual(cursor.diagnosticsLabel, "Cursor ACP")
        XCTAssertEqual(cursor.unknownEventPrefix, "cursor.acp.")
        XCTAssertEqual(
            ACPTransportMessage.noConversationSession(cursor.displayName),
            "Cursor opened no conversation session."
        )
        XCTAssertEqual(
            ACPTransportMessage.promptNotSent(cursor.displayName),
            "Threading could not send the Cursor turn."
        )
        XCTAssertEqual(
            ACPTransportMessage.exited(cursor.diagnosticsLabel, status: 3),
            "Cursor ACP exited with status 3."
        )
        XCTAssertEqual(
            ACPTransportMessage.handshakeTimedOut(cursor.displayName),
            "Cursor did not answer Threading's opening request."
        )
    }

    /// The `_meta` flag Cursor reads at `initialize` chooses between two **disjoint** model-id
    /// spaces. Threading sends none, which keeps it in the space its own `models` list is
    /// quoted in — and this test is what stops that being changed without noticing that
    /// `session/set_model` would start refusing every id (§10.1, §10.2).
    func testProfileStaysInTheRawModelIdentifierSpace() {
        XCTAssertTrue(ACPProviderProfile.cursor.clientCapabilitiesMeta.isEmpty)
    }

    /// Both readers answer nil because the standard wire members carry the facts: `session/new`
    /// and `session/load` both return `models.currentModelId` (§10.1, §10.4), and the command
    /// catalog arrives as an `available_commands_update` notification rather than inside the
    /// `initialize` result (§10.2).
    func testProfileAddsNoExtensionReadersBecauseTheStandardOnesAnswer() {
        let cursor = ACPProviderProfile.cursor
        let sessionResult: [String: Any] = [
            "sessionId": CursorFixture.sessionID,
            "models": ["currentModelId": CursorFixture.modelID]
        ]

        XCTAssertEqual(ACPWireAdapter.currentModel(in: sessionResult), CursorFixture.modelID)
        XCTAssertNil(cursor.extendedModelID(sessionResult))
        XCTAssertNil(cursor.initializeCommands(sessionResult))
        XCTAssertNil(cursor.initializeCommands(["_meta": ["availableCommands": []]]))
    }

    func testComposerCatalogRefusesOnlyWhatNativeChatCannotHonour() throws {
        let capabilities = ACPWireAdapter.composerCapabilities(
            from: CursorFixture.advertisedCommands,
            policy: ACPProviderProfile.cursor.commandCatalog
        )

        // A builtin skill is an ordinary turn.
        let skill = try XCTUnwrap(capabilities.first { $0.name == "create-rule" })
        XCTAssertEqual(skill.id, "cursor.command:create-rule")
        XCTAssertTrue(skill.isEnabled)
        XCTAssertEqual(skill.presentation, .turn)

        // So is a command this app has never heard of. The catalog is account state (§10.2), so
        // anything not named in the policy has to stay usable.
        let userCommand = try XCTUnwrap(capabilities.first { $0.name == "a-user-command" })
        XCTAssertTrue(userCommand.isEnabled)

        for refused in ["copy-request-id", "statusline", "update-cli-config", "loop"] {
            let capability = try XCTUnwrap(capabilities.first { $0.name == refused }, refused)
            XCTAssertFalse(capability.isEnabled, refused)
            XCTAssertEqual(
                capability.unavailableReason,
                L10n.string("Available in Cursor's own terminal; not available in native Chat yet"),
                refused
            )
        }

        let rename = try XCTUnwrap(capabilities.first { $0.name == "rename-chat" })
        XCTAssertTrue(rename.isEnabled)
        XCTAssertEqual(rename.presentation, .command)
    }

    // MARK: - Capabilities

    /// Each row cites its measurement in the `AgentKind.capabilities` comment; this holds the
    /// claims themselves, including the ones deliberately not made.
    func testCapabilityRowsClaimOnlyWhatWasMeasured() {
        XCTAssertTrue(AgentKind.cursor.supportsNativeUI)
        XCTAssertTrue(AgentKind.cursor.supportsResume)
        XCTAssertTrue(AgentKind.cursor.supportsThreadingBridge)

        XCTAssertFalse(AgentKind.cursor.supports(.terminalUI))
        XCTAssertFalse(AgentKind.cursor.supportsForking)
        XCTAssertFalse(AgentKind.cursor.supportsPermissionModes)
        XCTAssertFalse(AgentKind.cursor.supportsPresetSessionID)
        XCTAssertFalse(AgentKind.cursor.supportsAccounts)
        XCTAssertFalse(AgentKind.cursor.supports(.deferredSessionIdentifier))
        XCTAssertFalse(AgentKind.cursor.supports(.transcriptReplay))
        XCTAssertFalse(AgentKind.cursor.supports(.transcriptUsageIndex))
        XCTAssertFalse(AgentKind.cursor.supports(.headlessResearch))

        // No permission modes means no launch flags, in either direction.
        for mode in AgentPermissionMode.allCases {
            XCTAssertTrue(mode.launchFlags(for: .cursor).isEmpty, mode.rawValue)
        }

        // No login lives in a directory Threading could point an `env` prefix at.
        XCTAssertNil(AgentKind.cursor.accountEnvironmentKey)
        XCTAssertEqual(AgentKind.cursor.executableName, "cursor-agent")
    }

    /// A runtime with no terminal surface is always native. This is a clamp, not a refusal: the
    /// session is created either way, because losing the record over a surface Threading chose
    /// would be the worse answer.
    @MainActor
    func testACursorSessionIsAlwaysNativeHoweverItWasAskedFor() throws {
        let requestedTerminal = AgentSession(kind: .cursor, title: "Native", usesNativeUI: false)
        XCTAssertTrue(requestedTerminal.usesNativeUI)

        // And a stored record that says otherwise is corrected on the way in rather than
        // throwing away a conversation that exists on Cursor's side.
        var stored = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(requestedTerminal)
        ) as? [String: Any] ?? [:]
        stored["nativeUI"] = false
        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: stored)
        )
        XCTAssertTrue(decoded.usesNativeUI)

        // And nothing offers the choice, so the clamp is never what corrects a user's pick: the
        // sidebar's Interface submenu and the composer's surface chip both read this.
        XCTAssertFalse(
            SessionSurfaceTogglePresentation.canSwitchSurface(.cursor),
            "a runtime with one surface has nothing to switch between"
        )
        XCTAssertTrue(
            SessionSurfaceTogglePresentation.canSwitchSurface(.grok),
            "a runtime with both surfaces still offers the switch"
        )
    }

    // MARK: - Launch

    @MainActor
    func testNativePlanIsTheBareACPSubcommandWithTheBrowserNeutralised() throws {
        let transcriptID = TranscriptID(CursorFixture.sessionID)
        var session = AgentSession(kind: .cursor, title: "Native", usesNativeUI: true)
        session.resumeState = .resumable(transcriptID)
        let project = Project(name: "Fixture", folderURL: URL(fileURLWithPath: "/tmp/project"))

        let plan = try AgentLauncher.streamPlan(for: session, in: project)
        let source = try XCTUnwrap(plan.arguments.last)

        XCTAssertTrue(source.contains("'cursor-agent' 'acp'"), source)
        // `acp` takes no options of its own, and Cursor's model and mode are wire state rather
        // than launch state — so nothing else belongs on this line.
        XCTAssertFalse(source.contains("--model"), source)
        XCTAssertFalse(source.contains("--permission-mode"), source)
        XCTAssertTrue(source.contains("'cd' '/tmp/project'"), source)

        XCTAssertEqual(
            plan.environmentOverrides,
            ["BROWSER": "/usr/bin/true", "NO_OPEN_BROWSER": "1"]
        )
        let environment = plan.launchEnvironment()
        XCTAssertEqual(environment["BROWSER"], "/usr/bin/true")
        XCTAssertEqual(environment["NO_OPEN_BROWSER"], "1")
        XCTAssertNotNil(environment[EnvironmentKeys.path])

        XCTAssertEqual(plan.resumeState, .resumable(transcriptID))
    }

    /// There *is* a command line that would start Cursor's TUI. Running it here would open a
    /// different, empty chat beside the conversation the row names, because the two interfaces
    /// keep disjoint stores (§11) — so the launcher refuses instead.
    @MainActor
    func testTerminalPlanIsRefusedRatherThanLaunchingADifferentConversation() {
        let session = AgentSession(kind: .cursor, title: "Native")
        let project = Project(name: "Fixture", folderURL: URL(fileURLWithPath: "/tmp/project"))

        XCTAssertThrowsError(try AgentLauncher.plan(for: session, in: project)) { error in
            XCTAssertEqual(
                error as? AgentLaunchPlanningError,
                .unsupportedTerminalConversation(.cursor)
            )
        }
    }

    // MARK: - Wire

    /// One turn, assembled from §10's measured payloads: the four-key `session/new` result, the
    /// command catalog pushed afterwards, chunks with **no `messageId`**, a shell tool whose id
    /// carries a literal newline and whose output is in `rawOutput`, and a permission request
    /// with three options whose ids are hyphenated while their kinds are underscored.
    @MainActor
    func testMeasuredCursorHandshakeStreamsATurnEndToEnd() throws {
        let initialized = expectation(description: "session initialized")
        let catalog = expectation(description: "command catalog")
        let title = expectation(description: "session title")
        let permission = expectation(description: "permission request")
        let result = expectation(description: "tool result")
        let finished = expectation(description: "turn finished")

        let script = #"""
        read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcpCapabilities":{"http":true,"sse":true},"promptCapabilities":{"audio":false,"embeddedContext":false,"image":true},"sessionCapabilities":{"list":{}}},"authMethods":[{"id":"cursor_login","name":"Cursor Login","description":"Authenticate using existing Cursor login credentials."}]}}'
        read -r open_session
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent","description":"Full agent capabilities with tool access"},{"id":"plan","name":"Plan","description":"Read-only mode"},{"id":"ask","name":"Ask","description":"Q&A mode"}]},"models":{"currentModelId":"default[]","availableModels":[{"modelId":"default[]","name":"Auto"},{"modelId":"grok-4.6[effort=high,fast=true]","name":"grok-4.6"}]},"configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select"},{"id":"model","name":"Model","category":"model","type":"select"}]}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"create-rule","description":"Create Cursor rules for persistent AI guidance."},{"name":"copy-request-id","description":"Copy the last request ID to clipboard"}]}}}'
        read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"session_info_update","title":"Shell Command Echo"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user requested a"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":" shell command."}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"tool_call","toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","title":"`swift test`","kind":"execute","status":"pending","rawInput":{"command":"swift test"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","toolCall":{"toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","title":"`swift test`","kind":"execute","status":"pending","content":[{"type":"content","content":{"type":"text","text":"Not in allowlist: swift"}}]},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Allow always","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
        read -r permission_response
        case "$permission_response" in
          *allow-once*) ;;
          *) printf '%s\n' '{"jsonrpc":"2.0","id":3,"error":{"message":"wrong permission response"}}'; exit 8 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","status":"in_progress"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","status":"completed","rawOutput":{"exitCode":0,"stdout":"hello\n","stderr":""}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Ran it."}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        cat >/dev/null
        """#

        let session = CursorFixture.streamSession(script: script)
        let previousPresenter = PermissionBroker.present
        PermissionBroker.present = { request, completion in
            XCTAssertEqual(request.tool, .bash)
            XCTAssertEqual(request.input["command"], .string("swift test"))
            permission.fulfill()
            completion(.allow(reason: "test"))
        }
        defer {
            session.terminate()
            PermissionBroker.present = previousPresenter
        }

        var blocks: [ContentBlock] = []
        session.onComposerCapabilitiesChange = {
            let names = session.composerCapabilities.map(\.name)
            guard names.contains("create-rule") else { return }
            XCTAssertEqual(
                session.composerCapabilities.first { $0.name == "copy-request-id" }?.isEnabled,
                false
            )
            catalog.fulfill()
        }
        session.onSessionTitleChange = { reported in
            XCTAssertEqual(reported, "Shell Command Echo")
            title.fulfill()
        }
        session.onEvent = { event in
            switch event {
            case .initialised(let providerID, let model):
                XCTAssertEqual(providerID, TranscriptID(CursorFixture.sessionID))
                // Cursor's own spelling of Auto, in the raw id space this client stays in.
                XCTAssertEqual(model, "default[]")
                initialized.fulfill()
            case .assistantMessage(let reported):
                blocks.append(contentsOf: reported)
            case .toolResults(let values):
                XCTAssertEqual(values.first?.toolUseID, CursorFixture.multilineToolCallID)
                XCTAssertEqual(values.first?.isError, false)
                // The output is in `rawOutput`, not in ACP `content` (§10.6).
                XCTAssertEqual(
                    values.first?.text.contains("hello"),
                    true,
                    values.first?.text ?? ""
                )
                result.fulfill()
            case .turnFinished(let message, let outcome, _):
                XCTAssertNil(message)
                XCTAssertEqual(outcome, .completed)
                finished.fulfill()
            default:
                break
            }
        }

        session.start()
        XCTAssertTrue(session.send("Run the shell command: swift test"))
        wait(
            for: [initialized, catalog, title, permission, result, finished],
            timeout: CursorFixture.timeout
        )

        // No `messageId` arrives on any chunk (§10.3), so the two thought fragments have to be
        // joined by the runtime rather than by an identity the wire never sends.
        let thinking = blocks.compactMap { block -> String? in
            guard case .thinking(let text) = block else { return nil }
            return text
        }
        XCTAssertEqual(thinking, ["The user requested a shell command."])

        let toolUses = blocks.compactMap { block -> String? in
            guard case .toolUse(let id, _, _) = block else { return nil }
            return id
        }
        XCTAssertEqual(toolUses, [CursorFixture.multilineToolCallID])
    }

    /// Cursor answers a refused permission by completing the same tool call with no output and
    /// never reports `failed` (§10.5). The client's own answer is the only record, and the row
    /// has to say so.
    @MainActor
    func testARejectedToolCallIsShownAsRejectedEvenThoughCursorCompletesIt() throws {
        let result = expectation(description: "tool result")
        let finished = expectation(description: "turn finished")

        let script = #"""
        read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        read -r open_session
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","models":{"currentModelId":"default[]"}}}'
        read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"tool_call","toolCallId":"call-807c6aad-0","title":"`swift test`","kind":"execute","status":"pending","rawInput":{"command":"swift test"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","toolCall":{"toolCallId":"call-807c6aad-0","title":"`swift test`","kind":"execute","status":"pending"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Allow always","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
        read -r permission_response
        case "$permission_response" in
          *reject-once*) ;;
          *) printf '%s\n' '{"jsonrpc":"2.0","id":3,"error":{"message":"wrong permission response"}}'; exit 8 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-807c6aad-0","status":"completed"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        cat >/dev/null
        """#

        let session = CursorFixture.streamSession(script: script)
        let previousPresenter = PermissionBroker.present
        PermissionBroker.present = { _, completion in completion(.deny(reason: "test")) }
        defer {
            session.terminate()
            PermissionBroker.present = previousPresenter
        }

        session.onEvent = { event in
            switch event {
            case .toolResults(let values):
                XCTAssertEqual(values.first?.isError, true)
                XCTAssertEqual(values.first?.text, ACPTransportMessage.deniedToolCall)
                result.fulfill()
            case .turnFinished(_, let outcome, _):
                // The turn itself is not a failure: Cursor narrates the refusal and finishes.
                XCTAssertEqual(outcome, .completed)
                finished.fulfill()
            default:
                break
            }
        }

        session.start()
        XCTAssertTrue(session.send("Run the shell command: swift test"))
        wait(for: [result, finished], timeout: CursorFixture.timeout)
    }

    /// Resume, then stop. `session/load` replays the whole conversation as notifications
    /// *before* its result (§10.4), and its result carries `modes`/`models`/`configOptions` but
    /// no `sessionId` — the caller already knows it. A `session/cancel` notification then settles
    /// the pending prompt as `cancelled` (§10.7).
    @MainActor
    func testSessionLoadReplaysBeforeItsResultAndCancelSettlesTheTurn() throws {
        let initialized = expectation(description: "session initialized")
        let finished = expectation(description: "turn stopped")

        let script = #"""
        read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        read -r load_session
        case "$load_session" in
          *session\\/load*) ;;
          *) exit 9 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Reply with exactly: ok"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"modes":{"currentModeId":"agent"},"models":{"currentModelId":"default[]"},"configOptions":[]}}'
        read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eb2cf87-50a9-423c-9682-1bb4ca5588ca","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"1"}}}}'
        read -r cancel
        case "$cancel" in
          *session\\/cancel*) ;;
          *) exit 9 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
        cat >/dev/null
        """#

        let session = CursorFixture.streamSession(
            script: script,
            resumeState: .resumable(TranscriptID(CursorFixture.sessionID))
        )
        defer { session.terminate() }

        var order: [String] = []
        session.onEvent = { event in
            switch event {
            case .initialised(let providerID, let model):
                // The load result names no session, so the id has to come from what was stored.
                XCTAssertEqual(providerID, TranscriptID(CursorFixture.sessionID))
                XCTAssertEqual(model, "default[]")
                order.append("initialised")
                initialized.fulfill()
            case .userMessage(let text):
                XCTAssertEqual(text, "Reply with exactly: ok")
                order.append("replayed-user")
            case .assistantMessage:
                order.append("replayed-agent")
            case .turnFinished(_, let outcome, _):
                XCTAssertEqual(outcome, .stopped)
                finished.fulfill()
            default:
                break
            }
        }

        session.start()
        wait(for: [initialized], timeout: CursorFixture.timeout)
        XCTAssertEqual(order.prefix(3), ["replayed-user", "replayed-agent", "initialised"])

        XCTAssertTrue(session.send("count"))
        let acknowledged = expectation(description: "interrupt acknowledged")
        session.interrupt { receipt in
            XCTAssertEqual(receipt, .acknowledged)
            acknowledged.fulfill()
        }
        wait(for: [acknowledged, finished], timeout: CursorFixture.timeout)
        XCTAssertTrue(session.canSend)
    }
}

// MARK: - Fixtures

private enum CursorFixture {
    static let timeout: TimeInterval = 10
    static let sessionID = "9eb2cf87-50a9-423c-9682-1bb4ca5588ca"
    static let modelID = "default[]"

    /// Verbatim from §10.6: a Cursor call id and a provider function-call id joined by a
    /// literal newline.
    static let multilineToolCallID =
        "call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0"

    /// A slice of the 23 commands measured on this account, plus one standing in for the user's
    /// own — the list Cursor pushes is account state rather than a protocol constant.
    static var advertisedCommands: [[String: Any]] {
        [
            ["name": "create-rule", "description": "Create Cursor rules for persistent AI guidance."],
            ["name": "copy-request-id", "description": "Copy the last request ID to clipboard"],
            ["name": "statusline", "description": "Configure a custom status line in the CLI."],
            ["name": "update-cli-config", "description": "View and modify Cursor CLI configuration."],
            ["name": "loop", "description": "Run a prompt or skill on a recurring interval."],
            ["name": "rename-chat", "description": "Rename the current chat to match its focus."],
            ["name": "a-user-command", "description": "Something only this account has."]
        ]
    }

    @MainActor
    static func streamSession(
        script: String,
        resumeState: ResumeState = .unavailable
    ) -> ACPStreamSession {
        ACPStreamSession(
            sessionID: SessionID(),
            workingDirectory: "/tmp/project",
            profile: .cursor
        ) {
            AgentLaunchPlan(
                executable: "/bin/sh",
                arguments: ["-c", script],
                resumeState: resumeState
            )
        }
    }
}
