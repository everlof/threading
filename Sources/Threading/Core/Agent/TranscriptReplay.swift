import Foundation

/// Rebuilds a past conversation from the transcript its agent keeps on disk.
///
/// A resumed session picks up with its full context, but the CLI replays none of it down the
/// stream — so without this the agent remembers everything while the screen shows nothing. The
/// terminal never had this problem: its scrollback was the record. Drawing the conversation
/// ourselves means we have to reconstruct it.
///
/// Output is `[StreamEvent]`, deliberately: replayed and live content then travel the same
/// rendering path, and there is no second set of views to keep in step with the first.
enum TranscriptReplay {

    /// Reads a session's transcript off the main thread and calls back with what to render.
    ///
    /// `isTruncated` reports that older turns were dropped, so the view can say so rather than
    /// implying the conversation began where the replay does.
    @MainActor
    static func load(
        for session: AgentSession,
        in project: Project,
        completion: @escaping @MainActor @Sendable (
            _ events: [StreamEvent], _ isTruncated: Bool
        ) -> Void
    ) {
        guard let agentSessionID = session.resumeState.transcriptID else {
            completion([], false)
            return
        }

        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else {
            completion([], false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = SessionTranscript.url(
                sessionID: agentSessionID,
                for: session,
                in: project,
                account: account
            ), FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { completion([], false) }
                return
            }

            let (events, isTruncated) = read(at: url, kind: session.kind)
            DispatchQueue.main.async { completion(events, isTruncated) }
        }
    }

    // MARK: - Private Methods

    /// Reads one transcript file synchronously. Internal rather than private so the tests can
    /// point it at a fixture: `load` needs a real session, a real project and the on-disk
    /// layout of an installed CLI, none of which a test should have to fake to check that a
    /// record maps to the right event.
    static func read(at url: URL, kind: AgentKind) -> ([StreamEvent], Bool) {
        var events: [StreamEvent] = []
        var dropped = 0

        // Both formats stamp every record, and dropping those stamps is what left every
        // replayed turn without an end: nothing on disk says "turn finished", but the gap
        // between a turn's opening user record and its last record does. A synthetic
        // `.turnFinished` per boundary is what lets a resumed conversation fold its settled
        // turns and settle tool calls that never reported back — the same events, so replay
        // and live cannot diverge.
        var turnStartedAt: Date?
        var turnIsOpen = false
        var lastEventAt: Date?
        var lastContextTokens: Int?
        var lastContextWindow: Int?
        // Carried across turns on purpose, like the context readings above: both CLIs restate
        // effort only when a turn reports it, so a turn that reported none ran at whatever the
        // last one did.
        var lastEffort: String?

        func endOpenTurn() {
            guard turnIsOpen else { return }
            turnIsOpen = false

            var metrics = TurnMetrics.empty
            if let started = turnStartedAt, let ended = lastEventAt,
               ended > started {
                metrics.duration = ended.timeIntervalSince(started)
            }
            metrics.contextTokens = lastContextTokens
            metrics.contextWindow = lastContextWindow
            metrics.effort = lastEffort
            events.append(.turnFinished(text: nil, outcome: .completed, metrics: metrics))
        }

        JSONLReader.forEachRecord(at: url, limit: ReplayDefaults.scanLimit) { record in
            // Context facts ride records the event mapping skips — Codex's `token_count`
            // produces no row at all — so they are read before the mapping can bail.
            if let context = contextReading(of: record, kind: kind) {
                lastContextTokens = context.tokens
                if let window = context.window { lastContextWindow = window }
            }
            if let effort = effortReading(of: record, kind: kind) { lastEffort = effort }

            guard let event = self.event(from: record, kind: kind) else { return true }

            if case .userMessage = event {
                endOpenTurn()
                turnIsOpen = true
                turnStartedAt = timestamp(of: record)
            }
            if let stamp = timestamp(of: record) { lastEventAt = stamp }

            events.append(event)

            // A rolling window rather than a head-first cap: what matters in a conversation
            // being resumed is how it ended, not how it began.
            if events.count > ReplayDefaults.maximumEvents {
                events.removeFirst()
                dropped += 1
            }

            return true
        }
        endOpenTurn()

        return (events, dropped > 0)
    }

