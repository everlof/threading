import Foundation

/// The environment that sends one CLI invocation to one discovered account.
///
/// The default account is an explicit `env -u`, not an omitted assignment: Threading itself may
/// have been opened from a shell exporting an alternate home, and inheriting it would make a
/// command act on a different login from the session whose row was clicked. Agent launches and
/// provider archive commands share this construction so that lifecycle operations cannot drift
/// from resume routing.
///
/// A login with a long-lived token gets it as a credential entry, which the caller hands the
/// child's environment and never its command line. Every other login of that runtime gets an
/// explicit `env -u` for the token variable instead: a login shell's profile may export one, and
/// the CLI would then sign *every* session in as the token's account while Threading named and
/// metered the one chosen. `AgentEnvironment` already drops an inherited token from Threading's
/// own environment; the `-u` is for the one a profile re-exports after that.
enum AgentAccountRouting {

    struct Route: Equatable {
        /// The `env …` words; a caller appends the CLI's own words after them.
        let command: ShellCommand
        let credentials: AgentCredentialEnvironment
    }

    /// The route for a launch that authenticates. Reads the login's saved token from the vault.
    static func route(
        for kind: AgentKind,
        account: AgentAccount,
        tokens: AgentAccountTokenVault = .shared
    ) -> Route {
        route(for: kind, account: account, token: tokens.token(for: account.id))
    }

    static func route(
        for kind: AgentKind,
        account: AgentAccount,
        token: AgentAccountToken?
    ) -> Route {
        var prefix = ShellCommand(word: "env")
        // A runtime whose login is not a directory has nothing to point at, and callers reach
        // here only after asking for `.accounts`. The bare `env` still carries whatever the
        // caller appends after it.
        guard let accountKey = kind.accountEnvironmentKey else {
            return Route(command: prefix, credentials: .none)
        }
        if account.isDefault {
            prefix.append(flag: "-u", value: accountKey)
        }

        let tokenSpec = kind.longLivedToken
        if let tokenSpec, token == nil {
            prefix.append(flag: "-u", value: tokenSpec.environmentKey)
        }

        // env stops parsing options at the first assignment, so every -u must come first.
        if !account.isDefault {
            prefix.append(word: "\(accountKey)=\(account.configPath)")
        }

        guard let tokenSpec, let token else {
            return Route(command: prefix, credentials: .none)
        }
        return Route(
            command: prefix,
            credentials: AgentCredentialEnvironment([tokenSpec.environmentKey: token.value])
        )
    }

    /// Only the prefix, for a command that never authenticates — a provider's archive flag, for
    /// instance. A command that talks to the provider takes `route` and merges its credentials,
    /// or a token login silently falls back to its expired browser sign-in.
    static func prefix(for kind: AgentKind, account: AgentAccount) -> ShellCommand {
        route(for: kind, account: account).command
    }
}
