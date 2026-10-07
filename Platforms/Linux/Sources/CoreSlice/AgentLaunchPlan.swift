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

    /// Credentials this launch's child needs, such as a login's long-lived token.
    ///
    /// Unlike `environmentOverrides`, every transport merges these — terminal and native, local
    /// PTY and `threading-ptyd` alike — because a terminal cannot state them the way it states
    /// its other variables: as `env NAME=value` words, they would land in `EventLog` and `ps`.
    let credentialEnvironment: AgentCredentialEnvironment

    init(
        executable: String,
        arguments: [String],
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:],
        credentialEnvironment: AgentCredentialEnvironment = .none
    ) {
        self.executable = executable
        self.arguments = arguments
        self.resumeState = resumeState
        self.environmentOverrides = environmentOverrides
        self.credentialEnvironment = credentialEnvironment
    }

    /// Pure command composition; the host resolves its login shell and environment separately.
    static func inLoginShell(
        command: ShellCommand,
        in folder: String,
        shellPath: String,
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:],
        credentialEnvironment: AgentCredentialEnvironment = .none
    ) -> AgentLaunchPlan {
        let source = ShellCommand.executing(command, in: folder)
        return AgentLaunchPlan(
            executable: shellPath,
            arguments: ["-l", "-c", source.source],
            resumeState: resumeState,
            environmentOverrides: environmentOverrides,
            credentialEnvironment: credentialEnvironment
        )
    }
}
