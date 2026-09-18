import Foundation
import ThreadingDomain

/// Why a session cannot run on its project's remote host yet. Each is a scope refusal of the first
/// release, stated rather than attempted: a launch that half-worked on a host would be a session
/// the person cannot trust.
enum RemoteAgentLaunchError: LocalizedError, Equatable {
    /// Only Claude runs remotely so far. Codex, Grok and OpenCode learn their session identifier
    /// by reading this Mac's files or running their CLI here after launch.
    case unsupportedAgent(AgentKind)
    /// The host's login shell is not one `-l -c` can hand POSIX syntax to.
    case unsupportedLoginShell(String)
    /// A login shell on the host does not resolve `claude`.
    case agentNotInstalled(AgentKind)
    /// A side chat's first launch forks its parent's transcript, which is found on this Mac.
    case sideChatFork
    /// A managed workspace's checkout is a worktree on this Mac.
    case managedWorkspace
    /// A natively rendered conversation reads its transcript on this Mac.
    case nativeConversation

    var errorDescription: String? {
        switch self {
        case .unsupportedAgent(let kind):
            return L10n.format("%@ sessions can’t run on a remote host yet.", kind.displayName)
        case .unsupportedLoginShell(let shell):
            return L10n.format("The host’s login shell (%@) isn’t supported yet.", shell)
        case .agentNotInstalled(let kind):
            return L10n.format("%@ isn’t installed on the host, or its login shell can’t find it.", kind.displayName)
        case .sideChatFork:
            return L10n.string("Side chats can’t start on a remote host yet.")
        case .managedWorkspace:
            return L10n.string("Managed workspaces can’t run on a remote host yet.")
        case .nativeConversation:
            return L10n.string("Chats can’t run on a remote host yet. Use a terminal session.")
        }
    }

    var token: String {
        switch self {
        case .unsupportedAgent: return "unsupportedAgent"
        case .unsupportedLoginShell: return "unsupportedLoginShell"
        case .agentNotInstalled: return "agentNotInstalled"
        case .sideChatFork: return "sideChatFork"
        case .managedWorkspace: return "managedWorkspace"
        case .nativeConversation: return "nativeConversation"
        }
    }
}

/// A launch composed for a remote host: the command line and the exact environment the host's
/// daemon spawns it with.
struct RemoteAgentLaunch: Sendable {
    let plan: AgentLaunchPlan
    /// `NAME=value` entries, verbatim to the daemon, which adds nothing. Built from the host's
    /// facts; nothing from this Mac's process environment crosses.
    let environment: [String]

    /// A launch whose settings and MCP configuration are still objects. `make` decides everything on
    /// the main actor, where the session, the settings and the catalogue live; `encode()` turns the
    /// objects into the environment the launch script reads, which is JSON work and so is done off
    /// it. Separate types, so nothing can spawn a launch whose files would be written empty.
    struct Unencoded: Sendable {
        let plan: AgentLaunchPlan
        let environment: [String]
        let payloads: [Payload]

        func encode() -> RemoteAgentLaunch {
            let encoded = payloads.compactMap { payload -> String? in
                guard let data = try? JSONSerialization.data(withJSONObject: payload.object.value, options: [.sortedKeys])
                else { return nil }
                return "\(payload.variable)=\(String(decoding: data, as: UTF8.self))"
            }
            return RemoteAgentLaunch(plan: plan, environment: environment + encoded)
        }
    }

    /// One file's content, carried to the launch script in an environment variable.
    struct Payload: Sendable {
        let variable: String
        let object: JSONObjectBox
    }

    /// A JSON object built once and never mutated, handed to `encode()` on another queue.
    struct JSONObjectBox: @unchecked Sendable {
        let value: [String: Any]
    }

