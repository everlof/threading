import Foundation

/// The routing decision for one Claude `stream-json` line.
///
/// Claude forwards child output over the parent's stdout and distinguishes it with
/// `parent_tool_use_id`. The line must therefore be classified before the ordinary parser sees
/// it: parent lines still build the parent conversation, while child lines build only the
/// corresponding subagent conversation.
struct ClaudeSubagentRoute {
    let belongsToParent: Bool
    let events: [SubagentEvent]
}

/// Projects Claude's Agent/Task lifecycle onto the provider-neutral subagent timeline.
///
/// The Agent tool-use id is the stable UI identity. Background launches additionally introduce
/// an `agentId` and structured task lifecycle messages introduce a `task_id`; both are aliases
/// mapped back to the tool-use id so launch, transcript, progress, and completion never split
/// into separate rows.
struct ClaudeSubagentEventAdapter {

    private var trackedTaskIDs: Set<String> = []
    private var orderedTaskIDs: [String] = []
    private var finishedTaskIDs: Set<String> = []
    private var taskIDByAgentID: [String: String] = [:]
    private var taskIDByRuntimeTaskID: [String: String] = [:]
    private var parentThreadIDByTaskID: [String: String] = [:]

    mutating func reset() {
        trackedTaskIDs.removeAll(keepingCapacity: true)
        orderedTaskIDs.removeAll(keepingCapacity: true)
        finishedTaskIDs.removeAll(keepingCapacity: true)
        taskIDByAgentID.removeAll(keepingCapacity: true)
        taskIDByRuntimeTaskID.removeAll(keepingCapacity: true)
        parentThreadIDByTaskID.removeAll(keepingCapacity: true)
    }

    mutating func route(_ line: String) -> ClaudeSubagentRoute? {
        guard let data = line.data(using: .utf8),
              let wire = try? JSONDecoder().decode(ClaudeSubagentWireEvent.self, from: data)
        else { return nil }

        let parentToolUseID = nonempty(wire.parentToolUseID)
        let belongsToParent = parentToolUseID == nil
        var events = lifecycleEvents(from: wire)

        if let childTaskID = parentToolUseID {
            let parentThreadID = parentThreadIDByTaskID[childTaskID]
            events.append(contentsOf: discover(
                SubagentDescriptor(
                    threadID: childTaskID,
                    parentThreadID: parentThreadID,
                    nickname: nonempty(wire.taskDescription),
                    role: nonempty(wire.subagentType),
                    model: nonempty(wire.message?.model)
                )
            ))

            if !finishedTaskIDs.contains(childTaskID) {
                events.append(.state(threadID: childTaskID, status: .working, message: nil))
            }

            if case .events(let streamEvents) = StreamEvent.parse(line) {
                events.append(contentsOf: streamEvents.compactMap { event in
                    guard !event.isUnknown else { return nil }
                    return .conversation(threadID: childTaskID, event: event)
                })
            }
        }

        guard let message = wire.message else {
            return ClaudeSubagentRoute(belongsToParent: belongsToParent, events: events)
        }

        if wire.type == "assistant" {
            events.append(contentsOf: taskLaunchEvents(
                from: message,
                currentTaskID: parentToolUseID,
                sessionID: nonempty(wire.sessionID)
            ))
        } else if wire.type == "user" {
            events.append(contentsOf: taskResultEvents(from: message, metadata: wire.toolUseResult))
            events.append(contentsOf: notificationEvents(from: message))
        }

        return ClaudeSubagentRoute(belongsToParent: belongsToParent, events: events)
    }

    mutating func terminationEvents(status: Int32) -> [SubagentEvent] {
        let terminalStatus: SubagentStatus = status == 0 ? .stopped : .failed
        let activity = status == 0
            ? "Stopped when the Claude session ended"
            : "Failed when the Claude session exited"

        var events: [SubagentEvent] = []
        for taskID in orderedTaskIDs where !finishedTaskIDs.contains(taskID) {
            finishedTaskIDs.insert(taskID)
            events.append(contentsOf: [
                .state(threadID: taskID, status: terminalStatus, message: nil),
                .activity(threadID: taskID, text: activity)
            ])
        }
        return events
    }

    // MARK: - Structured Lifecycle

    private mutating func lifecycleEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        if wire.type == "tool_progress" {
            return toolProgressEvents(from: wire)
        }

