import Foundation

// MARK: - Agent Environment

/// Everything an agent runner exports about **its own run**, which must not be inherited by the
/// sessions Threading launches.
///
/// A session started from inside another agent's shell would otherwise be handed that
/// conversation's identifiers and treat itself as a nested child of it — and, worse than
/// identity, the *posture* that run was given. `open` forwards its caller's environment through
/// LaunchServices, so a Threading opened from a Codex tool call carried
/// `CODEX_SANDBOX_NETWORK_DISABLED=1` and `CODEX_PERMISSION_PROFILE=:workspace` into every
/// session under it: an agent told the network is off, by a sandbox that ended hours ago.
///
/// Named by family rather than variable by variable, because the failure is silent and the
/// families keep growing — `CODEX_THREAD` was listed and `CODEX_CI` was not, which is the kind of
/// gap nothing reports.
enum AgentEnvironment {
    /// The families. Each is a runner describing a run, never a machine describing itself.
    static let inheritedIdentityPrefixes = [
        "CLAUDE_",
        "CLAUDECODE",
        "CODEX_",
        "GROK_",
        "OPENCODE_",
        "AI_AGENT"
    ]

    /// The exception inside those families: where an account's config lives is a *place*, not a
    /// run, and it is how a launch reaches a login other than the default. `AgentKind` owns the
    /// names, so a new runtime cannot be added and forgotten here — and a runtime that keeps its
    /// login somewhere other than a directory contributes none.
    static var accountConfigKeys: Set<String> {
        Set(AgentKind.allCases.compactMap(\.accountEnvironmentKey))
    }

    static func isInheritedAgentIdentity(_ key: String) -> Bool {
        guard !accountConfigKeys.contains(key) else { return false }
        return inheritedIdentityPrefixes.contains { key.hasPrefix($0) }
    }

    /// Pure composition shared by GUI, headless and Linux hosts. Credentials and account
    /// directories survive; run identity belongs only to the parent that exported it.
    static func removingInheritedIdentity(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        for key in environment.keys where isInheritedAgentIdentity(key) {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// Puts Threading's command-line tools on `PATH`, when the user has asked for it.
    ///
    /// **One place, both paths.** `TerminalSession.buildEnvironment()` composes a PTY child's
    /// environment and this composes a headless one; they differ in the terminal variables and
    /// agree about everything else, so a rule that belongs to *what Threading launches* rather
    /// than to how it is drawn lives here and is called from both. Two copies would be two
    /// places for the opt-in to be half-applied.
    ///
    /// **Prepended, never substituted.** The entry goes in front of whatever `PATH` already
    /// says and nothing is removed, so `threading-ptyd` resolves to Threading's shim while every
    /// other command the user has resolves exactly as before. A login shell's `path_helper` and
    /// the user's own profile may *reorder* what they inherit — `/etc/paths` entries are
    /// commonly moved to the front — but neither drops an entry, so the directory stays
    /// reachable even when it stops being first.
    ///
    /// Refused when `PATH` is absent or empty rather than invented: a child that inherits no
    /// `PATH` gets `execvp`'s own default, and replacing that with a directory holding two
    /// symlinks would break every command in the session.
    static func prependingCommandLineTools(
        to environment: [String: String],
        directory: String,
        isEnabled: Bool
    ) -> [String: String] {
        guard isEnabled, !directory.isEmpty else { return environment }
        guard let existing = environment[EnvironmentKeys.path], !existing.isEmpty else {
            return environment
        }
        // Already leading: a second pass over the same value must not grow it.
        guard existing != directory, !existing.hasPrefix("\(directory):") else {
            return environment
        }
        var environment = environment
        environment[EnvironmentKeys.path] = "\(directory):\(existing)"
        return environment
    }
}
