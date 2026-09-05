import Foundation

// MARK: - Lifecycle Reports

/// The listener's second non-MCP endpoint, alongside permissions.
///
/// It lives in its own file rather than in `MCPServer` because it shares only the socket with
/// the JSON-RPC surface: a lifecycle report is a plain JSON POST from a command hook and speaks
/// no MCP. Turn starts are the deliberate exception to immediate acknowledgement: their reply
/// is the barrier that keeps the agent behind its git baseline.
extension MCPServer {

    /// Records a lifecycle hook's report of a turn boundary.
    ///
    /// Most boundaries answer immediately. A turn start answers only after its checkout snapshot
    /// is stored, because acknowledging that hook is what lets the agent begin changing files.
    ///
    /// The event is named in the query string rather than taken from the body, which keeps one
    /// endpoint per session while still distinguishing the events, and avoids depending on the
    /// payload's own event field — the two CLIs spell it differently.
    func routeLifecycle(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let target = request.path.dropFirst(MCPDefaults.lifecyclePathPrefix.count)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count > 1 ? String(parts[1]) : nil

        // Every rejection below is logged rather than dropped. A hook that reached this app and
        // was ignored looks exactly like a hook that never ran, and the two have entirely
        // different causes — one is a stale `hooks.json`, the other a CLI that is not firing.
        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token) else {
            respond(.accepted)
            ThreadingLogger.mcp.warning("Lifecycle report for unknown token")
            EventLog.shared.record(.hooks, "Lifecycle report for unknown session token", [
                "query": query ?? ""
            ])
            return
        }

        guard let event = Self.event(inQuery: query) else {
            respond(.accepted)
            ThreadingLogger.mcp.warning(
                "Lifecycle report naming no event: \(query ?? "", privacy: .private(mask: .hash))"
            )
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
            ThreadingLogger.mcp.warning("Lifecycle report with an empty body: \(event.rawValue, privacy: .public)")
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
            respond(.accepted)
            return
        }

        if event == .turnFinished {
            ThreadingLogger.mcp.debug(
                "Codex/Claude turn finish received for \(sessionID.uuidString, privacy: .public)"
            )
            DispatchQueue.main.async {
                // Stamped before the checkout fence below can move ownership: this report's
                // `cwd` names where the finished turn ran, and after a commit that is the
                // checkout the chat has just left. See `HookLifecycleReport.capturedOwnershipEpoch`.
                let report = Self.stamped(report)
                self.gitTurnCheckpointStoreProvider().finishTurn(
                    sessionID: sessionID,
                    assistantTurnID: report.turnID,
                    providerTurnID: report.turnID,
                    settlePendingCheckoutMove: false
                ) { checkpoint in
                    ThreadingLogger.mcp.debug(
                        "Turn finish checkpoint settled for \(sessionID.uuidString, privacy: .public): \(checkpoint?.status.rawValue ?? "none", privacy: .public)"
                    )
                    // Stop is the provider's authoritative interactive-turn boundary even when
                    // it reports work left running. Acknowledge before replacing the runtime:
                    // the reporting curl is a child of that process and must be allowed to exit.
                    // Keep the lifecycle relay closed until the durable checkout fence settles,
                    // so no watcher or outbox can admit the next prompt into the old checkout.
                    respond(.accepted)
                    SessionCheckoutCoordinator.shared.finishPendingMove(sessionID: sessionID) { succeeded in
                        ThreadingLogger.mcp.debug(
                            "Turn finish checkout fence settled for \(sessionID.uuidString, privacy: .public): \(succeeded, privacy: .public)"
                        )
                        HookLifecycleRelay.deliver(report)
                        ThreadingLogger.mcp.debug(
                            "Turn finish relayed for \(sessionID.uuidString, privacy: .public)"
                        )
                    }
                }
            }
            return
        }

        guard event == .turnStarted else {
            respond(.accepted)
            DispatchQueue.main.async {
                HookLifecycleRelay.deliver(Self.stamped(report))
            }
            return
        }

        DispatchQueue.main.async {
            let report = Self.stamped(report)
            self.gitTurnCheckpointStoreProvider().prepareTurn(
                sessionID: sessionID,
                userTurnID: report.turnID,
                providerTurnID: report.turnID
            ) { _ in
                // Stored before the response: once curl sees this acknowledgement the CLI may
                // run a tool immediately, and Last Turn must already have its immutable start.
                respond(.accepted)
                HookLifecycleRelay.deliver(report)
            }
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

    /// Stamps a report with the checkout ownership it arrived under.
    ///
    /// Read on the main actor, and read *before* any checkout fence the same request goes on to
    /// run: the value is only meaningful as "ownership as it was when this hook fired", and the
    /// tracker discards the report if that has moved by the time it is classified.
    @MainActor
    private static func stamped(_ report: HookLifecycleReport) -> HookLifecycleReport {
        var stamped = report
        stamped.capturedOwnershipEpoch = SessionExecutionLocusTracker.shared
            .ownershipEpoch(forSessionID: report.sessionID)
        return stamped
    }
}
