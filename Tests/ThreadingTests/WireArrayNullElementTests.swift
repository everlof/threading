import XCTest
@testable import Threading

/// Pins what the Claude and ACP readers do with a JSON array holding an element they cannot read.
///
/// **Every fixture here is JSON text.** A Swift array literal cannot hold the value this whole
/// file is about: `null` bridges to `NSNull`, which only `JSONSerialization` produces, and
/// `[["type": "text"], NSNull()]` is not something anyone writes by hand. That is exactly how the
/// boolean defect in `3277a3a0` stayed invisible to a suite full of literal-built payloads, so
/// nothing below is built from one — the fixtures are rendered to text and parsed back, or
/// written to a `.jsonl` file and replayed, the way the provider delivers them.
///
/// The defect: `value as? [[String: Any]]` is all-or-nothing. One `NSNull` answers `nil` for the
/// *whole* array rather than for the element, so a `null` beside an assistant's text lost the
/// turn, a `null` beside a tool result lost every result, and a number in `skills` lost every
/// skill name. `WireList` keeps the readable elements and counts what it dropped; two sites keep
/// refusing on purpose and are pinned here as deliberate.
///
/// **This file owns the Claude/ACP/Grok half.** `WireArrayNullRecoveryTests` owns the other one —
/// the Codex app-server, hook, usage, model-catalog and tool-input readers — and labels each case
/// RECOVERS or REFUSES, because that half is where both answers sit side by side. The split is by
/// reader, not by helper: one `WireList` serves both files, and the two never assert the same site.
final class WireArrayNullElementTests: XCTestCase {

    // MARK: - The Cast Itself

