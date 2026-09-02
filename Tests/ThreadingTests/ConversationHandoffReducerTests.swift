import XCTest
@testable import Threading

/// The handoff snapshot's budget, which is dialogue-first because one real handoff was not.
///
/// The numbers these tests hold were set against that handoff: a Codex session of 21 user turns
/// and 302 tool calls whose snapshot was 992k characters of tool output and no user message, read
/// in 24 pages to a 626k-token context. The stress case below is that conversation's shape.
final class ConversationHandoffReducerTests: XCTestCase {

    // MARK: - Helpers

    private func user(_ text: String) -> StreamEvent { .userMessage(text) }

    private func assistant(_ text: String) -> StreamEvent { .assistantMessage(blocks: [.text(text)]) }

    private func bash(_ id: String, _ command: String) -> StreamEvent {
        .assistantMessage(blocks: [.toolUse(id: id, tool: .bash, input: ["command": .string(command)])])
    }

    private func result(_ id: String, _ text: String, isError: Bool = false) -> StreamEvent {
        .toolResults([ToolResult(toolUseID: id, text: text, isError: isError)])
    }

    private func reduce(
        _ events: [StreamEvent],
        dropsHandoffTransport: Bool = false
    ) -> ConversationHandoffReducer {
        var reducer = ConversationHandoffReducer(dropsHandoffTransport: dropsHandoffTransport)
        for event in events { reducer.consume(event) }
        return reducer
    }

