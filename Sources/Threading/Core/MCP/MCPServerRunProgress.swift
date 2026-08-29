import Foundation

// MARK: - Run progress reports

extension MCPServer {
    /// Accepts a structured todo/plan hook without ever speaking back to the provider.
    func routeRunProgress(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let target = request.path.dropFirst(MCPDefaults.runProgressPathPrefix.count)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count > 1 ? String(parts[1]) : nil

        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token),
              let phase = Self.runProgressPhase(inQuery: query),
              let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let report = HookRunProgressReport(
                  sessionID: sessionID,
                  phase: phase,
                  payload: payload
              ) else {
            respond(.accepted)
            EventLog.shared.record(.hooks, "Ignored malformed run progress report", [
                "query": query ?? ""
            ])
            return
        }

        respond(.accepted)
        DispatchQueue.main.async {
            HookRunProgressRelay.deliver(report)
        }
    }

    static func runProgressPhase(inQuery query: String?) -> HookRunProgressPhase? {
        guard let query,
              let value = URLComponents(string: "?\(query)")?
                .queryItems?
                .first(where: { $0.name == MCPDefaults.runProgressPhaseParameter })?
                .value else { return nil }
        return HookRunProgressPhase(rawValue: value)
    }
}
