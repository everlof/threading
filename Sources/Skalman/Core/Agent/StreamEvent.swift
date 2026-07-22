import Foundation

// MARK: - Stream Event

/// One provider-neutral event consumed by the native conversation view.
///
/// Claude and Codex adapters map their different JSONL shapes here. Only what the panel
/// actually needs is modelled; anything unrecognised becomes `.unknown`, so a new provider event
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
    case unknown(type: String)
}

// MARK: - Content Block

/// The tools whose behavior Skalman understands, independent of the provider spelling that
/// introduced them. Unknown and MCP tools keep their original name: they still render
/// intelligibly, and a future tool cannot accidentally inherit the permissions of a known one.
enum ToolIdentity: Hashable {
    case bash
    case read
    case write
    case edit
    case multiEdit
    case notebookEdit
    case notebookRead
    case glob
    case grep
    case webFetch
    case webSearch
    case task
    case todoWrite
    case todoRead
    case toolSearch
    case plan
    case mcp(String)
    case unknown(String)

    init(_ rawName: String) {
        switch rawName {
        case "Bash": self = .bash
        case "Read": self = .read
        case "Write": self = .write
        case "Edit": self = .edit
        case "MultiEdit": self = .multiEdit
        case "NotebookEdit": self = .notebookEdit
        case "NotebookRead": self = .notebookRead
        case "Glob": self = .glob
        case "Grep": self = .grep
        case "WebFetch": self = .webFetch
        case "WebSearch": self = .webSearch
        case "Task": self = .task
        case "TodoWrite": self = .todoWrite
        case "TodoRead": self = .todoRead
        case "ToolSearch": self = .toolSearch
        case "Plan": self = .plan

        // Codex's spellings for the same behaviours. Taken from 1008 real rollouts on this
        // machine rather than from a list, which is how the long tail below was found at all.
        //
        // Only tools whose *behaviour* matches an identity already here are mapped. Everything
        // Codex-specific — spawning agents, goals, simulators — stays `.unknown` and therefore
        // prompts, because mapping a tool onto an identity also hands it that identity's
        // permissions.
        case "exec", "exec_command", "shell_command", "shell", "local_shell":
            self = .bash

        // Writing to a running process's stdin is part of the same shell interaction, and is no
        // less consequential than the command that opened it.
        case "write_stdin":
            self = .bash

        // A patch carries old and new text, which is an edit rather than a whole-file write —
        // and is what lets `CodexPatch` feed the same `DiffView`.
        case "apply_patch":
            self = .edit

        case "view_image":
            self = .read

        case "update_plan":
            self = .plan

        case "web_search":
            self = .webSearch

        case let name where name.hasPrefix("mcp__"): self = .mcp(name)
        default: self = .unknown(rawName)
        }
    }

    var rawName: String {
        switch self {
        case .bash: return "Bash"
        case .read: return "Read"
        case .write: return "Write"
        case .edit: return "Edit"
        case .multiEdit: return "MultiEdit"
        case .notebookEdit: return "NotebookEdit"
        case .notebookRead: return "NotebookRead"
        case .glob: return "Glob"
        case .grep: return "Grep"
        case .webFetch: return "WebFetch"
        case .webSearch: return "WebSearch"
        case .task: return "Task"
        case .todoWrite: return "TodoWrite"
        case .todoRead: return "TodoRead"
        case .toolSearch: return "ToolSearch"
        case .plan: return "Plan"
        case .mcp(let name), .unknown(let name): return name
        }
    }
}

/// One piece of an assistant message.
enum ContentBlock {
    case text(String)
    case thinking(String)
    case toolUse(id: String, tool: ToolIdentity, input: [String: Any])
}

// MARK: - Tool Result

struct ToolResult {
    let toolUseID: String
    let text: String
    let isError: Bool
}

// MARK: - JSON Value

