import Foundation

// MARK: - Stream Event

/// One provider-neutral event consumed by the native conversation view.
///
/// Claude and Codex adapters map their different JSONL shapes here. Only what the panel
/// actually needs is modelled; anything unrecognised becomes `.unknown`, so a new provider event
/// in a future release is ignored rather than fatal.
enum StreamEvent: Sendable {

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

    /// Provider-owned transcript chrome worth retaining without pretending the user said it.
    ///
    /// Claude records slash-command invocations as XML-shaped user messages. Replay reduces
    /// those records to one quiet line instead of drawing the transport envelope as a chat turn.
    case transcriptNotice(String)

    /// Results attached to earlier tool calls by their provider-issued item identifier.
    case toolResults([ToolResult])

    /// A complete ordered run plan reported independently of the tool-item stream.
    ///
    /// Codex app-server sends this as `turn/plan/updated`. Keeping it as its own event avoids
    /// inventing a tool row for a notification and lets the same timeline reducer consume live
    /// updates and any future replay source.
    case runPlanUpdated([RunProgress.Step])

    /// The work the agent has left running outside the turn, restated whenever it changes.
    ///
    /// Claude's stream sends the whole in-flight list on every change
    /// (`system` / `background_tasks_changed`), so this is a level rather than an edge and the
    /// last one seen is always current. It exists because a backgrounded shell re-enters the
    /// conversation on its own: the turn that queued it ends, and the agent then speaks again
    /// with nobody having typed. A session in that state has not finished anything.
    ///
    /// Carries identities and kinds rather than a count, so `BackgroundWorkLedger` can tell
    /// delegated work from standing work, and standing work a turn started from standing work
    /// parked in an earlier one.
    case backgroundWork(inFlight: [BackgroundTask])

    /// The turn finished, and `outcome` says how.
    ///
    /// Metrics are exact values from the provider where the stream supplies them, completed
    /// with the local round-trip clock by the session wrapper where it does not. Keeping them
    /// on the terminal event makes a finished turn one fact: content, outcome and receipt
    /// cannot arrive out of step in the view.
    case turnFinished(text: String?, outcome: TurnOutcome, metrics: TurnMetrics)

    /// Anything not modelled, kept so callers can log without the parser throwing.
    case unknown(type: String)
}

// MARK: - Turn Outcome

/// How a turn ended.
///
/// This was a `Bool` named `isError`, and the two facts it conflated are not the same fact:
/// every provider reports a user-stopped turn through its *error* channel — Claude answers
/// `result` with `subtype: "error_during_execution"`, Codex settles the turn as
/// `TurnStatus.interrupted`, ACP answers the pending prompt with `stopReason: "cancelled"` —
/// so a single flag made "you pressed Stop" indistinguishable from "the model call failed".
/// The fold under a settled turn read **You stopped after 42s** for a network error, and an
/// interrupted turn and a broken one were drawn identically.
///
/// Three values rather than two because the third is what the composer's Stop button produces,
/// and a turn the user ended deliberately is not a failure to report.
enum TurnOutcome: Equatable, Sendable {
    /// Ran to the end on its own.
    case completed

    /// The provider reported a failure: a refusal, a transport fault, a model error.
    case failed

    /// The user stopped it. Nothing went wrong.
    case stopped

    /// Whether accompanying text is a fault to show rather than an answer to render.
    ///
    /// A stopped turn is deliberately *not* an error here: whatever prose arrived before the
    /// interrupt is the agent's partial answer, not a diagnostic.
    var isError: Bool { self == .failed }

    /// Whether the turn ended before it was done, either way. This is the question the timeline
    /// asks when deciding whether to keep a turn expanded so the user keeps their place.
    var isIncomplete: Bool { self != .completed }

    /// The stable wire spelling for the execution ledger. Deliberately not `String(describing:)`,
    /// which would let a rename of a case silently rewrite the meaning of stored records.
    var auditName: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}

// MARK: - Turn Metrics

/// The small receipt shown after a native turn completes.
///
/// `outputTokens` is deliberately output rather than total context: the down-arrow in the
/// status line means "tokens the agent generated this turn". Input/context tokens can dwarf
/// the answer on a resumed conversation and answer a different question.
struct TurnMetrics: Equatable, Sendable {
    var duration: TimeInterval?
    var outputTokens: Int?
    var effort: String?

    /// How much of the model's context the last request occupied — prompt, cache reads and
    /// completion together. Distinct from `outputTokens` on purpose: that answers "how much
    /// did it say", this answers "how full is the window".
    var contextTokens: Int?

