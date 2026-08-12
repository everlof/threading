import Foundation

// MARK: - Turn Outcome

extension TurnOutcome {
    /// Reads the app-server's own `TurnStatus`.
    ///
    /// The mapping lives here rather than on `TurnOutcome` so the neutral type never learns a
    /// provider's spelling — the same boundary `ToolIdentity` keeps. `inProgress` cannot reach
    /// a terminal event and an unknown status is treated as a completion rather than invented
    /// into a failure the user would have to explain.
    init(codexTurnStatus status: String?) {
        switch status {
        case "failed": self = .failed
        case "interrupted": self = .stopped
        default: self = .completed
        }
    }
}

// MARK: - Parent Conversation Adapter

/// Maps app-server notifications onto the same provider-neutral events as Claude's stream.
enum CodexAppServerEvent {

    static func threadID(method: String, parameters: [String: Any]) -> String? {
        if method == "thread/started" {
            return (parameters["thread"] as? [String: Any])?["id"] as? String
        }
        return parameters["threadId"] as? String
    }

    static func streamEvents(
        method: String,
        parameters: [String: Any],
        outputTokens: Int? = nil,
        effort: String? = nil
    ) -> [StreamEvent] {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = parameters["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = parameters["delta"] as? String, !delta.isEmpty else { return [] }
            return [.thinkingDelta(delta)]

        case "item/started":
            guard let item = parameters["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "userMessage" {
                return userMessage(from: item).map { [.userMessage($0)] } ?? []
            }
            guard let block = toolUse(from: item) else { return [] }
            return [.assistantMessage(blocks: [block])]

        case "item/completed":
            guard let item = parameters["item"] as? [String: Any] else { return [] }
            return completed(item)

        case "turn/plan/updated":
            guard let plan = parameters["plan"] as? [[String: Any]] else { return [] }
            var steps: [RunProgress.Step] = []
            steps.reserveCapacity(plan.count)
            for item in plan {
                guard let title = item["step"] as? String,
                      let statusValue = item["status"] as? String,
                      let status = RunProgress.Step.Status(providerValue: statusValue) else {
                    // A partial plan would make both the numerator and denominator plausible
                    // but wrong. Ignore the notification atomically and wait for the next full
                    // snapshot instead.
                    return []
                }
                steps.append(RunProgress.Step(id: nil, title: title, status: status))
            }
            return [.runPlanUpdated(steps)]

        case "turn/completed":
            guard let turn = parameters["turn"] as? [String: Any] else { return [] }
            let status = turn["status"] as? String
            let error = turn["error"] as? [String: Any]
            let duration = integer(turn["durationMs"]).map { TimeInterval($0) / 1_000 }
            let message = error?["message"] as? String
                ?? error?["additionalDetails"] as? String

            // Codex is the one provider that names the three outcomes itself: `TurnStatus` is
            // `completed | interrupted | failed | inProgress`, so nothing has to be inferred
            // from an error channel here.
            return [.turnFinished(
                text: message,
                outcome: TurnOutcome(codexTurnStatus: status),
                metrics: TurnMetrics(
                    duration: duration,
                    outputTokens: outputTokens,
                    effort: effort
                )
            )]

        default:
            return []
        }
    }

