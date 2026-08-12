import Foundation

/// Asks the Claude CLI which account a config directory is logged into.
///
/// The alternate logins record `oauthAccount.emailAddress` in their own `.claude.json`, so
/// they are answered by a file read. The **default** login records only a hashed `userID` — its
/// identity lives in the Keychain, which this app deliberately never reads (a Keychain item
/// does not say which config directory it belongs to, and an unbundled binary re-prompts on
/// every rebuild). So the one account that cannot be named from disk is asked directly:
/// `claude auth status --json` reports `email`, honours `CLAUDE_CONFIG_DIR`, and needs no
/// token of ours.
///
/// It costs a subprocess, so the answer is cached on disk and the probe runs at most once per
/// account per install — an address does not change while a login does not.
enum AccountEmailProbe {

    private enum Keys {
        static let cache = "accountLoginEmails"
    }

    // MARK: - Cache

    /// Addresses learned from the CLI, keyed by account id. Persisted, because the cost being
    /// avoided is a process launch rather than a file read.
    @MainActor
    private static var cache: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.cache) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cache) }
    }

    @MainActor
    static func cachedEmail(for account: AgentAccount) -> String? {
        cache[account.id.rawValue]
    }

    // MARK: - Probing

    /// Fills in any account whose address is not already known, off the main thread.
    ///
    /// Only Claude: Codex's `id_token` carries its `email` claim, so its accounts are already
    /// answered locally. `completion` fires once, after everything asked has answered, so a
    /// caller can refresh a menu rather than poll.
    @MainActor
    static func prefetch(
        _ accounts: [AgentAccount],
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let pending = accounts.filter {
            $0.provider == .claude
                && AccountAvatarStore.cachedEmail(for: $0) == nil
                && cachedEmail(for: $0) == nil
        }

        guard !pending.isEmpty else { return }

        // Read on the main actor and carried in: the shell path comes from the profile store,
        // which the background work must not reach into.
        let shell = AgentLauncher.loginShellPath

        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            for account in pending {
                if let email = probe(account, shell: shell) { found[account.id.rawValue] = email }
            }

            guard !found.isEmpty else { return }
            let discovered = found

            DispatchQueue.main.async {
                cache = cache.merging(discovered) { _, new in new }
                completion()
            }
        }
    }

    /// Runs `claude auth status --json` for one account and reads its `email`.
    ///
    /// The account is selected the same way a launch selects one — `CLAUDE_CONFIG_DIR`, unset
    /// for the default — so this asks about exactly the login a session would run as.
    private static func probe(_ account: AgentAccount, shell: String) -> String? {
        var environment = AgentEnvironment.launchEnvironment()
        if let accountKey = AgentKind.claude.accountEnvironmentKey {
            if account.isDefault {
                environment.removeValue(forKey: accountKey)
            } else {
                environment[accountKey] = account.configPath
            }
        }
        var command = ShellCommand(word: AgentDefaults.claudeExecutable)
        command.append(word: "auth")
        command.append(word: "status")
        command.append(word: "--json")

        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: shell,
                arguments: ["-l", "-c", command.source],
                environment: environment,
                timeout: AccountProbeDefaults.timeout,
                maximumOutputBytes: AccountProbeDefaults.maximumOutputBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.agent.error(
                "Could not ask claude for its account: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
        guard result.termination == .exited(0), !result.outputWasTruncated,
              let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let email = json[AccountProbeDefaults.emailKey] as? String,
              !email.isEmpty
        else { return nil }

        return email
    }
}

enum AccountProbeDefaults {
    static let emailKey = "email"
    static let timeout: TimeInterval = 10
    static let maximumOutputBytes = 64 * 1024
}