    func testTheStrictCastLosesEveryReadableElementForOneNull() throws {
        let elements = try Self.array(#"[{"type":"text","text":"kept"},null]"#)
        XCTAssertEqual(elements.count, 2)

        XCTAssertNil(
            elements as? [[String: Any]],
            "one NSNull answers nil for the whole array, not for the element"
        )

        let recovered = try XCTUnwrap(
            WireList.objects(elements, site: "test.objects", log: ThreadingLogger.agent)
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?["text"] as? String, "kept")
    }

    func testTheStrictCastLosesEveryStringForOneNumber() throws {
        let elements = try Self.array(#"["research","review",7]"#)
        XCTAssertNil(elements as? [String], "one number answers nil for every name")
        XCTAssertEqual(
            WireList.stringsIfListed(elements, site: "test.strings", log: ThreadingLogger.agent),
            ["research", "review"]
        )
    }

    /// A list with nothing readable in it is not answered as an empty list.
    ///
    /// The difference matters wherever an empty list is itself a statement: `{"commands":["ctx"]}`
    /// must not empty a composer catalogue that a malformed message never described.
    func testAListWithNoReadableElementIsNotAnEmptyList() throws {
        let log = ThreadingLogger.agent
        XCTAssertNil(
            WireList.objectsIfListed(try Self.array(#"["ctx"]"#), site: "test.listed", log: log)
        )
        XCTAssertNil(
            WireList.stringsIfListed(try Self.array("[1,2]"), site: "test.listed", log: log)
        )

        XCTAssertEqual(
            WireList.objectsIfListed(try Self.array("[]"), site: "test.listed", log: log)?.count, 0
        )
        XCTAssertEqual(
            WireList.stringsIfListed(try Self.array("[]"), site: "test.listed", log: log), []
        )

        XCTAssertNil(WireList.objects("not an array", site: "test.listed", log: log))
        XCTAssertNil(WireList.objectsIfListed("not an array", site: "test.listed", log: log))
        XCTAssertNil(WireList.stringsIfListed("not an array", site: "test.listed", log: log))
    }

    /// The recovering pair answers `[]` for the very lists the `…IfListed` pair answers nil for.
    ///
    /// Both behaviours are load-bearing and they are one keyword apart, so the difference is
    /// asserted on the same two fixtures rather than left to the two names to imply.
    func testTheRecoveringPairAnswersAnEmptyListWhereTheListedPairAnswersNothing() throws {
        let log = ThreadingLogger.agent
        XCTAssertEqual(
            WireList.objects(try Self.array(#"["ctx"]"#), site: "test.recovering", log: log)?.count,
            0
        )
        XCTAssertEqual(
            WireList.strings(try Self.array("[1,2]"), site: "test.recovering", log: log),
            []
        )

        XCTAssertNil(WireList.strings("not an array", site: "test.recovering", log: log))
    }

    // MARK: - Claude Transcript Replay

    func testANullBesideAssistantTextKeepsTheTurn() throws {
        let events = try Self.replay(kind: .claude, named: "assistant-null", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"text","text":"kept"},null]}}
        """#)

        let texts = events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { block in
                guard case .text(let value) = block else { return nil }
                return value
            }
        }
        XCTAssertEqual(texts, ["kept"], "the whole turn used to vanish for the null")
    }

    func testANullBesideAToolResultKeepsTheResult() throws {
        let events = try Self.replay(kind: .claude, named: "tool-result-null", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"user","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},null]}}
        """#)

        let results = events.flatMap { event -> [ToolResult] in
            guard case .toolResults(let values) = event else { return [] }
            return values
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.toolUseID, "t1")
        XCTAssertEqual(results.first?.text, "ok")
    }

    func testANullBesideATypedPromptKeepsWhatWasTyped() throws {
        let events = try Self.replay(kind: .claude, named: "user-text-null", #"""
        {"type":"user","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"text","text":"do the thing"},null]}}
        """#)

        let typed = events.compactMap { event -> String? in
            guard case .userMessage(let text) = event else { return nil }
            return text
        }
        XCTAssertEqual(typed, ["do the thing"], "the prompt used to disappear from the replay")
    }

    func testANullInsideAToolResultsOwnBlocksKeepsItsText() throws {
        let events = try Self.replay(kind: .claude, named: "result-blocks-null", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"user","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"line"},null]}]}}
        """#)

        let results = events.flatMap { event -> [ToolResult] in
            guard case .toolResults(let values) = event else { return [] }
            return values
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "line", "the row used to draw with no output at all")
    }

    // MARK: - Codex Transcript Replay

    func testANullInsideCodexToolOutputKeepsTheTextBlocks() throws {
        let record = try Self.object(#"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{
         "type":"function_call_output","call_id":"c1",
         "output":[{"type":"text","text":"hello"},null]}}
        """#)
        guard case .toolResults(let results)? = TranscriptReplay.codexEvent(from: record),
              let result = results.first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertEqual(result.toolUseID, "c1")
        XCTAssertEqual(result.text, "hello")
    }

    /// A JSON array of scalars is not tool output written as typed blocks, and still falls
    /// through to the raw dump rather than being answered as an empty string.
    func testAScalarArrayOfCodexToolOutputStillFallsThroughToTheDump() throws {
        let record = try Self.object(#"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{
         "type":"function_call_output","call_id":"c1","output":[1,2]}}
        """#)
        guard case .toolResults(let results)? = TranscriptReplay.codexEvent(from: record),
              let result = results.first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertTrue(result.text.contains("1"), "got \(result.text)")
        XCTAssertTrue(result.text.contains("2"), "got \(result.text)")
    }

    // MARK: - The Execution Ledger

    func testANullInLedgerContentStillFilesTheToolCall() throws {
        let events = ClaudeProviderExecutionAdapter.events(line: Self.line(#"""
        {"type":"assistant","message":{"content":[
         {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},null]}}
        """#))

        XCTAssertEqual(events.count, 1, "the whole line used to file no events at all")
        XCTAssertEqual(events.first?.callID, "t1")
        XCTAssertEqual(events.first?.operation, "Bash")
        guard case .object(let input)? = events.first?.input else {
            return XCTFail("expected an object input, got \(String(describing: events.first?.input))")
        }
        XCTAssertEqual(input["command"], .string("ls"))
    }

    func testANullInLedgerContentStillFilesTheToolResult() throws {
        let events = ClaudeProviderExecutionAdapter.events(line: Self.line(#"""
        {"type":"user","message":{"content":[
         {"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"},null]}}
        """#))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.callID, "t1")
        XCTAssertEqual(events.first?.output, .string("boom"))
    }

    // MARK: - The Claude Command Catalogue

    func testANumberAmongTheSkillsKeepsEverySkillName() {
        let update = ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"init","slash_commands":["a","b"],"skills":["b",7]}"#
        )
        XCTAssertEqual(update?.commandNames, ["a", "b"])
        XCTAssertEqual(update?.skillNames, ["b"], "the readable skill name is kept")
    }

    func testANullAmongTheSlashCommandsKeepsTheReadableOnes() {
        let update = ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"init","slash_commands":["a",null],"skills":["b"]}"#
        )
        XCTAssertEqual(update?.commandNames, ["a"])
        XCTAssertEqual(update?.skillNames, ["b"])
    }

    func testANullAmongChangedCommandsKeepsTheReadableOnes() {
        let update = ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"commands_changed","commands":[{"name":"ctx","description":"Context"},null]}"#
        )
        XCTAssertEqual(update?.commands?.count, 1)
        XCTAssertEqual(update?.commands?.first?.name, "ctx")
        XCTAssertEqual(update?.commands?.first?.description, "Context")
    }

    func testANullAmongACommandsAliasesKeepsTheReadableOnes() {
        let update = ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"commands_changed","commands":[{"name":"ctx","aliases":["c",7]}]}"#
        )
        XCTAssertEqual(update?.commands?.first?.aliases, ["c"])
    }

    /// A list of bare strings is not a command catalogue, and still leaves the catalogue alone
    /// rather than emptying it.
    func testAScalarCommandsArrayIsStillNoAnswerAtAll() {
        XCTAssertNil(ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"commands_changed","commands":["ctx"]}"#
        ))
        XCTAssertNil(ClaudeCapabilityWire.commands(from: ["commands": ["ctx"]]))
    }

    // MARK: - Grok's Opening Catalogue

    func testANullAmongGroksAdvertisedCommandsKeepsTheReadableOnes() throws {
        let result = try Self.object(#"""
        {"_meta":{"availableCommands":[{"name":"compact","description":"Compact"},null]}}
        """#)
        let commands = try XCTUnwrap(GrokACPExtensions.availableCommands(in: result))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["name"] as? String, "compact")

        let capabilities = ACPWireAdapter.composerCapabilities(
            from: commands,
            policy: GrokACPComposerCatalog.policy
        )
        XCTAssertEqual(capabilities.map(\.name), ["compact"])
    }

    /// Nil, not an empty catalogue: the caller reads an answer here as "the opening catalogue has
    /// arrived", and an empty one would mark it ready with nothing in it.
    func testAScalarAvailableCommandsArrayIsNoCatalogueAtAll() throws {
        let result = try Self.object(#"{"_meta":{"availableCommands":["compact"]}}"#)
        XCTAssertNil(GrokACPExtensions.availableCommands(in: result))
    }

    // MARK: - Claude Subagents

    func testANullBesideAChildsLastToolCallStillReadsAsStopped() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Self.write(#"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","agentId":"agent-child","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},null]}}
        """#, to: directory, named: "agent-child.jsonl")

        let events = ClaudeSubagentTranscriptReplay.index(
            rootThreadID: "root", directory: directory
        )
        let statuses = events.compactMap { event -> SubagentStatus? in
            guard case .state(_, let status, _) = event else { return nil }
            return status
        }
        XCTAssertEqual(
            statuses, [.stopped],
            "a child that ended mid-tool used to be reported as completed"
        )
    }

    func testANullBesideAChildsTextKeepsTheChildTurn() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.write(#"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"text","text":"child said this"},null]}}
        """#, to: directory, named: "agent-child.jsonl")

        let replay = ClaudeSubagentTranscriptReplay.readConversation(at: url)
        let texts = replay.events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { block in
                guard case .text(let value) = block else { return nil }
                return value
            }
        }
        XCTAssertEqual(texts, ["child said this"])
    }

    // MARK: - The Failure Sentence

    func testANullBesideAnAPIErrorsWordsKeepsTheWords() throws {
        let record = try Self.object(#"""
        {"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed",
         "message":{"content":[{"type":"text","text":"Login expired · Please run /login"},null]}}
        """#)
        let failure = try XCTUnwrap(ClaudeTranscriptAPIError.parse(record))
        XCTAssertEqual(failure.reason, "authentication_failed")
        XCTAssertEqual(
            failure.text, "Login expired · Please run /login",
            "the record still stated the failure; only its sentence was being deleted"
        )
    }

    // MARK: - Deliberately Strict

    /// The interrupt marker is classified by "one text block and *nothing else*", so recovering
    /// the readable elements would report an interrupt nobody pressed. This refusal is on
    /// purpose; the control below proves the reader works on the shape it is for.
    func testAnInterruptMarkerBesideAnUnreadableElementIsNotAnInterrupt() throws {
        let clean = try Self.object(#"""
        {"type":"user","uuid":"u1","message":{"content":[
         {"type":"text","text":"[Request interrupted by user]"}]}}
        """#)
        XCTAssertNotNil(ClaudeTranscriptInterruption.interruption(in: clean))

        let withNull = try Self.object(#"""
        {"type":"user","uuid":"u2","message":{"content":[
         {"type":"text","text":"[Request interrupted by user]"},null]}}
        """#)
        XCTAssertNil(
            ClaudeTranscriptInterruption.interruption(in: withNull),
            "\"and nothing else\" is the classification; a recovered list would fake it"
        )
    }

    // MARK: - Helpers

    /// One JSON value, parsed from text the way the provider delivers it.
    private static func value(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func array(_ text: String) throws -> [Any] {
        try XCTUnwrap(value(text) as? [Any])
    }

    private static func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(value(text) as? [String: Any])
    }

    /// One transcript line, with the newlines a multi-line fixture carries removed — the readers
    /// under test are handed one line at a time by the framer.
    private static func line(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "")
    }

    private static func replay(
        kind: AgentKind, named name: String, _ text: String
    ) throws -> [StreamEvent] {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write(text, to: directory, named: "\(name).jsonl")
        let (events, _) = TranscriptReplay.read(at: url, kind: kind)
        return events
    }

    /// Always newline-terminated: `JSONLReader` withholds a final record with no newline,
    /// because a resumable reader cannot tell the end of a file from a line still being written.
    private static func write(_ text: String, to directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let terminated = text.hasSuffix("\n") ? text : text + "\n"
        try terminated.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wire-array-null-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
