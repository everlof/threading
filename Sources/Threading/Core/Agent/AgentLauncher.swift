import Foundation

// MARK: - Agent Launch Plan

/// A fully resolved command line for starting or resuming an agent session.
struct AgentLaunchPlan {
    let executable: String
    let arguments: [String]

    /// The conversation state this launch establishes.
    ///
    /// Claude launches and all resumes carry an identifier. Fresh Codex/OpenCode launches
    /// await the identifier assigned by the CLI; fresh Grok launches await confirmation that
    /// its caller-supplied UUID was persisted. Research runs and shells have none.
    let resumeState: ResumeState

    /// Environment entries this launch needs that the shared launch environment does not carry.
    ///
    /// A terminal launch states its environment as `env NAME=value` words inside the login-shell
    /// command, which a native launch has no room for: it spawns the child directly and hands it
    /// a dictionary. Empty for every plan that has nothing to add, so the mechanism costs the
    /// other runtimes nothing — the first user is Cursor, whose CLI opens a browser to
    /// authenticate unless `BROWSER` and `NO_OPEN_BROWSER` say otherwise.
    ///
    /// Read through `launchEnvironment()` rather than merged at each call site, so a transport
    /// cannot pick up the plan and silently drop what it asked for.
    let environmentOverrides: [String: String]

    init(
        executable: String,
        arguments: [String],
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.resumeState = resumeState
        self.environmentOverrides = environmentOverrides
    }

    /// The environment this plan's child is spawned with: the shared one, then this plan's own
    /// entries on top.
    func launchEnvironment() -> [String: String] {
        var environment = AgentEnvironment.launchEnvironment()
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return environment
    }
}

