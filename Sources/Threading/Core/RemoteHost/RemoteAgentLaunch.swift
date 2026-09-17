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
struct RemoteAgentLaunch {
    let plan: AgentLaunchPlan
    /// `NAME=value` entries, verbatim to the daemon, which adds nothing. Built from the host's
    /// facts; nothing from this Mac's process environment crosses.
    let environment: [String]

    /// Composes the launch from the host's facts, never from this Mac.
    ///
    /// The command is `<login shell> -l -c '<script>'`, where the script changes into the remote
    /// checkout and chooses between resuming and starting on the host itself: whether Claude
    /// holds a transcript for this session is a fact about the host's disk, so asking it there, at
    /// the moment of launch, is both correct and one round trip fewer. The transcript path uses
    /// Claude's own project-slug rule for the *remote* directory.
    @MainActor
    static func make(
        for session: AgentSession,
        in project: Project,
        assignment: RemoteExecutionHostAssignment,
        context: RemoteHostLaunchContext,
        initialPrompt: String?
    ) throws -> RemoteAgentLaunch {
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

        let commands = AgentLauncher.remoteClaudeCommands(for: session, prompt: initialPrompt)
        let transcript = "\(facts.home)/\(RemoteAgentLaunchDefaults.claudeProjectsDirectory)/"
            + "\(ClaudeTranscript.projectSlug(forPath: assignment.remoteDirectory))/"
            + "\(commands.transcriptID.rawValue)\(RemoteAgentLaunchDefaults.transcriptExtension)"

        let script = [
            "cd \(quoted(assignment.remoteDirectory)) || exit \(RemoteAgentLaunchDefaults.directoryFailureStatus)",
            "if [ -f \(quoted(transcript)) ]; then exec \(commands.resume.source); fi",
            "exec \(commands.fresh.source)"
        ].joined(separator: "\n")

        let plan = AgentLaunchPlan(
            executable: facts.loginShell,
            arguments: ["-l", "-c", script],
            resumeState: .resumable(commands.transcriptID)
        )
        return RemoteAgentLaunch(plan: plan, environment: environment(for: facts))
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
    private static func quoted(_ value: String) -> String {
        ShellCommand(word: value).source
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
