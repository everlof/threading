import Foundation

/// Everything needed to locate one root conversation's durable Claude child index.
struct ClaudeSubagentTranscriptPlan: Sendable {
    let rootThreadID: String
    let directory: URL
}

/// Rebuilds Claude's child-agent hierarchy and lazily replays one selected child.
///
/// Current Claude releases write a small `agent-<id>.meta.json` beside every JSONL. It contains
/// the spawning tool-use id and parent agent id, so indexing hundreds of children costs only
/// their metadata plus the first and last JSONL records. The full transcript is read only after
/// the user opens that child. Older sessions without metadata remain visible under their agent
/// id as top-level children.
enum ClaudeSubagentTranscriptReplay {

    // MARK: - Asynchronous Entry Points

    static func loadIndex(
        plan: ClaudeSubagentTranscriptPlan,
        completion: @escaping @MainActor @Sendable ([SubagentEvent]) -> Void
    ) {
        let span = PerformanceRecorder.shared.begin(
            "subagent.index.read",
            category: "conversation"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let events = index(
                rootThreadID: plan.rootThreadID,
                directory: plan.directory
            )
            span.end(metadata: ["events": "\(events.count)"])
            DispatchQueue.main.async { completion(events) }
        }
    }

    static func loadConversation(
        at url: URL,
        completion: @escaping @MainActor @Sendable (
            _ events: [StreamEvent], _ isTruncated: Bool
        ) -> Void
    ) {
        let span = PerformanceRecorder.shared.begin(
            "subagent.transcript.read",
            category: "conversation"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let replay = readConversation(at: url)
            span.end(metadata: [
                "events": "\(replay.events.count)",
                "truncated": replay.isTruncated ? "true" : "false"
            ])
            DispatchQueue.main.async { completion(replay.events, replay.isTruncated) }
        }
    }

    // MARK: - Index

    /// Synchronous seam used by tests and the background loader.
    static func index(rootThreadID: String, directory: URL) -> [SubagentEvent] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let snapshots = urls
            .filter {
                guard $0.pathExtension == AgentDefaults.transcriptExtension,
                      $0.lastPathComponent.hasPrefix(
                          ClaudeSubagentHistoryDefaults.agentPrefix
                      ) else { return false }
                let values = try? $0.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .compactMap { snapshot($0) }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.agentID < $1.agentID
            }

        var threadIDByAgentID: [String: String] = [:]
        for snapshot in snapshots where threadIDByAgentID[snapshot.agentID] == nil {
            threadIDByAgentID[snapshot.agentID] = snapshot.threadID
        }

