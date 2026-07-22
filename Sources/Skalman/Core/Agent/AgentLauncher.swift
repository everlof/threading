import Foundation

// MARK: - Agent Launch Plan

/// A fully resolved command line for starting or resuming an agent session.
struct AgentLaunchPlan {
    let executable: String
    let arguments: [String]

    /// The session identifier this launch will use, when known up front.
    ///
    /// Set for Claude (we mint it) and for any resume. Nil for a fresh Codex launch,
    /// whose identifier must be discovered afterwards.
    let agentSessionID: String?
}

// MARK: - Agent Launcher

/// Builds command lines for starting and resuming agent sessions.
///
/// Launches are wrapped in a login shell because a GUI app does not inherit the
/// user's interactive `PATH`, and the agent CLIs typically live in `~/.local/bin`
/// or a Node prefix that only a login shell resolves.
enum AgentLauncher {

    // MARK: - Public Methods

    /// Builds the launch plan for a session, choosing a fresh launch or a resume
    /// based on whether the session has run before and carries a resumable identifier.
    static func plan(
        for session: AgentSession,
        in project: Project,
        initialPrompt: String? = nil
    ) -> AgentLaunchPlan {
        let command: String
        let sessionID: String?

        switch session.kind {
        case .claude:
            (command, sessionID) = claudeCommand(for: session, in: project, prompt: initialPrompt)
        case .codex:
            (command, sessionID) = codexCommand(for: session, prompt: initialPrompt)
        case .shell:
            (command, sessionID) = (shellCommand(), nil)
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            agentSessionID: sessionID
        )
    }

    /// Builds the plan for a session Skalman renders itself, rather than showing a terminal.
    ///
    /// Same login shell and same account routing as `plan(for:in:)` — a headless run inherits
    /// no more of the user's `PATH` than a PTY does. What differs is the interface: the CLI
    /// speaks JSON over pipes rather than drawing its terminal UI.
    ///
    /// No `initialPrompt`: the first turn is sent over the stream like every other, so the
    /// opening message needs no special path.
    static func streamPlan(for session: AgentSession, in project: Project) -> AgentLaunchPlan {
        switch session.kind {
        case .claude:
            return claudeStreamPlan(for: session, in: project)
        case .codex:
            return codexStreamPlan(for: session, in: project)
        case .shell:
            preconditionFailure("Shell sessions do not support native conversation rendering")
        }
    }

