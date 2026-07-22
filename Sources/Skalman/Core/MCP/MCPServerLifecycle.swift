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

        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token) else {
            return
        }

        let payload = (try? JSONSerialization.jsonObject(with: request.body))
            as? [String: Any] ?? [:]

        guard let report = HookLifecycleReport(
            sessionID: sessionID,
            event: Self.event(inQuery: parts.count > 1 ? String(parts[1]) : nil),
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
