import Foundation

// MARK: - Structured run-progress hooks

/// The two observations needed to reconstruct a provider-owned checklist.
///
/// Tool use carries every snapshot or mutation. Tool result is retained because Claude assigns
/// a durable TaskCreate identifier only in the result, failed provisional creates must be
/// removed again, and a rejected optimistic TaskUpdate must not remain visible.
enum HookRunProgressPhase: String, CaseIterable, Sendable {
    case toolUse
    case toolResult
    case toolFailure

    var claudeRegistration: HookRegistration {
        switch self {
        case .toolUse:
            return .matched(
                eventNames: ["PreToolUse"],
                tools: ["TodoWrite", "TaskCreate", "TaskUpdate"]
            )
        case .toolResult:
            return .matched(eventNames: ["PostToolUse"], tools: ["TaskCreate", "TaskUpdate"])
        case .toolFailure:
            return .matched(
                eventNames: ["PostToolUseFailure"],
                tools: ["TaskCreate", "TaskUpdate"]
            )
        }
    }

    var codexRegistration: HookRegistration {
        switch self {
        case .toolUse:
            return .matched(eventNames: ["PreToolUse"], tools: ["update_plan"])
        case .toolResult, .toolFailure:
            return .unsupported
        }
    }
}

/// One provider-neutral mutation admitted from a hook payload.
struct HookRunProgressReport: Sendable {
    enum Mutation: Sendable {
        case toolUse(id: String, tool: ToolIdentity, input: [String: JSONValue])
        case result(ToolResult)
    }

    let sessionID: SessionID
    let phase: HookRunProgressPhase
    let mutation: Mutation

    init?(
        sessionID: SessionID,
        phase: HookRunProgressPhase,
        payload: [String: Any]
    ) {
        let id = Self.nonEmpty(
            payload["tool_use_id"] as? String
                ?? payload["toolUseID"] as? String
                ?? payload["tool_call_id"] as? String
                ?? payload["call_id"] as? String
        )
        guard let id else { return nil }

        self.sessionID = sessionID
        self.phase = phase

        switch phase {
        case .toolUse:
            guard let rawName = Self.nonEmpty(
                payload["tool_name"] as? String
                    ?? payload["toolName"] as? String
                    ?? payload["name"] as? String
            ) else { return nil }
            let tool = ToolIdentity(rawName)
            guard tool == .plan || tool == .todoWrite
                    || tool == .taskCreate || tool == .taskUpdate else { return nil }
            let foundationInput = payload["tool_input"] as? [String: Any]
                ?? payload["toolInput"] as? [String: Any]
                ?? payload["input"] as? [String: Any]
                ?? [:]
            self.mutation = .toolUse(
                id: id,
                tool: tool,
                input: JSONValue.convertingObject(from: foundationInput)
            )

        case .toolResult, .toolFailure:
            let value = payload["tool_response"]
                ?? payload["toolResponse"]
                ?? payload["tool_result"]
                ?? payload["result"]
                ?? payload["error"]
            self.mutation = .result(ToolResult(
                toolUseID: id,
                text: Self.text(value),
                isError: phase == .toolFailure || payload["error"] != nil
            ))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// Main-actor bridge between the listener and the runtime that owns terminal controllers.
@MainActor
enum HookRunProgressRelay {
    static var observe: ((HookRunProgressReport) -> Void)?

    static func deliver(_ report: HookRunProgressReport) {
        guard let observe else {
            EventLog.shared.record(.hooks, "Run progress report dropped, no observer", [
                "session": report.sessionID.uuidString,
                "phase": report.phase.rawValue,
            ])
            return
        }
        observe(report)
    }
}
