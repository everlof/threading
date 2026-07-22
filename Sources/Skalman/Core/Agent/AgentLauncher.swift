import Foundation

// MARK: - Agent Launch Plan

/// A fully resolved command line for starting or resuming an agent session.
struct AgentLaunchPlan {
    let executable: String
    let arguments: [String]

    /// The conversation state this launch establishes.
    ///
    /// Claude launches and all resumes carry an identifier. A fresh Codex launch awaits the
    /// identifier reported by the CLI, while research runs and shells have none by design.
    let resumeState: ResumeState
}

// MARK: - Agent Launcher

/// Builds command lines for starting and resuming agent sessions.
///
/// Launches are wrapped in a login shell because a GUI app does not inherit the
/// user's interactive `PATH`, and the agent CLIs typically live in `~/.local/bin`
/// or a Node prefix that only a login shell resolves.
@MainActor
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
        let resumeState: ResumeState

        switch session.kind {
        case .claude:
            (command, resumeState) = claudeCommand(
                for: session,
                in: project,
                prompt: initialPrompt
            )
        case .codex:
            (command, resumeState) = codexCommand(for: session, prompt: initialPrompt)
        case .shell:
            (command, resumeState) = (shellCommand(), .unavailable)
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            resumeState: resumeState
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

        let resumeState: ResumeState

        if let fork = claudeForkFlags(for: session, in: project) {
            command += fork.flags
            resumeState = .resumable(fork.sessionID)
        } else if let existingID = session.resumeState.transcriptID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            command += " --resume \(quoted(existingID))"
            resumeState = .resumable(existingID)
        } else {
            let mintedID = session.resumeState.transcriptID
                ?? TranscriptID(session.id.uuidString.lowercased())
            command += " --session-id \(quoted(mintedID))"
            resumeState = .resumable(mintedID)
        }

        if let settingsPath = MCPSessionRegistry.writePermissionSettings(for: session.id) {
            command += " --settings \(quoted(settingsPath))"
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            resumeState: resumeState
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
        if let existingID = session.resumeState.transcriptID {
            command = "\(executable)\(model) --sandbox workspace-write"
                + " exec resume \(quoted(existingID)) --json -"
        } else {
            command = "\(executable)\(model) --sandbox workspace-write exec --json -"
        }

        let routed = accountPrefix(for: session) + command + mcpFlags(for: session)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", "cd \(quoted(project.folderPath)) && exec \(routed)"],
            resumeState: session.resumeState
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
            resumeState: .unavailable
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
    ) -> (String, ResumeState) {
        let executable = AgentDefaults.claudeExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.claudeModelFlag)

        if let fork = claudeForkFlags(for: session, in: project) {
            let command = "\(executable)\(model)\(fork.flags)"
                + " --name \(quoted(session.launchName))"
                + trailingPrompt(prompt)
            return (command, .resumable(fork.sessionID))
        }

        if let existingID = session.resumeState.transcriptID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            // No prompt on resume: the conversation already has its opening.
            return (
                "\(executable)\(model) --resume \(quoted(existingID))",
                .resumable(existingID)
            )
        }

        let mintedID = session.resumeState.transcriptID
            ?? TranscriptID(session.id.uuidString.lowercased())
        let command = "\(executable)\(model) --session-id \(quoted(mintedID))"
            + " --name \(quoted(session.launchName))"
            + trailingPrompt(prompt)

        return (command, .resumable(mintedID))
    }

    /// The launch that makes a **side chat**: resume the *parent's* conversation, but write
    /// the turns somewhere new.
    ///
    /// `--fork-session` copies the parent's context into a fresh transcript and leaves the
    /// parent's own file untouched, which is what lets a side chat run *beside* a live
    /// session rather than fighting it for one transcript. `--session-id` is honoured
    /// alongside it (measured), so the child's identifier is minted here exactly like any
    /// other Claude session and never has to be discovered afterwards.
    ///
    /// Returns nil — leaving the caller's ordinary resume-or-fresh path to run — unless this
    /// is a side chat's *first* launch and the parent really has a conversation to fork. The
    /// fork happens once: from the second launch the child owns its own transcript and is
    /// resumed like anything else, which is why `hasLaunched` gates it.
    /// The session a side chat should fork from, or nil when this launch is an ordinary one.
    ///
    /// Read from the project's own records rather than the store, which is both the smaller
    /// dependency and the true one: `ProjectStore.addSideChat` puts a fork in its parent's
    /// project, because a fork resumes the parent's transcript and that is found through the
    /// project's folder.
    ///
    /// Nil once the child `hasLaunched`, since the fork is a birth rather than a mode — from
    /// its second launch a side chat owns a transcript of its own and resumes like anything
    /// else.
    static func forkParent(for session: AgentSession, in project: Project) -> AgentSession? {
        guard session.kind.supportsForking,
              !session.hasLaunched,
              let parentID = session.forkedFrom else { return nil }

        return project.sessions.first { $0.id == parentID && $0.resumeState.isResumable }
    }

    /// Returns the flags and the child's identifier, so both surfaces can compose them into
    /// their own command — the terminal adds `--name` and an opening prompt, the stream adds
    /// its transport flags.
    private static func claudeForkFlags(
        for session: AgentSession,
        in project: Project
    ) -> (flags: String, sessionID: TranscriptID)? {
        guard let parent = forkParent(for: session, in: project),
              let parentAgentID = parent.resumeState.transcriptID,
              ClaudeTranscript.exists(sessionID: parentAgentID, for: parent, in: project)
        else { return nil }

        let mintedID = session.resumeState.transcriptID
            ?? TranscriptID(session.id.uuidString.lowercased())
        let flags = " --resume \(quoted(parentAgentID))"
            + " --fork-session"
            + " --session-id \(quoted(mintedID))"

        return (flags, mintedID)
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
    ) -> (String, ResumeState) {
        let executable = AgentDefaults.codexExecutable
        let model = modelFlag(for: session, flag: AgentDefaults.codexModelFlag)

        if let existingID = session.resumeState.transcriptID {
            return (
                "\(executable)\(model) resume \(quoted(existingID))",
                .resumable(existingID)
            )
        }

        return ("\(executable)\(model)\(trailingPrompt(prompt))", .awaitingIdentifier)
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

    private static func quoted(_ value: TranscriptID) -> String {
        quoted(value.rawValue)
    }
}
