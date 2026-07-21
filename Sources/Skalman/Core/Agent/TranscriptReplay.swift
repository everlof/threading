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
    static func load(
        for session: AgentSession,
        in project: Project,
        completion: @escaping (_ events: [StreamEvent], _ isTruncated: Bool) -> Void
    ) {
        guard let agentSessionID = session.agentSessionID else {
            completion([], false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = transcriptURL(
                sessionID: agentSessionID,
                for: session,
                in: project
            ), FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { completion([], false) }
                return
            }

            let (events, isTruncated) = read(at: url, kind: session.kind)
            DispatchQueue.main.async { completion(events, isTruncated) }
        }
    }

    // MARK: - Private Methods

    private static func transcriptURL(
        sessionID: String,
        for session: AgentSession,
        in project: Project
    ) -> URL? {
        switch session.kind {
        case .claude:
            return ClaudeTranscript.url(sessionID: sessionID, for: session, in: project)
        case .codex:
            return CodexTranscript.url(sessionID: sessionID, for: session)
        case .shell:
            return nil
        }
    }

    private static func read(at url: URL, kind: AgentKind) -> ([StreamEvent], Bool) {
        var events: [StreamEvent] = []
        var dropped = 0

        JSONLReader.forEachRecord(at: url, limit: ReplayDefaults.scanLimit) { record in
            guard let event = self.event(from: record, kind: kind) else { return true }

            events.append(event)

            // A rolling window rather than a head-first cap: what matters in a conversation
            // being resumed is how it ended, not how it began.
            if events.count > ReplayDefaults.maximumEvents {
                events.removeFirst()
                dropped += 1
            }

            return true
        }

        return (events, dropped > 0)
    }

    /// Maps one transcript record to something worth drawing, or nil to skip it.
    private static func event(from record: [String: Any], kind: AgentKind) -> StreamEvent? {
        switch kind {
        case .claude:
            return claudeEvent(from: record)
        case .codex:
            return codexEvent(from: record)
        case .shell:
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

        return userEvent(from: message)
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
            let name = codexToolName(persistedName: persistedName, value: rawInput)
            return .assistantMessage(blocks: [.toolUse(id: id, name: name, input: input)])

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

    /// Produces the arguments expected by `PermissionRequest.summary`, so replayed rows use the
    /// same concise subject line as live ones rather than exposing the orchestration wrapper.
    private static func codexToolInput(persistedName: String, value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }

        guard let text = value as? String else { return [:] }
        if let dictionary = jsonDictionary(text) { return dictionary }

        if persistedName == "exec", codexNestedToolName(text) == "exec_command",
           let command = javascriptStringProperty("cmd", in: text) {
            return ["command": command]
        }

        return ["input": text]
    }

    private static func codexNestedToolName(_ source: String) -> String? {
        firstCapture(#"tools\.([A-Za-z0-9_]+)\s*\("#, in: source)
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
            // timing lines. Live `codex exec --json` exposes only `aggregated_output`, so remove
            // that envelope to keep a replayed row identical to the one originally shown.
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

    /// A user record is either something typed or a batch of tool results, and the two are
    /// told apart by shape: plain text for the first, `tool_result` blocks for the second.
    private static func userEvent(from message: [String: Any]) -> StreamEvent? {
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .userMessage(trimmed)
        }

        guard let content = message["content"] as? [[String: Any]] else { return nil }

        let results = content.compactMap(StreamEvent.toolResult)
        if !results.isEmpty { return .toolResults(results) }

        // A typed turn can also arrive as text blocks rather than a bare string.
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : .userMessage(text)
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
