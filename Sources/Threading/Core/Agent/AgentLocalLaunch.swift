import Foundation

/// The application composition root installs the runtime store before any sessions are restored.
/// Hosted unit fixtures which skip application startup keep their explicitly supplied shell.
/// Remote hosts never use this adapter: their paths and environment belong to their host.
enum AgentLocalLaunch {
    private static let state = StoreState()

    static var store: ManagedAgentRuntimeStore? { state.lock.withLock { state.store } }
    static func configure(_ store: ManagedAgentRuntimeStore?) {
        state.lock.withLock { state.store = store }
    }

    /// A missing managed receipt is known without filesystem work. Restored/scheduled chats
    /// bypass the composer, so they need the same actionable installation refusal.
    static func requireConfigured(_ kind: AgentKind) throws {
        guard let store else { return }
        let selected = store.selection(for: kind)
        if selected.managed && selected.version == nil {
            throw AgentClientUnavailable(kind: kind, executable: selected.executable)
        }
    }

    static func plan(command: ShellCommand, in directory: String,
                     shell: String, resumeState: ResumeState = .unavailable,
                     environmentOverrides: [String: String] = [:],
                     credentials: AgentCredentialEnvironment = .none) -> AgentLaunchPlan {
        if let store {
            return store.plan(command: command, in: directory, resumeState: resumeState,
                              environmentOverrides: environmentOverrides, credentials: credentials)
        }
        return AgentLaunchPlan.inLoginShell(
            command: command, in: directory, shellPath: shell, resumeState: resumeState,
            environmentOverrides: environmentOverrides, credentialEnvironment: credentials
        )
    }

    private final class StoreState: @unchecked Sendable {
        let lock = NSLock()
        var store: ManagedAgentRuntimeStore?
    }
}

struct AgentClientUnavailable: LocalizedError {
    let kind: AgentKind
    let executable: String

    var errorDescription: String? {
        L10n.format("The selected %@ installation is unavailable.", kind.displayName)
    }

    var failure: SessionLaunchFailure {
        SessionLaunchFailure(origin: .preflight, summary: errorDescription ?? "",
                             detail: [L10n.format("Selected executable: %@", executable)],
                             knownCause: SessionLaunchDiagnosis.Cause.executableMissing)
    }
}