    /// The assistant prose in the newest transcript turn, in conversational order.
    ///
    /// Terminal TUIs do not necessarily let the emulator perform wrapping. Codex, for example,
    /// lays markdown out to the current width and paints each visual row with cursor movement, so
    /// `BufferLine.isWrapped` cannot reconstruct the source sentence. The transcript is the one
    /// place that still has it intact.
    ///
    /// Reads backwards under a byte budget and stops at the newest real user-message boundary.
    /// Tool results, reasoning and duplicated response-item messages are excluded by the same
    /// provider normalization replay uses, so attachment detection cannot turn incidental tool
    /// output into something the assistant presented to the user.
    static func latestAssistantTexts(
        at url: URL,
        kind: AgentKind,
        scanLimit: Int
    ) -> [String] {
        guard scanLimit > 0 else { return [] }

        var newestFirst: [String] = []
        JSONLReader.forEachRecordFromEnd(at: url, limit: scanLimit) { record in
            guard let event = event(from: record, kind: kind) else { return true }

            switch event {
            case .userMessage:
                return false
            case .assistantMessage(let blocks):
                newestFirst += blocks.reversed().compactMap { block in
                    guard case .text(let text) = block, !text.isEmpty else { return nil }
                    return text
                }
            default:
                break
            }
            return true
        }

        return newestFirst.reversed()
    }

    /// The reasoning effort a turn actually ran at, where the record says.
    ///
    /// Read beside `contextReading` and for the same reason: the fact rides records the event
    /// mapping skips — Codex's `turn_context` produces no row at all — so it has to be taken
    /// before the mapping can bail.
    ///
    /// **This is more authoritative than the launch-time setting.** `AgentModels.defaultEffort`
    /// answers what a session *would* request by reading the account's config, which is the only
    /// answer available before a turn runs; it cannot see a mid-session change, so a conversation
    /// switched with `/effort` replayed at its original setting. The transcript records what each
    /// turn was actually given.
    ///
    /// Claude stamps `effort` at the top level of every assistant record. Sidechains are excluded
    /// on the same rule as the context reading: a subagent's turn is not this conversation's.
    /// Codex writes it as `payload.effort` on a `turn_context` record, and restates it in
    /// `thread_settings` when a setting is applied — the turn's own value is preferred, since the
    /// applied settings describe the thread rather than the turn that followed.
    private static func effortReading(of record: [String: Any], kind: AgentKind) -> String? {
        func nonEmpty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return text
        }