/// Arbitrary JSON retained inside typed provider envelopes, primarily for tool arguments and
/// results whose schemas belong to the tool rather than to the stream protocol.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var foundationValue: Any {
        switch self {
        case .object(let value):
            return value.mapValues(\.foundationValue)
        case .array(let value):
            return value.map(\.foundationValue)
        case .string(let value):
            return value
        case .integer(let value):
            return Int(exactly: value) ?? value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    var foundationObject: [String: Any]? {
        objectValue?.mapValues(\.foundationValue)
    }

    func encodedText(prettyPrinted: Bool = false) -> String {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Parse Result

/// A complete JSONL line either yields zero or more provider-neutral events, or is malformed.
/// Unknown but well-formed provider events are ordinary `.unknown` events, never malformed.
enum StreamLineParseResult {
    case events([StreamEvent])
    case malformed
}

struct StreamParseDiagnostics {
    private(set) var malformedLineCount = 0

    mutating func reset() {
        malformedLineCount = 0
    }

    mutating func recordMalformedLine(provider: String) {
        malformedLineCount += 1
        let total = malformedLineCount
        SkalmanLogger.agent.warning(
            "Skipped malformed \(provider, privacy: .public) stream line; total \(total)"
        )
    }
}

// MARK: - Parsing

extension StreamEvent {

    /// Parses one line of `stream-json` output.
    ///
    static func parse(_ line: String) -> StreamLineParseResult {
        guard let data = line.data(using: .utf8),
              let wire = try? JSONDecoder().decode(ClaudeWireEvent.self, from: data)
        else { return .malformed }

        let event: StreamEvent
        switch wire.type {
        case "system":
            guard wire.subtype == "init" else {
                return .events([.unknown(type: "system")])
            }
            event = .initialised(sessionID: wire.sessionID.map(TranscriptID.init), model: wire.model)

        case "stream_event":
            event = parseStreamEvent(wire.event)

        case "assistant":
            event = .assistantMessage(
                blocks: (wire.message?.content ?? []).compactMap(contentBlock)
            )

        case "user":
            let results = (wire.message?.content ?? []).compactMap(toolResult)
            event = results.isEmpty ? .unknown(type: "user") : .toolResults(results)

        case "result":
            event = .turnFinished(text: wire.result, isError: wire.isError)

        default:
            event = .unknown(type: wire.type)
        }

        return .events([event])
    }

    /// Only the deltas that carry visible text are surfaced; block start and stop are
    /// implied by the complete message that follows.
    private static func parseStreamEvent(_ event: ClaudeWireStreamEvent?) -> StreamEvent {
        guard event?.type == "content_block_delta", let delta = event?.delta else {
            return .unknown(type: "stream_event")
        }

        switch delta.type {
        case "text_delta":
            return .textDelta(delta.text ?? "")
        case "thinking_delta":
            return .thinkingDelta(delta.thinking ?? "")
        default:
            // `input_json_delta` streams a tool's arguments a fragment at a time. Showing
            // half-formed JSON helps nobody; the finished call arrives with the message.
            return .unknown(type: "stream_event")
        }
    }

    private static func contentBlock(_ block: ClaudeWireContentBlock) -> ContentBlock? {
        switch block.type {
        case "text":
            return .text(block.text ?? "")
        case "thinking":
            return .thinking(block.thinking ?? "")
        case "tool_use":
            guard let id = block.id, let name = block.name else {
                return nil
            }
            return .toolUse(
                id: id,
                tool: ToolIdentity(name),
                input: block.input?.foundationObject ?? [:]
            )
        default:
            return nil
        }
    }

    private static func toolResult(_ block: ClaudeWireContentBlock) -> ToolResult? {
        guard block.type == "tool_result", let id = block.toolUseID else { return nil }

        return ToolResult(
            toolUseID: id,
            text: resultText(block.content),
            isError: block.isError
        )
    }

    /// A tool result's content is a bare string for simple tools and an array of blocks for
    /// ones that return structured output, so both shapes are flattened to text.
    private static func resultText(_ content: JSONValue?) -> String {
        if let text = content?.stringValue { return text }
        guard case .array(let blocks) = content else { return "" }
        return blocks
            .compactMap { $0.objectValue?["text"]?.stringValue }
            .joined(separator: "\n")
    }

    // Transcript replay still reads scrubbed records through `JSONLReader`'s Foundation
    // representation. These adapters keep that disk format separate from the live Codable wire
    // models above until the transcript boundary gets its own migration.
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
            return .toolUse(
                id: id,
                tool: ToolIdentity(name),
                input: block["input"] as? [String: Any] ?? [:]
            )
        default:
            return nil
        }
    }

    static func toolResult(_ block: [String: Any]) -> ToolResult? {
        guard block["type"] as? String == "tool_result",
              let id = block["tool_use_id"] as? String else { return nil }

        return ToolResult(
            toolUseID: id,
            text: transcriptResultText(block["content"]),
            isError: block["is_error"] as? Bool ?? false
        )
    }

    private static func transcriptResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}