    /// The model's context capacity, where the provider states it. Codex reports
    /// `model_context_window` beside its token counts; Claude's stream does not name a
    /// limit, so its reading stays absolute.
    var contextWindow: Int?

    static let empty = TurnMetrics()

    var isEmpty: Bool {
        duration == nil && outputTokens == nil && effort == nil
            && contextTokens == nil && contextWindow == nil
    }

    /// Adds facts known by the process wrapper without replacing more authoritative values
    /// decoded from the provider's terminal event.
    func filling(
        duration: TimeInterval?,
        effort: String?,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil
    ) -> TurnMetrics {
        TurnMetrics(
            duration: self.duration ?? duration,
            outputTokens: outputTokens,
            effort: self.effort ?? effort,
            contextTokens: self.contextTokens ?? contextTokens,
            contextWindow: self.contextWindow ?? contextWindow
        )
    }
}

// MARK: - Content Block

/// The tools whose behavior Threading understands, independent of the provider spelling that
/// introduced them. Unknown and MCP tools keep their original name: they still render
/// intelligibly, and a future tool cannot accidentally inherit the permissions of a known one.
enum ToolIdentity: Hashable, Sendable {
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
    case taskCreate
    case taskUpdate
    case taskList
    case taskGet
    case todoWrite
    case todoRead
    case toolSearch
    case plan
    case mcp(String)
    case unknown(String)

    /// Every spelling either provider uses, mapped to the behaviour it denotes.
    ///
    /// A table rather than a `switch` because there are two vocabularies now and a third would
    /// not fit in a readable one — and because a `switch` over this many names is a branch per
    /// entry, which is complexity in the counted sense without being complexity in any sense a
    /// reader cares about.
    ///
    /// Codex's names come from 1008 real rollouts on the machine this was built for rather than
    /// from a published list, which is the only reason the long tail was found at all. Only
    /// tools whose *behaviour* matches an identity already here appear: everything
    /// Codex-specific — spawning agents, goals, simulators — is absent on purpose, because
    /// mapping a tool onto an identity also hands it that identity's permissions.
    private static let identitiesByName: [String: ToolIdentity] = [
        // Claude
        "Bash": .bash, "Read": .read, "Write": .write, "Edit": .edit,
        "MultiEdit": .multiEdit, "NotebookEdit": .notebookEdit, "NotebookRead": .notebookRead,
        "Glob": .glob, "Grep": .grep, "WebFetch": .webFetch, "WebSearch": .webSearch,
        "Task": .task, "Agent": .task,
        "TaskCreate": .taskCreate, "TaskUpdate": .taskUpdate,
        "TaskList": .taskList, "TaskGet": .taskGet,
        "TodoWrite": .todoWrite, "TodoRead": .todoRead,
        "ToolSearch": .toolSearch, "Plan": .plan,

        // Codex. `write_stdin` writes into a process an earlier command opened, which is part
        // of the same shell interaction and no less consequential than opening it.
        "exec": .bash, "exec_command": .bash, "shell_command": .bash,
        "shell": .bash, "local_shell": .bash, "write_stdin": .bash,

        // A patch carries old *and* new text, so it is an edit rather than a whole-file
        // write — which is what lets `CodexPatch` feed the same `DiffView`.
        "apply_patch": .edit,

        "view_image": .read,
        "update_plan": .plan,
        "web_search": .webSearch
    ]

    init(_ rawName: String) {
        if let known = Self.identitiesByName[rawName] {
            self = known
        } else if rawName.hasPrefix("mcp__") {
            self = .mcp(rawName)
        } else {
            self = .unknown(rawName)
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
        case .taskCreate: return "TaskCreate"
        case .taskUpdate: return "TaskUpdate"
        case .taskList: return "TaskList"
        case .taskGet: return "TaskGet"
        case .todoWrite: return "TodoWrite"
        case .todoRead: return "TodoRead"
        case .toolSearch: return "ToolSearch"
        case .plan: return "Plan"
        case .mcp(let name), .unknown(let name): return name
        }
    }
}

/// One piece of an assistant message.
enum ContentBlock: Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, tool: ToolIdentity, input: [String: JSONValue])
}

// MARK: - Tool Result

struct ToolResult: Sendable {
    let toolUseID: String
    let text: String
    let isError: Bool
}

// MARK: - JSON Value

