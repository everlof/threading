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

// MARK: - Shell Command

/// A shell command assembled from arguments rather than source-code fragments.
///
/// Every caller-provided word is single-quoted as it enters the command. The only syntax that
/// can be emitted raw is one of the fixed operators below, so interpolating a title, branch,
/// model, prompt, environment value, or path into `sh -c` is not an available operation.
struct ShellCommand: Equatable {
    enum Operator {
        case and
        case endOfOptions

        fileprivate var source: String {
            switch self {
            case .and: return "&&"
            case .endOfOptions: return "--"
            }
        }
    }

    private var components: [String] = []

    /// The command's trailing operand — for an agent launch, the opening prompt.
    ///
    /// Kept apart from the flags because both CLIs reject a positional argument that begins
    /// with `-`, and both reject it *before* the session exists: Claude's parser answers
    /// `error: unknown option '- Make sure all tests are green'` and exits 1, Codex answers
    /// `unexpected argument '- ' found`. A bulleted opening — a list of things to do, one per
    /// line — is an ordinary thing to type into the composer, and it killed the launch a
    /// third of a second after it started.
    ///
    /// Two rules together make it safe, and each is needed: the operand is emitted **last**,
    /// after the MCP flags `routed` appends around the command, and it is separated by `--`,
    /// the terminator both parsers honour. Appending `--` where the prompt used to sit would
    /// have handed `--mcp-config` to the CLI as prompt text instead.
    private var operand: String?

    init() {}

    init(word: String) {
        append(word: word)
    }

    mutating func append(word: String) {
        components.append(Self.quote(word))
    }

    mutating func append(flag: String) {
        precondition(flag.hasPrefix("-"), "A shell flag must start with '-'")
        append(word: flag)
    }

    mutating func append(flag: String, value: String) {
        append(flag: flag)
        append(word: value)
    }

    mutating func append(operator shellOperator: Operator) {
        components.append(shellOperator.source)
    }

    /// Sets the trailing operand. A command has at most one — the opening prompt.
    mutating func append(operand value: String) {
        precondition(operand == nil, "A command carries one trailing operand")
        operand = value
    }

    /// Composing commands carries the operand along, so it stays last however the outer
    /// command is built up afterwards.
    mutating func append(contentsOf command: ShellCommand) {
        components.append(contentsOf: command.components)
        if let inner = command.operand {
            append(operand: inner)
        }
    }

    var source: String {
        guard let operand else { return components.joined(separator: " ") }
        return (components + [Operator.endOfOptions.source, Self.quote(operand)])
            .joined(separator: " ")
    }

    /// Produces the fixed `cd <directory> && exec <command>` wrapper used by login-shell and
    /// interactive-shell launches. Only `&&` is syntax; both commands and the directory remain
    /// ordinary quoted words.
    static func executing(_ command: ShellCommand, in directory: String) -> ShellCommand {
        var source = ShellCommand(word: "cd")
        source.append(word: directory)
        source.append(operator: .and)
        source.append(word: "exec")
        source.append(contentsOf: command)
        return source
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
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
        let command: ShellCommand
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
        }