    /// Composes the launch from the host's facts, never from this Mac.
    ///
    /// The command is `<login shell> -l -c '<script>'`, where the script changes into the remote
    /// checkout and chooses between resuming and starting on the host itself: whether Claude
    /// holds a transcript for this session is a fact about the host's disk, so asking it there, at
    /// the moment of launch, is both correct and one round trip fewer. The transcript path uses
    /// Claude's own project-slug rule for the *remote* directory.
    ///
    /// **Hooks and tools (slice 4).** When the host has a route back to this Mac
    /// (`RemoteHostLaunchContext.toolRoute`), the launch carries the same `--settings` hooks and
    /// `--mcp-config` bridge a local Claude gets, pointed at the forwarded socket. Both files hold
    /// the session's token, so they are written *on the host*, `0600`, by the launch script, from
    /// environment variables: an argument would be readable in any user's `ps` there, and the
    /// environment of a process is its owner's alone.
    @MainActor
    static func make(
        for session: AgentSession,
        in project: Project,
        host: ProjectExecutionHost,
        context: RemoteHostLaunchContext,
        initialPrompt: String?,
        reportsLifecycle: Bool = AppSettings.shared.reportsClaudeLifecycleEvents,
        allowedTools: [String]? = nil
    ) throws -> RemoteAgentLaunch.Unencoded {
        guard session.kind.supports(.remoteExecutionHostLaunch) else {
            throw RemoteAgentLaunchError.unsupportedAgent(session.kind)
        }
        guard session.managedWorkspace == nil else { throw RemoteAgentLaunchError.managedWorkspace }
        guard AgentLauncher.forkParent(for: session, in: project) == nil else {
            throw RemoteAgentLaunchError.sideChatFork
        }
        let facts = context.facts
        guard facts.hasPOSIXLoginShell else {
            throw RemoteAgentLaunchError.unsupportedLoginShell(facts.loginShell)
        }
        guard facts.claudePath != nil else { throw RemoteAgentLaunchError.agentNotInstalled(session.kind) }

        let integration = Integration.make(
            for: session,
            context: context,
            reportsLifecycle: reportsLifecycle,
            allowedTools: allowedTools ?? MCPToolCatalog.remoteProviderLaunchToolNames
        )
        let commands = AgentLauncher.remoteClaudeCommands(
            for: session,
            prompt: initialPrompt,
            integration: integration.flags
        )
        let transcript = remoteTranscriptPath(
            home: facts.home,
            remoteDirectory: host.remoteDirectory,
            transcriptID: commands.transcriptID
        )

        let script = (integration.scriptLines + [
            "cd \(quoted(host.remoteDirectory)) || exit \(RemoteAgentLaunchDefaults.directoryFailureStatus)",
            "if [ -f \(quoted(transcript)) ]; then exec \(commands.resume.source); fi",
            "exec \(commands.fresh.source)"
        ]).joined(separator: "\n")

        let plan = AgentLaunchPlan(
            executable: facts.loginShell,
            arguments: ["-l", "-c", script],
            resumeState: .resumable(commands.transcriptID)
        )
        return Unencoded(
            plan: plan,
            environment: environment(for: facts) + integration.environment,
            payloads: integration.payloads
        )
    }

    /// Where Claude keeps a conversation's transcript on the host: the host's home, Claude's
    /// default config directory, and the project slug of the *remote* checkout. One function, so
    /// the launch's resume test and the transcript mirror can never disagree about the file.
    static func remoteTranscriptPath(home: String, remoteDirectory: String, transcriptID: TranscriptID) -> String {
        "\(home)/\(RemoteAgentLaunchDefaults.claudeProjectsDirectory)/"
            + "\(ClaudeTranscript.projectSlug(forPath: remoteDirectory))/"
            + "\(transcriptID.rawValue)\(RemoteAgentLaunchDefaults.transcriptExtension)"
    }

    /// The environment a remote child starts with. A login shell rebuilds `PATH` from the host's
    /// own profile; the seed here only has to be enough to find that shell's startup files.
    static func environment(for facts: RemoteHostFacts) -> [String] {
        [
            "\(EnvironmentKeys.term)=\(TerminalDefaults.terminalType)",
            "\(EnvironmentKeys.colorTerm)=\(TerminalDefaults.colorTerm)",
            "\(RemoteAgentLaunchDefaults.termProgramKey)=\(RemoteAgentLaunchDefaults.termProgram)",
            "\(EnvironmentKeys.lang)=\(RemoteAgentLaunchDefaults.language)",
            "\(EnvironmentKeys.home)=\(facts.home)",
            "\(RemoteAgentLaunchDefaults.userKey)=\(facts.user)",
            "\(RemoteAgentLaunchDefaults.logNameKey)=\(facts.user)",
            "\(EnvironmentKeys.shell)=\(facts.loginShell)",
            "\(EnvironmentKeys.path)=\(RemoteAgentLaunchDefaults.seedPath)"
        ]
    }

    /// One word, single-quoted for a POSIX shell.
    fileprivate static func quoted(_ value: String) -> String {
        ShellCommand(word: value).source
    }
}

/// The paths and tools a remote Claude command carries. Empty is a launch with neither.
struct RemoteAgentIntegrationFlags: Equatable, Sendable {
    var settingsPath: String?
    var mcpConfigPath: String?
    var allowedTools: [String] = []
}

extension RemoteAgentLaunch {

    /// Everything slice 4 adds to one launch, composed together so the files the script writes,
    /// the variables it reads them from and the flags that name them cannot disagree.
    struct Integration {
        var flags = RemoteAgentIntegrationFlags()
        var environment: [String] = []
        var payloads: [Payload] = []
        var scriptLines: [String] = []