enum AgentLaunchPlanningError: LocalizedError, Equatable {
    case unsupportedNativeConversation(AgentKind)
    case unsupportedTerminalConversation(AgentKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedNativeConversation(let kind):
            return "\(kind.displayName) does not provide a native conversation transport."
        case .unsupportedTerminalConversation(let kind):
            return "\(kind.displayName) conversations cannot be opened in a terminal."
        }
    }
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
    /// Kept apart from the flags because the operand-taking CLIs reject a positional argument that begins
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
    ///
    /// Throws for a runtime with no `.terminalUI`. There is a command line that would start
    /// Cursor's interactive TUI, and running it here is exactly the thing not to do: it would
    /// open a *different, empty* chat beside the conversation the row names, because its two
    /// interfaces do not share a conversation store (§11 of the archived Cursor ACP findings). Refusing
    /// is the honest answer, and the surface clamp in `AgentSession.resolvedNativeSurface`
    /// means no ordinary path reaches it.
    static func plan(
        for session: AgentSession,
        in project: Project,
        initialPrompt: String? = nil
    ) throws -> AgentLaunchPlan {
        var executionProject = project
        executionProject.folderPath = session.workingDirectory(in: project)
        let command: ShellCommand
        let resumeState: ResumeState

        switch session.kind {
        case .claude:
            (command, resumeState) = claudeCommand(
                for: session,
                in: executionProject,
                prompt: initialPrompt
            )
        case .codex:
            (command, resumeState) = codexCommand(for: session, prompt: initialPrompt)
        case .grok:
            (command, resumeState) = grokCommand(for: session, prompt: initialPrompt)
        case .openCode:
            (command, resumeState) = openCodeCommand(for: session, prompt: initialPrompt)
        case .cursor:
            throw AgentLaunchPlanningError.unsupportedTerminalConversation(.cursor)
        }

        return launchPlan(
            command: routed(command, for: session),
            in: executionProject.folderPath,
            resumeState: resumeState
        )
    }

    /// Builds the plan for a session Threading renders itself, rather than showing a terminal.
    ///
    /// Same login shell and same account routing as `plan(for:in:)` — a headless run inherits
    /// no more of the user's `PATH` than a PTY does. What differs is the interface: the CLI
    /// speaks JSON over pipes rather than drawing its terminal UI.
    ///
    /// No `initialPrompt`: the first turn is sent over the stream like every other, so the
    /// opening message needs no special path.
    static func streamPlan(
        for session: AgentSession,
        in project: Project
    ) throws -> AgentLaunchPlan {
        var executionProject = project
        executionProject.folderPath = session.workingDirectory(in: project)
        switch session.kind {
        case .claude:
            return claudeStreamPlan(for: session, in: executionProject)
        case .codex:
            return codexStreamPlan(for: session, in: executionProject)
        case .grok:
            return grokStreamPlan(for: session, in: executionProject)
        case .cursor:
            return cursorStreamPlan(for: session, in: executionProject)
        case .openCode:
            throw AgentLaunchPlanningError.unsupportedNativeConversation(.openCode)
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
        guard session.kind.supports(.remoteControl) else { return nil }
        return session.remoteControl ?? AppSettings.shared.claudeRemoteControl.startupValue
    }

    /// Whether this launch explicitly starts in Fast or Standard, or leaves speed to the CLI.
    ///
    /// Resolution is conversation override, then the app-wide default for this runtime, then
    /// nil. Nil is load-bearing: Claude may persist `fastMode` and Codex may configure a service
    /// tier, so omission is the only way to preserve the provider-owned answer. An explicit
    /// Standard therefore remains `false` all the way to the launch instead of collapsing into
    /// omission and inheriting Fast again.
    static func fastModeAtStartup(for session: AgentSession) -> Bool? {
        fastModeAtStartup(
            for: session,
            defaultSpeed: AppSettings.shared.startupSpeed(for: session.kind)
        )
    }

    /// Pure resolution seam for tests and callers that already hold a settings snapshot.
    static func fastModeAtStartup(
        for session: AgentSession,
        defaultSpeed: AgentStartupSpeed
    ) -> Bool? {
        guard session.kind.supports(.liveFastModeControl)
            || session.kind.supports(.serviceTierFastMode)
        else { return nil }

        guard let fast = session.fastMode ?? defaultSpeed.fastModeOverride else { return nil }

        // Claude's settings-layer switch can move an explicitly selected non-Opus model onto
        // Opus. A speed default must not silently replace a model choice, so a known unsupported
        // model is explicitly kept Standard. Nil remains eligible: it means the CLI's default
        // could not be named, and choosing Fast is the user's instruction for that case.
        if fast, session.kind.supports(.liveFastModeControl) {
            let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
            if let model = session.model ?? AgentModels.defaultModel(
                for: session.kind,
                account: account
            ), !AgentModels.claudeSupportsFastMode(model) {
                return false
            }
        }

        return fast
    }

    /// The silenced status line this terminal launch writes, or nil to leave the account's
    /// line exactly as the user configured it.
    ///
    /// Only with the suppression setting on, and only when the account actually resolves a
    /// command: an account with no status line has nothing to silence, and writing an override
    /// for it would add a key where the user has none. The account's own command is kept
    /// running inside the wrapper because these commands are commonly bridges with side
    /// effects the app itself relies on — see `ClaudeStatusLineSettings.silencedCommand`.
    ///
    /// Terminal launches only. A native conversation runs `--print`, where the CLI never
    /// draws a status line, so its settings file has nothing to say about one.
    static func statusLineOverride(for session: AgentSession, in project: Project) -> String? {
        guard session.kind.supports(.statusLine), AppSettings.shared.suppressesClaudeStatusLine,
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ),
              let command = ClaudeStatusLineSettings.resolvedCommand(
                  account: account,
                  projectDirectory: project.folderPath
              )
        else { return nil }

        return ClaudeStatusLineSettings.silencedCommand(wrapping: command)
    }

    /// The permission posture this launch states, or nil to state none.
    ///
    /// The conversation's own choice first, then the app-wide default for new sessions, then
    /// nil — which emits no flag and leaves the CLI's own configuration deciding. Nil has to
    /// survive to the command line rather than collapsing into a "safe" mode: naming any mode
    /// would override a `permissions.defaultMode` or `config.toml` the user set themselves.
    static func permissionMode(for session: AgentSession) -> AgentPermissionMode? {
        guard session.kind.supportsPermissionModes else { return nil }
        return session.permissionMode ?? AppSettings.shared.defaultPermissionMode
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

        for launchFlag in mode.launchFlags(for: session.kind) {
            command.append(flag: launchFlag.name, value: launchFlag.value)
        }
    }

    /// Claude keeps one bidirectional stream open for the lifetime of the conversation.
    private static func claudeStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        var command = ShellCommand(word: AgentDefaults.claudeExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.claudeModelFlag, to: &command)
        appendReasoningEffort(for: session, to: &command)
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
            remoteControl: remoteControlAtStartup(for: session),
            fastMode: fastModeAtStartup(for: session)
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

    /// Grok exposes the Agent Client Protocol over newline-delimited JSON-RPC. The stream
    /// wrapper owns the ACP initialize/session handshake; the launch only selects the supported
    /// stdio transport and any model the conversation already pinned.
    private static func grokStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        var command = ShellCommand(word: AgentDefaults.grokExecutable)
        command.append(word: "agent")
        appendModelFlag(for: session, flag: AgentDefaults.grokModelFlag, to: &command)
        // The same flag the terminal launch states, for the same reason. Without it, choosing
        // Plan or Bypass Permissions on a natively rendered Grok session recorded the choice
        // and redrew the chip while the process ran under whatever `grok` defaults to. The ACP
        // handshake carries no mode either, so the launch line is the only place to say it.
        appendPermissionMode(for: session, to: &command)
        command.append(word: "stdio")

        return launchPlan(
            command: routed(command, for: session),
            in: project.folderPath,
            resumeState: session.resumeState
        )
    }

    /// Cursor exposes the same Agent Client Protocol over `cursor-agent acp`, a hidden
    /// subcommand that takes no options of its own — everything else the CLI configures is a
    /// *global* placed before it, and the ACP session carries its own cwd, MCP servers, modes
    /// and model over the wire. So the launch line is the shortest of the three: the executable
    /// and the subcommand, plus whatever `routed` adds for the MCP bridge.
    ///
    /// No model flag, no permission mode: Cursor states the model inside `session/new` in one of
    /// two mutually exclusive id spaces, and its execution modes are a different axis from
    /// Threading's six.
    ///
    /// The two environment entries are not decoration. `authenticate` over ACP opens the user's
    /// browser, and the CLI reaches for it whenever it decides it needs a login — from a native
    /// app, mid-conversation. `BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` are what made the
    /// original measurements safe to run, and a shipping launch has more reason to set them, not
    /// less. They are the plan's own environment because a native launch spawns the child
    /// directly and has no shell words to put them in.
    private static func cursorStreamPlan(
        for session: AgentSession,
        in project: Project
    ) -> AgentLaunchPlan {
        var command = ShellCommand(word: AgentDefaults.cursorExecutable)
        command.append(word: AgentDefaults.cursorACPSubcommand)

        return launchPlan(
            command: routed(command, for: session),
            in: project.folderPath,
            resumeState: session.resumeState,
            environmentOverrides: AgentDefaults.cursorLaunchEnvironment
        )
    }

    /// Builds a one-shot, headless `codex exec` run used for background research — icon
    /// discovery today. Project folders do not have to be Git repositories, so the run
    /// explicitly skips Codex's repository preflight; the read-only sandbox remains the
    /// authority that bounds what the helper may do.
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
        if let accountKey = AgentKind.codex.accountEnvironmentKey {
            command.append(flag: "-u", value: accountKey)
        }
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
        command.append(flag: AgentDefaults.codexSkipGitRepoCheckFlag)
        command.append(operand: prompt)

        return launchPlan(command: command, in: folder, resumeState: .unavailable)
    }

    /// Builds the one-shot, headless run behind the AI settings search, on whichever runtime
    /// claims `.headlessResearch`.
    ///
    /// `codexResearchPlan`'s posture — default account through `env -u`, no session of ours,
    /// read-only where the runtime has a sandbox to say so — but with Threading's MCP endpoint
    /// attached and *scoped*: the endpoint belongs to an ad-hoc registration
    /// (`MCPSessionRegistry.beginAdHoc`), so the run is advertised and admitted exactly the
    /// tools it was launched for, rather than a catalogue a cheap model would spend its run
    /// reading. Claude additionally runs `--strict-mcp-config` and `--tools ''` — the opposite
    /// of a session launch, deliberately: a session must keep the user's own MCP servers and
    /// built-in tools, while a helper that reached either would be spending the user's tokens
    /// on capability the answer does not need.
    static func settingsResearchPlan(
        kind: AgentKind,
        sessionID: SessionID,
        prompt: String,
        in folder: String
    ) -> AgentLaunchPlan? {
        guard let command = settingsResearchCommand(
            kind: kind,
            prompt: prompt,
            mcpConfigPath: MCPSessionRegistry.writeConfiguration(for: sessionID),
            endpointURL: MCPSessionRegistry.endpointURL(for: sessionID)
        ) else { return nil }

        return launchPlan(command: command, in: folder, resumeState: .unavailable)
    }

    /// Internal for the tests: the command line is the contract with two CLIs, and the
    /// capability pairing test proves a plan exists exactly where `.headlessResearch` is
    /// claimed. The MCP config path (Claude) and endpoint URL (Codex) arrive as parameters so
    /// the pairing holds without a live listener.
    static func settingsResearchCommand(
        kind: AgentKind,
        prompt: String,
        mcpConfigPath: String?,
        endpointURL: String?
    ) -> ShellCommand? {
        guard kind.supports(.headlessResearch) else { return nil }

        var command = ShellCommand()
        command.append(word: "env")
        if let accountKey = kind.accountEnvironmentKey {
            command.append(flag: "-u", value: accountKey)
        }

        switch kind {
        case .claude:
            guard let mcpConfigPath else { return nil }
            command.append(word: AgentDefaults.claudeExecutable)
            command.append(
                flag: AgentDefaults.claudeModelFlag,
                value: AgentDefaults.claudeResearchModel
            )
            command.append(flag: "--print")
            command.append(flag: "--output-format", value: "json")
            // No built-in tools: the answer is a look-up in the catalogue the MCP tool
            // returns, not filesystem work.
            command.append(flag: "--tools", value: "")
            command.append(flag: "--mcp-config", value: mcpConfigPath)
            command.append(flag: "--strict-mcp-config")
            command.append(
                flag: "--allowedTools",
                value: MCPDefaults.allowedToolName(MCPBuiltInTool.listSettings.rawValue)
            )

        case .codex:
            guard let endpointURL else { return nil }
            command.append(word: AgentDefaults.codexExecutable)
            appendCodexConfigOverride(
                AgentDefaults.codexReasoningEffortKey,
                string: AgentDefaults.codexResearchReasoningEffort,
                to: &command
            )
            command.append(
                flag: AgentDefaults.codexSandboxFlag,
                value: AgentDefaults.codexSandboxReadOnly
            )
            let server = "mcp_servers.\(MCPDefaults.serverName)"
            let tool = MCPBuiltInTool.listSettings.rawValue
            appendCodexConfigOverride("\(server).url", string: endpointURL, to: &command)
            appendCodexConfigOverride(
                "\(server).enabled_tools",
                tomlValue: "[\(tomlString(tool))]",
                to: &command
            )
            appendCodexConfigOverride(
                "\(server).tools.\(tool).approval_mode",
                string: "approve",
                to: &command
            )
            command.append(word: "exec")
            command.append(flag: "--json")
            command.append(flag: AgentDefaults.codexSkipGitRepoCheckFlag)

        case .grok, .openCode, .cursor:
            // `.headlessResearch` is not granted here; the guard above already refused.
            return nil
        }

        command.append(operand: prompt)
        return command
    }

    /// The poke as something runnable: `usageWindowPokeCommand` inside a login shell, in a
    /// scratch directory so no project's instructions or MCP configuration is loaded into a run
    /// whose entire purpose is to be as small as possible.
    static func usageWindowPokePlan(
        kind: AgentKind,
        account: AgentAccount,
        in folder: String = FileManager.default.temporaryDirectory.path
    ) -> AgentLaunchPlan? {
        guard let command = usageWindowPokeCommand(kind: kind, account: account) else {
            return nil
        }
        return launchPlan(command: command, in: folder, resumeState: .unavailable)
    }

    /// Builds the one-shot run that opens an account's usage window: the smallest legal message
    /// this runtime can be asked to answer, on the account the user named.
    ///
    /// Three properties matter and each is a flag here. It runs on the **named account**, not
    /// the default one, because a window belongs to a login and poking the wrong one buys
    /// nothing. It carries **no context**: no MCP servers, no tools, and a working directory the
    /// caller sets to a scratch path, so nothing loads a `CLAUDE.md` or a tool catalogue whose
    /// input tokens would be charged to the weekly limit this feature exists to protect. And it
    /// asks for the **cheapest model**, since the reply is discarded and only the timestamp is
    /// wanted.
    ///
    /// Nil unless the runtime claims `.anchoredUsageWindow`. That is the whole provider gate:
    /// the day Codex's window is measured to be anchored, granting the flag turns this on there
    /// with the branch below already written.
    static func usageWindowPokeCommand(
        kind: AgentKind,
        account: AgentAccount
    ) -> ShellCommand? {
        guard kind.supports(.anchoredUsageWindow), account.provider == kind else { return nil }

        var command = ShellCommand()
        command.append(word: "env")
        if let accountKey = kind.accountEnvironmentKey {
            if account.isDefault {
                command.append(flag: "-u", value: accountKey)
            } else {
                command.append(word: "\(accountKey)=\(account.configPath)")
            }
        }

        switch kind {
        case .claude:
            command.append(word: AgentDefaults.claudeExecutable)
            command.append(flag: AgentDefaults.claudeModelFlag, value: AgentDefaults.claudePokeModel)
            command.append(flag: "--print")
            // The research run's own posture, minus the one MCP server it needed: a poke reads
            // nothing, so every tool it could reach is a tool it would be charged to describe.
            command.append(flag: "--tools", value: "")
            command.append(flag: "--strict-mcp-config")

        case .codex:
            command.append(word: AgentDefaults.codexExecutable)
            command.append(
                flag: AgentDefaults.codexSandboxFlag,
                value: AgentDefaults.codexSandboxReadOnly
            )
            command.append(word: "exec")
            command.append(flag: AgentDefaults.codexSkipGitRepoCheckFlag)

        case .grok, .openCode, .cursor:
            // `.anchoredUsageWindow` is not granted here; the guard above already refused.
            return nil
        }

        command.append(operand: AgentDefaults.usageWindowPokePrompt)
        return command
    }

    /// Appends flags registering Threading's own MCP server when one is available.
    ///
    /// Each launch receives a URL carrying the session's token — that URL is what lets a tool
    /// call find the right display panel. Claude takes it through a per-session JSON config;
    /// Codex takes equivalent one-off TOML overrides, preserving the user's own MCP servers.
    ///
    /// Deliberately not `--strict-mcp-config`: that would suppress the user's own MCP servers
    /// for every session Threading launches, which is a much larger change than adding one.
    ///
    /// Threading's MCP server is pre-approved as one app capability. Tools that need finer trust
    /// boundaries enforce them in the app: in particular, browser access is origin-gated and form
    /// submissions are confirmed because WKWebView may hold credentials the shell does not.
    private static func appendMCPFlags(for session: AgentSession, to command: inout ShellCommand) {
        // Which tools are exposed is the user's choice on the Tools settings page. With every
        // group switched off there is nothing to register — and an empty `enabled_tools` list is
        // ambiguous to Codex (it can read as "all"), so the server is skipped outright rather than
        // handed an empty allowlist.
        let enabledTools = MCPToolCatalog.toolNames(for: session.id)
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

        case .grok, .openCode, .cursor:
            // Do not rewrite any of these runtimes' persistent configuration. OpenCode's TUI
            // server has a dynamic MCP endpoint, but Threading does not own that server
            // lifecycle yet; Grok's equivalent per-TUI contract remains unmeasured. Grok and
            // Cursor both receive Threading's endpoint the honest way instead — in the
            // `mcpServers` array of their ACP `session/new`, which touches nothing on disk.
            break

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

        if !session.kind.supportsAccounts && !session.kind.supportsThreadingBridge {
            return command
        }

        if !session.kind.supportsAccounts {
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

        routed = AgentAccountRouting.prefix(for: session.kind, account: account)
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
    /// the same way under both agents. While the hook integration is enabled, the pre-rename
    /// aliases keep already-approved Codex commands runnable without rewriting their text and
    /// invalidating Codex's trust hash.
    private static func appendHookEnvironment(
        for session: AgentSession,
        brokersPermissions: Bool,
        to command: inout ShellCommand
    ) {
        guard let port = MCPServer.shared.port else { return }
        for word in hookEnvironmentWords(
            for: session,
            brokersPermissions: brokersPermissions,
            port: port,
            includesLegacyAliases: AppSettings.shared.installsCodexHooks
        ) {
            command.append(word: word)
        }
    }

    /// The environment words shared by the terminal and native launch paths.
    ///
    /// Internal so the compatibility contract can be pinned without starting the singleton
    /// listener in a unit test; production reaches it only through `appendHookEnvironment`.
    static func hookEnvironmentWords(
        for session: AgentSession,
        brokersPermissions: Bool,
        port: UInt16,
        includesLegacyAliases: Bool
    ) -> [String] {
        guard session.kind.supportsThreadingBridge else { return [] }
        let token = MCPSessionRegistry.token(for: session.id)
        var words = [
            "\(MCPDefaults.portEnvironmentKey)=\(port)",
            "\(MCPDefaults.sessionTokenEnvironmentKey)=\(token)"
        ]
        if includesLegacyAliases {
            words.append("\(MCPDefaults.legacyPortEnvironmentKey)=\(port)")
            words.append("\(MCPDefaults.legacySessionTokenEnvironmentKey)=\(token)")
        }

        // Exported only for the surface that needs brokering, which is what scopes Codex's
        // shared `hooks.json` to a single surface. Absent, its `PreToolUse` entry says nothing
        // and Codex's own approval flow runs untouched.
        if brokersPermissions {
            words.append("\(MCPDefaults.brokerEnvironmentKey)=1")
            if includesLegacyAliases {
                words.append("\(MCPDefaults.legacyBrokerEnvironmentKey)=1")
            }
        }
        return words
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
        appendReasoningEffort(for: session, to: &command)
        appendPermissionMode(for: session, to: &command)

        // Optional lifecycle hooks only. A terminal session raises the CLI's own permission
        // prompt, which the user can see and answer — intercepting it would replace a working
        // prompt with a second one. With reporting off, no Remote Control override and no
        // status-line override, `writeHookSettings` returns nil and the terminal launches
        // with no settings file.
        if let settingsPath = MCPSessionRegistry.writeHookSettings(
            for: session.id,
            brokersPermissions: false,
            reportsLifecycle: AppSettings.shared.reportsClaudeLifecycleEvents,
            remoteControl: remoteControlAtStartup(for: session),
            fastMode: fastModeAtStartup(for: session),
            statusLineOverride: statusLineOverride(for: session, in: project)
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

        // A session that has run before and still has no transcript is worth one line, because
        // the fallthrough below is about to relaunch with `--session-id` naming an identifier
        // Claude may already hold — which it refuses, exiting 1 within a second. That is what a
        // Resume button doing nothing looks like from outside, and the wrong-slug bug that
        // caused it was invisible for exactly as long as this path stayed silent.
        if session.hasLaunched, let existingID = session.resumeState.transcriptID {
            ThreadingLogger.agent.warning(
                """
                Session \(session.id.uuidString, privacy: .public) has run before but no \
                transcript for \(existingID.rawValue, privacy: .public) was found under \
                \(ClaudeTranscript.projectSlug(for: project), privacy: .public); \
                launching fresh
                """
            )
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

    /// Emits only values the selected model's provider-owned catalog publishes.
    ///
    /// Claude exposes a session-level CLI flag. Codex exposes the equivalent as a config
    /// override. Providers without a catalog and launch contract can still persist no value,
    /// so they deliberately reach neither branch.
    private static func appendReasoningEffort(
        for session: AgentSession,
        to command: inout ShellCommand
    ) {
        guard let effort = session.reasoningEffort, !effort.isEmpty else { return }

        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        let model = session.model ?? AgentModels.defaultModel(
            for: session.kind,
            account: account
        )
        switch session.kind {
        case .claude:
            guard AgentDefaults.claudeReasoningEfforts.contains(effort) else { return }
            command.append(flag: AgentDefaults.claudeEffortFlag, value: effort)
        case .codex:
            let option = AgentModels.option(
                identifier: model,
                for: session.kind,
                account: account
            )
            // Existing records outlive the cache that originally validated them. Preserve a
            // saved choice when metadata is unavailable; when the current catalog knows the
            // levels, it is authoritative and stale values are dropped.
            guard option?.reasoningLevels.isEmpty != false
                    || option?.supports(reasoningEffort: effort) == true
            else { return }
            appendCodexConfigOverride(
                AgentDefaults.codexReasoningEffortKey,
                string: effort,
                to: &command
            )
        case .grok, .openCode, .cursor:
            break
        }
    }

    /// Claude, Codex, and Grok take an opening prompt as a trailing positional argument — which is why it
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

    /// OpenCode's interactive TUI resumes with `--session <ses_…>`. A fresh invocation creates
    /// its own identifier, which `OpenCodeSessionDiscovery` reads back from the CLI's supported
    /// JSON session listing. Unlike Claude and Codex, the opening is a named `--prompt` value,
    /// not a positional operand.
    private static func openCodeCommand(
        for session: AgentSession,
        prompt: String?
    ) -> (ShellCommand, ResumeState) {
        var command = ShellCommand(word: AgentDefaults.openCodeExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.openCodeModelFlag, to: &command)

        if let existingID = session.resumeState.transcriptID {
            command.append(flag: "--session", value: existingID.rawValue)
            return (command, .resumable(existingID))
        }

        if session.isCrossProviderContinuation,
           session.kind.supports(.openingFileAttachments) {
            command.append(
                flag: "--file",
                value: ConversationHandoffStore.url(for: session.id).path
            )
        }

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command.append(flag: "--prompt", value: prompt)
        }
        return (command, .awaitingIdentifier)
    }

    /// Grok accepts a caller-supplied UUID for a new interactive conversation and a positional
    /// opening prompt. A resume names that same UUID with `--resume`; the opening is never
    /// replayed. These flags were measured against Grok 0.2.118 rather than inferred from its
    /// headless `--single` mode.
    private static func grokCommand(
        for session: AgentSession,
        prompt: String?
    ) -> (ShellCommand, ResumeState) {
        var command = ShellCommand(word: AgentDefaults.grokExecutable)
        appendModelFlag(for: session, flag: AgentDefaults.grokModelFlag, to: &command)
        appendPermissionMode(for: session, to: &command)

        if let existingID = session.resumeState.transcriptID {
            command.append(flag: "--resume", value: existingID.rawValue)
            return (command, .resumable(existingID))
        }

        let mintedID = TranscriptID(session.id.uuidString.lowercased())
        command.append(flag: "--session-id", value: mintedID.rawValue)
        appendPrompt(prompt, to: &command)
        return (command, .awaitingIdentifier)
    }

    /// Maps Threading's per-conversation reasoning and Fast choices onto Codex's launch
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
        appendReasoningEffort(for: session, to: &command)

        guard let fastMode = fastModeAtStartup(for: session) else { return }

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

        // Hosted tests run inside the shipping app and can build real launch plans. They must
        // not turn that read-only exercise into a write to the developer's own CODEX_HOME.
        if mayMaintainCodexHookConfiguration,
           let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) {
            CodexHookInstaller.install(inCodexHome: account.configPath)
        }

        if AppSettings.shared.bypassesCodexHookTrust {
            command.append(flag: AgentDefaults.codexBypassHookTrustFlag)
        }
    }

    /// Hosted unit tests build real plans inside the shipping app and therefore resolve the
    /// developer's real accounts. They may inspect a plan but never maintain that account's
    /// persistent hook file.
    static var mayMaintainCodexHookConfiguration: Bool {
        NSClassFromString("XCTestCase") == nil
    }

    /// Wraps a command invocation in the login-shell source shared by every launch surface.
    private static func launchPlan(
        command: ShellCommand,
        in folder: String,
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:]
    ) -> AgentLaunchPlan {
        let source = ShellCommand.executing(command, in: folder)

        return AgentLaunchPlan(
            executable: loginShellPath,
            arguments: ["-l", "-c", source.source],
            resumeState: resumeState,
            environmentOverrides: environmentOverrides
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
