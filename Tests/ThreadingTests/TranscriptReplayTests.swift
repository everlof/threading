import XCTest
@testable import Threading

final class TranscriptReplayTests: XCTestCase {

    func testCodexCustomToolCallReplaysAsBash() throws {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "id": "tool-record",
                "call_id": "call-1",
                "status": "completed",
                "name": "exec",
                "input": #"const r = await tools.exec_command({cmd:"ls -la",workdir:"/tmp"}); text(r.output);"#
            ]
        ]

        let event = try XCTUnwrap(TranscriptReplay.codexEvent(from: record))
        guard case .assistantMessage(let blocks) = event,
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected one replayed tool call")
        }

        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(tool, .bash)
        XCTAssertEqual(input["command"], .string("ls -la"))
    }

    func testCodexCustomToolOutputAttachesToCall() throws {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output",
                "call_id": "call-1",
                "output": [
                    ["type": "input_text", "text": "Script completed\nOutput:\n"],
                    ["type": "input_text", "text": "file.txt\n"]
                ]
            ]
        ]

        let event = try XCTUnwrap(TranscriptReplay.codexEvent(from: record))
        guard case .toolResults(let results) = event else {
            return XCTFail("Expected one replayed tool result")
        }

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.toolUseID, "call-1")
        XCTAssertEqual(result.text, "file.txt\n")
        XCTAssertFalse(result.isError)
    }

    func testCodexResponseMessagesRemainIgnoredToAvoidDuplicates() {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "message", "role": "assistant"]
        ]

        XCTAssertNil(TranscriptReplay.codexEvent(from: record))
    }

    /// Codex's TUI wraps markdown into separately painted terminal rows. The rollout retains the
    /// original message, and only that prose — not tool output or reasoning beside it — belongs
    /// in terminal attachment detection.
    func testLatestCodexAssistantTextsRecoverIntactProseFromTheNewestTurn() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try write(
            [
                #"{"type":"event_msg","payload":{"type":"user_message","message":"old"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"old.png"}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"render"}}"#,
                #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"incidental-tool.png"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"private-reasoning.png"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"First /tmp/a-very-long-render-name.png"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"#
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        XCTAssertEqual(
            TranscriptReplay.latestAssistantTexts(
                at: transcript,
                kind: .codex,
                scanLimit: 64 * 1024
            ),
            ["First /tmp/a-very-long-render-name.png", "Done."]
        )
    }

    /// Claude records tool results as user-role rows. They are not a new human turn and must not
    /// stop the backwards walk; their paths are also not assistant prose and must not be scanned.
    func testLatestClaudeAssistantTextsCrossToolResultsButStopAtTheHumanPrompt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")
        try write(
            [
                #"{"type":"user","message":{"role":"user","content":"old"}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"old.png"}]}}"#,
                #"{"type":"user","message":{"role":"user","content":"make the render"}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":"tool-input.png"}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"read-1","content":"tool-output.png"}]}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning.png"},{"type":"text","text":"Saved /tmp/final-render.png"}]}}"#
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        XCTAssertEqual(
            TranscriptReplay.latestAssistantTexts(
                at: transcript,
                kind: .claude,
                scanLimit: 64 * 1024
            ),
            ["Saved /tmp/final-render.png"]
        )
    }

    /// A tail cap may answer nothing, but it may not jump over an unreadable newest record and
    /// return an older turn as though it were the one that just completed.
    func testLatestAssistantTextTailLimitDoesNotLeakAnOlderTurn() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        let oversized = String(repeating: "x", count: JSONLDefaults.chunkBytes * 2)
        try write(
            [
                #"{"type":"event_msg","payload":{"type":"user_message","message":"old"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"old.png"}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"new"}}"#,
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\(oversized)\"}}"
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        XCTAssertEqual(
            TranscriptReplay.latestAssistantTexts(
                at: transcript,
                kind: .codex,
                scanLimit: JSONLDefaults.chunkBytes
            ),
            []
        )
    }

    func testClaudeTaskProgressSurvivesTranscriptReplay() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")

        try write(
            [
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"create-1","name":"TaskCreate","input":{"subject":"Inspect protocol","activeForm":"Inspecting protocol"}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"create-1","content":"Task #1 created successfully","is_error":false}]}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"create-2","name":"TaskCreate","input":{"subject":"Implement renderer","activeForm":"Implementing renderer"}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"create-2","content":"Task #2 created successfully","is_error":false}]}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"update-1","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"update-2","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress","activeForm":"Implementing renderer"}}]}}"#
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        let (events, isTruncated) = TranscriptReplay.read(at: transcript, kind: .claude)
        XCTAssertFalse(isTruncated)

        var timeline = ConversationTimeline(sessionID: SessionID())
        var progress: RunProgress?
        for event in events {
            for change in timeline.apply(event) {
                if case .runProgress(let value) = change {
                    progress = value
                }
            }
        }

        XCTAssertEqual(progress?.step, 2)
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.label, "Step 2 / 2")
    }

    func testClaudeReplaySeparatesCommandAndControlRecordsFromDialogue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")

        try write(
            [
                #"{"type":"user","message":{"role":"user","content":""# +
                    #"<command-name>/compact</command-name>\n<command-message>compact"# +
                    #"</command-message>\n<command-args>focus on replay</command-args>"}}"#,
                #"{"type":"user","message":{"role":"user","content":""# +
                    #"<command-message>compact</command-message>\n<command-args>"# +
                    #"focus on replay</command-args>"}}"#,
                #"{"type":"user","message":{"role":"user","content":""# +
                    #"<task-notification><task-id>agent-7</task-id><status>completed"# +
                    #"</status></task-notification>"}}"#,
                #"{"type":"user","message":{"role":"user","content":""# +
                    #"<local-command-stdout>Compacted output</local-command-stdout>"}}"#,
                #"{"type":"user","message":{"role":"user","# +
                    #""content":"Keep <custom-element>literal</custom-element>."}}"#,
                #"{"type":"assistant","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        let (events, isTruncated) = TranscriptReplay.read(
            at: transcript,
            kind: .claude
        )
        XCTAssertFalse(isTruncated)

        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }

        XCTAssertEqual(timeline.rows, [
            .notice("/compact focus on replay", kind: .muted),
            .userMessage("Keep <custom-element>literal</custom-element>."),
            .assistant(markdown: "Done.")
        ])
    }

    func testIncompleteOrUnrecognizedClaudeEnvelopeRemainsLiteralUserText() throws {
        let samples = [
            "<task-notification>unfinished",
            "<thinking>not a transcript protocol</thinking>",
            "<final>not a transcript protocol</final>",
            "<analysis>user-authored content</analysis>",
            "<Task-notification>case matters</Task-notification>",
            "<task-notification>provider-shaped</task-notification>\nKeep this",
            "<command-name>/compact</command-name>\n<command-message>partial</command-message>",
            "<fork-boilerplate>literal parent text</fork-boilerplate>\nKeep this"
        ]

        for sample in samples {
            let event = try XCTUnwrap(ClaudeTranscriptUserRecord.event(from: [
                "content": sample
            ], scope: .parent))
            guard case .userMessage(let text) = event else {
                return XCTFail("Expected literal user text for \(sample)")
            }
            XCTAssertEqual(text, sample)
        }

        let incompleteChildFork = "<fork-boilerplate>unfinished child instructions"
        let childEvent = try XCTUnwrap(ClaudeTranscriptUserRecord.event(from: [
            "content": incompleteChildFork
        ], scope: .child))
        guard case .userMessage(let childText) = childEvent else {
            return XCTFail("Expected incomplete child fork text to remain literal")
        }
        XCTAssertEqual(childText, incompleteChildFork)
    }

    func testClaudeForkBoilerplateIsRemovedButItsTaskPromptSurvives() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("agent-fork.jsonl")

        try write(
            #"{"toolUseId":"tool-fork","description":"Forked audit"}"#,
            to: directory.appendingPathComponent("agent-fork.meta.json")
        )
        try write(
            [
                #"{"type":"user","agentId":"fork","message":{"role":"user","content":[{"# +
                    #""type":"text","text":"<fork-boilerplate>Internal provider instructions"# +
                    #"</fork-boilerplate>\nAudit <Widget> handling without changing it."}]}}"#,
                #"{"type":"assistant","agentId":"fork","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"Audit complete."}],"# +
                    #""stop_reason":"end_turn"}}"#
            ].joined(separator: "\n") + "\n",
            to: transcript
        )

        var subagents = SubagentTimeline(sessionID: SessionID())
        for event in ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root",
            directory: directory
        ) {
            subagents.apply(event)
        }
        XCTAssertEqual(
            subagents.agents.first?.descriptor.prompt,
            "Audit <Widget> handling without changing it."
        )

        let replay = ClaudeSubagentTranscriptReplay.readConversation(at: transcript)
        var conversation = ConversationTimeline(sessionID: SessionID())
        for event in replay.events { _ = conversation.apply(event) }
        XCTAssertEqual(conversation.rows, [
            .userMessage("Audit <Widget> handling without changing it."),
            .assistant(markdown: "Audit complete.")
        ])
    }

    func testClaudeSubagentIndexRestoresHierarchyAndCompletion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(
            """
            {"agentType":"Explore","description":"Audit parser","spawnDepth":1,
             "toolUseId":"tool-parent"}
            """,
            to: directory.appendingPathComponent("agent-parent.meta.json")
        )
        try write(
            """
            {"agentType":"general-purpose","description":"Inspect failure","spawnDepth":2,
             "toolUseId":"tool-child","parentAgentId":"parent"}
            """,
            to: directory.appendingPathComponent("agent-child.meta.json")
        )
        let parentURL = directory.appendingPathComponent("agent-parent.jsonl")
        try write(
            [
                #"{"type":"user","agentId":"parent","# +
                    #""timestamp":"2026-07-28T12:00:00.000Z","message":{"role":"user","# +
                    #""content":"Find the routing bug"}}"#,
                #"{"type":"assistant","agentId":"parent","message":{"role":"assistant","# +
                    #""content":[{"type":"tool_use","id":"bash-1","name":"Bash","# +
                    #""input":{"command":"swift test"}}]}}"#,
                #"{"type":"user","agentId":"parent","message":{"role":"user","# +
                    #""content":[{"type":"tool_result","tool_use_id":"bash-1","# +
                    #""content":"All tests passed","is_error":false}]}}"#,
                #"{"type":"assistant","agentId":"parent","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"The adapter is correct."}],"# +
                    #""stop_reason":"end_turn"}}"#
            ].joined(separator: "\n") + "\n",
            to: parentURL
        )
        try write(
            [
                #"{"type":"user","agentId":"child","# +
                    #""timestamp":"2026-07-28T12:00:01.000Z","message":{"role":"user","# +
                    #""content":"Inspect the failing test"}}"#,
                #"{"type":"assistant","agentId":"child","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"No failure remains."}],"# +
                    #""stop_reason":"end_turn"}}"#
            ].joined(separator: "\n") + "\n",
            to: directory.appendingPathComponent("agent-child.jsonl")
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root",
            directory: directory
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.agents.count, 2)
        let parent = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "tool-parent"
        })
        let child = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "tool-child"
        })
        XCTAssertEqual(parent.descriptor.parentThreadID, "root")
        XCTAssertEqual(parent.descriptor.nickname, "Audit parser")
        XCTAssertEqual(parent.descriptor.prompt, "Find the routing bug")
        XCTAssertEqual(
            parent.descriptor.path.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            },
            parentURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(parent.status, .completed)
        XCTAssertEqual(child.descriptor.parentThreadID, "tool-parent")
        XCTAssertEqual(child.descriptor.role, "general-purpose")
        XCTAssertEqual(child.status, .completed)

        let replay = ClaudeSubagentTranscriptReplay.readConversation(at: parentURL)
        XCTAssertFalse(replay.isTruncated)
        var conversation = ConversationTimeline(sessionID: SessionID())
        for event in replay.events { _ = conversation.apply(event) }

        guard conversation.rows.count == 3 else {
            return XCTFail("Expected prompt, resolved tool call, and assistant conclusion")
        }
        XCTAssertEqual(conversation.rows.first, .userMessage("Find the routing bug"))
        guard case .toolCall(let call) = conversation.rows[1] else {
            return XCTFail("Expected a replayed child tool call")
        }
        XCTAssertEqual(call.tool, .bash)
        XCTAssertEqual(call.summary, "swift test")
        XCTAssertEqual(call.result?.text, "All tests passed")
        XCTAssertEqual(conversation.rows.last, .assistant(markdown: "The adapter is correct."))
    }

    func testClaudeSubagentIndexRefusesOversizedMetadataAndKeepsLegacyFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = directory.appendingPathComponent("agent-bounded.meta.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: metadata.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: metadata)
        try handle.truncate(
            atOffset: UInt64(ClaudeSubagentHistoryDefaults.maximumMetadataBytes + 1)
        )
        try handle.close()
        try write(
            #"{"type":"assistant","agentId":"bounded","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"stop_reason":"end_turn"}}"#,
            to: directory.appendingPathComponent("agent-bounded.jsonl")
        )

        let events = ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root",
            directory: directory
        )
        guard case .discovered(let descriptor)? = events.first else {
            return XCTFail("The transcript should remain discoverable without its metadata")
        }
        XCTAssertEqual(descriptor.threadID, "bounded")
        XCTAssertNil(descriptor.nickname)
    }

    func testClaudeSubagentIndexMarksUnfinishedTranscriptStopped() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(
            """
            {"toolUseId":"tool-active","description":"Still working"}
            """,
            to: directory.appendingPathComponent("agent-active.meta.json")
        )
        try write(
            """
            {"type":"assistant","agentId":"active","message":{"role":"assistant",
             "content":[{"type":"tool_use","id":"read-1","name":"Read",
             "input":{"file_path":"/tmp/example"}}],"stop_reason":"tool_use"}}

            """,
            to: directory.appendingPathComponent("agent-active.jsonl")
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root",
            directory: directory
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.agents.first?.status, .stopped)
        XCTAssertEqual(
            timeline.agents.first?.activity.last,
            ClaudeSubagentHistoryDefaults.incompleteActivity
        )
    }

    func testClaudeSubagentIndexAcceptsLegacyFinalTextWithoutStopReason() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(
            #"{"toolUseId":"tool-legacy","description":"Legacy child"}"#,
            to: directory.appendingPathComponent("agent-legacy.meta.json")
        )
        try write(
            #"{"type":"assistant","agentId":"legacy","message":{"role":"assistant","# +
                #""content":[{"type":"text","# +
                #""text":"Finished on an older Claude release."}],"stop_reason":null}}"#,
            to: directory.appendingPathComponent("agent-legacy.jsonl")
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root",
            directory: directory
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.agents.first?.status, .completed)
    }

    // MARK: - Reasoning Effort

    /// Claude stamps `effort` on every assistant record, and that is the only place the effort a
    /// settled turn *actually ran at* is recorded: `AgentModels.defaultEffort` reads the account
    /// config, which is the launch-time intention rather than the turn's history.
    func testClaudeReplayCarriesTheEffortEachTurnRanAt() throws {
        let events = try replay(
            [
                #"{"type":"user","message":{"role":"user","content":"first"}}"#,
                #"{"type":"assistant","effort":"xhigh","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"a"}],"stop_reason":"end_turn"}}"#
            ],
            kind: .claude
        )

        XCTAssertEqual(efforts(in: events), ["xhigh"])
    }

    /// `/effort` mid-conversation is exactly the case the config-read answer gets wrong, so each
    /// turn has to keep its own reading rather than the session's latest.
    func testClaudeReplayKeepsEachTurnsOwnEffortWhenItChangesMidSession() throws {
        let events = try replay(
            [
                #"{"type":"user","message":{"role":"user","content":"first"}}"#,
                #"{"type":"assistant","effort":"xhigh","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"a"}],"stop_reason":"end_turn"}}"#,
                #"{"type":"user","message":{"role":"user","content":"second"}}"#,
                #"{"type":"assistant","effort":"low","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"b"}],"stop_reason":"end_turn"}}"#
            ],
            kind: .claude
        )

        XCTAssertEqual(efforts(in: events), ["xhigh", "low"])
    }

    /// A turn that reports no effort ran at whatever the last one did — the CLI restates the
    /// value only when a turn carries it, so carrying it forward is the reading, not a guess.
    func testAnEffortlessTurnInheritsTheOneBeforeIt() throws {
        let events = try replay(
            [
                #"{"type":"user","message":{"role":"user","content":"first"}}"#,
                #"{"type":"assistant","effort":"high","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"a"}],"stop_reason":"end_turn"}}"#,
                #"{"type":"user","message":{"role":"user","content":"second"}}"#,
                #"{"type":"assistant","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"b"}],"stop_reason":"end_turn"}}"#
            ],
            kind: .claude
        )

        XCTAssertEqual(efforts(in: events), ["high", "high"])
    }

    /// Sidechains are excluded on the same rule as the context reading: a subagent's turn is not
    /// this conversation's, and a delegated agent running at a different effort must not be
    /// reported as what the user's own turn ran at.
    func testASubagentsEffortIsNotTheConversations() throws {
        let events = try replay(
            [
                #"{"type":"user","message":{"role":"user","content":"first"}}"#,
                #"{"type":"assistant","effort":"high","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"a"}],"stop_reason":"end_turn"}}"#,
                #"{"type":"assistant","effort":"low","isSidechain":true,"# +
                    #""message":{"role":"assistant","content":[{"type":"text","text":"sub"}]}}"#
            ],
            kind: .claude
        )

        XCTAssertEqual(efforts(in: events), ["high"])
    }

    /// An empty string is not a reading. It would otherwise overwrite a real inherited value with
    /// something no UI can name.
    func testAnEmptyEffortIsNotAReading() throws {
        let events = try replay(
            [
                #"{"type":"user","message":{"role":"user","content":"first"}}"#,
                #"{"type":"assistant","effort":"high","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"a"}],"stop_reason":"end_turn"}}"#,
                #"{"type":"user","message":{"role":"user","content":"second"}}"#,
                #"{"type":"assistant","effort":"","message":{"role":"assistant","# +
                    #""content":[{"type":"text","text":"b"}],"stop_reason":"end_turn"}}"#
            ],
            kind: .claude
        )

        XCTAssertEqual(efforts(in: events), ["high", "high"])
    }

    /// Codex records it on a `turn_context` record, which the event mapping produces no row for —
    /// the reason this is read before the mapping can bail, like the context reading beside it.
    func testCodexReplayReadsEffortFromTurnContext() throws {
        let events = try replay(
            [
                #"{"type":"turn_context","payload":{"effort":"high","model":"gpt-5"}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"first"}}"#,
                #"{"type":"response_item","payload":{"type":"agent_message","text":"a"}}"#
            ],
            kind: .codex
        )

        XCTAssertEqual(efforts(in: events), ["high"])
    }

    /// When no turn stated its own effort, the applied thread settings are the next best answer.
    func testCodexFallsBackToAppliedThreadSettings() throws {
        let events = try replay(
            [
                #"{"type":"event_msg","payload":{"type":"thread_settings_applied","# +
                    #""thread_settings":{"reasoning_effort":"medium"}}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"first"}}"#,
                #"{"type":"response_item","payload":{"type":"agent_message","text":"a"}}"#
            ],
            kind: .codex
        )

        XCTAssertEqual(efforts(in: events), ["medium"])
    }

    // MARK: - Helpers

    private func replay(_ lines: [String], kind: AgentKind) throws -> [StreamEvent] {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")

        try write(lines.joined(separator: "\n") + "\n", to: transcript)

        let (events, isTruncated) = TranscriptReplay.read(at: transcript, kind: kind)
        XCTAssertFalse(isTruncated)
        return events
    }

    /// The effort each settled turn reports, in order. Mapped off the metrics rather than
    /// compact-mapped off the effort, so a turn that reports *none* stays visible as nil instead
    /// of vanishing from the list and passing a count assertion it should fail.
    private func efforts(in events: [StreamEvent]) -> [String?] {
        events
            .compactMap { event -> TurnMetrics? in
                guard case .turnFinished(_, _, let metrics) = event else { return nil }
                return metrics
            }
            .map(\.effort)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-claude-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try XCTUnwrap(text.data(using: .utf8)).write(to: url)
    }
}
