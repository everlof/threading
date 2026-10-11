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
    /// Both terminal and native launches merge these into the child's spawn environment. The
    /// login shell can still replace ordinary values such as EDITOR from its own profile.
    /// Empty for every plan that has nothing to add, so the mechanism costs those runs nothing.
    ///
    /// Read through `launchEnvironment()` or `environmentEntries(on:)` rather than merged at
    /// each transport call site, so a transport cannot silently drop what the plan asked for.
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

    /// PTY transports use KEY=value entries rather than a dictionary. Apply ordinary plan
    /// overrides before credentials, replacing a prior entry for the same key in both cases.
    func environmentEntries(on inherited: [String]) -> [String] {
        let keys = Set(environmentOverrides.keys)
        let kept = inherited.filter { entry in
            guard let separator = entry.firstIndex(of: "=") else { return true }
            return !keys.contains(String(entry[..<separator]))
        }
        let overrides = environmentOverrides.keys.sorted().map { key in
            "\(key)=\(environmentOverrides[key] ?? "")"
        }
        return credentialEnvironment.applied(toEntries: kept + overrides)
    }
}
