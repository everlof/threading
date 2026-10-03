import Foundation
import ThreadingController

// MARK: - Mail Notice Hook

/// The answering hook entries for agent mail, for both runtimes whose hooks can answer
/// (`AgentCapabilities.answeringMailHooks`).
///
/// They sit **beside** the silent lifecycle hooks, never inside them: the lifecycle commands and
/// their frozen-text test are unchanged. These differ in exactly one respect — curl's stdout is
/// the hook's stdout, because the reply is the point — and keep everything else: stderr is
/// discarded, failure is swallowed so the hook always exits 0, and the timeout is short. An app
/// that is not running therefore prints nothing, and the agent carries on.
enum MailNoticeHook {
    /// Registered for these three events, each as its own entry with no tool matcher.
    static let events: [MailNoticeEvent] = [.postToolUse, .stop, .sessionStart]

    /// The runtime's own hook name for an event. Claude and Codex spell all three the same.
    static func hookName(for event: MailNoticeEvent) -> String {
        switch event {
        case .postToolUse: return "PostToolUse"
        case .stop: return "Stop"
        case .sessionStart: return "SessionStart"
        }
    }

    /// Whether a terminal launch of this runtime gets the answering entries: its hooks must be
    /// able to answer, and the "Other sessions" tools — whose `mail_inbox` the notice names —
    /// must be on.
    @MainActor
    static func isWanted(for kind: AgentKind) -> Bool {
        kind.supports(.answeringMailHooks) && MCPToolCatalog.isEnabled(MCPToolCatalog.workspace)
    }

    static func endpoint(token: String, event: MailNoticeEvent) -> String {
        "\(MCPDefaults.mailNoticePathPrefix)\(token)?\(MCPDefaults.mailNoticeEventParameter)=\(event.rawValue)"
    }

    /// The host-local form for a session whose mailbox lives on its remote host: the hook runs
    /// the controller's own `agent-notice`, which reads the mailbox address and credential from
    /// the agent's environment and prints the same hook JSON, or nothing. It needs neither this
    /// Mac nor the tunnel. Stderr and failure are swallowed exactly as above.
    ///
    /// The Mac still has to *know* when that hook blocked a Stop: its silent lifecycle Stop hook
    /// reports a finished turn either way, and `MailStopContinuationLedger` keeps the session from
    /// being shown idle while the agent continues. So after answering, the hook also tells this
    /// Mac what it answered — in the background, through the tunnel like the lifecycle hooks, and
    /// only while a session token is set. The Mac's reply to that is always empty; a host that
    /// cannot reach the Mac answers its agent exactly the same.
    static func hostCommand(executable: String, event: MailNoticeEvent) -> String {
        let payload = "threading_hook_payload", answer = "threading_mail_answer"
        let observed = "threading_mail_observed"
        let report = MCPDefaults.hookPostCommand(
            payloadVariable: payload,
            endpointSuffix: observedEndpoint(event: event, observedVariable: observed),
            timeout: MCPDefaults.mailNoticeTimeout
        )
        return "\(payload)=$(cat); "
            + "\(answer)=$(printf '%s' \"$\(payload)\" | \(ShellCommand(word: executable).source) agent-notice \(event.rawValue) 2>/dev/null); "
            + "\(observed)=\(MCPDefaults.mailNoticeObservedSeen); "
            + "[ -n \"$\(answer)\" ] && \(observed)=\(MCPDefaults.mailNoticeObservedBlock); "
            + "[ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ] && { \(payload)='{}'; \(report) >/dev/null 2>&1 & }; "
            + "printf '%s' \"$\(answer)\"; true"
    }

    /// `/mail-notice/$THREADING_SESSION_TOKEN?event=…&observed=$…`: the session token expands on
    /// the host, as the Codex entries' does.
    static func observedEndpoint(event: MailNoticeEvent, observedVariable: String) -> String {
        "\(MCPDefaults.mailNoticePathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.mailNoticeEventParameter)=\(event.rawValue)"
            + "&\(MCPDefaults.mailNoticeObservedParameter)=$\(observedVariable)"
    }

    /// `settings` with the host-local notice entries appended beside whatever hooks it holds.
    static func addingHostNoticeHooks(to settings: [String: Any], executable: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let name = hookName(for: event)
            var entries = hooks[name] as? [[String: Any]] ?? []
            entries.append(["hooks": [["type": "command", "command": hostCommand(executable: executable, event: event)]]])
            hooks[name] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Claude's entry: the token is baked into the per-session `--settings` file.
    static func claudeCommand(token: String, event: MailNoticeEvent) -> String {
        let payload = "threading_hook_payload"
        return "\(payload)=$(cat); " + MCPDefaults.hookPostCommand(
            payloadVariable: payload,
            endpointSuffix: endpoint(token: token, event: event),
            timeout: MCPDefaults.mailNoticeTimeout
        ) + " 2>/dev/null || true"
    }
}