        guard wire.type == "system", let subtype = wire.subtype else { return [] }
        switch subtype {
        case "task_started":
            return taskStartedEvents(from: wire)
        case "task_progress":
            return taskProgressEvents(from: wire)
        case "task_updated":
            return taskUpdatedEvents(from: wire)
        case "task_notification":
            return taskNotificationEvents(from: wire)
        default:
            return []
        }
    }

    private mutating func taskStartedEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        let isAgentTask = wire.taskType.map {
            $0 == "local_agent" || $0 == "remote_agent"
        }

        // Background Bash and Monitor tasks use the same lifecycle messages. An explicit
        // non-agent type must never become a child row; an older event with no type is accepted
        // only when its tool-use id is already known from an Agent launch.
        if isAgentTask == false { return [] }

        guard let taskID = resolvedTaskID(
            toolUseID: wire.toolUseID,
            runtimeTaskID: wire.taskID,
            mayDiscover: isAgentTask == true
        ) else { return [] }

        if let runtimeTaskID = nonempty(wire.taskID) {
            taskIDByRuntimeTaskID[runtimeTaskID] = taskID
        }

        var events = discover(SubagentDescriptor(
            threadID: taskID,
            nickname: nonempty(wire.description),
            role: nonempty(wire.subagentType)
        ))
        events.append(.state(threadID: taskID, status: .working, message: nil))
        events.append(.progress(
            threadID: taskID,
            progress: SubagentProgress(taskID: nonempty(wire.taskID))
        ))
        return events
    }

    private mutating func taskProgressEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        guard let taskID = resolvedTaskID(
            toolUseID: wire.toolUseID,
            runtimeTaskID: wire.taskID,
            mayDiscover: nonempty(wire.subagentType) != nil
        ) else { return [] }

        if let runtimeTaskID = nonempty(wire.taskID) {
            taskIDByRuntimeTaskID[runtimeTaskID] = taskID
        }

        var events = discover(SubagentDescriptor(
            threadID: taskID,
            nickname: nonempty(wire.description),
            role: nonempty(wire.subagentType)
        ))
        events.append(.state(threadID: taskID, status: .working, message: nil))
        events.append(.progress(
            threadID: taskID,
            progress: progress(from: wire)
        ))
        return events
    }

    private mutating func taskUpdatedEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        guard let taskID = resolvedTaskID(
            toolUseID: wire.toolUseID,
            runtimeTaskID: wire.taskID,
            mayDiscover: false
        ) else { return [] }

        var events = discover(SubagentDescriptor(
            threadID: taskID,
            nickname: nonempty(wire.patch?.description)
        ))
        events.append(.progress(
            threadID: taskID,
            progress: SubagentProgress(
                taskID: nonempty(wire.taskID),
                isBackgrounded: wire.patch?.isBackgrounded
            )
        ))

        if let wireStatus = wire.patch?.status {
            let status = notificationStatus(wireStatus)
            let message = status == .failed ? nonempty(wire.patch?.error) : nil
            events.append(.state(threadID: taskID, status: status, message: message))
            if status.isDone {
                finishedTaskIDs.insert(taskID)
                events.append(.activity(
                    threadID: taskID,
                    text: message ?? notificationActivity(status)
                ))
            }
        }
        return events
    }

    private mutating func taskNotificationEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        guard let taskID = resolvedTaskID(
            toolUseID: wire.toolUseID,
            runtimeTaskID: wire.taskID,
            mayDiscover: false
        ) else { return [] }

        let status = notificationStatus(wire.status)
        let summary = nonempty(wire.summary)
        var events = discover(SubagentDescriptor(threadID: taskID))
        events.append(.progress(
            threadID: taskID,
            progress: progress(from: wire)
        ))
        events.append(.state(
            threadID: taskID,
            status: status,
            message: status == .failed ? summary : nil
        ))
        events.append(.activity(
            threadID: taskID,
            text: summary ?? notificationActivity(status)
        ))
        if status.isDone {
            finishedTaskIDs.insert(taskID)
        }
        return events
    }

    private mutating func toolProgressEvents(
        from wire: ClaudeSubagentWireEvent
    ) -> [SubagentEvent] {
        let taskID: String?
        if let parentToolUseID = nonempty(wire.parentToolUseID),
           trackedTaskIDs.contains(parentToolUseID) {
            taskID = parentToolUseID
        } else if let runtimeTaskID = nonempty(wire.taskID) {
            taskID = taskIDByRuntimeTaskID[runtimeTaskID]
        } else {
            taskID = nil
        }

        guard let taskID else { return [] }
        return [
            .progress(
                threadID: taskID,
                progress: SubagentProgress(
                    taskID: nonempty(wire.taskID),
                    currentTool: nonempty(wire.toolName),
                    elapsed: wire.elapsedTimeSeconds
                )
            )
        ]
    }

    private func progress(from wire: ClaudeSubagentWireEvent) -> SubagentProgress {
        SubagentProgress(
            taskID: nonempty(wire.taskID),
            summary: nonempty(wire.summary),
            currentTool: nonempty(wire.lastToolName),
            totalTokens: wire.usage?.totalTokens,
            toolUses: wire.usage?.toolUses,
            duration: wire.usage?.durationMS.map { $0 / 1_000 }
        )
    }

    /// Resolves every lifecycle spelling back to the Agent tool-use id.
    private mutating func resolvedTaskID(
        toolUseID: String?,
        runtimeTaskID: String?,
        mayDiscover: Bool
    ) -> String? {
        if let toolUseID = nonempty(toolUseID),
           trackedTaskIDs.contains(toolUseID) || mayDiscover {
            return toolUseID
        }
        if let runtimeTaskID = nonempty(runtimeTaskID) {
            if let mapped = taskIDByRuntimeTaskID[runtimeTaskID] { return mapped }
            if trackedTaskIDs.contains(runtimeTaskID) || mayDiscover { return runtimeTaskID }
        }
        return nil
    }

    // MARK: - Launches

    private mutating func taskLaunchEvents(
        from message: ClaudeSubagentWireMessage,
        currentTaskID: String?,
        sessionID: String?
    ) -> [SubagentEvent] {
        message.blocks.flatMap { block -> [SubagentEvent] in
            guard block.type == "tool_use",
                  let taskID = nonempty(block.id),
                  let toolName = nonempty(block.name),
                  toolName == "Task" || toolName == "Agent"
            else { return [] }

            let input = block.input?.foundationObject ?? [:]
            finishedTaskIDs.remove(taskID)
            let parentThreadID = currentTaskID ?? sessionID
            let descriptor = SubagentDescriptor(
                threadID: taskID,
                parentThreadID: parentThreadID,
                nickname: nonempty(input["description"])
                    ?? nonempty(input["name"]),
                role: nonempty(input["subagent_type"]),
                prompt: nonempty(input["prompt"]),
                model: nonempty(input["model"])
            )

            var events = discover(descriptor)
            events.append(.state(threadID: taskID, status: .working, message: nil))
            events.append(.activity(threadID: taskID, text: "Started"))
            return events
        }
    }

    // MARK: - Results

    private mutating func taskResultEvents(
        from message: ClaudeSubagentWireMessage,
        metadata: ClaudeSubagentWireToolUseResult?
    ) -> [SubagentEvent] {
        message.blocks.flatMap { block -> [SubagentEvent] in
            guard block.type == "tool_result",
                  let taskID = nonempty(block.toolUseID),
                  trackedTaskIDs.contains(taskID)
            else { return [] }

            if let agentID = nonempty(metadata?.agentID) {
                taskIDByAgentID[agentID] = taskID
            }

            var events = discover(SubagentDescriptor(
                threadID: taskID,
                nickname: nonempty(metadata?.description),
                prompt: nonempty(metadata?.prompt),
                model: nonempty(metadata?.resolvedModel)
            ))

            let outcome = resultOutcome(
                status: metadata?.status,
                isAsync: metadata?.isAsync ?? false,
                isError: block.isError
            )
            events.append(.state(
                threadID: taskID,
                status: outcome.status,
                message: outcome.message
            ))
            events.append(.activity(threadID: taskID, text: outcome.activity))

            if outcome.status.isDone {
                finishedTaskIDs.insert(taskID)
            }
            return events
        }
    }

    private func resultOutcome(
        status: ClaudeSubagentWireStatus?,
        isAsync: Bool,
        isError: Bool
    ) -> (status: SubagentStatus, activity: String, message: String?) {
        switch status {
        case .failed:
            return (.failed, "Failed", "Claude reported that the task failed.")
        case .interrupted:
            return (.interrupted, "Interrupted", nil)
        case .stopped:
            return (.stopped, "Stopped", nil)
        case .completed:
            return (.completed, "Finished", nil)
        case .working:
            return (.working, "Started in background", nil)
        default:
            if isError {
                return (.failed, "Failed", "Claude reported that the task failed.")
            }
            if isAsync {
                return (.working, "Started in background", nil)
            }
            return (.completed, "Finished", nil)
        }
    }

    // MARK: - Legacy Background Notifications

    /// Older Claude releases injected completion as XML text instead of the structured
    /// `task_notification` message. Keep this fallback so existing installs do not strand a
    /// background row in Working.
    private mutating func notificationEvents(
        from message: ClaudeSubagentWireMessage
    ) -> [SubagentEvent] {
        message.texts.flatMap { text -> [SubagentEvent] in
            guard let notification = ClaudeTaskNotification.parse(text),
                  let rawTaskID = notification.identity
            else { return [] }

            let taskID = taskIDByAgentID[rawTaskID] ?? rawTaskID
            let wireStatus = notification.status.map(
                ClaudeSubagentWireStatus.init(providerValue:)
            )
            let summary = notification.summary
            let status = notificationStatus(wireStatus)
            var events = discover(SubagentDescriptor(threadID: taskID))
            events.append(.state(
                threadID: taskID,
                status: status,
                message: status == .failed ? summary : nil
            ))
            events.append(.activity(
                threadID: taskID,
                text: summary ?? notificationActivity(status)
            ))
            if status.isDone {
                finishedTaskIDs.insert(taskID)
            }
            return events
        }
    }

    private func notificationStatus(_ value: ClaudeSubagentWireStatus?) -> SubagentStatus {
        switch value {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .stopped: return .stopped
        default: return .working
        }
    }

    private func notificationActivity(_ status: SubagentStatus) -> String {
        switch status {
        case .completed: return "Finished"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .stopped: return "Stopped"
        case .pending, .working: return "Working"
        }
    }

    // MARK: - Shared Helpers

    private mutating func discover(_ descriptor: SubagentDescriptor) -> [SubagentEvent] {
        let taskID = descriptor.threadID
        if trackedTaskIDs.insert(taskID).inserted {
            orderedTaskIDs.append(taskID)
        }
        if let parentThreadID = descriptor.parentThreadID {
            parentThreadIDByTaskID[taskID] = parentThreadID
        }
        return [.discovered(descriptor)]
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

}

