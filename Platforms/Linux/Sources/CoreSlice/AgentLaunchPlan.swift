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

    /// Pure command composition; the host resolves its login shell and environment separately.
    static func inLoginShell(
        command: ShellCommand,
        in folder: String,
        shellPath: String,
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:]
    ) -> AgentLaunchPlan {
        let source = ShellCommand.executing(command, in: folder)
        return AgentLaunchPlan(
            executable: shellPath,
            arguments: ["-l", "-c", source.source],
            resumeState: resumeState,
            environmentOverrides: environmentOverrides
        )
    }
}