// MARK: - Claude Wire Models

private struct ClaudeWireEvent: Decodable {
    let type: String
    let subtype: String?
    let sessionID: String?
    let model: String?
    let event: ClaudeWireStreamEvent?
    let message: ClaudeWireMessage?
    let result: String?
    let isError: Bool

    private enum CodingKeys: String, CodingKey {
        case type, subtype, model, event, message, result
        case sessionID = "session_id"
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        subtype = try? container.decode(String.self, forKey: .subtype)
        sessionID = try? container.decode(String.self, forKey: .sessionID)
        model = try? container.decode(String.self, forKey: .model)
        event = try? container.decode(ClaudeWireStreamEvent.self, forKey: .event)
        message = try? container.decode(ClaudeWireMessage.self, forKey: .message)
        result = try? container.decode(String.self, forKey: .result)
        isError = (try? container.decode(Bool.self, forKey: .isError)) ?? false
    }
}

private struct ClaudeWireStreamEvent: Decodable {
    let type: String?
    let delta: ClaudeWireDelta?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = try? container.decode(String.self, forKey: DynamicCodingKey("type"))
        delta = try? container.decode(ClaudeWireDelta.self, forKey: DynamicCodingKey("delta"))
    }
}

private struct ClaudeWireDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = try? container.decode(String.self, forKey: DynamicCodingKey("type"))
        text = try? container.decode(String.self, forKey: DynamicCodingKey("text"))
        thinking = try? container.decode(String.self, forKey: DynamicCodingKey("thinking"))
    }
}

private struct ClaudeWireMessage: Decodable {
    let content: [ClaudeWireContentBlock]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        content = (try? container.decode(
            [ClaudeWireContentBlock].self,
            forKey: DynamicCodingKey("content")
        )) ?? []
    }
}

private struct ClaudeWireContentBlock: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let toolUseID: String?
    let content: JSONValue?
    let isError: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = try? container.decode(String.self, forKey: DynamicCodingKey("type"))
        text = try? container.decode(String.self, forKey: DynamicCodingKey("text"))
        thinking = try? container.decode(String.self, forKey: DynamicCodingKey("thinking"))
        id = try? container.decode(String.self, forKey: DynamicCodingKey("id"))
        name = try? container.decode(String.self, forKey: DynamicCodingKey("name"))
        input = try? container.decode(JSONValue.self, forKey: DynamicCodingKey("input"))
        toolUseID = try? container.decode(String.self, forKey: DynamicCodingKey("tool_use_id"))
        content = try? container.decode(JSONValue.self, forKey: DynamicCodingKey("content"))
        isError = (try? container.decode(Bool.self, forKey: DynamicCodingKey("is_error"))) ?? false
    }
}

private struct DynamicCodingKey: CodingKey {
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
