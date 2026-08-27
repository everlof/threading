import Foundation

/// The standard Agent Client Protocol wire shapes, read the same way for every ACP agent.
///
/// Nothing here reads `_meta`: the protocol sanctions that member as each agent's extension
/// point, so anything found under it belongs to an `ACPProviderProfile` rather than to the
/// shared runtime.
///
/// **Every reader below works on `JSONValue`, not on `Any`.** The transport still hands over the
/// dictionary `JSONSerialization` produced — that boundary is shared with the Codex app-server
/// adapter — so each entry point converts once at the door through `fields(of:)` and nothing
/// underneath performs a dynamic cast. The vocabularies the protocol closes (a content block's
/// type, a plan status, a stop reason) are enumerations with an `unknown` case, so a value this
/// client does not recognise stays visible as itself instead of turning into `nil` halfway down a
/// chain of optional casts.
enum ACPWireAdapter {

    // MARK: - Payloads

    /// Reads one wire payload as JSON.
    ///
    /// Every member arrived from `JSONSerialization`, so every member is already a JSON value and
    /// nothing is dropped in practice. The per-key conversion is deliberate all the same: the
    /// all-or-nothing container rule exists so tool-owned JSON survives a round trip intact, and
    /// applying it to *naming a field* would mean one unreadable member costing the whole
    /// message — a title, a status, an entire assistant chunk — which is precisely the silent
    /// loss this adapter must not introduce.
    static func fields(of payload: [String: Any]) -> [String: JSONValue] {
        payload.compactMapValues(JSONValue.init(foundationValue:))
    }

    /// The array at `value`, but only when every element is an object.
    ///
    /// `as? [[String: Any]]`, which the readers below used to spell, is all-or-nothing: one
    /// non-object element yields no array at all rather than the elements that did parse. That is
    /// kept rather than quietly improved, because recovering the readable half of a malformed
    /// `content` array would change which tool rows an agent's mistake produces, and this
    /// conversion is not the place to decide that.
    private static func objectArray(_ value: JSONValue?) -> [[String: JSONValue]]? {
        guard let list = value?.arrayValue else { return nil }
        let objects = list.compactMap(\.objectValue)
        return objects.count == list.count ? objects : nil
    }

    // MARK: - Session

    /// The model an agent reports in its standard `session/new` or `session/load` result.
    ///
    /// An agent that names its model somewhere else supplies `ACPProviderProfile.extendedModelID`
    /// instead of teaching this reader a second location.
    static func currentModel(in result: [String: Any]?) -> String? {
        guard let result else { return nil }
        return fields(of: result)["models"]?.objectValue?["currentModelId"]?.stringValue
    }