    private static func completed(_ item: [String: Any]) -> [StreamEvent] {
        switch item["type"] as? String {
        case "userMessage":
            return userMessage(from: item).map { [.userMessage($0)] } ?? []

        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.text(text)])]

        case "reasoning":
            let sections = (item["summary"] as? [String] ?? [])
                + (item["content"] as? [String] ?? [])
            let text = sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { return [] }
            return [.assistantMessage(blocks: [.thinking(text)])]

        default:
            guard let result = toolResult(from: item) else { return [] }
            return [.toolResults([result])]
        }
    }

    private static func userMessage(from item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { input -> String? in
            guard input["type"] as? String == "text" else { return nil }
            return input["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func toolUse(from item: [String: Any]) -> ContentBlock? {
        guard let id = item["id"] as? String,
              let type = item["type"] as? String else { return nil }

        switch type {
        case "commandExecution":
            return .toolUse(
                id: id,
                tool: .bash,
                input: ["command": .string(item["command"] as? String ?? "")]
            )

        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            return .toolUse(
                id: id,
                tool: .mcp("mcp__\(server)__\(tool)"),
                input: dictionary(item["arguments"])
            )

        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            return .toolUse(
                id: id,
                tool: ToolIdentity(tool),
                input: dictionary(item["arguments"])
            )

        case "fileChange":
            guard let input = JSONValue.object(from: item) else { return nil }
            return .toolUse(id: id, tool: .edit, input: input)

        case "plan":
            guard let input = JSONValue.object(from: item) else { return nil }
            return .toolUse(id: id, tool: .plan, input: input)

        default:
            return nil
        }
    }

    private static func toolResult(from item: [String: Any]) -> ToolResult? {
        guard let id = item["id"] as? String,
              let type = item["type"] as? String,
              toolTypes.contains(type) else { return nil }

        let status = item["status"] as? String
        let exitCode = integer(item["exitCode"])
        let isError = status == "failed" || (exitCode.map { $0 != 0 } ?? false)

        let value: Any?
        switch type {
        case "commandExecution":
            value = item["aggregatedOutput"]
        case "mcpToolCall":
            value = item["result"] ?? item["error"]
        case "dynamicToolCall":
            value = item["contentItems"] ?? item["success"]
        default:
            value = item["changes"] ?? item["text"] ?? item
        }

        return ToolResult(
            toolUseID: id,
            text: value as? String ?? CodexAppServerEnvelope.encodedText(value),
            isError: isError
        )
    }

    private static let toolTypes: Set<String> = [
        "commandExecution", "mcpToolCall", "dynamicToolCall", "fileChange", "plan"
    ]

    private static func dictionary(_ value: Any?) -> [String: JSONValue] {
        if let object = value as? [String: Any] {
            return JSONValue.object(from: object) ?? [:]
        }
        guard let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return JSONValue.object(from: object) ?? [:]
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

// MARK: - Child-Agent Adapter

enum CodexSubagentEvent {

    static func events(
        method: String,
        parameters: [String: Any],
        rootThreadID: String?
    ) -> [SubagentEvent] {
        switch method {
        case "thread/started":
            return threadStarted(parameters, rootThreadID: rootThreadID)

        case "thread/status/changed":
            guard let threadID = parameters["threadId"] as? String,
                  threadID != rootThreadID,
                  let status = parameters["status"] as? [String: Any]
            else { return [] }
            return [.state(
                threadID: threadID,
                status: threadStatus(status),
                message: nil
            )]

        case "item/started", "item/completed":
            guard let item = parameters["item"] as? [String: Any] else { return [] }
            var events = structuralEvents(from: item)

            if let threadID = parameters["threadId"] as? String,
               threadID != rootThreadID {
                for event in CodexAppServerEvent.streamEvents(
                    method: method,
                    parameters: parameters
                ) {
                    events.append(.conversation(threadID: threadID, event: event))
                }
            }
            return events

        case "item/agentMessage/delta",
             "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta",
             "turn/plan/updated":
            guard let threadID = parameters["threadId"] as? String,
                  threadID != rootThreadID else { return [] }
            return CodexAppServerEvent.streamEvents(
                method: method,
                parameters: parameters
            ).map { .conversation(threadID: threadID, event: $0) }

        case "turn/completed":
            guard let threadID = parameters["threadId"] as? String,
                  threadID != rootThreadID else { return [] }
            let turn = parameters["turn"] as? [String: Any]
            let failed = turn?["status"] as? String == "failed"
            let message = (turn?["error"] as? [String: Any])?["message"] as? String
            var events = CodexAppServerEvent.streamEvents(
                method: method,
                parameters: parameters
            ).map { SubagentEvent.conversation(threadID: threadID, event: $0) }
            events.append(.state(
                threadID: threadID,
                status: failed ? .failed : .completed,
                message: message
            ))
            return events

        default:
            return []
        }
    }

    private static func threadStarted(
        _ parameters: [String: Any],
        rootThreadID: String?
    ) -> [SubagentEvent] {
        guard let thread = parameters["thread"] as? [String: Any],
              let threadID = thread["id"] as? String,
              threadID != rootThreadID,
              let parentThreadID = thread["parentThreadId"] as? String
        else { return [] }

        let descriptor = SubagentDescriptor(
            threadID: threadID,
            parentThreadID: parentThreadID,
            nickname: thread["agentNickname"] as? String,
            role: thread["agentRole"] as? String
        )
        let status = (thread["status"] as? [String: Any]).map(threadStatus) ?? .pending
        return [
            .discovered(descriptor),
            .state(threadID: threadID, status: status, message: nil)
        ]
    }

    private static func structuralEvents(from item: [String: Any]) -> [SubagentEvent] {
        switch item["type"] as? String {
        case "collabAgentToolCall":
            return collaborationEvents(from: item)
        case "subAgentActivity":
            return activityEvents(from: item)
        default:
            return []
        }
    }

    private static func collaborationEvents(from item: [String: Any]) -> [SubagentEvent] {
        let receiverIDs = item["receiverThreadIds"] as? [String] ?? []
        let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
        let parentThreadID = item["senderThreadId"] as? String
        let prompt = item["prompt"] as? String
        let model = item["model"] as? String
        let effort = item["reasoningEffort"] as? String

        var events: [SubagentEvent] = []
        for threadID in receiverIDs {
            events.append(.discovered(SubagentDescriptor(
                threadID: threadID,
                parentThreadID: parentThreadID,
                prompt: prompt,
                model: model,
                reasoningEffort: effort
            )))

            let state = states[threadID]
            let status = state.flatMap { $0["status"] as? String }
                .map(collaborationStatus)
                ?? fallbackStatus(item)
            events.append(.state(
                threadID: threadID,
                status: status,
                message: state?["message"] as? String
            ))
        }
        return events
    }

    private static func activityEvents(from item: [String: Any]) -> [SubagentEvent] {
        guard let threadID = item["agentThreadId"] as? String else { return [] }
        let kind = item["kind"] as? String ?? "interacted"
        let status: SubagentStatus = kind == "interrupted" ? .interrupted : .working
        let text: String
        switch kind {
        case "started": text = "Started"
        case "interrupted": text = "Interrupted"
        default: text = "Received new input"
        }

        return [
            // `agentPath` is a logical collaboration address such as
            // `/root/review_pr612_codex`, not a rollout file. Only the stop hook supplies a
            // transcript path that can safely be persisted and replayed.
            .discovered(SubagentDescriptor(threadID: threadID)),
            .state(threadID: threadID, status: status, message: nil),
            .activity(threadID: threadID, text: text)
        ]
    }

    private static func fallbackStatus(_ item: [String: Any]) -> SubagentStatus {
        switch item["status"] as? String {
        case "failed": return .failed
        case "completed": return .completed
        default: return .pending
        }
    }

    private static func collaborationStatus(_ value: String) -> SubagentStatus {
        switch value {
        case "pendingInit": return .pending
        case "running": return .working
        case "completed": return .completed
        case "interrupted": return .interrupted
        case "errored", "notFound": return .failed
        case "shutdown": return .stopped
        default: return .pending
        }
    }

    private static func threadStatus(_ status: [String: Any]) -> SubagentStatus {
        switch status["type"] as? String {
        case "active": return .working
        case "idle": return .completed
        case "systemError": return .failed
        default: return .pending
        }
    }
}