// MARK: - Typed Wire Boundary

/// Only the fields used by the child projection are modelled. Tool-owned arguments remain
/// `JSONValue`, matching the ordinary stream parser's tolerant typed boundary.
private struct ClaudeSubagentWireEvent: Decodable {
    let type: String
    let subtype: String?
    let parentToolUseID: String?
    let sessionID: String?
    let taskDescription: String?
    let subagentType: String?
    let message: ClaudeSubagentWireMessage?
    let toolUseResult: ClaudeSubagentWireToolUseResult?

    let taskID: String?
    let toolUseID: String?
    let description: String?
    let taskType: String?
    let status: ClaudeSubagentWireStatus?
    let summary: String?
    let usage: ClaudeSubagentWireUsage?
    let lastToolName: String?
    let toolName: String?
    let elapsedTimeSeconds: TimeInterval?
    let patch: ClaudeSubagentWireTaskPatch?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        type = try container.decode(String.self, forKey: ClaudeSubagentCodingKey("type"))
        subtype = container.decodeFirst(String.self, keys: ["subtype"])
        parentToolUseID = container.decodeFirst(
            String.self,
            keys: ["parent_tool_use_id", "parentToolUseId"]
        )
        sessionID = container.decodeFirst(String.self, keys: ["session_id", "sessionId"])
        taskDescription = container.decodeFirst(
            String.self,
            keys: ["task_description", "taskDescription"]
        )
        subagentType = container.decodeFirst(
            String.self,
            keys: ["subagent_type", "subagentType"]
        )
        message = container.decodeFirst(ClaudeSubagentWireMessage.self, keys: ["message"])
        toolUseResult = container.decodeFirst(
            ClaudeSubagentWireToolUseResult.self,
            keys: ["tool_use_result", "toolUseResult"]
        )
        taskID = container.decodeFirst(String.self, keys: ["task_id", "taskId"])
        toolUseID = container.decodeFirst(String.self, keys: ["tool_use_id", "toolUseId"])
        description = container.decodeFirst(String.self, keys: ["description"])
        taskType = container.decodeFirst(String.self, keys: ["task_type", "taskType"])
        status = container.decodeFirst(String.self, keys: ["status"])
            .map(ClaudeSubagentWireStatus.init(providerValue:))
        summary = container.decodeFirst(String.self, keys: ["summary"])
        usage = container.decodeFirst(ClaudeSubagentWireUsage.self, keys: ["usage"])
        lastToolName = container.decodeFirst(
            String.self,
            keys: ["last_tool_name", "lastToolName"]
        )
        toolName = container.decodeFirst(String.self, keys: ["tool_name", "toolName"])
        elapsedTimeSeconds = container.decodeFirst(
            TimeInterval.self,
            keys: ["elapsed_time_seconds", "elapsedTimeSeconds"]
        )
        patch = container.decodeFirst(ClaudeSubagentWireTaskPatch.self, keys: ["patch"])
    }
}