        @MainActor
        static func make(
            for session: AgentSession,
            context: RemoteHostLaunchContext,
            reportsLifecycle: Bool,
            allowedTools: [String]
        ) -> Integration {
            var integration = Integration()
            guard let route = context.toolRoute else { return integration }
            let facts = context.facts
            let token = MCPSessionRegistry.token(for: session.id)
            // The same two words a local launch exports (`AgentLauncher.hookEnvironmentWords`), so
            // a person's own hooks find Threading on the host exactly as they do on the Mac. There
            // is no port: the loopback endpoint is this Mac's, and nothing forwards it.
            integration.environment = [
                "\(MCPDefaults.socketEnvironmentKey)=\(route.socketPath)",
                "\(MCPDefaults.sessionTokenEnvironmentKey)=\(token)"
            ]

            let directory = "\(facts.home)/\(RemoteHostDefaults.remoteSessionFilesDirectory)"
            let stem = session.id.uuidString
            var files: [(variable: String, path: String, object: [String: Any])] = []

            // A hook is a `curl` on the host, so a host without one cannot report; the session then
            // falls back to reading its output, as any session without hooks does. Account-derived
            // settings (the status-line override, the speed default) are left out: they describe
            // this Mac's logins, not the host's.
            if let settings = MCPSessionRegistry.hookSettings(
                for: session.id,
                brokersPermissions: false,
                reportsLifecycle: reportsLifecycle && facts.curlPath != nil,
                remoteControl: AgentLauncher.remoteControlAtStartup(for: session),
                fastMode: session.fastMode
            ) {
                let path = "\(directory)/\(stem)\(RemoteAgentLaunchDefaults.settingsFileSuffix)"
                files.append((RemoteAgentLaunchDefaults.settingsVariable, path, settings))
                integration.flags.settingsPath = path
            }

            if let bridgePath = route.bridgePath, !allowedTools.isEmpty {
                let invocation = MCPBridgeInvocation(
                    command: bridgePath,
                    arguments: [
                        MCPBridgeDefaults.socketArgument, route.socketPath,
                        MCPBridgeDefaults.tokenArgument, token,
                        MCPBridgeDefaults.cacheArgument,
                        "\(route.cacheDirectory)/\(stem).\(MCPDefaults.configFileExtension)"
                    ]
                )
                let configuration: [String: Any] = [
                    "mcpServers": [MCPDefaults.serverName: MCPServerBinding.stdio(invocation).claudeServerObject]
                ]
                let path = "\(directory)/\(stem)\(RemoteAgentLaunchDefaults.mcpConfigFileSuffix)"
                files.append((RemoteAgentLaunchDefaults.mcpConfigVariable, path, configuration))
                integration.flags.mcpConfigPath = path
                integration.flags.allowedTools = allowedTools
            }

            guard !files.isEmpty else { return integration }
            // In a subshell, so the owner-only umask governs these files and not the agent's own.
            // A file that cannot be written ends the launch with the daemon's status for a
            // directory that cannot be entered, rather than starting an agent whose flags name
            // nothing.
            var writes = [
                "umask 077",
                "mkdir -p \(RemoteAgentLaunch.quoted(directory)) \(RemoteAgentLaunch.quoted(route.cacheDirectory))"
            ]
            for file in files {
                integration.payloads.append(Payload(variable: file.variable, object: JSONObjectBox(value: file.object)))
                writes.append("printf '%s' \"$\(file.variable)\" > \(RemoteAgentLaunch.quoted(file.path))")
            }
            integration.scriptLines = [
                "( " + writes.joined(separator: " && ") + " ) || exit \(RemoteAgentLaunchDefaults.directoryFailureStatus)",
                "unset " + files.map(\.variable).joined(separator: " ")
            ]
            return integration
        }
    }
}

enum RemoteAgentLaunchDefaults {
    static let claudeProjectsDirectory = ".claude/projects"
    static let transcriptExtension = ".jsonl"
    /// The daemon's own status for a directory that cannot be entered, kept the same here.
    static let directoryFailureStatus = 126
    static let termProgramKey = "TERM_PROGRAM"
    static let termProgram = "Threading"
    /// Present on every glibc and musl system, unlike this Mac's `en_US.UTF-8`, which a minimal
    /// Debian lacks and which makes every locale-aware tool warn.
    static let language = "C.UTF-8"
    static let userKey = "USER"
    static let logNameKey = "LOGNAME"
    static let seedPath = "/usr/local/bin:/usr/bin:/bin"
    /// Carry a session's settings and MCP configuration to the launch script, which writes them to
    /// owner-only files and unsets both before the agent starts.
    static let settingsVariable = "THREADING_LAUNCH_SETTINGS"
    static let mcpConfigVariable = "THREADING_LAUNCH_MCP_CONFIG"
    static let settingsFileSuffix = ".settings.json"
    static let mcpConfigFileSuffix = ".mcp.json"
}

// MARK: - Placement

/// Where a host-backed terminal's child runs. See `TerminalSession.hostPlacement`.
enum PTYHostPlacement: Equatable, Sendable {
    case local
    /// On a remote execution host, spawned with this environment.
    case remote(environment: [String])

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}
