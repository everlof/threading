import Foundation

/// The standard Agent Client Protocol wire shapes, read the same way for every ACP agent.
///
/// Nothing here reads `_meta`: the protocol sanctions that member as each agent's extension
/// point, so anything found under it belongs to an `ACPProviderProfile` rather than to the
/// shared runtime.
enum ACPWireAdapter {

    // MARK: - Session

    /// The model an agent reports in its standard `session/new` or `session/load` result.
    ///
    /// An agent that names its model somewhere else supplies `ACPProviderProfile.extendedModelID`
    /// instead of teaching this reader a second location.
    static func currentModel(in result: [String: Any]?) -> String? {
        let models = result?["models"] as? [String: Any]
        return models?["currentModelId"] as? String
    }

    static func sessionTitle(in update: [String: Any]) -> String? {
        guard let title = update["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func textContent(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func planSteps(in update: [String: Any]) -> [RunProgress.Step] {
        let entries = update["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let title = entry["content"] as? String,
                  let rawStatus = entry["status"] as? String,
                  let status = RunProgress.Step.Status(providerValue: rawStatus)
            else { return nil }
            return RunProgress.Step(id: nil, title: title, status: status)
        }
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
            guard let name = command["name"] as? String, !name.isEmpty,
                  let description = command["description"] as? String else { return nil }
            let input = command["input"] as? [String: Any]
            let availability: ComposerCapability.Availability =
                policy.hostOnlyNames.contains(name)
                    ? .unavailable(reason: policy.hostOnlyReason)
                    : .available
            return ComposerCapability(
                id: "\(policy.identifierPrefix)\(name)",
                name: name,
                description: description,
                argumentHint: input?["hint"] as? String ?? "",
                kind: .command,
                trigger: .slash,
                presentation: policy.sessionCommandNames.contains(name) ? .command : .turn,
                availability: availability
            )
        }
    }

    // MARK: - Tool Calls

    static func toolIdentity(kind: String?, title: String) -> ToolIdentity {
        switch kind {
        case "read": return .read
        case "edit", "delete", "move": return .edit
        case "search": return .grep
        case "execute": return .bash
        case "think": return .plan
        case "fetch": return .webFetch
        default: return ToolIdentity(title)
        }
    }

    static func toolInput(from payload: [String: Any]) -> [String: JSONValue] {
        JSONValue.object(from: toolInputFoundation(from: payload)) ?? [:]
    }

    static func toolInputFoundation(from payload: [String: Any]) -> [String: Any] {
        var input: [String: Any]
        if let object = payload["rawInput"] as? [String: Any] {
            input = object
        } else if let rawInput = payload["rawInput"], !(rawInput is NSNull) {
            input = ["input": rawInput]
        } else {
            input = [:]
        }

        if input["title"] == nil, let title = payload["title"] as? String {
            input["title"] = title
        }
        if input["kind"] == nil, let kind = payload["kind"] as? String {
            input["kind"] = kind
        }
        if input["file_path"] == nil,
           let locations = payload["locations"] as? [[String: Any]],
           let path = locations.first?["path"] as? String {
            input["file_path"] = path
        }
        if let contents = payload["content"] as? [[String: Any]],
           let diff = contents.first(where: { $0["type"] as? String == "diff" }) {
            input["file_path"] = input["file_path"] ?? diff["path"]
            input["old_string"] = input["old_string"] ?? diff["oldText"]
            input["new_string"] = input["new_string"] ?? diff["newText"]
        }
        return input
    }

    static func toolResultText(from payload: [String: Any]) -> String {
        if let rawOutput = payload["rawOutput"], !(rawOutput is NSNull) {
            if let text = rawOutput as? String { return text }
            return JSONRPCLineEnvelope.encodedText(rawOutput)
        }

        let contents = payload["content"] as? [[String: Any]] ?? []
        return contents.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content":
                guard let content = item["content"] as? [String: Any] else { return nil }
                if content["type"] as? String == "text" {
                    return content["text"] as? String
                }
                return nil
            case "diff":
                return item["path"] as? String
            case "terminal":
                return item["terminalId"] as? String
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Tool Call State

/// One tool call as the wire has described it so far.
///
/// ACP reports a call across `tool_call`, any number of `tool_call_update`s and a permission
/// request, each of which may carry only the fields that changed, so the merged payload is the
/// only complete description of what ran.
struct ACPToolCallState {
    var payload: [String: Any]
    var title: String
    var kind: String?
    var status: String?
    var didEmitCall = false
    var didEmitResult = false

    init(update: [String: Any]) {
        payload = update
        title = update["title"] as? String ?? ACPToolCallDefaults.title
        kind = update["kind"] as? String
        status = update["status"] as? String
    }

    mutating func merge(_ update: [String: Any]) {
        payload.merge(update) { _, new in new }
        if let value = update["title"] as? String { title = value }
        if let value = update["kind"] as? String { kind = value }
        if let value = update["status"] as? String { status = value }
    }
}

private enum ACPToolCallDefaults {
    static let title = "tool"
}

// MARK: - Turn Outcome

extension TurnOutcome {
    /// Reads the stop reason ACP answers a `session/prompt` with.
    ///
    /// `cancelled` is the protocol's own word for a turn the client ended through
    /// `session/cancel`, and the spec is explicit that an agent must answer with it rather than
    /// with an error precisely so the two can be told apart. A refusal is a real failure; an
    /// unrecognised reason completes rather than inventing one.
    init(acpStopReason reason: String?) {
        switch reason {
        case "cancelled": self = .stopped
        case "refusal": self = .failed
        default: self = .completed
        }
    }
}
