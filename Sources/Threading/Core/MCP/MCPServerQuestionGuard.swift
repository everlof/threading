import Foundation

// MARK: - Question Guard Hook

/// The answering hook's endpoint: `/question-guard/<token>?event=pre-tool-use|stop`.
///
/// Like `/mail-notice/`, a deliberate exception to "hooks are silent": its reply is hook JSON or
/// an empty body. `WorkroomQuestionGuard` decides; this only parses the route and the hook's own
/// payload, and keeps the continuation ledger honest when a `Stop` is blocked.
extension MCPServer {

    func routeQuestionGuard(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let target = request.path.dropFirst(MCPDefaults.questionGuardPathPrefix.count)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token),
              parts.count > 1,
              let raw = URLComponents(string: "?\(parts[1])")?.queryItems?
                .first(where: { $0.name == MCPDefaults.questionGuardEventParameter })?.value,
              let event = WorkroomQuestionGuard.Event(rawValue: raw) else {
            respond(MacMailHookOutput.silence)
            return
        }
        let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let snapshot = WorkroomQuestionGuardPayload(payload)
        Task { @MainActor in
            // A guard call after a blocked stop is, like a mail-hook call, the turn going on.
            MailStopContinuationLedger.recordEvidence(sessionID)
            guard let reply = await WorkroomQuestionGuard.decide(sessionID, event: event, payload: snapshot.values),
                  let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else {
                return respond(MacMailHookOutput.silence)
            }
            if event == .stop { Self.recordStopBlock(sessionID) }
            respond(.json(data))
        }
    }
}

/// The few hook-payload fields the guard reads, copied out of the untyped JSON so only Sendable
/// values cross into the main actor.
struct WorkroomQuestionGuardPayload: Sendable {
    let toolName: String?
    let stopHookActive: Bool?
    let lastAssistantMessage: String?
    let turnID: String?

    init(_ payload: [String: Any]) {
        toolName = payload["tool_name"] as? String
        stopHookActive = payload["stop_hook_active"] as? Bool
        lastAssistantMessage = (payload["last_assistant_message"] as? String).map { String($0.suffix(8_192)) }
        turnID = payload["turn_id"] as? String
    }

    var values: [String: Any] {
        var values: [String: Any] = [:]
        values["tool_name"] = toolName
        values["stop_hook_active"] = stopHookActive
        values["last_assistant_message"] = lastAssistantMessage
        values["turn_id"] = turnID
        return values
    }
}
