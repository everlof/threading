import Foundation

// MARK: - Lifecycle Reports

/// The listener's second non-MCP endpoint, alongside permissions.
///
/// It lives in its own file rather than in `MCPServer` because it shares only the socket with
/// the JSON-RPC surface: a lifecycle report is a plain JSON POST from a command hook, speaks no
/// MCP, and is answered before it is even read.
extension MCPServer {

    /// Records a lifecycle hook's report of a turn boundary.
    ///
    /// The opposite of `routePermission` in the one way that matters: it answers immediately and
    /// never blocks. These hooks fire on the agent's own turn boundaries, so any pause here is
    /// latency the user feels before their prompt is answered — and nothing in the reply is
    /// read.
    ///
    /// The event is named in the query string rather than taken from the body, which keeps one
    /// endpoint per session while still distinguishing the events, and avoids depending on the
    /// payload's own event field — the two CLIs spell it differently.
    func routeLifecycle(
        _ request: HTTPRequest,
        respond: @escaping (HTTPResponse) -> Void
    ) {
        // Answer first. Reading the body is this app's problem, not the agent's to wait for.
        respond(.accepted)

        let target = request.path.dropFirst(MCPDefaults.lifecyclePathPrefix.count)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count > 1 ? String(parts[1]) : nil

        // Every rejection below is logged rather than dropped. A hook that reached this app and
        // was ignored looks exactly like a hook that never ran, and the two have entirely
        // different causes — one is a stale `hooks.json`, the other a CLI that is not firing.
        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token) else {
            SkalmanLogger.mcp.warning("Lifecycle report for unknown token")
            EventLog.shared.record(.hooks, "Lifecycle report for unknown session token", [
                "query": query ?? ""
            ])
            return
        }

        guard let event = Self.event(inQuery: query) else {
            SkalmanLogger.mcp.warning("Lifecycle report naming no event: \(query ?? "", privacy: .public)")
            EventLog.shared.record(.hooks, "Lifecycle report named no known event", [
                "session": sessionID.uuidString,
                "query": query ?? ""
            ])
            return
        }

        // An empty body is the failure a probe found and a test now pins: a hook that guards
        // before draining stdin posts nothing, and the session identifier it was carrying is
        // lost in silence.
        if request.body.isEmpty {
            SkalmanLogger.mcp.warning("Lifecycle report with an empty body: \(event.rawValue, privacy: .public)")
            EventLog.shared.record(.hooks, "Lifecycle report arrived with no payload", [
                "session": sessionID.uuidString,
                "event": event.rawValue
            ])
        }

        let payload = (try? JSONSerialization.jsonObject(with: request.body))
            as? [String: Any] ?? [:]

        guard let report = HookLifecycleReport(
            sessionID: sessionID,
            event: event,
            payload: payload
        ) else {
            return
        }

        DispatchQueue.main.async {
            HookLifecycleRelay.deliver(report)
        }
    }

    /// Reads the `event` parameter out of a request's query string.
    ///
    /// An unrecognised or missing name yields nil, which `HookLifecycleReport` refuses outright:
    /// a report that cannot say which boundary it describes must not be allowed to guess, since
    /// every guess moves a session's state on no evidence.
    static func event(inQuery query: String?) -> HookLifecycleEvent? {
        guard let query,
              let value = URLComponents(string: "?\(query)")?
                .queryItems?
                .first(where: { $0.name == MCPDefaults.lifecycleEventParameter })?
                .value
        else {
            return nil
        }

        return HookLifecycleEvent(rawValue: value)
    }
}
