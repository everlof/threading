import Foundation

/// Maps `codex exec --json` JSONL records onto the provider-neutral events rendered by the
/// native conversation view.
enum CodexStreamEvent {

    static func parse(_ line: String) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            return [.initialised(sessionID: object["thread_id"] as? String, model: nil)]

        case "turn.completed":
            return [.turnFinished(text: nil, isError: false)]

        case "turn.failed":
            return [.turnFinished(text: errorText(in: object), isError: true)]

        case "error":
            return [.turnFinished(text: errorText(in: object), isError: true)]

        case "item.started":
            guard let item = object["item"] as? [String: Any],
                  let block = toolUse(from: item) else { return [] }
            return [.assistantMessage(blocks: [block])]

        case "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            return completed(item)

        default:
            return [.other(type: type)]
        }
    }

    // MARK: - Items

    private static func completed(_ item: [String: Any]) -> [StreamEvent] {
        switch item["type"] as? String {
        case "agent_message":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.text(text)])]

        case "reasoning":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.thinking(text)])]

        default:
            guard let result = toolResult(from: item) else { return [] }
            return [.toolResults([result])]
        }
    }

    private static func toolUse(from item: [String: Any]) -> ContentBlock? {
        guard let id = item["id"] as? String,
              let type = item["type"] as? String else { return nil }

        switch type {
        case "command_execution":
            return .toolUse(
                id: id,
                name: "Bash",
                input: ["command": item["command"] as? String ?? ""]
            )

        case "mcp_tool_call":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? item["name"] as? String ?? "tool"
            return .toolUse(
                id: id,
                name: "mcp__\(server)__\(tool)",
                input: dictionary(item["arguments"])
            )

        case "web_search":
            return .toolUse(
                id: id,
                name: "WebSearch",
                input: ["query": item["query"] as? String ?? ""]
            )

        case "file_change":
            return .toolUse(id: id, name: "Edit", input: item)

        case "plan_update":
            return .toolUse(id: id, name: "Plan", input: item)

        default:
            return nil
        }
    }

    private static func toolResult(from item: [String: Any]) -> ToolResult? {
        guard let id = item["id"] as? String,
              let type = item["type"] as? String,
              toolTypes.contains(type) else { return nil }

        let status = item["status"] as? String
        let exitCode = item["exit_code"] as? Int
        let isError = status == "failed" || (exitCode.map { $0 != 0 } ?? false)

        let text: String
        switch type {
        case "command_execution":
            text = item["aggregated_output"] as? String ?? ""
        case "mcp_tool_call":
            text = resultText(item["result"] ?? item["error"])
        default:
            text = resultText(item["changes"] ?? item["result"] ?? item)
        }

        return ToolResult(toolUseID: id, text: text, isError: isError)
    }

    private static let toolTypes: Set<String> = [
        "command_execution", "mcp_tool_call", "web_search", "file_change", "plan_update"
    ]

    // MARK: - Values

    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        guard let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func resultText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func errorText(in object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? resultText(error)
        }
        return nil
    }
}
