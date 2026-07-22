import Foundation

// MARK: - Stream Event

/// One provider-neutral event consumed by the native conversation view.
///
/// Claude and Codex adapters map their different JSONL shapes here. Only what the panel
/// actually needs is modelled; anything unrecognised becomes `.other`, so a new provider event
/// in a future release is ignored rather than fatal.
enum StreamEvent {

    /// Session established. Carries the identifier the CLI settled on, which for a resume is
    /// not necessarily the one we asked for.
    case initialised(sessionID: TranscriptID?, model: String?)

    /// A block of the in-progress assistant message grew. Used only to show text as it
    /// arrives — the authoritative copy comes in `assistantMessage`.
    case textDelta(String)
    case thinkingDelta(String)

    /// A finished assistant message, replacing whatever was streamed for it.
    case assistantMessage(blocks: [ContentBlock])

    /// A user turn. Only ever produced when replaying a transcript — a live session echoes
    /// what was typed as it is sent, so emitting it here too would render it twice.
    case userMessage(String)

    /// Results attached to earlier tool calls by their provider-issued item identifier.
    case toolResults([ToolResult])

    /// The turn finished. `isError` marks a turn that failed rather than completed.
    case turnFinished(text: String?, isError: Bool)

    /// Anything not modelled, kept so callers can log without the parser throwing.
    case other(type: String)
}

// MARK: - Content Block

/// One piece of an assistant message.
enum ContentBlock {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: Any])
}

// MARK: - Tool Result

struct ToolResult {
    let toolUseID: String
    let text: String
    let isError: Bool
}

// MARK: - Parsing

extension StreamEvent {

    /// Parses one line of `stream-json` output.
    ///
    /// Returns nil for lines that are not JSON at all, which the CLI should not emit but a
    /// crashing subprocess might.
    static func parse(_ line: String) -> StreamEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return .other(type: "system") }
            return .initialised(
                sessionID: (object["session_id"] as? String).map(TranscriptID.init),
                model: object["model"] as? String
            )

        case "stream_event":
            return parseStreamEvent(object)

        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
            return .assistantMessage(blocks: (content ?? []).compactMap(contentBlock))

        case "user":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
            let results = (content ?? []).compactMap(toolResult)
            return results.isEmpty ? .other(type: "user") : .toolResults(results)

        case "result":
            return .turnFinished(
                text: object["result"] as? String,
                isError: object["is_error"] as? Bool ?? false
            )

        default:
            return .other(type: type)
        }
    }

    /// Only the deltas that carry visible text are surfaced; block start and stop are
    /// implied by the complete message that follows.
    private static func parseStreamEvent(_ object: [String: Any]) -> StreamEvent {
        guard let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any] else {
            return .other(type: "stream_event")
        }

        switch delta["type"] as? String {
        case "text_delta":
            return .textDelta(delta["text"] as? String ?? "")
        case "thinking_delta":
            return .thinkingDelta(delta["thinking"] as? String ?? "")
        default:
            // `input_json_delta` streams a tool's arguments a fragment at a time. Showing
            // half-formed JSON helps nobody; the finished call arrives with the message.
            return .other(type: "stream_event")
        }
    }

    static func contentBlock(_ block: [String: Any]) -> ContentBlock? {
        switch block["type"] as? String {
        case "text":
            return .text(block["text"] as? String ?? "")
        case "thinking":
            return .thinking(block["thinking"] as? String ?? "")
        case "tool_use":
            guard let id = block["id"] as? String, let name = block["name"] as? String else {
                return nil
            }
            return .toolUse(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
        default:
            return nil
        }
    }

    static func toolResult(_ block: [String: Any]) -> ToolResult? {
        guard block["type"] as? String == "tool_result",
              let id = block["tool_use_id"] as? String else { return nil }

        return ToolResult(
            toolUseID: id,
            text: resultText(block["content"]),
            isError: block["is_error"] as? Bool ?? false
        )
    }

    /// A tool result's content is a bare string for simple tools and an array of blocks for
    /// ones that return structured output, so both shapes are flattened to text.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }

        guard let blocks = content as? [[String: Any]] else { return "" }

        return blocks
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}