    /// Claude keeps one bidirectional stream open for the lifetime of the conversation.
    private static func claudeStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        let executable = AgentDefaults.claudeExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.claudeModelFlag)

        var command = "\(executable)\(model) --print"
            + " --input-format stream-json"
            + " --output-format stream-json"
            + " --include-partial-messages"
            + " --verbose"

        let agentSessionID: String?

        if session.isResumable,
           let existingID = session.agentSessionID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            command += " --resume \(quoted(existingID))"
            agentSessionID = existingID
        } else {
            let mintedID = session.agentSessionID ?? session.id.uuidString.lowercased()
            command += " --session-id \(quoted(mintedID))"
            agentSessionID = mintedID
        }

        if let settingsPath = MCPSessionRegistry.writePermissionSettings(for: session.id) {
            command += " --settings \(quoted(settingsPath))"
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            agentSessionID: agentSessionID
        )
    }

    /// Codex runs one JSONL-producing process per turn. The first creates a thread; later
    /// turns resume the identifier reported by `thread.started`.
    private static func codexStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        let executable = AgentDefaults.codexExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.codexModelFlag)

        let command: String
        if session.isResumable, let existingID = session.agentSessionID {
            command = "\(executable)\(model) --sandbox workspace-write"
                + " exec resume \(quoted(existingID)) --json -"
        } else {
            command = "\(executable)\(model) --sandbox workspace-write exec --json -"
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            agentSessionID: session.agentSessionID
        )
    }

    /// Builds a one-shot, headless `codex exec` run used for background research — icon
    /// discovery today.
    ///
    /// Routed to the default account (research belongs to a project, not any session — the
    /// same `env -u` rule as `accountPrefix`), sandboxed read-only because research must
    /// not write, and with reasoning effort turned down: the answer is a look-up, not a
    /// plan. No MCP flags — a run with no terminal has no panel to reach.
    static func codexResearchPlan(in folder: String, prompt: String) -> AgentLaunchPlan {
        let environmentKey = AgentKind.codex.accountEnvironmentKey ?? ""
        let accountPrefix = environmentKey.isEmpty ? "" : "env -u \(environmentKey) "

        let command = accountPrefix + AgentDefaults.codexExecutable
            + codexConfigOverride(
                AgentDefaults.codexReasoningEffortKey,
                string: AgentDefaults.codexResearchReasoningEffort
            )
            + " --sandbox read-only exec --json \(quoted(prompt))"

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(folder)) && exec \(command)"],
            agentSessionID: nil
        )
    }

    /// Flags registering Skalman's own MCP server for this session, or "" when unavailable.
    ///
    /// Each launch receives a URL carrying the session's token — that URL is what lets a tool
    /// call find the right display panel. Claude takes it through a per-session JSON config;
    /// Codex takes equivalent one-off TOML overrides, preserving the user's own MCP servers.
    ///
    /// Deliberately not `--strict-mcp-config`: that would suppress the user's own MCP servers
    /// for every session Skalman launches, which is a much larger change than adding one.
    ///
    /// Skalman's own tools are pre-approved because they call back into the app the user is
    /// already looking at. Without this, showing panel content or driving the browser raises a
    /// permission prompt every time, which costs more attention than the action it is guarding.
    private static func mcpFlags(for session: AgentSession) -> String {
        // Which tools are exposed is the user's choice on the Tools settings page. With every
        // group switched off there is nothing to register — and an empty `enabled_tools` list is
        // ambiguous to Codex (it can read as "all"), so the server is skipped outright rather than
        // handed an empty allowlist.
        let enabledTools = MCPToolCatalog.enabledToolNames
        guard !enabledTools.isEmpty else { return "" }

        switch session.kind {
        case .claude:
            guard let configPath = MCPSessionRegistry.writeConfiguration(for: session.id) else {
                return ""
            }

            return " --mcp-config \(quoted(configPath))"
                + " --allowedTools \(quoted(MCPDefaults.allowedToolsPattern))"

        case .codex:
            guard let url = MCPSessionRegistry.endpointURL(for: session.id) else {
                return ""
            }

            let server = "mcp_servers.\(MCPDefaults.serverName)"
            let toolList = enabledTools
                .map(tomlString)
                .joined(separator: ",")

            var flags = codexConfigOverride("\(server).url", string: url)
                + codexConfigOverride(
                    "\(server).enabled_tools",
                    tomlValue: "[\(toolList)]"
                )

            for tool in enabledTools {
                flags += codexConfigOverride(
                    "\(server).tools.\(tool).approval_mode",
                    string: "approve"
                )
            }

            return flags

        case .shell:
            return ""
        }
    }

    /// A one-run Codex config override. Values are TOML inside a shell-quoted argument.
    private static func codexConfigOverride(_ key: String, string value: String) -> String {
        codexConfigOverride(key, tomlValue: tomlString(value))
    }

    private static func codexConfigOverride(_ key: String, tomlValue: String) -> String {
        " --config \(quoted("\(key)=\(tomlValue)"))"
    }

    /// A TOML basic-string literal for values supplied through Codex's `--config` flag.
    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Builds the `env` prefix that routes the launch to the session's account.
    ///
    /// The default account explicitly *clears* the variable rather than leaving it unset:
    /// the login shell may export an override, and a bare invocation would then silently
    /// run against the wrong account.
    private static func accountPrefix(for session: AgentSession) -> String {
        guard let environmentKey = session.kind.accountEnvironmentKey,
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ) else { return "" }

        return account.isDefault
            ? "env -u \(environmentKey) "
            : "env \(environmentKey)=\(quoted(account.configPath)) "
    }

    // MARK: - Private Methods

    /// Claude accepts a caller-supplied session identifier, so we reuse the session's
    /// own UUID and never have to discover it.
    ///
    /// Because the identifier is minted before the conversation exists, a session that
    /// exited without exchanging any messages has an identifier but no transcript.
    /// Resuming it would fail, so the launch falls back to starting fresh under the same
    /// identifier — which keeps the sidebar entry stable either way.
    private static func claudeCommand(
        for session: AgentSession,
        in project: Project,
        prompt: String?
    ) -> (String, String?) {
        let executable = AgentDefaults.claudeExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.claudeModelFlag)

        if session.isResumable,
           let existingID = session.agentSessionID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            // No prompt on resume: the conversation already has its opening.
            return ("\(executable)\(model) --resume \(quoted(existingID))", existingID)
        }

        let mintedID = session.agentSessionID ?? session.id.uuidString.lowercased()
        let command = "\(executable)\(model) --session-id \(quoted(mintedID))"
            + " --name \(quoted(session.launchName))"
            + trailingPrompt(prompt)

        return (command, mintedID)
    }

    /// The model flag, or "" when the session takes the CLI's default.
    private static func modelFlag(for session: AgentSession, flag: String) -> String {
        guard let model = session.model, !model.isEmpty else { return "" }
        return " \(flag) \(quoted(model))"
    }

    /// Both CLIs take an opening prompt as a trailing positional argument.
    private static func trailingPrompt(_ prompt: String?) -> String {
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return " \(quoted(prompt))"
    }

    /// Codex assigns its own session identifier, so a fresh launch takes no flag and
    /// the identifier is recovered afterwards by `CodexSessionDiscovery`.
    private static func codexCommand(
        for session: AgentSession,
        prompt: String?
    ) -> (String, String?) {
        let executable = AgentDefaults.codexExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.codexModelFlag)

        if session.isResumable, let existingID = session.agentSessionID {
            return ("\(executable)\(model) resume \(quoted(existingID))", existingID)
        }

        return ("\(executable)\(model)\(trailingPrompt(prompt))", nil)
    }

    private static func shellCommand() -> String {
        let profile = ProfileStorage.shared.defaultProfile
        let arguments = profile.shellArguments.map(quoted).joined(separator: " ")
        return arguments.isEmpty
            ? quoted(profile.shellPath)
            : "\(quoted(profile.shellPath)) \(arguments)"
    }

    /// The user's login shell, used so agent launches inherit the interactive `PATH`.
    private static var loginShellPath: String {
        ProcessInfo.processInfo.environment[EnvironmentKeys.shell]
            ?? ProfileStorage.shared.defaultProfile.shellPath
    }

    /// Wraps a value in single quotes, escaping any it contains, so it survives the
    /// login shell unchanged.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
