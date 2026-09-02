import XCTest
@testable import Threading

/// The two shapes Codex has written its dialogue in, and the tripwire for a third.
///
/// The rule under test came from measuring, not from a changelog: 963 rollouts on one machine
/// showed `user_message`/`agent_message` events up to 0.146, `item_completed` items from 0.147,
/// and nothing but items from 0.150.1. Threading read only the first shape, so for a month every
/// newer Codex conversation replayed as tool rows with no text, and a cross-provider handoff
/// froze 992k characters of tool output without one user message. This class exists so the next
/// shape is a failing test and a visible notice rather than a silent month.
final class CodexRolloutFormatTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func rollout(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/\(name).jsonl")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Missing fixture \(name). Regenerate with scripts/scrub_transcript.py."
        )
        return url
    }

    // Records shaped exactly as a 0.151 rollout writes them, content aside.

    private func meta(version: String) -> String {
        #"{"timestamp":"2026-08-31T18:25:05.950Z","type":"session_meta","payload":{"id":"01a05911-5f71-7902-b293-d2439a7dc5f1","timestamp":"2026-08-31T18:25:05.950Z","cwd":"/tmp/project","originator":"codex-tui","cli_version":"\#(version)","source":"cli"}}"#
    }

    private func item(_ body: String, ordinal: Int = 9) -> String {
        #"{"timestamp":"2026-08-31T18:25:10.483Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":\#(body),"started_at_ms":1,"completed_at_ms":2}}"#
    }

    private func userItem(_ text: String) -> String {
        item(#"{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"\#(text)","text_elements":[]}]}"#)
    }

    private func agentItem(_ text: String) -> String {
        item(#"{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"\#(text)"}],"phase":"final_answer"}"#)
    }

    private func reasoningItem(summaries: [String]) -> String {
        let list = summaries.map { "\"\($0)\"" }.joined(separator: ",")
        return item(#"{"type":"Reasoning","id":"rs_1","summary_text":[\#(list)],"raw_content":[]}"#)
    }

    private func compactionItem() -> String {
        item(#"{"type":"ContextCompaction","id":"c1"}"#)
    }

    private func commandItem() -> String {
        item(#"{"type":"CommandExecution","id":"exec-1","command":["/bin/bash","-lc","pwd"],"cwd":"file:///tmp","status":"completed","aggregated_output":"/tmp","exit_code":0}"#)
    }

    /// The model-visible history copy of a message: kept in every format so far, and the
    /// reference the probe compares the reduction against.
    private func historyMessage(role: String, _ text: String) -> String {
        let blockType = role == "assistant" ? "output_text" : "input_text"
        return #"{"timestamp":"2026-08-31T18:25:13.784Z","ordinal":13,"type":"response_item","payload":{"type":"message","id":"msg_1","role":"\#(role)","content":[{"type":"\#(blockType)","text":"\#(text)"}]}}"#
    }

    private func unknownItem(type: String, _ text: String) -> String {
        item(#"{"type":"\#(type)","id":"x1","content":[{"type":"Text","text":"\#(text)"}]}"#)
    }

    private func toolCall() -> String {
        #"{"timestamp":"2026-08-31T18:25:36.609Z","ordinal":39,"type":"response_item","payload":{"type":"custom_tool_call","id":"ct_1","status":"completed","call_id":"call_1","name":"exec","input":"text(await tools.exec_command({cmd: \"pwd\"}))"}}"#
    }

    private func toolOutput() -> String {
        #"{"timestamp":"2026-08-31T18:25:36.700Z","ordinal":40,"type":"response_item","payload":{"type":"custom_tool_call_output","id":"cto_1","call_id":"call_1","output":[{"type":"input_text","text":"/tmp"}]}}"#
    }

    // MARK: - Helpers

    private func userTexts(_ events: [StreamEvent]) -> [String] {
        events.compactMap { if case .userMessage(let text) = $0 { return text } else { return nil } }
    }

    private func assistantTexts(_ events: [StreamEvent]) -> [String] {
        events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
        }
    }

    private func thinking(_ events: [StreamEvent]) -> [String] {
        events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { if case .thinking(let text) = $0 { return text } else { return nil } }
        }
    }

    private func notices(_ events: [StreamEvent]) -> [String] {
        events.compactMap { if case .transcriptNotice(let text) = $0 { return text } else { return nil } }
    }

    // MARK: - The Current Shape

    func testItemCompletedUserAndAgentMessagesReplayAsDialogueOnce() throws {
        let url = try rollout([
            meta(version: "0.151.0"),
            userItem("Rename the chat"),
            historyMessage(role: "user", "Rename the chat"),
            agentItem("Done."),
            historyMessage(role: "assistant", "Done."),
        ])

        let replay = TranscriptReplay.replay(at: url, kind: .codex)

        // The history copies must not double the conversation: one turn each.
        XCTAssertEqual(userTexts(replay.events), ["Rename the chat"])
        XCTAssertEqual(assistantTexts(replay.events), ["Done."])
        XCTAssertEqual(replay.format, .recognised)
        XCTAssertTrue(notices(replay.events).isEmpty, "\(notices(replay.events))")
    }

    func testReasoningItemReplaysItsSummaryAsThinkingAndAnEmptyOneAsNothing() throws {
        let url = try rollout([
            meta(version: "0.151.0"),
            userItem("Go"),
            reasoningItem(summaries: []),
            reasoningItem(summaries: ["Checking the branch", "Then the tests"]),
            agentItem("Both fine."),
        ])

        let events = TranscriptReplay.replay(at: url, kind: .codex).events

        XCTAssertEqual(thinking(events), ["Checking the branch\n\nThen the tests"])
        XCTAssertEqual(assistantTexts(events), ["Both fine."])
    }

    func testContextCompactionItemReplaysTheLiveStreamsNotice() throws {
        let url = try rollout([meta(version: "0.151.0"), userItem("Go"), compactionItem(), agentItem("On.")])

        let events = TranscriptReplay.replay(at: url, kind: .codex).events

        XCTAssertEqual(notices(events), [L10n.string("Context compacted.")])
    }

    func testToolShapedItemsMapToNothingBecauseTheirResponseItemsReplayThem() throws {
        let url = try rollout([
            meta(version: "0.151.0"),
            userItem("Where am I"),
            toolCall(),
            commandItem(),
            toolOutput(),
            agentItem("In /tmp."),
        ])

        let events = TranscriptReplay.replay(at: url, kind: .codex).events

        let toolRows = events.filter { event in
            guard case .assistantMessage(let blocks) = event else { return false }
            return blocks.contains { if case .toolUse = $0 { return true } else { return false } }
        }
        XCTAssertEqual(toolRows.count, 1, "the CommandExecution item drew a second row for one call")
        XCTAssertEqual(assistantTexts(events), ["In /tmp."])
    }

    func testResponseItemMessagesRemainIgnoredInTheNewShapeToo() throws {
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(historyMessage(role: "user", "typed").utf8)
            ) as? [String: Any]
        )

        XCTAssertNil(TranscriptReplay.codexEvent(from: record))
    }

    // MARK: - Both Fixtures

    func testTheLegacyAndCurrentFixturesBothReplayBothVoices() throws {
        for name in ["codex-exec-and-patch", "codex-item-completed"] {
            let replay = TranscriptReplay.replay(at: try fixture(name), kind: .codex)

            XCTAssertFalse(userTexts(replay.events).isEmpty, "\(name) replayed no user turns")
            XCTAssertFalse(assistantTexts(replay.events).isEmpty, "\(name) replayed no answers")
            XCTAssertEqual(replay.format, .recognised, name)
        }
    }

    /// The fixture says which release wrote it, and the pin in code is not allowed to fall behind
    /// the evidence on disk.
    func testTheCurrentFixtureIsWithinTheVerifiedRange() throws {
        let url = try fixture("codex-item-completed")
        var cliVersion: String?
        JSONLReader.forEachRecord(at: url, limit: 64 * 1024) { record in
            guard record["type"] as? String == CodexRolloutFormat.RecordType.sessionMeta,
                  let payload = record["payload"] as? [String: Any] else { return true }
            cliVersion = payload[CodexRolloutFormat.Key.cliVersion] as? String
            return false
        }

        let version = try XCTUnwrap(cliVersion, "the fixture lost its session_meta")
        XCTAssertEqual(
            version.compare(CodexRolloutFormat.newestVerifiedCLIVersion, options: .numeric),
            .orderedAscending,
            "\(version) is newer than the verified \(CodexRolloutFormat.newestVerifiedCLIVersion); bump the pin"
        )
        XCTAssertEqual(
            CodexRolloutFormat.oldestVerifiedCLIVersion.compare(version, options: .numeric),
            .orderedAscending
        )
    }

    // MARK: - The Tripwire

    func testAThirdDialogueShapeIsReportedWhereTheConversationShouldBe() throws {
        let url = try rollout([
            meta(version: "0.199.0"),
            historyMessage(role: "user", "Question"),
            unknownItem(type: "Utterance", "Answer"),
            historyMessage(role: "assistant", "Answer"),
        ])

        let replay = TranscriptReplay.replay(at: url, kind: .codex)

        XCTAssertEqual(replay.format, .codexDialogueUnreadable(CodexRolloutFormatDrift(
            cliVersion: "0.199.0",
            unfamiliarItemTypes: ["Utterance"],
            unreadAssistantMessages: 1
        )))
        XCTAssertTrue(assistantTexts(replay.events).isEmpty, "an unknown item was drawn as text")
        let first = try XCTUnwrap(replay.events.first)
        guard case .transcriptNotice(let notice) = first else {
            return XCTFail("the notice was not the first thing drawn: \(first)")
        }
        XCTAssertTrue(notice.contains("0.199.0"), notice)
    }

    func testAnUnreadableFileWithoutAVersionStillSaysSo() throws {
        let url = try rollout([
            historyMessage(role: "assistant", "Answer"),
            unknownItem(type: "Utterance", "Answer"),
        ])

        let replay = TranscriptReplay.replay(at: url, kind: .codex)

        guard case .codexDialogueUnreadable(let drift)? = replay.format else {
            return XCTFail("\(String(describing: replay.format))")
        }
        XCTAssertNil(drift.cliVersion)
        XCTAssertFalse(drift.notice.isEmpty)
        XCTAssertTrue(drift.refusal.contains("Codex"), drift.refusal)
    }

    /// A spawned sub-agent's rollout carries its brief as a user-role history message and has no
    /// `UserMessage` item. 18 measured 0.150+ files were that shape, and each was correct.
    func testASubAgentRolloutWithABriefAndNoUserItemIsRecognised() throws {
        let url = try rollout([
            meta(version: "0.151.0"),
            historyMessage(role: "user", "Brief from the parent"),
            agentItem("Working on it."),
            historyMessage(role: "assistant", "Working on it."),
        ])

        let replay = TranscriptReplay.replay(at: url, kind: .codex)

        XCTAssertEqual(replay.format, .recognised)
        XCTAssertTrue(notices(replay.events).isEmpty)
    }

    func testAToolOnlyRolloutHasNothingToMisreadAndIsRecognised() throws {
        let url = try rollout([meta(version: "0.151.0"), toolCall(), toolOutput()])

        XCTAssertEqual(TranscriptReplay.replay(at: url, kind: .codex).format, .recognised)
    }

    func testAClaudeTranscriptHasNoProbeYet() throws {
        let url = try rollout([
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"1","timestamp":"2026-08-31T18:25:05.950Z"}"#
        ])

        XCTAssertNil(TranscriptReplay.replay(at: url, kind: .claude).format)
    }

    // MARK: - Consumers

    func testTheHandoffRefusesAnUnreadableTranscriptInsteadOfFreezingToolOutput() throws {
        let url = try rollout([
            meta(version: "0.199.0"),
            historyMessage(role: "user", "Question"),
            toolCall(),
            toolOutput(),
            historyMessage(role: "assistant", "Answer"),
        ])

        let result = ConversationHandoffCapture.reduce(
            transcript: url,
            kind: .codex,
            isContinuedSource: false
        )

        guard case .failure(let error) = result else {
            return XCTFail("a snapshot of tool output alone was accepted")
        }
        XCTAssertEqual(error.code, .transcriptFormatUnreadable)
        XCTAssertTrue(error.message.contains("0.199.0"), error.message)
    }

    func testTheImportTitleReadsTheTypedUserTurnInTheCurrentShape() throws {
        let url = try rollout([
            meta(version: "0.151.0"),
            historyMessage(role: "user", "<environment_context>injected preamble</environment_context>"),
            userItem("Investigate the flaky login test"),
            agentItem("Looking."),
        ])

        let title = try XCTUnwrap(SessionImporter.codexTitle(at: url))

        XCTAssertTrue(title.localizedCaseInsensitiveContains("flaky"), title)
        XCTAssertFalse(title.contains("environment_context"), title)
    }

    // MARK: - Opt-in Audit

    /// Runs the reader over the newest rollouts on this machine and fails if any parent thread's
    /// dialogue could not be read. Skipped unless asked for: it reads the developer's own
    /// conversations, and it is the step that earns a bump of `newestVerifiedCLIVersion`.
    func testLocalRolloutsOfTheInstalledCodexReplayTheirDialogue() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_CODEX_ROLLOUT_AUDIT"] == "1",
            "Set THREADING_CODEX_ROLLOUT_AUDIT=1 to audit ~/.codex/sessions against the reader."
        )
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))
        let rollouts = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == CodexDiscoveryDefaults.rolloutExtension }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
            .prefix(40)
        try XCTSkipIf(rollouts.isEmpty, "No Codex rollouts under \(root.path)")

        var unreadable: [String] = []
        var newestVersion = CodexRolloutFormat.newestVerifiedCLIVersion
        for url in rollouts {
            let replay = TranscriptReplay.replay(at: url, kind: .codex)
            if case .codexDialogueUnreadable(let drift)? = replay.format {
                unreadable.append("\(url.lastPathComponent) cli=\(drift.cliVersion ?? "?") "
                    + "items=\(drift.unfamiliarItemTypes)")
            }
            var version: String?
            JSONLReader.forEachRecord(at: url, limit: CodexDiscoveryDefaults.headerReadLimit) { record in
                guard record["type"] as? String == CodexRolloutFormat.RecordType.sessionMeta else {
                    return true
                }
                version = (record["payload"] as? [String: Any])?[CodexRolloutFormat.Key.cliVersion] as? String
                return false
            }
            if let version, version.compare(newestVersion, options: .numeric) == .orderedDescending {
                newestVersion = version
            }
        }

        XCTAssertTrue(unreadable.isEmpty, "Dialogue unreadable in:\n" + unreadable.joined(separator: "\n"))
        print("Codex rollout audit: \(rollouts.count) rollouts read, newest cli_version \(newestVersion), "
            + "verified through \(CodexRolloutFormat.newestVerifiedCLIVersion)")
    }
}
