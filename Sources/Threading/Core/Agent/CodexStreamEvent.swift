import Foundation

/// Maps `codex exec --json` JSONL records onto the provider-neutral events rendered by the
/// native conversation view.
enum CodexStreamEvent {

    static func parse(_ line: String) -> StreamLineParseResult {
        guard let data = line.data(using: .utf8),
              let wire = try? JSONDecoder().decode(CodexWireEvent.self, from: data)
        else { return .malformed }

        switch wire.type {
        case "thread.started":
            return .events([.initialised(
                sessionID: wire.threadID.map(TranscriptID.init),
                model: nil
            )])

        case "turn.completed":
            return .events([.turnFinished(
                text: nil,
                isError: false,
                metrics: TurnMetrics(outputTokens: wire.usage?.outputTokens)
            )])

        case "turn.failed", "error":
            return .events([.turnFinished(
                text: errorText(in: wire),
                isError: true,
                metrics: TurnMetrics(outputTokens: wire.usage?.outputTokens)
            )])

        case "item.started":
            guard let item = wire.item else { return .malformed }
            guard let block = toolUse(from: item) else {
                return .events([.unknown(type: "item.started:\(item.type ?? "unknown")")])
            }
            return .events([.assistantMessage(blocks: [block])])

        case "item.completed":
            guard let item = wire.item else { return .malformed }
            return .events(completed(item))

        default:
            return .events([.unknown(type: wire.type)])
        }
    }

    // MARK: - Items

    private static func completed(_ item: CodexWireItem) -> [StreamEvent] {
        switch item.type {
        case "agent_message":
            guard let text = item.string("text"), !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.text(text)])]

        case "reasoning":
            guard let text = item.string("text"), !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.thinking(text)])]

        default:
            guard let result = toolResult(from: item) else {
                return [.unknown(type: "item.completed:\(item.type ?? "unknown")")]
            }
            return [.toolResults([result])]
        }
    }

    private static func toolUse(from item: CodexWireItem) -> ContentBlock? {
        guard let id = item.string("id"), let type = item.type else { return nil }

        switch type {
        case "command_execution":
            return .toolUse(
                id: id,
                tool: .bash,
                input: ["command": .string(item.string("command") ?? "")]
            )

        case "mcp_tool_call":
            let server = item.string("server") ?? "mcp"
            let tool = item.string("tool") ?? item.string("name") ?? "tool"
            return .toolUse(
                id: id,
                tool: .mcp("mcp__\(server)__\(tool)"),
                input: arguments(from: item.value("arguments"))
            )

        case "web_search":
            return .toolUse(
                id: id,
                tool: .webSearch,
                input: ["query": .string(item.string("query") ?? "")]
            )

        case "file_change":
            return .toolUse(id: id, tool: .edit, input: item.values)

        case "plan_update":
            return .toolUse(id: id, tool: .plan, input: item.values)

        default:
            return nil
        }
    }

    private static func toolResult(from item: CodexWireItem) -> ToolResult? {
        guard let id = item.string("id"),
              let type = item.type,
              toolTypes.contains(type) else { return nil }

        let status = item.string("status")
        let exitCode = item.integer("exit_code")
        let isError = status == "failed" || (exitCode.map { $0 != 0 } ?? false)

        let value: JSONValue?
        switch type {
        case "command_execution":
            value = item.value("aggregated_output")
        case "mcp_tool_call":
            value = item.value("result") ?? item.value("error")
        default:
            value = item.value("changes") ?? item.value("result") ?? item.rawValue
        }

        return ToolResult(
            toolUseID: id,
            text: resultText(value),
            isError: isError
        )
    }

    private static let toolTypes: Set<String> = [
        "command_execution", "mcp_tool_call", "web_search", "file_change", "plan_update"
    ]

    // MARK: - Values

    private static func arguments(from value: JSONValue?) -> [String: JSONValue] {
        if let object = value?.objectValue { return object }
        guard let text = value?.stringValue,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [:] }
        return decoded.objectValue ?? [:]
    }

    private static func resultText(_ value: JSONValue?) -> String {
        if let text = value?.stringValue { return text }
        return value?.encodedText(prettyPrinted: true) ?? ""
    }

    private static func errorText(in event: CodexWireEvent) -> String? {
        if let message = event.message { return message }
        if let error = event.error?.stringValue { return error }
        if let message = event.error?.objectValue?["message"]?.stringValue { return message }
        guard let error = event.error else { return nil }
        let text = error.encodedText(prettyPrinted: true)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Codex Wire Models

private struct CodexWireEvent: Decodable {
    let type: String
    let threadID: String?
    let item: CodexWireItem?
    let message: String?
    let error: JSONValue?
    let usage: CodexWireUsage?

    private enum CodingKeys: String, CodingKey {
        case type, item, message, error, usage
        case threadID = "thread_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        threadID = try? container.decode(String.self, forKey: .threadID)
        item = try? container.decode(CodexWireItem.self, forKey: .item)
        message = try? container.decode(String.self, forKey: .message)
        error = try? container.decode(JSONValue.self, forKey: .error)
        usage = try? container.decode(CodexWireUsage.self, forKey: .usage)
    }
}

private struct CodexWireUsage: Decodable {
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
    }
}

private struct CodexWireItem: Decodable {
    let values: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let values) = value else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Codex item must be a JSON object"
                )
            )
        }
        self.values = values
    }

    var type: String? { string("type") }
    var rawValue: JSONValue { .object(values) }
    var foundationObject: [String: Any] { values.mapValues(\.foundationValue) }

    func value(_ key: String) -> JSONValue? {
        values[key]
    }

    func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    func integer(_ key: String) -> Int64? {
        guard case .integer(let value) = values[key] else { return nil }
        return value
    }
}
