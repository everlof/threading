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
    private static var cache: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.cache) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cache) }
    }

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
    static func prefetch(_ accounts: [AgentAccount], completion: @escaping () -> Void) {
        let pending = accounts.filter {
            $0.provider == .claude
                && AccountAvatarStore.cachedEmail(for: $0) == nil
                && cachedEmail(for: $0) == nil
        }

        guard !pending.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            for account in pending {
                if let email = probe(account) { found[account.id.rawValue] = email }
            }

            guard !found.isEmpty else { return }

            DispatchQueue.main.async {
                cache = cache.merging(found) { _, new in new }
                completion()
            }
        }
    }

    /// Runs `claude auth status --json` for one account and reads its `email`.
    ///
    /// The account is selected the same way a launch selects one — `CLAUDE_CONFIG_DIR`, unset
    /// for the default — so this asks about exactly the login a session would run as.
    private static func probe(_ account: AgentAccount) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentLauncher.loginShellPath)

        let redirect = account.isDefault
            ? "env -u \(AgentKind.claude.accountEnvironmentKey)"
            : "env \(AgentKind.claude.accountEnvironmentKey)='\(account.configPath)'"

        process.arguments = [
            "-l", "-c",
            "\(redirect) \(AgentDefaults.claudeExecutable) auth status --json"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            SkalmanLogger.agent.error("Could not ask claude for its account: \(error.localizedDescription)")
            return nil
        }

        // Read before waiting: a full pipe buffer with nobody draining it deadlocks the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json[AccountProbeDefaults.emailKey] as? String,
              !email.isEmpty
        else { return nil }

        return email
    }
}

enum AccountProbeDefaults {
    static let emailKey = "email"
}