        switch kind {
        case .claude:
            guard record["type"] as? String == "assistant",
                  record["isSidechain"] as? Bool != true
            else { return nil }
            return nonEmpty(record["effort"])

        case .codex:
            guard let payload = record["payload"] as? [String: Any] else { return nil }
            if let effort = nonEmpty(payload["effort"]) { return effort }
            guard let settings = payload["thread_settings"] as? [String: Any] else { return nil }
            return nonEmpty(settings["reasoning_effort"])
        case .grok, .openCode:
            return nil
        }
    }

    /// How full the model's window was as of this record, where the record says.
    ///
    /// Claude writes a `usage` object on every assistant record — `input_tokens` excludes
    /// cache reads, so the parts are summed. Codex writes `token_count` records whose
    /// `last_token_usage.total_tokens` is the most recent request's size (the running
    /// `total_token_usage` exceeds the window on any long session, and must not be used),
    /// with `model_context_window` beside it.
    private static func contextReading(
        of record: [String: Any],
        kind: AgentKind
    ) -> (tokens: Int, window: Int?)? {
        switch kind {
        case .claude:
            guard record["type"] as? String == "assistant",
                  record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return nil }
            let input = (usage["input_tokens"] as? NSNumber)?.intValue
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue
            let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue
            guard input != nil || cacheRead != nil || cacheCreation != nil else { return nil }
            let output = (usage["output_tokens"] as? NSNumber)?.intValue
            let tokens = (input ?? 0) + (cacheRead ?? 0) + (cacheCreation ?? 0) + (output ?? 0)
            return (tokens, nil)

        case .codex:
            guard let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let tokens = (last["total_tokens"] as? NSNumber)?.intValue else { return nil }
            return (tokens, (info["model_context_window"] as? NSNumber)?.intValue)
        case .grok, .openCode:
            return nil
        }
    }

    /// When a record was written. Shared with import, which asks the same question of the same
    /// two formats from the other end of the file.
    private static func timestamp(of record: [String: Any]) -> Date? {
        TranscriptTimestamp.of(record)
    }

    /// Maps one transcript record to something worth drawing, or nil to skip it.
    private static func event(from record: [String: Any], kind: AgentKind) -> StreamEvent? {
        switch kind {
        case .claude:
            return claudeEvent(from: record)
        case .codex:
            return codexEvent(from: record)
        case .grok, .openCode:
            return nil
        }
    }

    /// Maps one Claude transcript record to something worth drawing, or nil to skip it.
    private static func claudeEvent(from record: [String: Any]) -> StreamEvent? {
        // Records Claude writes about itself rather than about the conversation: mode
        // changes, titles, file snapshots, deferred-tool deltas. None of it is dialogue.
        guard let type = record["type"] as? String,
              type == "user" || type == "assistant" else { return nil }

        // `isMeta` marks text the CLI injected on the user's behalf — the local-command
        // caveat, for one — which was never typed and should not appear as though it was.
        guard record["isMeta"] as? Bool != true else { return nil }

        // Sidechains are subagent conversations. They belong to a run of the Task tool, not
        // to this thread, and interleaving them would make the transcript read as nonsense.
        guard record["isSidechain"] as? Bool != true else { return nil }

        guard let message = record["message"] as? [String: Any] else { return nil }

        if type == "assistant" {
            let content = message["content"] as? [[String: Any]] ?? []
            let blocks = content.compactMap(StreamEvent.contentBlock)
            return blocks.isEmpty ? nil : .assistantMessage(blocks: blocks)
        }

        return ClaudeTranscriptUserRecord.event(from: message, scope: .parent)
    }

    /// Codex records dialogue as `event_msg` and tool activity as `response_item`. Response
    /// items also contain copies of messages, so only their tool shapes are accepted here —
    /// otherwise every user and assistant message would be replayed twice.
    static func codexEvent(from record: [String: Any]) -> StreamEvent? {
        guard let recordType = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return nil }

        if recordType == "response_item" {
            return codexToolEvent(from: payload)
        }

        guard recordType == "event_msg",
              let type = payload["type"] as? String else { return nil }

        switch type {
        case CodexDiscoveryDefaults.userMessageType:
            guard let text = payload["message"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .userMessage(trimmed)

        case "agent_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return nil }
            return .assistantMessage(blocks: [.text(text)])

        case "agent_reasoning":
            guard let text = payload["text"] as? String, !text.isEmpty else { return nil }
            return .assistantMessage(blocks: [.thinking(text)])

        default:
            return nil
        }
    }

    /// Rebuilds the tool row Codex showed while the turn was live. Current rollouts persist
    /// orchestrated tools as a call and a later output joined by `call_id`; older function-call
    /// records use the same pairing, so accepting both keeps existing sessions useful too.
    private static func codexToolEvent(from payload: [String: Any]) -> StreamEvent? {
        guard let type = payload["type"] as? String else { return nil }

        switch type {
        case "custom_tool_call", "function_call":
            guard let id = (payload["call_id"] as? String) ?? (payload["id"] as? String),
                  let persistedName = payload["name"] as? String else { return nil }

            let rawInput = payload["input"] ?? payload["arguments"]
            let input = codexToolInput(persistedName: persistedName, value: rawInput)
            guard let typedInput = JSONValue.object(from: input) else { return nil }
            let name = codexToolName(persistedName: persistedName, value: rawInput)
            return .assistantMessage(blocks: [
                .toolUse(id: id, tool: ToolIdentity(name), input: typedInput)
            ])

        case "custom_tool_call_output", "function_call_output":
            guard let id = payload["call_id"] as? String else { return nil }
            let value = payload["output"] ?? payload["result"] ?? payload["error"]
            return .toolResults([
                ToolResult(
                    toolUseID: id,
                    text: codexToolOutput(value),
                    isError: payload["status"] as? String == "failed" || payload["error"] != nil
                )
            ])

        default:
            return nil
        }
    }

    /// Turns Codex's persisted tool name into the vocabulary used by the live stream adapter.
    /// A `custom_tool_call` named `exec` is the orchestration wrapper; the actual tool appears
    /// inside its JavaScript input as `tools.exec_command(...)`.
    private static func codexToolName(persistedName: String, value: Any?) -> String {
        let nestedName = (value as? String).flatMap(codexNestedToolName)

        switch nestedName ?? persistedName {
        case "exec", "exec_command":
            return "Bash"
        case "apply_patch", "file_change":
            return "Edit"
        case "web_search":
            return "WebSearch"
        case "view_image":
            return "Read"
        case "update_plan":
            return "Plan"
        default:
            return nestedName ?? persistedName
        }
    }

    /// Produces the arguments expected by `PermissionRequest.summary` and `EditDiff`, so
    /// replayed rows use the same concise subject line as live ones rather than exposing the
    /// orchestration wrapper.
    ///
    /// **Codex and Claude do not name their arguments alike**, and passing Codex's through
    /// unchanged is why every replayed `exec_command` rendered as a bare `$ Bash` with no
    /// command beside it: the summary reads `command`, Codex writes `cmd`. Found by rendering
    /// a real rollout and looking at it — no parser test could see it, because the parsing was
    /// correct and only the vocabulary was wrong.
    private static func codexToolInput(persistedName: String, value: Any?) -> [String: Any] {
        let raw: [String: Any]

        if let dictionary = value as? [String: Any] {
            raw = dictionary
        } else if let text = value as? String, let dictionary = jsonDictionary(text) {
            raw = dictionary
        } else if let text = value as? String {
            // `apply_patch` is not JSON at all: its argument is the patch itself.
            if persistedName == "apply_patch" || persistedName == "file_change" {
                return CodexPatch.toolInput(patch: text)
            }
            switch codexNestedToolName(text) {
            case "exec_command" where persistedName == "exec":
                if let command = javascriptStringProperty("cmd", in: text) {
                    return ["command": command]
                }
            case "apply_patch", "file_change":
                // The wrapper assigns the patch to a variable and passes it positionally —
                // `const patch = "*** Begin Patch…"; text(await tools.apply_patch(patch))` —
                // so there is no property to read it from. Found by the render harness: these
                // edits drew no path and no diff, while `apply_patch` called directly did.
                if let patch = javascriptPatchLiteral(in: text) {
                    return CodexPatch.toolInput(patch: patch)
                }
            default:
                break
            }
            return ["input": text]
        } else {
            return [:]
        }

        return normalised(raw, persistedName: persistedName)
    }

    /// Renames Codex's arguments to the ones the renderer already understands, leaving the rest
    /// in place so nothing is lost for tools with no rule.
    private static func normalised(
        _ input: [String: Any],
        persistedName: String
    ) -> [String: Any] {
        var input = input

        if let command = input["cmd"] as? String {
            input["command"] = command
        }
        if let path = (input["path"] ?? input["file_path"]) as? String {
            input["file_path"] = path
        }
        if let patch = input["patch"] as? String {
            return CodexPatch.toolInput(patch: patch)
        }
        if let query = (input["query"] ?? input["q"]) as? String {
            input["query"] = query
        }

        return input
    }

    private static func codexNestedToolName(_ source: String) -> String? {
        firstCapture(#"tools\.([A-Za-z0-9_]+)\s*\("#, in: source)
    }

    /// The patch inside a generated wrapper, found by what it *is* rather than by the name it
    /// was bound to — the variable is arbitrary, but a patch always opens `*** Begin Patch`.
    private static func javascriptPatchLiteral(in source: String) -> String? {
        let pattern = #"("\*\*\* Begin Patch(?:\\.|[^"\\])*")"#
        guard let literal = firstCapture(pattern, in: source),
              let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// Extracts a JSON-style quoted string from the generated JavaScript and lets JSONDecoder
    /// handle escapes. If Codex changes wrapper syntax, the row still renders with raw input.
    private static func javascriptStringProperty(_ property: String, in source: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        let pattern = #"\b"# + escapedProperty + #"\s*:\s*("(?:\\.|[^"\\])*")"#
        guard let literal = firstCapture(pattern, in: source),
              let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func jsonDictionary(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Tool output can be a string or a sequence of typed text blocks. Blocks already carry
    /// their own newlines, so concatenate rather than inserting formatting Codex did not emit.
    private static func codexToolOutput(_ value: Any?) -> String {
        if let text = value as? String { return text }

        if let blocks = value as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined()

            // The orchestration layer prefixes command output with its own completion and
            // timing lines. Live structured Codex events expose only the aggregated output, so
            // remove that envelope to keep a replayed row identical to the one originally shown.
            if text.hasPrefix("Script completed\n"),
               let marker = text.range(of: "\nOutput:\n") {
                return String(text[marker.upperBound...])
            }

            return text
        }

        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

}

// MARK: - Claude User Records

/// Separates user dialogue from the XML-shaped control records Claude persists as user messages.
///
/// This is deliberately an allowlist at the transcript boundary, not an XML cleaner. Unknown
/// tags remain literal user text. Known envelopes are accepted only in the complete shapes
/// measured from Claude 2.1.220 transcripts, so code, HTML and a user-authored `<word>` cannot
/// disappear merely because it uses angle brackets.
enum ClaudeTranscriptUserRecord {

    enum Scope {
        case parent
        case child
    }

    /// A user record is either something typed, a batch of tool results, or provider chrome.
    static func event(
        from message: [String: Any],
        scope: Scope
    ) -> StreamEvent? {
        if let content = message["content"] as? [[String: Any]] {
            let results = content.compactMap(StreamEvent.toolResult)
            if !results.isEmpty { return .toolResults(results) }
        }

        guard let text = text(from: message) else { return nil }
        switch presentation(of: text, scope: scope) {
        case .user(let value):
            return .userMessage(value)
        case .notice(let value):
            return .transcriptNotice(value)
        case .suppressed:
            return nil
        }
    }

    /// The actual task prompt from a child's opening record, with Claude's fork instructions
    /// removed. Used by the cheap metadata index without replaying the whole conversation.
    static func userText(from message: [String: Any]) -> String? {
        guard let text = text(from: message),
              case .user(let value) = presentation(of: text, scope: .child) else {
            return nil
        }
        return value
    }

    private enum Presentation {
        case user(String)
        case notice(String)
        case suppressed
    }

    private static func text(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            return nonempty(text)
        }

        guard let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        return nonempty(content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n"))
    }

    private static func presentation(
        of text: String,
        scope: Scope
    ) -> Presentation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fork children receive 928 characters of provider instructions followed by the real
        // task in the same text block. Dropping the record loses the task; stripping any other
        // leading tag risks deleting user content. It is child-only as well as shape-specific:
        // a parent user is still free to discuss this literal tag.
        if scope == .child, let fork = consumeLeadingEnvelope(
            tag: "fork-boilerplate",
            from: trimmed
        ) {
            return nonempty(fork.remainder).map(Presentation.user) ?? .suppressed
        }

        // A local slash command is one record containing these three envelopes in this order.
        // Its name is useful history; its transport message and arguments are not another turn.
        if let name = consumeLeadingEnvelope(tag: "command-name", from: trimmed),
           let message = consumeLeadingEnvelope(
               tag: "command-message",
               from: name.remainder
           ),
           let arguments = consumeLeadingEnvelope(
               tag: "command-args",
               from: message.remainder
           ),
           nonempty(arguments.remainder) == nil {
            guard let command = nonempty(name.body) else { return .user(trimmed) }
            let invocation = nonempty(arguments.body)
                .map { "\(command) \($0)" }
                ?? command
            return .notice(invocation)
        }

        // Some Claude releases persist the message/arguments half separately. It duplicates
        // the command-name record above and has no standalone conversational meaning.
        if let message = consumeLeadingEnvelope(tag: "command-message", from: trimmed),
           let arguments = consumeLeadingEnvelope(
               tag: "command-args",
               from: message.remainder
           ),
           nonempty(arguments.remainder) == nil {
            return .suppressed
        }

        // These are complete provider control records. Structured live adapters already turn
        // task notifications into lifecycle events; command output and reminders are CLI chrome.
        for tag in [
            "task-notification",
            "local-command-stdout",
            "local-command-caveat",
            "system-reminder"
        ] {
            if let envelope = consumeLeadingEnvelope(tag: tag, from: trimmed),
               nonempty(envelope.remainder) == nil {
                return .suppressed
            }
        }

        return .user(trimmed)
    }

    private static func consumeLeadingEnvelope(
        tag: String,
        from text: String
    ) -> (body: String, remainder: String)? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<\(tag)>"
        let closing = "</\(tag)>"
        guard candidate.hasPrefix(opening),
              let closingRange = candidate.range(
                  of: closing,
                  range: candidate.index(
                      candidate.startIndex,
                      offsetBy: opening.count
                  )..<candidate.endIndex
              ) else {
            return nil
        }

        let bodyStart = candidate.index(
            candidate.startIndex,
            offsetBy: opening.count
        )
        let body = String(candidate[bodyStart..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(candidate[closingRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, remainder)
    }

    private static func nonempty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Replay Defaults

enum ReplayDefaults {
    /// Read the whole file rather than a prefix: the end of a conversation is what is wanted,
    /// and it is by definition at the end.
    static let scanLimit = 64 * 1024 * 1024

    /// Rendered items kept. Each is a view, so a very long conversation would otherwise cost
    /// thousands of them at launch for turns nobody is going to scroll back to.
    static let maximumEvents = 400
}
