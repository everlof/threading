import XCTest
@testable import Threading

/// Drives `ConversationTimeline` with real conversations.
///
/// The fixtures under `Tests/Fixtures/Transcripts` are genuine Claude and Codex sessions with
/// their content replaced by `scripts/scrub_transcript.py` — record shapes, markdown structure
/// and diff structure all preserved, names and paths not. Real files matter here because this
/// project has already paid for assuming otherwise twice: a fixed byte cap that silently
/// skipped 62% of Codex rollouts, and an opening turn assumed to be near the top of the file
/// when compaction pushes it past 500 KB.
final class ConversationTimelineTests: XCTestCase {

    // MARK: - Fixtures

    private enum Fixture: String, CaseIterable {
        case claudeEditHeavy = "claude-edit-heavy"
        case claudeToolsAndThinking = "claude-tools-and-thinking"
        case codexExecAndPatch = "codex-exec-and-patch"
        case codexReasoning = "codex-reasoning"

        var kind: AgentKind {
            rawValue.hasPrefix("claude") ? .claude : .codex
        }

        /// Located from `#filePath` rather than the test bundle, so the fixtures need no
        /// membership in the Xcode target and cannot be silently dropped from it.
        var url: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Transcripts/\(rawValue).jsonl")
        }
    }

    private func timeline(for fixture: Fixture) throws -> ConversationTimeline {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "Missing fixture \(fixture.rawValue). Regenerate with scripts/scrub_transcript.py."
        )

        let (events, _) = TranscriptReplay.read(at: fixture.url, kind: fixture.kind)
        XCTAssertFalse(events.isEmpty, "\(fixture.rawValue) produced no events")

        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return timeline
    }

    // MARK: - Shape

    func testEveryFixtureProducesAConversationWithBothVoices() throws {
        for fixture in Fixture.allCases {
            let rows = try timeline(for: fixture).rows

            let users = rows.filter { if case .userMessage = $0 { return true } else { return false } }
            let assistants = rows.filter { if case .assistant = $0 { return true } else { return false } }

            XCTAssertFalse(users.isEmpty, "\(fixture.rawValue) replayed no user turns")
            XCTAssertFalse(assistants.isEmpty, "\(fixture.rawValue) replayed no assistant turns")
        }
    }

    func testNoRowIsRenderedEmpty() throws {
        // An empty row is invisible but still takes its spacing, so it reads as a gap the
        // conversation cannot account for. Both CLIs emit empty text blocks around tool calls.
        for fixture in Fixture.allCases {
            for row in try timeline(for: fixture).rows {
                switch row {
                case .userMessage(let message):
                    XCTAssertFalse(
                        message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(fixture.rawValue) produced an empty row"
                    )
                case .assistant(let text), .thinking(let text), .notice(let text, _):
                    XCTAssertFalse(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(fixture.rawValue) produced an empty row"
                    )
                case .turnOutcome:
                    break
                case .toolCall(let call):
                    XCTAssertFalse(call.name.isEmpty, "\(fixture.rawValue) produced a nameless tool call")
                }
            }
        }
    }

    func testStructuredContextRoundTripsThroughProviderTranscriptText() {
        let attachment = ConversationContextAttachment(
            id: UUID(uuidString: "A9143D6F-B539-468D-8CD7-B244CFC50E26")!,
            kind: .comment,
            source: .code,
            title: "PromptView.swift:42",
            excerpt: "guard canSend else { return }",
            comment: "Should this explain why sending is disabled?",
            locator: "Sources/Threading/UI/Design/PromptView.swift",
            lineStart: 42,
            lineEnd: 42
        )
        let prompt = ConversationPrompt(
            text: "Please update this while keeping the existing behavior.",
            context: [attachment]
        )

        XCTAssertTrue(prompt.transportText.contains("<threading_context_attachments version=\"1\">"))
        XCTAssertEqual(ConversationPrompt.replaying(prompt.transportText), prompt.userMessage)
    }

    func testWorkspaceFileReferenceRoundTripsThroughTranscriptAndRemoteDTO() throws {
        let attachment = ConversationContextAttachment(
            id: UUID(uuidString: "83E6E2B1-BD3A-4E28-84D1-20DFD83F2C99")!,
            kind: .reference,
            source: .workspaceFile,
            title: "PromptView.swift",
            locator: "Sources/Threading/UI/Design/PromptView.swift"
        )
        let prompt = ConversationPrompt(text: "Review this file.", context: [attachment])

        XCTAssertEqual(ConversationPrompt.replaying(prompt.transportText), prompt.userMessage)
        XCTAssertEqual(
            ConversationContextAttachment(remoteDTO: attachment.remoteDTO),
            attachment
        )
        XCTAssertEqual(attachment.remoteDTO.locator, attachment.locator)
        XCTAssertFalse(attachment.remoteDTO.locator?.hasPrefix("/") ?? true)
    }

    func testCommentOnlyPromptGetsReadableFallbackWithoutFlatteningReceipt() {
        let comment = ConversationContextAttachment(
            kind: .comment,
            source: .attachment,
            title: "layout.png",
            comment: "The spacing above the toolbar feels too large.",
            locator: "attachments/layout.png"
        )
        let prompt = ConversationPrompt(text: "", context: [comment])

        XCTAssertEqual(prompt.visibleText, "Please address the comment above.")
        XCTAssertEqual(prompt.userMessage.context, [comment])
        XCTAssertEqual(ConversationPrompt.replaying(prompt.transportText), prompt.userMessage)
    }

    func testMalformedContextMarkerRemainsVisibleUserText() {
        let value = """
            Keep this literal.

            <threading_context_attachments version="1">
            not-json
            </threading_context_attachments>
            """

        XCTAssertEqual(ConversationPrompt.replaying(value), ConversationUserMessage(text: value))
    }

    func testContextBatchIsBoundedAsOneReplayableEnvelope() throws {
        let attachments = (0..<ConversationContextPolicy.maximumAttachments).map { index in
            ConversationContextAttachment(
                kind: .comment,
                source: .attachment,
                title: "large-\(index).txt",
                excerpt: String(repeating: "e", count: ConversationContextPolicy.maximumDetailCharacters),
                comment: String(repeating: "c", count: ConversationContextPolicy.maximumDetailCharacters),
                locator: "attachments/" + String(
                    repeating: "p",
                    count: ConversationContextPolicy.maximumLocatorCharacters
                )
            )
        }
        let prompt = ConversationPrompt(text: "Review these.", context: attachments)
        let encoded = try ConversationContextPolicy.encoder.encode(prompt.context)

        XCTAssertLessThan(prompt.context.count, attachments.count)
        XCTAssertLessThanOrEqual(
            encoded.count,
            ConversationContextPolicy.maximumEnvelopeUTF8Bytes
        )
        XCTAssertEqual(ConversationPrompt.replaying(prompt.transportText), prompt.userMessage)
    }

    // MARK: - Tool Calls

    func testToolResultsAttachToTheirCalls() throws {
        // The whole point of keying by the provider's item id. An agent fires several tools in
        // one turn, so results arrive interleaved and out of order — matching by position would
        // put a command's output under a different command.
        for fixture in Fixture.allCases {
            let calls = try timeline(for: fixture).rows.compactMap { row -> ConversationTimeline.ToolCall? in
                if case .toolCall(let call) = row { return call }
                return nil
            }

            guard !calls.isEmpty else { continue }

            let resolved = calls.filter { $0.result != nil }
            XCTAssertGreaterThan(
                Double(resolved.count) / Double(calls.count), 0.5,
                "\(fixture.rawValue): only \(resolved.count) of \(calls.count) tool calls got a result"
            )
        }
    }

    func testToolCallsCarryAOneLineSubject() throws {
        // The collapsed row shows the glyph, the tool and this. A call with no subject collapses
        // to a bare tool name, which says nothing a reader can act on.
        let calls = try timeline(for: .claudeEditHeavy).rows.compactMap { row -> ConversationTimeline.ToolCall? in
            if case .toolCall(let call) = row { return call }
            return nil
        }

        // Strict: a subject that wraps makes a collapsed row taller than its neighbours, and
        // the whole treatment rests on collapsed rows being one height. A multi-line `cd … &&`
        // command used to do exactly that.
        for call in calls {
            XCTAssertFalse(call.summary.contains("\n"), "\(call.name)'s subject ran to several lines")
        }

        // Tolerant: a tool whose only argument is a code blob — `Workflow` takes a script —
        // genuinely has nothing that reads as a subject, and inventing one from the first line
        // of source says less than the tool's own name does.
        let anonymous = calls.filter { $0.summary.isEmpty }
        XCTAssertLessThanOrEqual(
            Double(anonymous.count), Double(calls.count) * 0.15,
            "\(anonymous.count) of \(calls.count) tool rows had no subject "
            + "(\(Set(anonymous.map(\.name)).sorted()))"
        )
    }

    func testCodexToolCallsAlsoCarryASubject() throws {
        // Regression for the defect this whole exercise found: Codex names its arguments
        // differently from Claude — `cmd`, not `command` — so every replayed `exec_command`
        // rendered as a bare `$ Bash` with nothing beside it. Twenty identical anonymous rows
        // down a conversation, and the parser was correct the whole time.
        for fixture in [Fixture.codexExecAndPatch, .codexReasoning] {
            let calls = try timeline(for: fixture).rows.compactMap { row -> ConversationTimeline.ToolCall? in
                if case .toolCall(let call) = row { return call }
                return nil
            }
            guard !calls.isEmpty else { continue }

            // A tool called with no arguments at all — Codex's `list_agents` — genuinely has
            // no subject, and inventing one would say less than the tool's own name.
            let anonymous = calls.filter { $0.summary.isEmpty }
            XCTAssertLessThanOrEqual(
                Double(anonymous.count), Double(calls.count) * 0.15,
                "\(fixture.rawValue): \(anonymous.count) of \(calls.count) tool rows had no subject "
                + "(\(Set(anonymous.map(\.name)).sorted()))"
            )
        }
    }

    func testCodexPatchesRenderAsDiffsNamingTheirFile() throws {
        // `apply_patch` carries the change already written. It used to arrive as
        // `["input": <the whole patch>]`, so the row had no path and drew no diff — while the
        // diff sat unread in the argument.
        let calls = try timeline(for: .codexExecAndPatch).rows.compactMap { row -> ConversationTimeline.ToolCall? in
            if case .toolCall(let call) = row, call.name == "Edit" { return call }
            return nil
        }

        XCTAssertFalse(calls.isEmpty, "Fixture no longer covers apply_patch")

        for call in calls {
            XCTAssertFalse(call.summary.isEmpty, "A Codex patch named no file")
            let diff = try XCTUnwrap(call.diff, "A Codex patch drew no diff")
            XCTAssertTrue(diff.contains { $0.kind == .added }, "A patch with no additions")
            XCTAssertFalse(
                diff.contains { $0.text.hasPrefix("*** Begin") },
                "The patch envelope leaked into the diff"
            )
        }
    }

    /// Work left running answers "has this session finished", which is the sidebar's question
    /// and the notification's. It is not a row, and a status line claiming otherwise would be
    /// the conversation narrating its own bookkeeping.
    func testBackgroundWorkDrawsNothingInTheConversation() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        let opening = timeline.apply(.userMessage("run the tests in the background"))

        let changes = timeline.apply(.backgroundWork(
            inFlight: [BackgroundTask(id: "b4vc22id4", kind: .standing)]
        ))

        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(timeline.rows.count, opening.count)
    }

    func testPlanCallReportsRunProgressBesideItsToolRow() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        let changes = timeline.apply(.assistantMessage(blocks: [
            .toolUse(
                id: "plan-1",
                tool: .plan,
                input: [
                    "plan": [
                        ["step": "Inspect", "status": "completed"],
                        ["step": "Implement", "status": "in_progress"],
                        ["step": "Verify", "status": "pending"],
                        ["step": "Document", "status": "pending"],
                    ]
                ]
            )
        ]))

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.last, .runProgress(RunProgress(steps: [
            .init(id: nil, title: "Inspect", status: .completed),
            .init(id: nil, title: "Implement", status: .inProgress),
            .init(id: nil, title: "Verify", status: .pending),
            .init(id: nil, title: "Document", status: .pending),
        ])))
    }

    func testClaudeTaskEventsBuildProgressThroughTheOrdinaryTimeline() {
        var timeline = ConversationTimeline(sessionID: SessionID())

        let created = timeline.apply(.assistantMessage(blocks: [
            .toolUse(
                id: "create-1",
                tool: .taskCreate,
                input: ["subject": "Inspect"]
            )
        ]))
        XCTAssertEqual(created.last, .runProgress(RunProgress(steps: [
            .init(id: nil, title: "Inspect", status: .pending),
        ])))

        let bound = timeline.apply(.toolResults([
            ToolResult(
                toolUseID: "create-1",
                text: "Task #1 created successfully: Inspect",
                isError: false
            )
        ]))
        XCTAssertEqual(bound.last, .runProgress(RunProgress(steps: [
            .init(id: "1", title: "Inspect", status: .pending),
        ])))

        let completed = timeline.apply(.assistantMessage(blocks: [
            .toolUse(
                id: "update-1",
                tool: .taskUpdate,
                input: ["taskId": "1", "status": "completed"]
            )
        ]))
        XCTAssertEqual(completed.last, .runProgress(RunProgress(steps: [
            .init(id: "1", title: "Inspect", status: .completed),
        ])))
    }

    func testExplicitEmptyPlanClearsRunProgress() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.runPlanUpdated([
            RunProgress.Step(id: nil, title: "Inspect", status: .inProgress)
        ]))

        XCTAssertEqual(timeline.apply(.runPlanUpdated([])), [.runProgress(nil)])
    }

    func testNoToolSubjectIsRawJSON() throws {
        // The subject exists so a reader is not asked to parse an argument schema before
        // understanding a row. `Read` and Codex's `update_plan` both fell through to the
        // `default:` branch and dumped their arguments verbatim.
        for fixture in Fixture.allCases {
            for row in try timeline(for: fixture).rows {
                guard case .toolCall(let call) = row else { continue }
                XCTAssertFalse(
                    call.summary.hasPrefix("{") || call.summary.hasPrefix("["),
                    "\(call.name) showed raw JSON as its subject: \(call.summary.prefix(60))"
                )
            }
        }
    }

    func testBashCallsShowTheCommandAndEditsShowThePath() throws {
        let calls = try timeline(for: .claudeEditHeavy).rows.compactMap { row -> ConversationTimeline.ToolCall? in
            if case .toolCall(let call) = row { return call }
            return nil
        }

        for call in calls where call.name == "Edit" {
            XCTAssertTrue(
                call.summary.contains("/") || call.summary.contains("."),
                "An Edit's subject should be its file path, got \(call.summary)"
            )
        }
    }

    // MARK: - Diffs

    func testEditsCarryADiffBuiltFromTheirOwnArguments() throws {
        // `EditDiff` reads the call, not the result, so the change is known before the tool
        // runs. If this regresses, edits silently render as plain tool rows.
        var edits = 0

        for fixture in [Fixture.claudeEditHeavy, .claudeToolsAndThinking] {
            for row in try timeline(for: fixture).rows {
                guard case .toolCall(let call) = row,
                      ["Edit", "Write", "MultiEdit"].contains(call.name) else { continue }

                edits += 1
                let diff = try XCTUnwrap(call.diff, "\(call.name) produced no diff")
                XCTAssertFalse(diff.isEmpty, "\(call.name) produced an empty diff")
            }
        }

        XCTAssertGreaterThanOrEqual(edits, 10, "Fixtures no longer cover edits; re-pick them")
    }

    func testSettledTurnRetainsRecordedFileChangesForReplay() {
        let patch = """
        *** Begin Patch
        *** Update File: status.txt
        @@
        -before
        +after
        *** End Patch
        """
        var timeline = ConversationTimeline(sessionID: SessionID())

        _ = timeline.apply(.userMessage("Update status.txt"))
        _ = timeline.apply(.assistantMessage(blocks: [
            .toolUse(
                id: "edit-1",
                tool: .edit,
                input: ["patch": .string(patch)]
            )
        ]))
        _ = timeline.apply(.toolResults([
            ToolResult(toolUseID: "edit-1", text: "Applied patch", isError: false)
        ]))
        _ = timeline.apply(.assistantMessage(blocks: [.text("Updated status.txt.")]))
        _ = timeline.apply(.turnFinished(
            text: nil,
            outcome: .completed,
            metrics: .empty
        ))

        let changes = timeline.fileChanges(inTurnStartingAt: 0)
        XCTAssertEqual(changes.map(\.path), ["status.txt"])
        XCTAssertEqual(changes.flatMap(\.lines).filter { $0.kind == .removed }.map(\.text), ["before"])
        XCTAssertEqual(changes.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["after"])
    }

    func testAnEditDiffContainsBothSides() throws {
        // A diff of only additions is what `Write` produces; an `Edit` that shows no removals
        // means the alignment walk collapsed and the reader cannot see what was replaced.
        let diffs = try timeline(for: .claudeEditHeavy).rows.compactMap { row -> [DiffLine]? in
            guard case .toolCall(let call) = row, call.name == "Edit" else { return nil }
            return call.diff
        }

        XCTAssertFalse(diffs.isEmpty, "No Edit diffs in the fixture")

        let withBothSides = diffs.filter { diff in
            diff.contains { $0.kind == .added } && diff.contains { $0.kind == .removed }
        }
        XCTAssertGreaterThan(withBothSides.count, 0, "No Edit showed both an addition and a removal")
    }

    func testNonEditingToolsGetNoDiff() throws {
        for fixture in Fixture.allCases {
            for row in try timeline(for: fixture).rows {
                guard case .toolCall(let call) = row,
                      ["Bash", "Read", "Grep", "Glob", "exec", "exec_command"].contains(call.name)
                else { continue }

                XCTAssertNil(call.diff, "\(call.name) should not render as a diff")
            }
        }
    }

    // MARK: - Reasoning

    func testCodexReasoningReplaysAsThinkingRows() throws {
        // Codex writes far more reasoning than message, so if these land as ordinary assistant
        // text the conversation reads as the agent talking to itself in its normal voice.
        let rows = try timeline(for: .codexReasoning).rows
        let thinking = rows.filter { if case .thinking = $0 { return true } else { return false } }

        XCTAssertGreaterThan(thinking.count, 5, "Codex reasoning did not replay as thinking rows")
    }

    func testClaudeReasoningCannotReplayBecauseItIsNotWrittenDown() throws {
        // Not a limitation of the parser. Claude Code writes a `thinking` block for every
        // reasoning turn but strips its text, keeping only the `signature`: measured at 4451
        // thinking blocks across the 120 most recent transcripts on this machine, of which 65
        // — 1.5% — carried any text at all. So a replayed Claude conversation shows no
        // reasoning, while a replayed Codex one shows all of it, and the asymmetry is the
        // CLIs', not ours.
        //
        // Pinned as a test because it is invisible otherwise: the code reads as though it
        // renders Claude reasoning, and only real transcripts say that it never gets the
        // chance. If a future release starts persisting the text, this fails and the feature
        // is there to be turned on.
        let url = Fixture.claudeToolsAndThinking.url
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        var blocksInRecord = 0
        JSONLReader.forEachRecord(at: url, limit: 50_000_000) { record in
            guard record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return true }

            blocksInRecord += content.filter { $0["type"] as? String == "thinking" }.count
            return true
        }

        XCTAssertGreaterThan(blocksInRecord, 0, "Fixture has no thinking blocks to reason about")

        let rows = try timeline(for: .claudeToolsAndThinking).rows
        let thinkingRows = rows.filter { if case .thinking = $0 { return true } else { return false } }

        XCTAssertTrue(
            thinkingRows.isEmpty,
            "Claude now persists reasoning text — \(thinkingRows.count) rows from \(blocksInRecord) "
            + "blocks. The transport can show it; enable it and update this test."
        )
    }

    func testEmptyReasoningNeverBecomesAnEmptyRow() {
        // Which is what keeps the above from drawing 115 blank rows down the conversation.
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [.thinking(""), .text("The answer.")]))

        XCTAssertEqual(timeline.rows, [.assistant(markdown: "The answer.")])
    }

    // MARK: - Truncation

    func testLongToolOutputIsCutAndSaysSo() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [
            .toolUse(id: "call-1", tool: .bash, input: ["command": "cat huge.log"])
        ]))
        _ = timeline.apply(.toolResults([
            ToolResult(
                toolUseID: "call-1",
                text: String(repeating: "x", count: ConversationDefaults.toolResultLimit * 2),
                isError: false
            )
        ]))

        guard case .toolCall(let call) = timeline.rows[0], let result = call.result else {
            return XCTFail("Expected a resolved tool call")
        }

        XCTAssertTrue(result.isTruncated)
        XCTAssertLessThan(result.text.count, ConversationDefaults.toolResultLimit + 10)
        XCTAssertTrue(result.text.hasSuffix("…"))
    }

    func testShortToolOutputIsNotMarkedTruncated() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [
            .toolUse(id: "call-1", tool: .bash, input: ["command": "echo hi"])
        ]))
        _ = timeline.apply(.toolResults([
            ToolResult(toolUseID: "call-1", text: "hi\n", isError: false)
        ]))

        guard case .toolCall(let call) = timeline.rows[0], let result = call.result else {
            return XCTFail("Expected a resolved tool call")
        }

        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.text, "hi\n")
    }

    // MARK: - Streaming

    func testAFinishedMessageReplacesWhatWasStreamedForIt() {
        // The finished message is authoritative — reconstructing state from deltas is what the
        // live/replay split already refuses to do.
        var timeline = ConversationTimeline(sessionID: SessionID())

        XCTAssertEqual(timeline.apply(.textDelta("Hel")), [.streaming("Hel")])
        XCTAssertEqual(timeline.apply(.textDelta("lo")), [.streaming("Hello")])

        let changes = timeline.apply(.assistantMessage(blocks: [.text("Hello, world.")]))

        XCTAssertEqual(changes.first, .streaming(nil), "The placeholder was not dropped")
        XCTAssertEqual(timeline.rows, [.assistant(markdown: "Hello, world.")])
        XCTAssertTrue(timeline.streamingText.isEmpty)
    }

    func testAStoppedTurnPreservesItsPartialReplyAndRecordsTheInterruption() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.userMessage("Keep working."))
        _ = timeline.apply(.textDelta("Working until stopped…"))

        let changes = timeline.apply(.turnFinished(
            text: nil,
            outcome: .stopped,
            metrics: .empty
        ))

        XCTAssertEqual(timeline.rows, [
            .userMessage("Keep working."),
            .assistant(markdown: "Working until stopped…"),
            .turnOutcome(.stopped)
        ])
        XCTAssertTrue(timeline.streamingText.isEmpty)
        XCTAssertEqual(changes.prefix(3), [
            .streaming(nil),
            .appended(index: 1),
            .appended(index: 2)
        ])
        XCTAssertTrue(changes.contains(.turnSettled(startIndex: 0, outcome: .stopped)))
    }

    func testTerminalReplySupersedesAnUnfinishedDeltaWithoutDuplicatingIt() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.userMessage("Q"))
        _ = timeline.apply(.textDelta("Draft"))

        _ = timeline.apply(.turnFinished(
            text: "Authoritative answer",
            outcome: .completed,
            metrics: .empty
        ))

        XCTAssertEqual(timeline.rows, [
            .userMessage("Q"),
            .assistant(markdown: "Authoritative answer")
        ])
    }

    func testEmptyTextBlocksAroundToolCallsAddNoRows() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [
            .text(""),
            .toolUse(id: "call-1", tool: .bash, input: ["command": "ls"]),
            .text("")
        ]))

        XCTAssertEqual(timeline.rows.count, 1)
    }

    // MARK: - Orphans

    func testAResultWithNoCallIsShownRatherThanDropped() {
        // The replay window is a rolling cap, so it can cut between a call and its result.
        var timeline = ConversationTimeline(sessionID: SessionID())
        let change = timeline.apply(.toolResults([
            ToolResult(toolUseID: "gone", text: "orphaned output", isError: false)
        ]))

        XCTAssertEqual(change, [.appended(index: 0)])
        XCTAssertEqual(timeline.rows, [.notice("orphaned output", kind: .muted)])
    }

    func testSuccessfulResultFillsCommandOnlyOutputWithoutRepeatingAnAssistantTurn() {
        var succeeded = ConversationTimeline(sessionID: SessionID())
        _ = succeeded.apply(.userMessage("Do the work"))
        _ = succeeded.apply(.assistantMessage(blocks: [.text("All done.")]))
        _ = succeeded.apply(.turnFinished(
            text: "All done.",
            outcome: .completed,
            metrics: .empty
        ))
        XCTAssertEqual(succeeded.rows, [
            .userMessage("Do the work"),
            .assistant(markdown: "All done.")
        ], "A successful model turn repeated its final assistant message")

        var command = ConversationTimeline(sessionID: SessionID())
        _ = command.apply(.turnFinished(
            text: "## Context\n42% remaining",
            outcome: .completed,
            metrics: .empty
        ))
        XCTAssertEqual(command.rows, [
            .assistant(markdown: "## Context\n42% remaining")
        ])

        var failed = ConversationTimeline(sessionID: SessionID())
        _ = failed.apply(.turnFinished(
            text: "Rate limited.",
            outcome: .failed,
            metrics: .empty
        ))
        XCTAssertEqual(failed.rows, [
            .notice("Rate limited.", kind: .error),
            .turnOutcome(.failed)
        ])
    }

    // MARK: - Tool Outcome

    func testAShellFailureIsSniffedFromItsText() {
        // The provider's error flag is not sufficient: a command can print `command not found`
        // and still be reported as a success. The text itself settles the outcome.
        for text in [
            "zsh: command not found: threading-build",
            "ls: /nowhere: No such file or directory",
            "Error: spawn ENOENT",
            "the build step exited with code 2"
        ] {
            XCTAssertEqual(
                ToolOutcome.classify(text: text, isError: false, tool: .bash), .failed,
                "\(text) was not read as a failure"
            )
        }
    }

    func testTheSniffOnlyTrustsAShellsOpeningLines() {
        // Deeper down, the same phrase is as likely quoted output — a grep through a script,
        // a log being catted — as a report about the command itself.
        let buried = "line1\nline2\nline3\nline4: command not found in this prose"
        XCTAssertEqual(ToolOutcome.classify(text: buried, isError: false, tool: .bash), .succeeded)

        // But an explicit exit-code report is specific enough to trust anywhere — except for
        // code 0, which is the shell saying it worked.
        let reported = "…40 lines of output…\nscript exited with exit code 1"
        XCTAssertEqual(ToolOutcome.classify(text: reported, isError: false, tool: .bash), .failed)
        XCTAssertEqual(
            ToolOutcome.classify(text: "exited with code 0", isError: false, tool: .bash),
            .succeeded
        )
    }

    func testFileContentIsNeverSniffed() {
        // A Read or Grep result is arbitrary file content; `No such file or directory` inside
        // it proves nothing about the call that fetched it.
        let text = "zsh: command not found: foo\nls: x: No such file or directory"
        XCTAssertEqual(ToolOutcome.classify(text: text, isError: false, tool: .read), .succeeded)
        XCTAssertEqual(ToolOutcome.classify(text: text, isError: false, tool: .grep), .succeeded)

        // The provider's own flag still fails any tool.
        XCTAssertEqual(ToolOutcome.classify(text: "", isError: true, tool: .read), .failed)
    }

    func testAnUnansweredCallSettlesAsStoppedWhenTheTurnEnds() {
        // A turn can end around a call that never reported back — without a terminal state
        // that row reads "running…" forever.
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [
            .toolUse(id: "call-1", tool: .bash, input: ["command": "sleep 100"])
        ]))
        let changes = timeline.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))

        XCTAssertTrue(changes.contains(.resultAttached(index: 0)))
        guard case .toolCall(let call) = timeline.rows[0] else {
            return XCTFail("The tool row went missing")
        }
        XCTAssertEqual(call.result?.outcome, .interrupted)
    }

    func testALateResultStillLandsOnAStoppedRow() {
        // The interruption placeholder is a guess about a result that may yet arrive; the real
        // one wins.
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.assistantMessage(blocks: [
            .toolUse(id: "call-1", tool: .bash, input: ["command": "make"])
        ]))
        _ = timeline.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))
        let changes = timeline.apply(.toolResults([
            ToolResult(toolUseID: "call-1", text: "ok", isError: false)
        ]))

        XCTAssertEqual(changes.first, .resultAttached(index: 0))
        guard case .toolCall(let call) = timeline.rows[0] else {
            return XCTFail("The tool row went missing")
        }
        XCTAssertEqual(call.result?.outcome, .succeeded)
        XCTAssertEqual(call.result?.text, "ok")
    }

    // MARK: - Turns

    func testATurnKnowsItsExtentAndConclusion() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.userMessage("Fix the bug"))
        _ = timeline.apply(.assistantMessage(blocks: [
            .thinking("hmm"),
            .toolUse(id: "call-1", tool: .bash, input: ["command": "ls"]),
            .text("Considering the layout…")
        ]))
        _ = timeline.apply(.toolResults([
            ToolResult(toolUseID: "call-1", text: "ok", isError: false)
        ]))
        _ = timeline.apply(.assistantMessage(blocks: [.text("Fixed.")]))
        _ = timeline.apply(.userMessage("Thanks"))

        let turns = timeline.turns
        XCTAssertEqual(turns.count, 2)

        // Rows: 0 user, 1 thinking, 2 tool, 3 assistant, 4 assistant, 5 user.
        let first = turns[0]
        XCTAssertEqual(first.rowIndex, 0)
        XCTAssertEqual(first.endIndex, 4)
        XCTAssertEqual(first.finalAssistantIndex, 4)
        XCTAssertEqual(first.assistantText, "Fixed.")
        XCTAssertEqual(timeline.turn(startingAt: 0), first)

        // The turn in flight ends at the newest row and has no conclusion yet.
        let second = turns[1]
        XCTAssertEqual(second.rowIndex, 5)
        XCTAssertEqual(second.endIndex, 5)
        XCTAssertNil(second.finalAssistantIndex)
        XCTAssertEqual(timeline.turn(startingAt: 5), second)
        XCTAssertNil(timeline.turn(startingAt: 2))
    }

    func testATurnRetainsItsDurationFromTheTerminalEvent() {
        // `.turnFinished` metrics used to pass straight through to the status line and be
        // discarded; the fold's "Worked for 42s" is why they are now retained per turn.
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.userMessage("Q"))
        let changes = timeline.apply(.turnFinished(
            text: nil,
            outcome: .completed,
            metrics: TurnMetrics(duration: 42)
        ))

        XCTAssertEqual(timeline.turns.first?.duration, 42)
        XCTAssertTrue(changes.contains(.turnSettled(startIndex: 0, outcome: .completed)))
    }

    func testAnInterruptedTurnSettlesAsInterrupted() {
        // The view keeps an interrupted turn expanded — the user keeps their place — and the
        // change carrying `interrupted` is what tells it to.
        var timeline = ConversationTimeline(sessionID: SessionID())
        _ = timeline.apply(.userMessage("Q"))
        let changes = timeline.apply(.turnFinished(text: nil, outcome: .stopped, metrics: .empty))

        XCTAssertTrue(changes.contains(.turnSettled(startIndex: 0, outcome: .stopped)))
        XCTAssertTrue(timeline.rows.contains(.turnOutcome(.stopped)))
    }

    func testATurnEndWithNoOpenTurnSettlesNothing() {
        // A replay window can open mid-turn: its first synthetic turn end has no user message
        // to attribute to, and must not invent one.
        var timeline = ConversationTimeline(sessionID: SessionID())
        let changes = timeline.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))

        XCTAssertFalse(changes.contains {
            if case .turnSettled = $0 { return true } else { return false }
        })
    }

    func testReplayedTranscriptsCarryTurnEndsWithDurations() throws {
        // Both CLIs stamp every record; replay derives each turn's length from the gap
        // between its opening user record and its last record. Without this, every resumed
        // conversation folds behind a bare "Worked" and unanswered calls read "running…"
        // forever.
        for fixture in Fixture.allCases {
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: fixture.url.path),
                "Missing fixture \(fixture.rawValue). Regenerate with scripts/scrub_transcript.py."
            )
            let (events, _) = TranscriptReplay.read(at: fixture.url, kind: fixture.kind)
            let durations = events.compactMap { event -> TimeInterval? in
                guard case .turnFinished(_, _, let metrics) = event else { return nil }
                return metrics.duration
            }
            XCTAssertFalse(
                durations.isEmpty,
                "\(fixture.rawValue) replayed no measured turn ends"
            )
            XCTAssertTrue(
                durations.allSatisfy { $0 > 0 },
                "\(fixture.rawValue) produced a non-positive turn duration"
            )
        }
    }

    func testReplayedTurnEndsCarryContextReadings() throws {
        // Claude stamps a `usage` object on every assistant record; Codex writes
        // `token_count` records with `model_context_window` beside the counts. Both feed the
        // context meter on a resumed conversation.
        for fixture in Fixture.allCases {
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: fixture.url.path),
                "Missing fixture \(fixture.rawValue). Regenerate with scripts/scrub_transcript.py."
            )
            let (events, _) = TranscriptReplay.read(at: fixture.url, kind: fixture.kind)
            let readings = events.compactMap { event -> (tokens: Int?, window: Int?)? in
                guard case .turnFinished(_, _, let metrics) = event else { return nil }
                return (metrics.contextTokens, metrics.contextWindow)
            }

            XCTAssertTrue(
                readings.contains { ($0.tokens ?? 0) > 0 },
                "\(fixture.rawValue) replayed no context readings"
            )
            if fixture.kind == .codex {
                XCTAssertTrue(
                    readings.contains { $0.window != nil },
                    "\(fixture.rawValue) lost Codex's model_context_window"
                )
            }
        }
    }

    // MARK: - Session Identity

    func testTheCLIsOwnSessionIDIsAdopted() {
        // A resume can settle on an identifier other than the one asked for, and resuming again
        // must use what it actually used.
        var timeline = ConversationTimeline(sessionID: SessionID())
        let transcriptID = TranscriptID("settled-on-this")
        let changes = timeline.apply(.initialised(sessionID: transcriptID, model: "opus"))

        XCTAssertEqual(changes, [
            .adoptedSessionID(transcriptID),
            .status(.ready(model: "opus", lastTurn: nil))
        ])
    }

    func testCodexThreadRestartsDoNotOverwriteWorking() {
        // A resumed transport may restate its thread while a turn is already starting.
        // Reporting Ready there would say the turn had finished while the model was still running.
        var timeline = ConversationTimeline(sessionID: SessionID())
        let transcriptID = TranscriptID("thread-1")
        let changes = timeline.apply(.initialised(sessionID: transcriptID, model: nil))

        XCTAssertEqual(changes, [.adoptedSessionID(transcriptID)])
        XCTAssertFalse(changes.contains { if case .status = $0 { return true } else { return false } })
    }
}