    private func segments(_ reducer: ConversationHandoffReducer, prefix: String) -> [String] {
        reducer.segments.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Shape

    func testDialogueIsKeptWholeAndToolOutputOnlyForTheNewestTurns() {
        let reducer = reduce([
            user("one"), bash("a", "ls"), result("a", "r1"), assistant("A1"),
            user("two"), bash("b", "pwd"), result("b", "r2"), assistant("A2"),
            user("three"), bash("c", "git status"), result("c", "r3"), assistant("A3"),
        ])
        let history = reducer.segments.joined(separator: "\n")

        for text in ["[USER]\none", "[USER]\ntwo", "[USER]\nthree", "[ASSISTANT]\nA1", "[ASSISTANT]\nA3"] {
            XCTAssertTrue(history.contains(text), history)
        }
        XCTAssertEqual(segments(reducer, prefix: "[ASSISTANT TOOL CALL: Bash]").count, 3)
        XCTAssertTrue(history.contains("[TOOL RESULT]\nr2"), history)
        XCTAssertTrue(history.contains("[TOOL RESULT]\nr3"), history)
        XCTAssertFalse(history.contains("r1"), "the first turn's output outlived its window")
        XCTAssertFalse(reducer.wasTruncated, "trimmed tool context is the design, not a truncation")
        XCTAssertEqual(reducer.userMessageCount, 3)
        XCTAssertEqual(reducer.assistantMessageCount, 3)
    }

    func testTheOrderOfWhatSurvivesIsTheConversationsOrder() {
        let reducer = reduce([
            user("first"), bash("a", "ls"), result("a", "out"), assistant("reply"),
            user("second"),
        ])

        XCTAssertEqual(
            reducer.segments.map { $0.split(separator: "\n").first.map(String.init) ?? "" },
            ["[USER]", "[ASSISTANT TOOL CALL: Bash]", "[TOOL RESULT]", "[ASSISTANT]", "[USER]"]
        )
    }

    // MARK: - Tool Calls

    func testAToolCallBecomesOneBoundedLine() {
        let long = String(repeating: "x", count: 5_000)
        let reducer = reduce([user("go"), bash("a", long), bash("b", "echo one\necho two")])
        let calls = segments(reducer, prefix: "[ASSISTANT TOOL CALL: Bash]")

        XCTAssertEqual(calls.count, 2)
        let body = calls[0].dropFirst("[ASSISTANT TOOL CALL: Bash]\n".count)
        XCTAssertLessThanOrEqual(body.count, ConversationHandoffBudget.toolCallSummaryCharacterLimit)
        XCTAssertTrue(body.hasSuffix("…"), String(body))
        XCTAssertEqual(calls[1], "[ASSISTANT TOOL CALL: Bash]\necho one …")
    }

    func testAToolWithoutASubjectLineFallsBackToItsArguments() {
        let summary = ConversationHandoffReducer.toolCallSummary(
            tool: .mcp("mcp__threading__set_session_name"),
            input: ["name": .string("HANDOFF")]
        )

        XCTAssertTrue(summary.hasPrefix("[ASSISTANT TOOL CALL: mcp__threading__set_session_name]\n"), summary)
        XCTAssertTrue(summary.contains("HANDOFF"), summary)
    }

    func testToolCallSummariesAreBudgetedNewestFirst() {
        var events: [StreamEvent] = [user("go")]
        for index in 0..<400 {
            events.append(bash("c\(index)", "command-\(index) " + String(repeating: "y", count: 180)))
        }
        let reducer = reduce(events)
        let calls = segments(reducer, prefix: "[ASSISTANT TOOL CALL: Bash]")
        let total = calls.reduce(0) { $0 + $1.count }

        XCTAssertLessThanOrEqual(
            total,
            ConversationHandoffBudget.toolCallSummaryBudget
                + ConversationHandoffBudget.toolCallSummaryCharacterLimit + 40
        )
        XCTAssertTrue(calls.last?.contains("command-399") == true)
        XCTAssertFalse(calls.contains { $0.contains("command-0 ") })
        XCTAssertFalse(reducer.wasTruncated)
    }

    // MARK: - Tool Results

    func testToolResultsAreCutAndBudgeted() {
        var events: [StreamEvent] = [user("go")]
        for index in 0..<20 {
            events.append(bash("r\(index)", "cat"))
            events.append(result("r\(index)", "result-\(index) " + String(repeating: "z", count: 10_000)))
        }
        let reducer = reduce(events)
        let results = segments(reducer, prefix: "[TOOL RESULT]")
        let total = results.reduce(0) { $0 + $1.count }

        for segment in results {
            XCTAssertLessThanOrEqual(
                segment.count,
                ConversationHandoffBudget.toolResultCharacterLimit + 80,
                "one result kept more than its cap"
            )
            XCTAssertTrue(segment.contains("[… remainder omitted from handoff …]"))
        }
        XCTAssertLessThanOrEqual(total, ConversationHandoffBudget.toolResultBudget + 2_100)
        XCTAssertTrue(results.last?.contains("result-19 ") == true)
        XCTAssertFalse(results.contains { $0.contains("result-0 ") })
    }

    func testAnErroringResultKeepsItsLabel() {
        let reducer = reduce([user("go"), bash("a", "false"), result("a", "exit 1", isError: true)])

        XCTAssertTrue(reducer.segments.contains("[TOOL RESULT: ERROR]\nexit 1"), "\(reducer.segments)")
    }

    // MARK: - Dialogue

    func testTheDialogueBudgetKeepsTheNewestAndSaysSo() {
        var events: [StreamEvent] = []
        for index in 0..<10 {
            events.append(user("message-\(index) " + String(repeating: "d", count: 20_000)))
        }
        let reducer = reduce(events)
        let users = segments(reducer, prefix: "[USER]")
        let total = users.reduce(0) { $0 + $1.count }

        XCTAssertLessThanOrEqual(
            total,
            ConversationHandoffBudget.dialogueCharacterLimit
                + ConversationHistoryPage.segmentCharacterLimit + 40
        )
        XCTAssertTrue(users.last?.contains("message-9 ") == true)
        XCTAssertFalse(users.contains { $0.contains("message-0 ") })
        XCTAssertTrue(reducer.wasTruncated, "dropped dialogue is a truncation the page must report")
    }

    func testPrivateReasoningNeverCrossesTheBoundary() {
        let reducer = reduce([
            user("go"),
            .assistantMessage(blocks: [.thinking("private chain"), .text("visible")]),
        ])
        let history = reducer.segments.joined(separator: "\n")

        XCTAssertTrue(history.contains("[ASSISTANT]\nvisible"), history)
        XCTAssertFalse(history.contains("private chain"), history)
    }

    func testATranscriptNoticeIsCarriedAsOne() {
        let reducer = reduce([user("go"), .transcriptNotice("Context compacted."), assistant("on")])

        XCTAssertTrue(reducer.segments.contains("[TRANSCRIPT NOTICE]\nContext compacted."), "\(reducer.segments)")
    }

    // MARK: - Repeated Handoff

    func testTheTransportOfAnEarlierHandoffIsNotCopiedAgain() {
        let reducer = reduce(
            [
                user("Threading cross-provider continuation bootstrap, not a new user request."),
                .assistantMessage(blocks: [.toolUse(
                    id: "history",
                    tool: .mcp("mcp__threading__conversation_history"),
                    input: [:]
                )]),
                result("history", "<conversation_history>old turn</conversation_history>"),
                assistant("Continuing."),
                user("New question"),
                assistant("New answer"),
            ],
            dropsHandoffTransport: true
        )
        let history = reducer.segments.joined(separator: "\n")

        XCTAssertFalse(history.contains("bootstrap"), history)
        XCTAssertFalse(history.contains("old turn"), history)
        XCTAssertFalse(history.contains("conversation_history"), history)
        XCTAssertTrue(history.contains("[ASSISTANT]\nContinuing."), history)
        XCTAssertTrue(history.contains("[USER]\nNew question"), history)
        XCTAssertTrue(history.contains("[ASSISTANT]\nNew answer"), history)
    }

    func testAFirstHandoffKeepsEverythingItIsGiven() {
        let reducer = reduce(
            [user("Threading cross-provider continuation bootstrap"), assistant("ok")],
            dropsHandoffTransport: false
        )

        XCTAssertEqual(reducer.userMessageCount, 1)
    }

    // MARK: - The Conversation That Set The Numbers

    /// 21 user turns, 81 answers, 302 tool calls and their output — 28 of them at the old 16k
    /// cap, the rest around the median — interleaved as the real rollout was. The old snapshot
    /// of this shape was 992k characters over 24 pages; the reducer's fits three, keeps every
    /// user turn, and drops no dialogue.
    func testTheRealHandoffShapeFitsThreePagesWithEveryUserTurn() throws {
        var events: [StreamEvent] = []
        var call = 0
        for turn in 0..<21 {
            events.append(user("Turn \(turn): " + String(repeating: "u", count: 80)))
            // 302 calls over 21 turns: eight turns of 15 and thirteen of 14, four steps each.
            let callsThisTurn = turn < 8 ? 15 : 14
            for step in 0..<4 {
                events.append(assistant("Answer \(turn).\(step) " + String(repeating: "a", count: 280)))
                let callsThisStep = callsThisTurn / 4 + (step < callsThisTurn % 4 ? 1 : 0)
                for _ in 0..<callsThisStep {
                    let id = "call-\(call)"
                    events.append(bash(id, "rg -n 'pattern-\(call)' Sources | head -40"))
                    let size = call % 11 == 0 ? 16_051 : 2_180
                    events.append(result(id, "output-\(call) " + String(repeating: "o", count: size)))
                    call += 1
                }
            }
        }
        XCTAssertEqual(call, 302)

        let reducer = reduce(events)
        let total = reducer.segments.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, ConversationHandoffBudget.snapshotCharacterLimit)
        XCTAssertEqual(segments(reducer, prefix: "[USER]").count, 21)
        XCTAssertEqual(segments(reducer, prefix: "[ASSISTANT]").count, 84)
        XCTAssertFalse(reducer.wasTruncated)
        XCTAssertFalse(reducer.segments.contains { $0.contains("output-0 ") })
        XCTAssertTrue(reducer.segments.contains { $0.contains("output-301 ") })

        // Through the store and the page, as the destination reads it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-handoff-pages-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sessionID = SessionID()
        try ConversationHandoffStore.save(
            snapshot: ConversationHandoffSnapshot(
                sourceProvider: "Codex",
                sourceTitle: "FWLOGS",
                wasTruncated: reducer.wasTruncated,
                segments: reducer.segments
            ),
            for: sessionID,
            rootDirectory: root
        )
        let url = ConversationHandoffStore.url(for: sessionID, rootDirectory: root)

        var cursor: String?
        var pages = 0
        repeat {
            let page = try ConversationHistoryPage.render(
                snapshotURL: url,
                legacySourceKind: nil,
                legacySourceTitle: "",
                cursor: cursor
            ).get()
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any]
            )
            pages += 1
            cursor = payload["next_cursor"] as? String
        } while cursor != nil && pages < 10

        XCTAssertLessThanOrEqual(pages, 3, "the destination would read \(pages) pages")
    }

    // MARK: - Capture

    func testReducingTheCurrentCodexFixtureKeepsTheConversation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/codex-item-completed.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let (segments, _) = try ConversationHandoffCapture.reduce(
            transcript: url,
            kind: .codex,
            isContinuedSource: false
        ).get()

        XCTAssertFalse(segments.filter { $0.hasPrefix("[USER]") }.isEmpty)
        XCTAssertFalse(segments.filter { $0.hasPrefix("[ASSISTANT]") }.isEmpty)
        XCTAssertLessThanOrEqual(
            segments.reduce(0) { $0 + $1.count },
            ConversationHandoffBudget.snapshotCharacterLimit
        )
    }

    func testTheOpenCodeExportGoesThroughTheSameBudget() throws {
        let export: [String: Any] = [
            "info": ["id": "session"],
            "messages": [
                ["info": ["role": "user"], "parts": [["type": "text", "text": "Question"]]],
                [
                    "info": ["role": "assistant"],
                    "parts": [[
                        "type": "tool", "tool": "read", "id": "prt_1",
                        "state": ["input": ["path": "README"], "output": String(repeating: "c", count: 9_000)]
                    ]]
                ],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: export)
        let history = try ConversationHandoffCapture.openCodeSegments(from: data)

        let results = history.filter { $0.hasPrefix("[TOOL RESULT]") }
        XCTAssertEqual(results.count, 1)
        XCTAssertLessThanOrEqual(results[0].count, ConversationHandoffBudget.toolResultCharacterLimit + 80)
    }
}
