import Foundation
import ThreadingController

// MARK: - Mail Notice Hook

/// The answering hook's endpoint: `/mail-notice/<token>?event=post-tool-use|stop|session-start`.
///
/// Every other hook this listener serves is silent by contract. This one is the deliberate,
/// narrow exception the agent-mail draft records: its reply is hook JSON carrying **one
/// host-authored notice line** — counts, senders, hosts, never message text — or an empty body.
/// The controller decides the notice (`mailNotice`), including its bounds: each message is
/// announced once per event kind and blocks a stop at most once, and nothing is said when no
/// unannounced mail is waiting. A failure of any kind answers empty, because a hook that errors
/// surfaces inside the agent's turn and a missed notice only delays mail.
extension MCPServer {

    func routeMailNotice(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let target = request.path.dropFirst(MCPDefaults.mailNoticePathPrefix.count)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count > 1 ? String(parts[1]) : nil

        guard let token = parts.first.map(String.init),
              let sessionID = MCPSessionRegistry.session(forToken: token),
              let event = Self.mailNoticeEvent(inQuery: query) else {
            respond(MacMailHookOutput.silence)
            return
        }

        Task { @MainActor in
            // The Tools page's "Other sessions" switch is the off switch for mail too.
            // A host-local mailbox is told about by the host's own `agent-notice`.
            guard MCPToolCatalog.isEnabled(MCPToolCatalog.workspace),
                  !RemoteSessionMailboxes.shared.keepsMailOnHost(sessionID) else {
                return respond(MacMailHookOutput.silence)
            }
            // Any mail hook call after a blocked stop is the agent still running its turn.
            MailStopContinuationLedger.recordEvidence(sessionID)
            guard let notice = await MacMailbox.shared.notice(for: sessionID, event: event) else {
                return respond(MacMailHookOutput.silence)
            }
            if event == .stop,
               MailStopContinuationLedger.recordBlock(sessionID) == .reopenTurn,
               let reopened = HookLifecycleReport(sessionID: sessionID, event: .turnStarted, payload: [:]) {
                // The silent Stop hook's finish was already relayed: the turn this block
                // continues has to be open again before anything treats the session as idle.
                HookLifecycleRelay.observe?(reopened)
            }
            respond(MacMailHookOutput.response(event: event, notice: notice))
        }
    }

    static func mailNoticeEvent(inQuery query: String?) -> MailNoticeEvent? {
        guard let query,
              let value = URLComponents(string: "?\(query)")?
                .queryItems?
                .first(where: { $0.name == MCPDefaults.mailNoticeEventParameter })?
                .value else { return nil }
        return MailNoticeEvent(rawValue: value)
    }
}

// MARK: - Hook Output

/// The hook JSON both Claude Code and Codex accept, in the shape the controller's own
/// `agent-notice` command prints (`ControllerAgentNotice.hookOutput`): additional context after a
/// tool call or at session start, and a one-time block with a reason at a stop.
enum MacMailHookOutput {
    /// An empty 200: the hook prints nothing and the CLI carries on.
    static let silence = HTTPResponse(status: 200, reason: "OK", contentType: nil, body: Data())

    static func response(event: MailNoticeEvent, notice: String) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object(event: event, notice: notice),
                                                     options: [.sortedKeys]) else { return silence }
        return .json(data)
    }

    static func object(event: MailNoticeEvent, notice: String) -> [String: Any] {
        switch event {
        case .stop:
            return ["decision": "block", "reason": notice]
        case .postToolUse, .sessionStart:
            return ["hookSpecificOutput": [
                "hookEventName": event == .postToolUse ? "PostToolUse" : "SessionStart",
                "additionalContext": notice
            ]]
        }
    }
}