        return launchPlan(
            command: routed(command, for: session),
            in: project.folderPath,
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
        }
    }

    /// Whether this launch turns Claude's Remote Control bridge on, off, or says nothing.
    ///
    /// Three answers, resolved in the order the user set them: the conversation's own choice
    /// first, then the app-wide default for new sessions, then nil — which writes no key and
    /// leaves it to `claude /config`. Nil is the only answer that changes nothing, so it has to
    /// survive all the way to the settings file rather than collapsing into `false` on the way.
    ///
    /// Claude-only. Codex has no comparable bridge, and its launches never carry the key.
    static func remoteControlAtStartup(for session: AgentSession) -> Bool? {
        guard session.kind == .claude else { return nil }
        return session.remoteControl ?? AppSettings.shared.claudeRemoteControl.startupValue
    }

    /// The permission posture this launch states, or nil to state none.
    ///
    /// The conversation's own choice first, then the app-wide default for new sessions, then
    /// nil — which emits no flag and leaves the CLI's own configuration deciding. Nil has to
    /// survive to the command line rather than collapsing into a "safe" mode: naming any mode
    /// would override a `permissions.defaultMode` or `config.toml` the user set themselves.
    static func permissionMode(for session: AgentSession) -> AgentPermissionMode? {
        session.permissionMode ?? AppSettings.shared.defaultPermissionMode
    }

    /// Adds the flags that state the mode, in each CLI's own vocabulary.
    ///
    /// Codex takes two flags because it has two axes, and both must be stated together: its
    /// approval policy and its sandbox are independently defaulted, so setting one and leaving
    /// the other would produce a posture that is neither the mode asked for nor the CLI's own.
    private static func appendPermissionMode(
        for session: AgentSession,
        to command: inout ShellCommand
    ) {
        guard let mode = permissionMode(for: session) else { return }

        switch session.kind {
        case .claude:
            command.append(
                flag: AgentDefaults.claudePermissionModeFlag,
                value: mode.claudeFlagValue
            )
        case .codex:
            command.append(flag: AgentDefaults.codexApprovalFlag, value: mode.codexApprovalPolicy)
            command.append(flag: AgentDefaults.codexSandboxFlag, value: mode.codexSandboxMode)
        }
    }

    /// Claude keeps one bidirectional stream open for the lifetime of the conversation.
    private static func claudeStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        var command = ShellCommand(word: AgentDefaults.claudeExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.claudeModelFlag, to: &command)
        appendPermissionMode(for: session, to: &command)
        command.append(flag: "--print")
        command.append(flag: "--input-format", value: "stream-json")
        command.append(flag: "--output-format", value: "stream-json")
        command.append(flag: "--include-partial-messages")
        command.append(flag: "--verbose")
        command.append(flag: "--forward-subagent-text")

        // Purely diagnostic, and the only view of the one failure this app cannot see: a hook
        // that never reaches the listener leaves nothing here, while the agent silently waits
        // on a blocked tool. `HookOutcomeLog` reads what this adds; nothing renders it.
        command.append(flag: "--include-hook-events")

        let resumeState: ResumeState

        if let fork = claudeForkFlags(for: session, in: project) {
            command.append(contentsOf: fork.flags)
            resumeState = .resumable(fork.sessionID)
        } else if let existingID = session.resumeState.transcriptID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            command.append(flag: "--resume", value: existingID.rawValue)
            resumeState = .resumable(existingID)
        } else {
            let mintedID = session.resumeState.transcriptID
                ?? TranscriptID(session.id.uuidString.lowercased())
            command.append(flag: "--session-id", value: mintedID.rawValue)
            resumeState = .resumable(mintedID)
        }

        // Brokered: a headless run has nowhere to ask, so without the `PreToolUse` hook it
        // silently blocks the tools it would otherwise prompt about.
        if let settingsPath = MCPSessionRegistry.writeHookSettings(
            for: session.id,
            brokersPermissions: true,
            reportsLifecycle: AppSettings.shared.reportsClaudeLifecycleEvents,
            remoteControl: remoteControlAtStartup(for: session)
        ) {
            command.append(flag: "--settings", value: settingsPath)
        }

        return launchPlan(
            command: routed(command, for: session, brokersPermissions: true),
            in: project.folderPath,
            resumeState: resumeState
        )
    }

    /// Codex app-server keeps one JSON-RPC process subscribed to the conversation and any child
    /// threads it creates. The session wrapper performs `thread/start` or `thread/resume` over
    /// stdin after initialization.
    private static func codexStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        var command = ShellCommand(word: AgentDefaults.codexExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.codexModelFlag, to: &command)
        appendCodexConversationOverrides(for: session, to: &command)

        // A stated mode replaces the sandbox this transport otherwise fixes, rather than adding
        // a second `--sandbox`. Unstated it stays `workspace-write`, which is not a default so
        // much as this surface's own requirement: a natively rendered session that suddenly
        // inherited a read-only `config.toml` would stop being able to edit anything, and would
        // say so only through failing tools.
        if permissionMode(for: session) != nil {
            appendPermissionMode(for: session, to: &command)
        } else {
            command.append(
                flag: AgentDefaults.codexSandboxFlag,
                value: AgentDefaults.codexSandboxWorkspaceWrite
            )
        }

        appendCodexHookFlags(for: session, to: &command)
        command.append(word: "app-server")
        command.append(flag: "--listen", value: "stdio://")

        return launchPlan(
            command: routed(command, for: session, brokersPermissions: true),
            in: project.folderPath,
            resumeState: session.resumeState
        )
    }

    /// Builds a one-shot, headless `codex exec` run used for background research — icon
    /// discovery today.
    ///
    /// Routed to the default account (research belongs to a project, not any session — the
    /// same `env -u` rule as `routed`), sandboxed read-only because research must
    /// not write, and with reasoning effort turned down: the answer is a look-up, not a
    /// plan. No MCP flags — a run with no terminal has no panel to reach.
    static func codexResearchPlan(in folder: String, prompt: String) -> AgentLaunchPlan {
        var command = ShellCommand()
        // `env -u`, not a bare command: a login shell may export an override, which would
        // otherwise route research at whichever account that names.
        command.append(word: "env")
        command.append(flag: "-u", value: AgentKind.codex.accountEnvironmentKey)
        command.append(word: AgentDefaults.codexExecutable)
        appendCodexConfigOverride(
            AgentDefaults.codexReasoningEffortKey,
            string: AgentDefaults.codexResearchReasoningEffort,
            to: &command
        )
        // Fixed, and not a permission mode: research belongs to a project rather than to any
        // session, so there is no conversation whose posture it could follow.
        command.append(
            flag: AgentDefaults.codexSandboxFlag,
            value: AgentDefaults.codexSandboxReadOnly
        )
        command.append(word: "exec")
        command.append(flag: "--json")
        command.append(operand: prompt)

        return launchPlan(command: command, in: folder, resumeState: .unavailable)
    }

    /// Appends flags registering Skalman's own MCP server when one is available.
    ///
    /// Each launch receives a URL carrying the session's token — that URL is what lets a tool
    /// call find the right display panel. Claude takes it through a per-session JSON config;
    /// Codex takes equivalent one-off TOML overrides, preserving the user's own MCP servers.
    ///
    /// Deliberately not `--strict-mcp-config`: that would suppress the user's own MCP servers
    /// for every session Skalman launches, which is a much larger change than adding one.
    ///
    /// Skalman's MCP server is pre-approved as one app capability. Tools that need finer trust
    /// boundaries enforce them in the app: in particular, browser access is origin-gated and form
    /// submissions are confirmed because WKWebView may hold credentials the shell does not.
    private static func appendMCPFlags(for session: AgentSession, to command: inout ShellCommand) {
        // Which tools are exposed is the user's choice on the Tools settings page. With every
        // group switched off there is nothing to register — and an empty `enabled_tools` list is
        // ambiguous to Codex (it can read as "all"), so the server is skipped outright rather than
        // handed an empty allowlist.
        let enabledTools = MCPToolCatalog.enabledToolNames
        guard !enabledTools.isEmpty else { return }

        switch session.kind {
        case .claude:
            guard let configPath = MCPSessionRegistry.writeConfiguration(for: session.id) else {
                return
            }

            command.append(flag: "--mcp-config", value: configPath)
            command.append(flag: "--allowedTools", value: MCPDefaults.allowedToolsPattern)

        case .codex:
            guard let url = MCPSessionRegistry.endpointURL(for: session.id) else {
                return
            }

            let server = "mcp_servers.\(MCPDefaults.serverName)"
            let toolList = enabledTools
                .map(tomlString)
                .joined(separator: ",")

            appendCodexConfigOverride("\(server).url", string: url, to: &command)
            appendCodexConfigOverride(
                "\(server).enabled_tools",
                tomlValue: "[\(toolList)]",
                to: &command
            )

            for tool in enabledTools {
                appendCodexConfigOverride(
                    "\(server).tools.\(tool).approval_mode",
                    string: "approve",
                    to: &command
                )
            }

        }
    }

    /// A one-run Codex config override. Values are TOML inside a shell-quoted argument.
    private static func appendCodexConfigOverride(
        _ key: String,
        string value: String,
        to command: inout ShellCommand
    ) {
        appendCodexConfigOverride(key, tomlValue: tomlString(value), to: &command)
    }

    private static func appendCodexConfigOverride(
        _ key: String,
        tomlValue: String,
        to command: inout ShellCommand
    ) {
        command.append(flag: "--config", value: "\(key)=\(tomlValue)")
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
    private static func routed(
        _ command: ShellCommand,
        for session: AgentSession,
        brokersPermissions: Bool = false
    ) -> ShellCommand {
        var routed = ShellCommand()

        let environmentKey = session.kind.accountEnvironmentKey
        guard let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ) else {
            routed.append(word: "env")
            appendHookEnvironment(
                for: session,
                brokersPermissions: brokersPermissions,
                to: &routed
            )
            routed.append(contentsOf: command)
            appendMCPFlags(for: session, to: &routed)
            return routed
        }

        routed.append(word: "env")
        if account.isDefault {
            routed.append(flag: "-u", value: environmentKey)
        } else {
            routed.append(word: "\(environmentKey)=\(account.configPath)")
        }
        appendHookEnvironment(
            for: session,
            brokersPermissions: brokersPermissions,
            to: &routed
        )
        routed.append(contentsOf: command)
        appendMCPFlags(for: session, to: &routed)
        return routed
    }

    /// Exports the listener's port and the session's token, which is how a hook finds its way
    /// back to the right session.
    ///
    /// Codex needs this: its `hooks.json` is shared by every session under an account, so the
    /// routing cannot live in the file. Claude is given the same variables even though its
    /// per-session settings file already embeds them, because a user's *own* hooks then work
    /// the same way under both agents.
    private static func appendHookEnvironment(
        for session: AgentSession,
        brokersPermissions: Bool,
        to command: inout ShellCommand
    ) {
        guard let port = MCPServer.shared.port else { return }

        command.append(word: "\(MCPDefaults.portEnvironmentKey)=\(port)")
        command.append(
            word: "\(MCPDefaults.sessionTokenEnvironmentKey)="
                + MCPSessionRegistry.token(for: session.id)
        )

        // Exported only for the surface that needs brokering, which is what scopes Codex's
        // shared `hooks.json` to a single surface. Absent, its `PreToolUse` entry says nothing
        // and Codex's own approval flow runs untouched.
        if brokersPermissions {
            command.append(word: "\(MCPDefaults.brokerEnvironmentKey)=1")
        }
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
    ) -> (ShellCommand, ResumeState) {
        var command = ShellCommand(word: AgentDefaults.claudeExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.claudeModelFlag, to: &command)
        appendPermissionMode(for: session, to: &command)

        // Optional lifecycle hooks only. A terminal session raises the CLI's own permission
        // prompt, which the user can see and answer — intercepting it would replace a working
        // prompt with a second one. With reporting off and no Remote Control override,
        // `writeHookSettings` returns nil and the terminal launches with no settings file.
        if let settingsPath = MCPSessionRegistry.writeHookSettings(
            for: session.id,
            brokersPermissions: false,
            reportsLifecycle: AppSettings.shared.reportsClaudeLifecycleEvents,
            remoteControl: remoteControlAtStartup(for: session)
        ) {
            command.append(flag: "--settings", value: settingsPath)
        }

        if let fork = claudeForkFlags(for: session, in: project) {
            command.append(contentsOf: fork.flags)
            appendLaunchName(for: session, to: &command)
            appendPrompt(prompt, to: &command)
            return (command, .resumable(fork.sessionID))
        }

        if let existingID = session.resumeState.transcriptID,
           ClaudeTranscript.exists(sessionID: existingID, for: session, in: project) {
            // No prompt on resume: the conversation already has its opening.
            command.append(flag: "--resume", value: existingID.rawValue)
            return (command, .resumable(existingID))
        }

        let mintedID = session.resumeState.transcriptID
            ?? TranscriptID(session.id.uuidString.lowercased())
        command.append(flag: "--session-id", value: mintedID.rawValue)
        appendLaunchName(for: session, to: &command)
        appendPrompt(prompt, to: &command)

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
    /// their own command — the terminal adds an opening prompt, the stream adds its
    /// transport flags.
    private static func claudeForkFlags(
        for session: AgentSession,
        in project: Project
    ) -> (flags: ShellCommand, sessionID: TranscriptID)? {
        guard let parent = forkParent(for: session, in: project),
              let parentAgentID = parent.resumeState.transcriptID,
              ClaudeTranscript.exists(sessionID: parentAgentID, for: parent, in: project)
        else { return nil }

        let mintedID = session.resumeState.transcriptID
            ?? TranscriptID(session.id.uuidString.lowercased())
        var flags = ShellCommand()
        flags.append(flag: "--resume", value: parentAgentID.rawValue)
        flags.append(flag: "--fork-session")
        flags.append(flag: "--session-id", value: mintedID.rawValue)

        return (flags, mintedID)
    }

    /// Adds `--name` only when the user has explicitly renamed the session.
    ///
    /// The flag marks the conversation custom-titled in the CLI, which stops it generating
    /// its own `ai-title` (measured: 9 of 10 transcripts launched under a default name held
    /// none) — so anything less deliberate than the user's own choice would switch off the
    /// agent-naming signal the sidebar prefers, and echo the fallback back as the terminal
    /// title on top of it.
    private static func appendLaunchName(
        for session: AgentSession,
        to command: inout ShellCommand
    ) {
        guard let name = session.launchName else { return }
        command.append(flag: "--name", value: name)
    }

    /// Adds the model flag when the session does not use the CLI's default.
    private static func appendModelFlag(
        for session: AgentSession,
        flag: String,
        to command: inout ShellCommand
    ) {
        guard let model = session.model, !model.isEmpty else { return }
        command.append(flag: flag, value: model)
    }

    /// Both CLIs take an opening prompt as a trailing positional argument — which is why it
    /// goes in as `ShellCommand`'s operand rather than as another word: see the note there for
    /// what a prompt beginning with `-` did to the launch.
    private static func appendPrompt(_ prompt: String?, to command: inout ShellCommand) {
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        command.append(operand: prompt)
    }

    /// Codex assigns its own session identifier, so a fresh launch takes no flag and
    /// the identifier is recovered afterwards by `CodexSessionDiscovery`.
    private static func codexCommand(
        for session: AgentSession,
        prompt: String?
    ) -> (ShellCommand, ResumeState) {
        var command = ShellCommand(word: AgentDefaults.codexExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.codexModelFlag, to: &command)
        appendCodexConversationOverrides(for: session, to: &command)
        appendPermissionMode(for: session, to: &command)
        appendCodexHookFlags(for: session, to: &command)

        if let existingID = session.resumeState.transcriptID {
            command.append(word: "resume")
            command.append(word: existingID.rawValue)
            return (command, .resumable(existingID))
        }

        appendPrompt(prompt, to: &command)
        return (command, .awaitingIdentifier)
    }

    /// Maps Skalman's per-conversation reasoning and Fast choices onto Codex's launch
    /// configuration.
    ///
    /// Terminal launches consume these directly. Native app-server uses them to seed the
    /// process, then repeats the latest model, effort and service tier on `turn/start` so idle
    /// changes do not need a restart. `default` is explicit rather than omission when the user
    /// chose Standard, because omission would inherit an account configured for Fast.
    private static func appendCodexConversationOverrides(
        for session: AgentSession,
        to command: inout ShellCommand
    ) {
        if let effort = session.reasoningEffort, !effort.isEmpty {
            let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
            let model = session.model ?? AgentModels.defaultModel(
                for: session.kind,
                account: account
            )
            let option = AgentModels.option(
                identifier: model,
                for: session.kind,
                account: account
            )

            // Preserve an override when the cache is unavailable or predates reasoning
            // metadata. When the current catalog does know the model, it is authoritative:
            // never launch Luna with a stale Ultra choice saved while the session used Sol.
            if option?.reasoningLevels.isEmpty != false
                || option?.supports(reasoningEffort: effort) == true {
                appendCodexConfigOverride(
                    AgentDefaults.codexReasoningEffortKey,
                    string: effort,
                    to: &command
                )
            }
        }

        guard let fastMode = session.fastMode else { return }

        if fastMode {
            let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
            let model = session.model ?? AgentModels.defaultModel(
                for: session.kind,
                account: account
            )
            let tier = AgentModels.option(
                identifier: model,
                for: session.kind,
                account: account
            )?.fastServiceTier ?? AgentDefaults.codexFastServiceTier

            appendCodexConfigOverride(
                AgentDefaults.codexServiceTierKey,
                string: tier,
                to: &command
            )
            // A deliberate Fast choice should still work when the account disabled the TUI
            // selector. Managed configuration remains authoritative over this one-run layer.
            appendCodexConfigOverride(
                AgentDefaults.codexFastModeFeatureKey,
                tomlValue: "true",
                to: &command
            )
        } else {
            appendCodexConfigOverride(
                AgentDefaults.codexServiceTierKey,
                string: AgentDefaults.codexStandardServiceTier,
                to: &command
            )
        }
    }

    /// Installs the account's lifecycle hooks and, if the user asked for it, skips the review
    /// that would otherwise stop them running.
    ///
    /// Both halves are opt-in and separate, because they are different decisions. Installing
    /// writes to a file the user owns; bypassing review lowers a security gate on *every* hook
    /// in that directory, not only ours. Installing alone is the useful safe default: the
    /// entries sit there inert until the user trusts them once in the Codex TUI, and because
    /// their text never changes, that one review holds.
    private static func appendCodexHookFlags(
        for session: AgentSession,
        to command: inout ShellCommand
    ) {
        guard AppSettings.shared.installsCodexHooks else { return }

        if let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) {
            CodexHookInstaller.install(inCodexHome: account.configPath)
        }

        if AppSettings.shared.bypassesCodexHookTrust {
            command.append(flag: AgentDefaults.codexBypassHookTrustFlag)
        }
    }

    /// Wraps a command invocation in the login-shell source shared by every launch surface.
    private static func launchPlan(
        command: ShellCommand,
        in folder: String,
        resumeState: ResumeState
    ) -> AgentLaunchPlan {
        let source = ShellCommand.executing(command, in: folder)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", source.source],
            resumeState: resumeState
        )
    }

    /// The user's login shell, used so agent launches inherit the interactive `PATH`.
    ///
    /// Internal rather than private: anything that runs a CLI has the same problem — a GUI app
    /// does not inherit the interactive `PATH`, and `claude` lives in `~/.local/bin`. See
    /// `AccountEmailProbe`.
    static var loginShellPath: String {
        ProcessInfo.processInfo.environment[EnvironmentKeys.shell]
            ?? ProfileStorage.shared.defaultProfile.shellPath
    }

}