/// Arbitrary JSON retained inside typed provider envelopes, primarily for tool arguments and
/// results whose schemas belong to the tool rather than to the stream protocol.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    /// A Foundation value this model cannot represent, named by the type it had.
    ///
    /// Only `converting(foundationValue:)` produces it, and only for something
    /// `JSONSerialization` never emits — so it marks an in-process caller's mistake rather than
    /// a provider's malformed line. It exists because the alternative already shipped: the
    /// container conversion below is all-or-nothing, and its callers spelled that `?? [:]` or
    /// `return nil`, so **one** member the bridge could not read discarded a whole tool input,
    /// audit payload or replayed row with nothing left to say anything had been there.
    ///
    /// It carries the type's name and never the value. This marker must never become a way for
    /// content to reach a ledger around `ExecutionAuditSanitizer`.
    ///
    /// It is deliberately not symmetric under `Codable`, because there is no JSON for "not
    /// JSON": it encodes as the `<unconvertible:Type>` placeholder — the spelling the execution
    /// audit's redactions already use — and decoding reads that back as the string it now is.
    /// Decoding never produces this case, since JSON text is JSON by definition.
    case unconvertible(String)

    /// How an unconvertible value is spelled wherever JSON itself is required.
    static func unconvertibleMarker(_ describedType: String) -> String {
        "<unconvertible:\(describedType)>"
    }

    /// The scalar half of the Foundation bridge, shared by both conversions below.
    ///
    /// **`NSNumber` is matched before `Bool`, and the order is the whole point.** A number
    /// `JSONSerialization` parsed is an `NSNumber`, and `NSNumber as? Bool` succeeds for exactly
    /// the values `0` and `1` — so matching `Bool` first turned a wire `1` into `true` and a wire
    /// `0` into `false`, silently, everywhere a provider payload reached this initializer. The
    /// `CFBooleanGetTypeID` test below is the honest question, because it asks what the number
    /// *is* rather than what it could be read as. A Swift `Bool` still lands there: it bridges to
    /// `__NSCFBoolean`, which that test recognises.
    private static func scalar(foundationValue value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                return .integer(value.int64Value)
            }
            return .number(value.doubleValue)
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        default:
            return nil
        }
    }

    /// The strict bridge: a container is converted whole or not at all.
    ///
    /// Reach for this only where a *partial* answer would be worse than no answer — the two
    /// permission surfaces, which show a person the arguments they are approving and refuse the
    /// request explicitly rather than ask about half of it. Everywhere else the honest bridge is
    /// `converting(foundationValue:)`, which keeps what it can and names what it cannot.
    init?(foundationValue value: Any) {
        if let scalar = Self.scalar(foundationValue: value) {
            self = scalar
            return
        }
        switch value {
        case let value as [Any]:
            let converted = value.compactMap(JSONValue.init(foundationValue:))
            guard converted.count == value.count else { return nil }
            self = .array(converted)
        case let value as [String: Any]:
            guard let converted = Self.object(from: value) else { return nil }
            self = .object(converted)
        default:
            return nil
        }
    }

    /// The strict container bridge. See `init?(foundationValue:)` for when that is the right ask.
    static func object(from value: [String: Any]) -> [String: JSONValue]? {
        var converted: [String: JSONValue] = [:]
        converted.reserveCapacity(value.count)
        for (key, raw) in value {
            guard let item = JSONValue(foundationValue: raw) else { return nil }
            converted[key] = item
        }
        return converted
    }

    /// Bridges a Foundation value member by member, keeping everything that converts and
    /// marking everything that does not as `.unconvertible`.
    ///
    /// Every member keeps its place, so a reader sees a value was there and what type it had.
    /// This never fails, which is the point: the shape of the record survives.
    static func converting(foundationValue value: Any) -> JSONValue {
        if let scalar = Self.scalar(foundationValue: value) { return scalar }
        switch value {
        case let value as [Any]:
            return .array(value.map(JSONValue.converting(foundationValue:)))
        case let value as [String: Any]:
            return .object(convertingObject(from: value))
        default:
            return .unconvertible(String(describing: type(of: value)))
        }
    }

    /// The per-member container bridge. See `converting(foundationValue:)`.
    static func convertingObject(from value: [String: Any]) -> [String: JSONValue] {
        value.mapValues(JSONValue.converting(foundationValue:))
    }

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
        case .unconvertible(let describedType):
            try container.encode(Self.unconvertibleMarker(describedType))
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

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// The value read as a whole number, the way `NSNumber.intValue` reads one.
    ///
    /// A boolean is not a number here even though Foundation will hand one over as `1`: a token
    /// count of `true` is a protocol error, not a count of one. A non-integral number truncates
    /// toward zero and an out-of-range one saturates, both matching `intValue`.
    var integerValue: Int? {
        switch self {
        case .integer(let value):
            return Int(truncatingIfNeeded: value)
        case .number(let value):
            return Int(exactly: value.rounded(.towardZero)) ?? (value < 0 ? .min : .max)
        case .object, .array, .string, .bool, .null, .unconvertible:
            return nil
        }
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
        case .unconvertible(let describedType):
            return Self.unconvertibleMarker(describedType)
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

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int64) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
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
        ThreadingLogger.agent.warning(
            "Skipped malformed \(provider, privacy: .public) stream line; total \(total, privacy: .public)"
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
            switch wire.subtype {
            case "init":
                event = .initialised(
                    sessionID: wire.sessionID.map(TranscriptID.init),
                    model: wire.model
                )
            case "background_tasks_changed":
                // The list is the whole truth each time, including empty. Verified against CLI
                // 2.1.220: one of these arrives as a backgrounded shell starts and another,
                // empty, as the last one ends. The stream spells the identity `task_id` where
                // the hook payload spells it `id`; a missing one falls back to its position,
                // which is stable for as long as the entry is.
                //
                // It spells the *kind* differently too — `task_type` here, carrying the raw
                // discriminant (`local_agent`), against the hook's `type` carrying the friendly
                // label (`subagent`). `BackgroundWorkKind` reads both, which is why neither
                // surface needs to translate for the other.
                event = .backgroundWork(
                    inFlight: (wire.backgroundTasks ?? []).enumerated().map { index, task in
                        BackgroundTask(
                            id: task.objectValue?["task_id"]?.stringValue ?? "#\(index)",
                            kind: BackgroundWorkKind(
                                reportedType: task.objectValue?["task_type"]?.stringValue
                            )
                        )
                    }
                )
            default:
                return .events([.unknown(type: "system")])
            }

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
            // `.failed` rather than `.stopped`, even though Claude reports a user interrupt
            // through this same error channel (`subtype: "error_during_execution"`). That
            // subtype covers genuine execution faults too, so the wire cannot tell the two
            // apart. Only the session knows whether it asked for the interrupt, and it
            // restates the outcome on the way out — see `ClaudeStreamSession.outcome(for:)`.
            event = .turnFinished(
                text: wire.result,
                outcome: wire.isError ? .failed : .completed,
                metrics: TurnMetrics(
                    duration: wire.durationMS.map { $0 / 1_000 },
                    outputTokens: wire.usage?.outputTokens,
                    contextTokens: wire.usage?.contextTokens
                )
            )

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
                input: block.input?.objectValue ?? [:]
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
            // Per member, for the reason the Codex replay above is: a transcript row that
            // vanishes is indistinguishable from a tool the agent never called.
            let rawInput = block["input"] as? [String: Any] ?? [:]
            return .toolUse(
                id: id,
                tool: ToolIdentity(name),
                input: JSONValue.convertingObject(from: rawInput)
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
        // Per element. One `null` among a tool result's blocks drew the row with no output at
        // all, which reads as a tool that returned nothing rather than as text we could not read.
        guard let blocks = WireList.objects(
            content, site: WireListSite.claudeToolResultContent, log: ThreadingLogger.agent
        ) else { return "" }
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
    let durationMS: TimeInterval?
    let usage: ClaudeWireUsage?

    /// The in-flight background work carried by `background_tasks_changed`. Kept opaque: each
    /// entry describes a shell, child or monitor this side never renders, and only its identity
    /// and kind are read back out.
    let backgroundTasks: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case type, subtype, model, event, message, result, usage
        case sessionID = "session_id"
        case isError = "is_error"
        case durationMS = "duration_ms"
        case backgroundTasks = "tasks"
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
        durationMS = try? container.decode(TimeInterval.self, forKey: .durationMS)
        usage = try? container.decode(ClaudeWireUsage.self, forKey: .usage)
        backgroundTasks = try? container.decode([JSONValue].self, forKey: .backgroundTasks)
    }
}

private struct ClaudeWireUsage: Decodable {
    let outputTokens: Int?
    let inputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    /// The window the last request occupied: prompt, cache reads and creation, and the
    /// completion together. Claude's `input_tokens` excludes what was served from cache, so
    /// the parts are summed rather than any one being trusted alone. Nil when the record
    /// carried no input-side numbers at all — an output-only reading says nothing about
    /// context.
    var contextTokens: Int? {
        guard inputTokens != nil || cacheReadInputTokens != nil
                || cacheCreationInputTokens != nil else { return nil }
        return (inputTokens ?? 0)
            + (cacheReadInputTokens ?? 0)
            + (cacheCreationInputTokens ?? 0)
            + (outputTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
        case inputTokens = "input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
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
