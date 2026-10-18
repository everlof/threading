import Foundation

/// What a spawned child launches with once the manager's plan has left choices out.
///
/// A choice is inherited from the manager only when the child runs the **same runtime**. A model
/// identifier, an effort level and a fast-mode switch each belong to one provider's vocabulary:
/// a Claude manager's `claude-opus-…` handed to a Codex child became `--model claude-opus-…` on
/// the Codex launch line, because the launcher passes a stored model through unchanged. The
/// account is the same story — a Claude login's name does not name a Codex login. Permission mode
/// is the one shared vocabulary (`AgentPermissionMode`), and it is also the ceiling admission
/// checks, so it is carried wherever the child's runtime has modes at all.
///
/// Pure, so the rule can be read and tested without a store, a usage service or a window.
struct SpawnChildChoices: Equatable {

    // MARK: - Types

    /// Which login the child starts on, before usage admission.
    enum AccountRequest: Equatable {
        /// A login id, handle or display name, or `best`, resolved against fresh readings.
        case named(String)
        /// A runtime without account routing: it has one login, and nothing to meter.
        case standard
    }

    // MARK: - Properties

    let kind: AgentKind
    let account: AccountRequest
    let model: String?
    let reasoningEffort: String?
    let fastMode: Bool?
    let usesNativeUI: Bool
    let permissionMode: AgentPermissionMode?

    // MARK: - Public Methods

    /// Resolves the child's choices, or the words refusing a plan the runtime cannot honour.
    ///
    /// `defaultAccountName` answers for a child on another runtime that names no account; it is
    /// asked only then, since its answer reads the project's login order and discovery.
    @MainActor
    static func resolve(
        plan: SpawnSessionPlanArguments?,
        manager: AgentSession,
        defaultAccountName: (AgentKind) -> String
    ) -> Result<SpawnChildChoices, SupervisionActionFailure> {
        let kind = plan?.kind ?? manager.kind
        let sameRuntime = kind == manager.kind

        let account: AccountRequest
        if kind.supportsAccounts {
            account = .named(plan?.account
                ?? (sameRuntime ? manager.accountHandle.name : defaultAccountName(kind)))
        } else if plan?.account == nil {
            account = .standard
        } else {
            return .failure(.init(
                "\(kind.displayName) has no separate logins in Threading; omit account."
            ))
        }

        let usesNativeUI = plan?.usesNativeUI ?? kind.supportsNativeUI
        if usesNativeUI, !kind.supportsNativeUI {
            return .failure(.init(
                "\(kind.displayName) has no native chat in Threading; set uses_native_ui to false."
            ))
        }
        if !usesNativeUI, !kind.supports(.terminalUI) {
            return .failure(.init(
                "\(kind.displayName) runs only in Threading's native chat; omit uses_native_ui."
            ))
        }

        return .success(SpawnChildChoices(
            kind: kind,
            account: account,
            model: plan?.model ?? (sameRuntime ? manager.model : nil),
            reasoningEffort: plan?.reasoningEffort ?? (sameRuntime ? manager.reasoningEffort : nil),
            fastMode: plan?.fastMode ?? (sameRuntime ? manager.fastMode : nil),
            usesNativeUI: usesNativeUI,
            permissionMode: kind.supportsPermissionModes
                ? (plan?.permissionMode ?? manager.permissionMode)
                : nil
        ))
    }
}