private struct ClaudeSubagentWireMessage: Decodable {
    let model: String?
    let blocks: [ClaudeSubagentWireContentBlock]
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        model = container.decodeFirst(String.self, keys: ["model"])
        blocks = container.decodeFirst(
            [ClaudeSubagentWireContentBlock].self,
            keys: ["content"]
        ) ?? []
        text = container.decodeFirst(String.self, keys: ["content"])
    }

    var texts: [String] {
        var result = text.map { [$0] } ?? []
        result.append(contentsOf: blocks.compactMap { block in
            guard block.type == "text" else { return nil }
            return block.text
        })
        return result
    }
}

private struct ClaudeSubagentWireContentBlock: Decodable {
    let type: String?
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let toolUseID: String?
    let isError: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        type = container.decodeFirst(String.self, keys: ["type"])
        text = container.decodeFirst(String.self, keys: ["text"])
        id = container.decodeFirst(String.self, keys: ["id"])
        name = container.decodeFirst(String.self, keys: ["name"])
        input = container.decodeFirst(JSONValue.self, keys: ["input"])
        toolUseID = container.decodeFirst(
            String.self,
            keys: ["tool_use_id", "toolUseId"]
        )
        isError = container.decodeFirst(Bool.self, keys: ["is_error", "isError"]) ?? false
    }
}

