import XCTest
@testable import Threading

final class GrokACPStreamSessionTests: XCTestCase {

    func testSharedJSONRPCEnvelopeAcceptsACPVersionMember() throws {
        let envelope = try XCTUnwrap(JSONRPCLineEnvelope.parse(
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-1"}}"#
        ))

        guard case .notification(let method, let parameters) = envelope else {
            return XCTFail("Expected an ACP notification")
        }
        XCTAssertEqual(method, "session/update")
        XCTAssertEqual(parameters["sessionId"] as? String, "grok-1")
    }

    func testAdapterReadsStandardSessionModelAndUsage() {
        XCTAssertEqual(GrokACPAdapter.currentModel(in: [
            "models": ["currentModelId": "grok-4.5"]
        ]), "grok-4.5")
        XCTAssertEqual(GrokACPAdapter.integer(42), 42)
        XCTAssertNil(GrokACPAdapter.integer(true))
        XCTAssertEqual(GrokACPAdapter.sessionTitle(in: [
            "title": "  Repair the parser  "
        ]), "Repair the parser")
        XCTAssertNil(GrokACPAdapter.sessionTitle(in: ["title": "  "]))
    }

    func testAdapterMapsACPPlanStatuses() {
        let steps = GrokACPAdapter.planSteps(in: [
            "entries": [
                ["content": "Inspect", "priority": "high", "status": "completed"],
                ["content": "Implement", "priority": "high", "status": "in_progress"],
                ["content": "Verify", "priority": "medium", "status": "pending"]
            ]
        ])

        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.map(\.title), ["Inspect", "Implement", "Verify"])
        XCTAssertEqual(steps.map(\.status), [.completed, .inProgress, .pending])
    }

    func testAdapterMapsACPToolKindsToPermissionIdentities() {
        XCTAssertEqual(GrokACPAdapter.toolIdentity(kind: "execute", title: "Run"), .bash)
        XCTAssertEqual(GrokACPAdapter.toolIdentity(kind: "read", title: "Open"), .read)
        XCTAssertEqual(GrokACPAdapter.toolIdentity(kind: "edit", title: "Patch"), .edit)
        XCTAssertEqual(GrokACPAdapter.toolIdentity(kind: "fetch", title: "Fetch"), .webFetch)
        XCTAssertEqual(
            GrokACPAdapter.toolIdentity(kind: "future", title: "NovelTool"),
            .unknown("NovelTool")
        )
    }

    func testAdapterPreservesRawToolInputAndDiffLocation() {
        let input = GrokACPAdapter.toolInput(from: [
            "title": "Edit file",
            "kind": "edit",
            "rawInput": ["replacement": "new"],
            "content": [[
                "type": "diff",
                "path": "/tmp/example.swift",
                "oldText": "old",
                "newText": "new"
            ]]
        ])

        XCTAssertEqual(input["replacement"], .string("new"))
        XCTAssertEqual(input["file_path"], .string("/tmp/example.swift"))
        XCTAssertEqual(input["old_string"], .string("old"))
        XCTAssertEqual(input["new_string"], .string("new"))
    }

    func testComposerCatalogKeepsSafeCommandsAndGatesSessionOwnership() throws {
        let capabilities = GrokACPComposerCatalog.capabilities(from: [
            ["name": "deep-research", "description": "Research", "input": ["hint": "query"]],
            ["name": "always-approve", "description": "Skip prompts"]
        ])

        let research = try XCTUnwrap(capabilities.first { $0.name == "deep-research" })
        XCTAssertTrue(research.isEnabled)
        XCTAssertEqual(research.presentation, .turn)
        XCTAssertEqual(research.argumentHint, "query")

        let approval = try XCTUnwrap(capabilities.first { $0.name == "always-approve" })
        XCTAssertFalse(approval.isEnabled)
        XCTAssertNotNil(approval.unavailableReason)
    }

    @MainActor
    func testGrokNativePlanUsesACPStdioAndPreservesResumeState() throws {
        let transcriptID = TranscriptID("019fc20d-1381-76a3-8870-71bb7f90c4ba")
        var session = AgentSession(kind: .grok, title: "Native", model: "grok-4.5")
        session.resumeState = .resumable(transcriptID)
        // Stated on the session rather than left to inherit. The launch now carries the mode —
        // it silently did not, so a native Grok session ran on whatever `grok` defaults to no
        // matter what the chip said — and an inherited mode would make this assertion depend on
        // the developer's own `defaultPermissionMode`, which a hosted test reads for real.
        session.permissionMode = .plan
        let project = Project(
            name: "Fixture",
            folderURL: URL(fileURLWithPath: "/tmp/project")
        )

        let plan = try AgentLauncher.streamPlan(for: session, in: project)
        let source = try XCTUnwrap(plan.arguments.last)

        XCTAssertTrue(
            source.contains("'grok' 'agent' '--model' 'grok-4.5' '--permission-mode' 'plan' 'stdio'"),
            source
        )
        XCTAssertEqual(plan.resumeState, .resumable(transcriptID))
        XCTAssertTrue(AgentKind.grok.supportsNativeUI)
        XCTAssertTrue(AgentKind.grok.supportsThreadingBridge)
    }

    @MainActor
    func testACPHandshakeStreamsMetadataToolsPermissionAndCompletion() throws {
        let initialized = expectation(description: "session initialized")
        let catalog = expectation(description: "command catalog")
        let title = expectation(description: "session title")
        let text = expectation(description: "assistant text")
        let tool = expectation(description: "tool call")
        let permission = expectation(description: "permission request")
        let result = expectation(description: "tool result")
        let plan = expectation(description: "plan update")
        let finished = expectation(description: "turn finished")

        let script = #"""
        read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"_meta":{"availableCommands":[{"name":"deep-research","description":"Research","input":{"hint":"query"}}]}}}'
        read -r open_session
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"grok-test","models":{"currentModelId":"grok-4.5"}}}'
        read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"session_info_update","title":"Repair the parser"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"agent_message_chunk","messageId":"message-1","content":{"type":"text","text":"Done"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Run checks","kind":"execute","status":"pending","rawInput":{"command":"swift test"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{"sessionId":"grok-test","toolCall":{"toolCallId":"tool-1"},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
        read -r permission_response
        case "$permission_response" in
          *allow-once*) ;;
          *) printf '%s\n' '{"jsonrpc":"2.0","id":3,"error":{"message":"wrong permission response"}}'; exit 8 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"completed","rawOutput":"tests passed"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"usage_update","used":25,"size":500000}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-test","update":{"sessionUpdate":"plan","entries":[{"content":"Verify","priority":"high","status":"completed"}]}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        cat >/dev/null
        """#

        let sessionID = SessionID()
        let session = GrokACPStreamSession(
            sessionID: sessionID,
            workingDirectory: "/tmp/project"
        ) {
            AgentLaunchPlan(
                executable: "/bin/sh",
                arguments: ["-c", script],
                resumeState: .unavailable
            )
        }
        let previousPresenter = PermissionBroker.present
        PermissionBroker.present = { request, completion in
            XCTAssertEqual(request.sessionID, sessionID)
            XCTAssertEqual(request.tool, .bash)
            XCTAssertEqual(request.input["command"], .string("swift test"))
            permission.fulfill()
            completion(.allow(reason: "test"))
        }
        defer {
            session.terminate()
            PermissionBroker.present = previousPresenter
        }

        session.onComposerCapabilitiesChange = {
            guard session.composerCapabilities.contains(where: {
                $0.name == "deep-research" && $0.isEnabled
            }) else { return }
            catalog.fulfill()
        }
        session.onSessionTitleChange = { reported in
            XCTAssertEqual(reported, "Repair the parser")
            title.fulfill()
        }
        session.onEvent = { event in
            switch event {
            case .initialised(let providerID, let model):
                XCTAssertEqual(providerID, TranscriptID("grok-test"))
                XCTAssertEqual(model, "grok-4.5")
                initialized.fulfill()
            case .assistantMessage(let blocks):
                for block in blocks {
                    switch block {
                    case .text("Done"):
                        text.fulfill()
                    case .toolUse(let id, let identity, let input):
                        XCTAssertEqual(id, "tool-1")
                        XCTAssertEqual(identity, .bash)
                        XCTAssertEqual(input["command"], .string("swift test"))
                        tool.fulfill()
                    default:
                        break
                    }
                }
            case .toolResults(let values):
                XCTAssertEqual(values.first?.toolUseID, "tool-1")
                XCTAssertEqual(values.first?.text, "tests passed")
                XCTAssertEqual(values.first?.isError, false)
                result.fulfill()
            case .runPlanUpdated(let steps):
                XCTAssertEqual(steps.map(\.title), ["Verify"])
                XCTAssertEqual(steps.map(\.status), [.completed])
                plan.fulfill()
            case .turnFinished(let message, let outcome, let metrics):
                XCTAssertNil(message)
                XCTAssertEqual(outcome, .completed)
                XCTAssertEqual(metrics.contextTokens, 25)
                XCTAssertEqual(metrics.contextWindow, 500_000)
                finished.fulfill()
            default:
                break
            }
        }

        session.start()
        XCTAssertTrue(session.send("Fix it"), "the opening prompt should queue during ACP setup")

        wait(
            for: [initialized, catalog, title, text, tool, permission, result, plan, finished],
            timeout: 3
        )
        XCTAssertTrue(session.canSend)
    }
}
