import Foundation

/// Provider-specific extraction of execution facts from native wire objects.
///
/// These adapters do not share the conversation timeline's `ToolIdentity` normalization. The
/// audit keeps the provider's exact operation spelling and decoded JSON payload; only category is
/// a deterministic Threading projection used for filtering.
enum ClaudeProviderExecutionAdapter {
    static func events(line: String) -> [ProviderExecutionEvent] {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              let message = root["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }

        switch type {
        case "assistant":
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_use",
                      let id = block["id"] as? String,
                      let operation = block["name"] as? String,
                      let input = block["input"],
                      let value = JSONValue(foundationValue: input) else { return nil }
                return ProviderExecutionEvent(
                    category: ExecutionAuditStore.category(for: operation),
                    phase: .requested,
                    operation: operation,
                    callID: id,
                    input: value,
                    output: nil,
                    fidelity: .exact
                )
            }

        case "user":
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String else { return nil }
                let output = block["content"].flatMap(JSONValue.init(foundationValue:)) ?? .null
                return ProviderExecutionEvent(
                    category: .tool,
                    phase: (block["is_error"] as? Bool) == true ? .failed : .completed,
                    operation: nil,
                    callID: id,
                    input: nil,
                    output: output,
                    fidelity: .exact
                )
            }

        default:
            return []
        }
    }
}

enum CodexProviderExecutionAdapter {
    private static let toolTypes: Set<String> = [
        "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch",
        "imageView", "collabAgentToolCall", "plan"
    ]

    static func events(method: String, parameters: [String: Any]) -> [ProviderExecutionEvent] {
        guard method == "item/started" || method == "item/completed",
              let item = parameters["item"] as? [String: Any],
              let type = item["type"] as? String,
              toolTypes.contains(type),
              let id = item["id"] as? String,
              let payload = JSONValue(foundationValue: parameters) else { return [] }

        let operation = exactOperation(type: type, item: item)
        let category = category(type: type, operation: operation)
        if method == "item/started" {
            return [ProviderExecutionEvent(
                category: category,
                phase: .requested,
                operation: operation,
                callID: id,
                input: payload,
                output: nil,
                fidelity: .exact
            )]
        }

        let failed = item["status"] as? String == "failed"
            || ((item["exitCode"] as? NSNumber)?.intValue).map { $0 != 0 } == true
        return [ProviderExecutionEvent(
            category: category,
            phase: failed ? .failed : .completed,
            operation: operation,
            callID: id,
            input: nil,
            output: payload,
            fidelity: .exact
        )]
    }

    private static func exactOperation(type: String, item: [String: Any]) -> String {
        switch type {
        case "mcpToolCall", "dynamicToolCall":
            return item["tool"] as? String ?? type
        default:
            return type
        }
    }

    private static func category(
        type: String,
        operation: String
    ) -> ExecutionAuditRecord.Category {
        switch type {
        case "commandExecution": return .shell
        case "fileChange", "imageView": return .filesystem
        case "webSearch": return .network
        case "collabAgentToolCall": return .subagent
        case "plan": return .lifecycle
        default: return ExecutionAuditStore.category(for: operation)
        }
    }
}

/// Serves every Agent Client Protocol CLI, not one vendor's.
///
/// A `tool_call` update names its own tool the same way whichever agent sent it, and the audit
/// category is derived from the neutral `ToolIdentity` rather than from the runtime — so there is
/// nothing here for a second ACP provider to specialize.
enum ACPProviderExecutionAdapter {
    static func event(
        update: [String: Any],
        operation: String,
        kind: String?,
        phase: ExecutionAuditRecord.Phase,
        asInput: Bool
    ) -> ProviderExecutionEvent? {
        guard let callID = update["toolCallId"] as? String,
              let raw = JSONValue(foundationValue: update) else { return nil }
        return ProviderExecutionEvent(
            category: ExecutionAuditStore.category(
                for: ACPWireAdapter.toolIdentity(kind: kind, title: operation).rawName
            ),
            phase: phase,
            operation: operation,
            callID: callID,
            input: asInput ? raw : nil,
            output: asInput ? nil : raw,
            fidelity: .exact
        )
    }
}