private struct ClaudeSubagentWireToolUseResult: Decodable {
    let agentID: String?
    let description: String?
    let prompt: String?
    let resolvedModel: String?
    let status: ClaudeSubagentWireStatus?
    let isAsync: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        agentID = container.decodeFirst(String.self, keys: ["agentId", "agent_id"])
        description = container.decodeFirst(String.self, keys: ["description"])
        prompt = container.decodeFirst(String.self, keys: ["prompt"])
        resolvedModel = container.decodeFirst(
            String.self,
            keys: ["resolvedModel", "resolved_model"]
        )
        status = container.decodeFirst(String.self, keys: ["status"])
            .map(ClaudeSubagentWireStatus.init(providerValue:))
        isAsync = container.decodeFirst(Bool.self, keys: ["isAsync", "is_async"])
    }
}

private struct ClaudeSubagentWireUsage: Decodable {
    let totalTokens: Int?
    let toolUses: Int?
    let durationMS: TimeInterval?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        totalTokens = container.decodeFirst(Int.self, keys: ["total_tokens", "totalTokens"])
        toolUses = container.decodeFirst(Int.self, keys: ["tool_uses", "toolUses"])
        durationMS = container.decodeFirst(
            TimeInterval.self,
            keys: ["duration_ms", "durationMs"]
        )
    }
}

private struct ClaudeSubagentWireTaskPatch: Decodable {
    let status: ClaudeSubagentWireStatus?
    let description: String?
    let error: String?
    let isBackgrounded: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClaudeSubagentCodingKey.self)
        status = container.decodeFirst(String.self, keys: ["status"])
            .map(ClaudeSubagentWireStatus.init(providerValue:))
        description = container.decodeFirst(String.self, keys: ["description"])
        error = container.decodeFirst(String.self, keys: ["error"])
        isBackgrounded = container.decodeFirst(
            Bool.self,
            keys: ["is_backgrounded", "isBackgrounded"]
        )
    }
}

private enum ClaudeSubagentWireStatus: Equatable {
    case completed
    case failed
    case interrupted
    case stopped
    case working
    case unknown(String)

    init(providerValue: String) {
        switch providerValue.lowercased() {
        case "completed", "success", "succeeded": self = .completed
        case "failed", "error", "errored": self = .failed
        case "interrupted", "cancelled", "canceled", "killed": self = .interrupted
        case "stopped", "shutdown": self = .stopped
        case "async_launched", "in_progress", "running", "pending": self = .working
        default: self = .unknown(providerValue)
        }
    }
}

private struct ClaudeSubagentCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension KeyedDecodingContainer where Key == ClaudeSubagentCodingKey {
    func decodeFirst<Value: Decodable>(
        _ type: Value.Type,
        keys: [String]
    ) -> Value? {
        for name in keys {
            let key = ClaudeSubagentCodingKey(name)
            if let value = try? decode(type, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private extension StreamEvent {
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}