    static func sessionTitle(in update: [String: Any]) -> String? {
        guard let title = fields(of: update)["title"]?.stringValue else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func textContent(in update: [String: Any]) -> String? {
        guard let block = ACPContentBlock(fields(of: update)["content"]),
              block.kind == .text
        else { return nil }
        return block.text
    }

    /// What an agent says the turn has spent of its context window.
    static func contextUsage(in update: [String: Any]) -> ACPContextUsage {
        let fields = fields(of: update)
        return ACPContextUsage(
            used: fields["used"]?.integerValue,
            size: fields["size"]?.integerValue
        )
    }

    static func planSteps(in update: [String: Any]) -> [RunProgress.Step] {
        ACPPlanUpdate(fields(of: update)).steps
    }

    // MARK: - Command Catalog

    /// Turns an agent's advertised commands into the provider-neutral composer catalog.
    ///
    /// The wire shape is standard; which commands the host refuses, and how a session-owning one
    /// is presented, is the profile's policy.
    static func composerCapabilities(
        from commands: [[String: Any]],
        policy: ACPCommandCatalogPolicy
    ) -> [ComposerCapability] {
        commands.compactMap { command in
            let command = fields(of: command)
            guard let name = command["name"]?.stringValue, !name.isEmpty,
                  let description = command["description"]?.stringValue else { return nil }
            let availability: ComposerCapability.Availability =
                policy.hostOnlyNames.contains(name)
                    ? .unavailable(reason: policy.hostOnlyReason)
                    : .available
            return ComposerCapability(
                id: "\(policy.identifierPrefix)\(name)",
                name: name,
                description: description,
                argumentHint: command["input"]?.objectValue?["hint"]?.stringValue ?? "",
                kind: .command,
                trigger: .slash,
                presentation: policy.sessionCommandNames.contains(name) ? .command : .turn,
                availability: availability
            )
        }
    }

    // MARK: - Tool Calls

    static func toolIdentity(kind: ACPToolCallKind?, title: String) -> ToolIdentity {
        switch kind {
        case .read: return .read
        case .edit, .delete, .move: return .edit
        case .search: return .grep
        case .execute: return .bash
        case .think: return .plan
        case .fetch: return .webFetch
        case .unknown, .none: return ToolIdentity(title)
        }
    }

    static func toolInput(from payload: [String: Any]) -> [String: JSONValue] {
        toolInput(from: fields(of: payload))
    }

    /// The arguments to show for a tool call, assembled from wherever ACP put them.
    ///
    /// `rawInput` is the tool's own JSON and is therefore kept verbatim; everything added around
    /// it is protocol metadata this client has to fold in, because the standard fields an agent
    /// reports beside the call — its title, its kind, the file it touched, the diff it produced —
    /// are the only description of the call some agents send at all. A value the tool already
    /// supplied always wins: the merge fills gaps and never overwrites.
    static func toolInput(from payload: [String: JSONValue]) -> [String: JSONValue] {
        var input: [String: JSONValue]
        switch payload["rawInput"] {
        case .object(let object): input = object
        case .null, .none: input = [:]
        case .some(let value): input = [ACPToolInputKey.wrappedRawInput: value]
        }

        if input[ACPToolInputKey.title] == nil, let title = payload["title"]?.stringValue {
            input[ACPToolInputKey.title] = .string(title)
        }
        if input[ACPToolInputKey.kind] == nil, let kind = payload["kind"]?.stringValue {
            input[ACPToolInputKey.kind] = .string(kind)
        }
        if input[ACPToolInputKey.filePath] == nil,
           let locations = objectArray(payload["locations"]),
           let path = locations.first?["path"]?.stringValue {
            input[ACPToolInputKey.filePath] = .string(path)
        }
        if let contents = objectArray(payload["content"]),
           let diff = contents.first(where: { ACPToolCallContentKind($0["type"]) == .diff }) {
            input[ACPToolInputKey.filePath] = input[ACPToolInputKey.filePath] ?? diff["path"]
            input[ACPToolInputKey.oldString] = input[ACPToolInputKey.oldString] ?? diff["oldText"]
            input[ACPToolInputKey.newString] = input[ACPToolInputKey.newString] ?? diff["newText"]
        }
        return input
    }

    static func toolResultText(from payload: [String: Any]) -> String {
        toolResultText(from: fields(of: payload))
    }

    /// What a finished tool call has to say for itself.
    ///
    /// `rawOutput` is the tool's own answer and wins when it is there. Absent or explicitly null,
    /// the protocol's own content blocks answer instead — which is why those two share a branch
    /// below rather than being guarded before the switch: "the agent sent no raw output" and "the
    /// agent sent null" are the same statement about this call.
    static func toolResultText(from payload: [String: JSONValue]) -> String {
        switch payload["rawOutput"] {
        case .string(let text): return text
        case .object, .array:
            // Serialized through the transport's encoder rather than `JSONValue.encodedText()`
            // so the text an agent's output produces does not change with the representation.
            return JSONRPCLineEnvelope.encodedText(payload["rawOutput"]?.foundationValue)
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null, .none: break
        }

        let contents = objectArray(payload["content"]) ?? []
        return contents.compactMap { item -> String? in
            switch ACPToolCallContentKind(item["type"]) {
            case .content:
                guard let block = ACPContentBlock(item["content"]), block.kind == .text else {
                    return nil
                }
                return block.text
            case .diff:
                return item["path"]?.stringValue
            case .terminal:
                return item["terminalId"]?.stringValue
            case .absent, .unknown:
                return nil
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Content

/// One ACP content block.
///
/// The type is read as a closed vocabulary so a block this client does not render is a named
/// kind rather than a failed cast: `textContent(in:)` and a tool result both have to say "this
/// was a block, and it was not text", which two chained `as?` casts cannot distinguish from
/// "there was no block at all".
struct ACPContentBlock {
    let kind: ACPContentBlockKind
    let text: String?

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue,
              let type = object["type"]?.stringValue else { return nil }
        kind = ACPContentBlockKind(providerValue: type)
        text = object["text"]?.stringValue
    }
}

enum ACPContentBlockKind: Equatable, Sendable {
    case text
    case image
    case audio
    case resource
    case resourceLink
    case unknown(String)

    init(providerValue: String) {
        switch providerValue {
        case "text": self = .text
        case "image": self = .image
        case "audio": self = .audio
        case "resource": self = .resource
        case "resource_link": self = .resourceLink
        default: self = .unknown(providerValue)
        }
    }
}

/// The three shapes a tool call's `content` entries take, plus the two ways one can fail to say.
enum ACPToolCallContentKind: Equatable, Sendable {
    case content
    case diff
    case terminal
    /// No `type` member, or one that is not a string.
    case absent
    case unknown(String)

    init(_ value: JSONValue?) {
        guard let providerValue = value?.stringValue else {
            self = .absent
            return
        }
        switch providerValue {
        case "content": self = .content
        case "diff": self = .diff
        case "terminal": self = .terminal
        default: self = .unknown(providerValue)
        }
    }
}

// MARK: - Session Updates

/// The `usage_update` session notification.
struct ACPContextUsage: Equatable, Sendable {
    let used: Int?
    let size: Int?
}

/// The `plan` session notification.
struct ACPPlanUpdate {
    struct Entry {
        let title: String?
        let status: ACPPlanEntryStatus?

        init(_ fields: [String: JSONValue]) {
            title = fields["content"]?.stringValue
            status = fields["status"]?.stringValue.map(ACPPlanEntryStatus.init(providerValue:))
        }
    }

    let entries: [Entry]

    init(_ fields: [String: JSONValue]) {
        // All-or-nothing, matching the `as? [[String: Any]]` this replaced: a malformed element
        // withdraws the plan rather than presenting a partial one the agent never described.
        let raw = fields["entries"]?.arrayValue ?? []
        let objects = raw.compactMap(\.objectValue)
        entries = objects.count == raw.count ? objects.map(Entry.init) : []
    }

    /// The steps the run indicator can draw.
    ///
    /// An entry whose status this client does not know is left out rather than guessed at, which
    /// is what the run indicator did before this was typed. The difference is that the omission
    /// is now a named branch: a status ACP adds later arrives here as `.unknown` and can be
    /// answered on purpose, instead of vanishing into a failed initializer three types away.
    var steps: [RunProgress.Step] {
        entries.compactMap { entry in
            guard let title = entry.title, let status = entry.status else { return nil }
            switch status {
            case .pending: return RunProgress.Step(id: nil, title: title, status: .pending)
            case .inProgress: return RunProgress.Step(id: nil, title: title, status: .inProgress)
            case .completed: return RunProgress.Step(id: nil, title: title, status: .completed)
            case .unknown: return nil
            }
        }
    }
}

enum ACPPlanEntryStatus: Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown(String)

    init(providerValue: String) {
        switch providerValue {
        case "pending": self = .pending
        // The specification says `in_progress`; the camel spelling is accepted because the
        // reader this replaced accepted it, and an agent that sends it is understood today.
        case "in_progress", "inProgress": self = .inProgress
        case "completed": self = .completed
        default: self = .unknown(providerValue)
        }
    }
}

// MARK: - Tool Call State

/// One tool call as the wire has described it so far.
///
/// ACP reports a call across `tool_call`, any number of `tool_call_update`s and a permission
/// request, each of which may carry only the fields that changed, so the merged payload is the
/// only complete description of what ran.
struct ACPToolCallState {
    var payload: [String: JSONValue]
    var title: String
    var kind: ACPToolCallKind?
    var status: ACPToolCallStatus?
    var didEmitCall = false
    var didEmitResult = false

    init(update: [String: Any]) {
        payload = ACPWireAdapter.fields(of: update)
        title = payload["title"]?.stringValue ?? ACPToolCallDefaults.title
        kind = payload["kind"]?.stringValue.map(ACPToolCallKind.init(providerValue:))
        status = payload["status"]?.stringValue.map(ACPToolCallStatus.init(providerValue:))
    }

    mutating func merge(_ update: [String: Any]) {
        let update = ACPWireAdapter.fields(of: update)
        payload.merge(update) { _, new in new }
        if let value = update["title"]?.stringValue { title = value }
        if let value = update["kind"]?.stringValue {
            kind = ACPToolCallKind(providerValue: value)
        }
        if let value = update["status"]?.stringValue {
            status = ACPToolCallStatus(providerValue: value)
        }
    }
}

enum ACPToolCallKind: Equatable, Sendable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case unknown(String)

    init(providerValue: String) {
        switch providerValue {
        case "read": self = .read
        case "edit": self = .edit
        case "delete": self = .delete
        case "move": self = .move
        case "search": self = .search
        case "execute": self = .execute
        case "think": self = .think
        case "fetch": self = .fetch
        default: self = .unknown(providerValue)
        }
    }

    var providerValue: String {
        switch self {
        case .read: return "read"
        case .edit: return "edit"
        case .delete: return "delete"
        case .move: return "move"
        case .search: return "search"
        case .execute: return "execute"
        case .think: return "think"
        case .fetch: return "fetch"
        case .unknown(let value): return value
        }
    }
}

enum ACPToolCallStatus: Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case unknown(String)

    init(providerValue: String) {
        switch providerValue {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .unknown(providerValue)
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

private enum ACPToolCallDefaults {
    static let title = "tool"
}

/// The keys `toolInput(from:)` writes, which are the neutral names the tool rows already read.
private enum ACPToolInputKey {
    static let wrappedRawInput = "input"
    static let title = "title"
    static let kind = "kind"
    static let filePath = "file_path"
    static let oldString = "old_string"
    static let newString = "new_string"
}

// MARK: - Turn Outcome

/// The reason ACP gives for a `session/prompt` returning.
enum ACPStopReason: Equatable, Sendable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    /// The agent answered without naming a reason. The member is optional in the protocol, so
    /// this is a silence rather than a word this client failed to recognise.
    case absent
    case unknown(String)

    init(providerValue: String?) {
        switch providerValue {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        case .some(let value): self = .unknown(value)
        case .none: self = .absent
        }
    }
}

extension TurnOutcome {
    /// Reads the stop reason ACP answers a `session/prompt` with.
    ///
    /// `cancelled` is the protocol's own word for a turn the client ended through
    /// `session/cancel`, and the spec is explicit that an agent must answer with it rather than
    /// with an error precisely so the two can be told apart. A refusal is a real failure; an
    /// unrecognised reason completes rather than inventing one.
    ///
    /// The switch is exhaustive on purpose: a reason added to `ACPStopReason` has to be answered
    /// here rather than falling into `completed` because nobody revisited this line.
    init(acpStopReason reason: String?) {
        switch ACPStopReason(providerValue: reason) {
        case .cancelled: self = .stopped
        case .refusal: self = .failed
        case .endTurn, .maxTokens, .maxTurnRequests, .absent, .unknown: self = .completed
        }
    }
}