        var events: [SubagentEvent] = []
        for snapshot in snapshots {
            let parentThreadID = snapshot.parentAgentID
                .flatMap { threadIDByAgentID[normalisedAgentID($0)] }
                ?? rootThreadID
            events.append(.discovered(SubagentDescriptor(
                threadID: snapshot.threadID,
                alternateThreadIDs: snapshot.agentID == snapshot.threadID
                    ? nil
                    : [snapshot.agentID],
                parentThreadID: parentThreadID,
                nickname: snapshot.description,
                role: snapshot.agentType,
                path: snapshot.transcriptURL.path,
                prompt: snapshot.prompt,
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort
            )))
            events.append(.state(
                threadID: snapshot.threadID,
                status: snapshot.status,
                message: nil
            ))
            if snapshot.status == .stopped {
                events.append(.activity(
                    threadID: snapshot.threadID,
                    text: ClaudeSubagentHistoryDefaults.incompleteActivity
                ))
            }
        }
        return events
    }

    private static func snapshot(_ transcriptURL: URL) -> Snapshot? {
        let fallbackAgentID = normalisedAgentID(
            transcriptURL.deletingPathExtension().lastPathComponent
        )
        guard !fallbackAgentID.isEmpty else { return nil }

        let metadataURL = transcriptURL
            .deletingPathExtension()
            .appendingPathExtension(ClaudeSubagentHistoryDefaults.metadataExtension)
        let metadata = (try? BoundedFileReader.read(
            metadataURL,
            maximumBytes: ClaudeSubagentHistoryDefaults.maximumMetadataBytes
        ))
            .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }

        var firstRecord: [String: Any]?
        JSONLReader.forEachRecord(at: transcriptURL, limit: .max) { record in
            firstRecord = record
            return false
        }

        let agentID = normalisedAgentID(
            nonempty(firstRecord?["agentId"] as? String) ?? fallbackAgentID
        )
        let message = firstRecord?["message"] as? [String: Any]
        let prompt = firstRecord?["type"] as? String == "user"
            ? message.flatMap { ClaudeTranscriptUserRecord.userText(from: $0) }
            : nil
        let timestamp = nonempty(firstRecord?["timestamp"] as? String)
        let resource = try? transcriptURL.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey
        ])
        let startedAt = timestamp.flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? resource?.creationDate
            ?? resource?.contentModificationDate
            ?? .distantPast

        let lastRecord = JSONLReader.lastRecord(at: transcriptURL)
        let status = historicalStatus(lastRecord)

        return Snapshot(
            agentID: agentID,
            threadID: nonempty(metadata?.toolUseID) ?? agentID,
            parentAgentID: nonempty(metadata?.parentAgentID),
            agentType: nonempty(metadata?.agentType)
                ?? nonempty(firstRecord?["attributionAgent"] as? String),
            description: nonempty(metadata?.description),
            prompt: prompt,
            model: nonempty(message?["model"] as? String),
            reasoningEffort: nonempty(firstRecord?["effort"] as? String),
            transcriptURL: transcriptURL,
            startedAt: startedAt,
            status: status
        )
    }

    private static func historicalStatus(_ record: [String: Any]?) -> SubagentStatus {
        guard let record else { return .stopped }
        if record["error"] != nil || record["is_error"] as? Bool == true {
            return .failed
        }
        guard record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any] else {
            return .stopped
        }

        switch message["stop_reason"] as? String {
        case "end_turn", "stop_sequence":
            return .completed
        case "tool_use", "max_tokens", "pause_turn":
            return .stopped
        case nil:
            // Older Claude transcripts leave the stop reason null even after the final text
            // block. Ending on a tool call is still incomplete; text-only output is the
            // historical spelling of a completed child.
            // Per element. This asks whether the child's last message ended on a tool call, and
            // the strict cast answered "no" for a `content` it simply could not read — so a
            // child that stopped mid-tool was reported as having completed.
            let blocks = WireList.objects(
                message["content"],
                site: WireListSite.claudeSubagentStatusContent,
                log: ThreadingLogger.agent
            ) ?? []
            let endedOnTool = blocks.contains { $0["type"] as? String == "tool_use" }
            return endedOnTool ? .stopped : .completed
        default:
            return .stopped
        }
    }

    // MARK: - Selected Transcript

    /// Reads a selected child through the same `StreamEvent` path as the live transport.
    static func readConversation(
        at url: URL
    ) -> (events: [StreamEvent], isTruncated: Bool) {
        var events: [StreamEvent] = []
        var dropped = 0

        JSONLReader.forEachRecord(at: url, limit: .max) { record in
            guard let event = conversationEvent(from: record) else { return true }
            events.append(event)

            if events.count > ClaudeSubagentHistoryDefaults.maximumConversationEvents {
                events.removeFirst()
                dropped += 1
            }
            return true
        }

        return (events, dropped > 0)
    }

    private static func conversationEvent(from record: [String: Any]) -> StreamEvent? {
        guard record["isMeta"] as? Bool != true,
              let type = record["type"] as? String,
              type == "user" || type == "assistant",
              let message = record["message"] as? [String: Any] else {
            return nil
        }

        if type == "assistant" {
            // Per element, exactly as the parent replay is: a child's turn that vanishes reads
            // as a subagent that never answered.
            let content = WireList.objects(
                message["content"],
                site: WireListSite.claudeSubagentContent,
                log: ThreadingLogger.agent
            ) ?? []
            let blocks = content.compactMap(StreamEvent.contentBlock).filter(hasVisibleContent)
            return blocks.isEmpty ? nil : .assistantMessage(blocks: blocks)
        }

        return ClaudeTranscriptUserRecord.event(from: message, scope: .child)
    }

    private static func hasVisibleContent(_ block: ContentBlock) -> Bool {
        switch block {
        case .text(let text), .thinking(let text):
            return !text.isEmpty
        case .toolUse:
            return true
        }
    }

    private static func normalisedAgentID(_ value: String) -> String {
        value.hasPrefix(ClaudeSubagentHistoryDefaults.agentPrefix)
            ? String(value.dropFirst(ClaudeSubagentHistoryDefaults.agentPrefix.count))
            : value
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private extension ClaudeSubagentTranscriptReplay {
    struct Snapshot {
        let agentID: String
        let threadID: String
        let parentAgentID: String?
        let agentType: String?
        let description: String?
        let prompt: String?
        let model: String?
        let reasoningEffort: String?
        let transcriptURL: URL
        let startedAt: Date
        let status: SubagentStatus
    }

    struct Metadata: Decodable {
        let agentType: String?
        let description: String?
        let parentAgentID: String?
        let toolUseID: String?

        private enum CodingKeys: String, CodingKey {
            case agentType, description, parentAgentId, toolUseId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agentType = try? container.decode(String.self, forKey: .agentType)
            description = try? container.decode(String.self, forKey: .description)
            parentAgentID = try? container.decode(String.self, forKey: .parentAgentId)
            toolUseID = try? container.decode(String.self, forKey: .toolUseId)
        }
    }
}

enum ClaudeSubagentHistoryDefaults {
    static let agentPrefix = "agent-"
    static let metadataExtension = "meta.json"
    static let maximumConversationEvents = ReplayDefaults.maximumEvents
    static let maximumMetadataBytes = 1 * 1_024 * 1_024
    static let incompleteActivity = "Saved transcript ended before Claude reported completion"
    static let truncatedActivity = "Earlier child transcript omitted"
}
