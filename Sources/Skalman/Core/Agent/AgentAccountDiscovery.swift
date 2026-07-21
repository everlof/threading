import Foundation

/// Discovers the agent accounts configured on this machine.
///
/// Accounts are found by scanning for config directories rather than by parsing shell
/// aliases, so they are found whether or not the user has an alias for them. Aliases are
/// consulted only to label an account with the name the user already calls it by.
///
/// Directories are admitted only when they carry proof of a real login, which keeps
/// agent-shaped state that is not an account — notably Claude Science's data root — out of
/// the list.
enum AgentAccountDiscovery {

    // MARK: - Public Methods

    /// All accounts for a provider, the default account first.
    static func accounts(for provider: AgentKind) -> [AgentAccount] {
        switch provider {
        case .claude: return claudeAccounts()
        case .codex: return codexAccounts()
        case .shell: return []
        }
    }

    /// Looks up an account by handle, falling back to the provider's default.
    static func account(for provider: AgentKind, handle: String?) -> AgentAccount? {
        let available = accounts(for: provider)

        guard let handle else {
            return available.first { $0.isDefault } ?? available.first
        }

        if let match = available.first(where: { $0.handle == handle }) {
            return match
        }

        SkalmanLogger.agent.warning(
            "Account \(handle, privacy: .public) not found for \(provider.rawValue, privacy: .public); using default"
        )
        return available.first { $0.isDefault } ?? available.first
    }

    // MARK: - Claude

    /// The standard `~/.claude` directory plus any `~/.claude-*` directory holding a config
    /// file, excluding Claude Science data roots.
    private static func claudeAccounts() -> [AgentAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let aliases = ShellAliasReader.accountAliasesByConfigPath()
        var accounts: [AgentAccount] = []

        let defaultDirectory = home.appendingPathComponent(AgentAccountDefaults.claudeDefaultDirectory)
        if isDirectory(defaultDirectory) {
            accounts.append(makeAccount(
                provider: .claude,
                handle: AgentAccountDefaults.defaultHandle,
                directory: defaultDirectory,
                aliases: aliases
            ))
        }

        for directory in alternateDirectories(prefix: AgentAccountDefaults.claudeDirectoryPrefix) {
            guard !isClaudeScienceDataDirectory(directory) else { continue }
            guard AgentAccountDefaults.claudeConfigMarkers.contains(where: {
                isFile(directory.appendingPathComponent($0))
            }) else { continue }

            accounts.append(makeAccount(
                provider: .claude,
                handle: handle(for: directory),
                directory: directory,
                aliases: aliases
            ))
        }

        return accounts
    }

    /// Whether a directory is Claude Science's data root rather than a Claude Code login.
    ///
    /// The reserved name matches outright. A custom root must show every structural marker,
    /// so an ordinary config directory is never excluded merely for holding common files.
    static func isClaudeScienceDataDirectory(_ directory: URL) -> Bool {
        guard isDirectory(directory) else { return false }

        if directory.lastPathComponent == AgentAccountDefaults.claudeScienceDirectory {
            return true
        }

        guard isFile(directory.appendingPathComponent(AgentAccountDefaults.claudeScienceFileMarker)) else {
            return false
        }

        return AgentAccountDefaults.claudeScienceDirectoryMarkers.allSatisfy {
            isDirectory(directory.appendingPathComponent($0))
        }
    }

    // MARK: - Codex

    /// The Codex home from the environment (or `~/.codex`) plus any `~/.codex-*` directory,
    /// admitting only those holding a completed login.
    private static func codexAccounts() -> [AgentAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let aliases = ShellAliasReader.accountAliasesByConfigPath()
        var accounts: [AgentAccount] = []
        var seen = Set<String>()

        func admit(handle: String, directory: URL) {
            let path = directory.standardizedFileURL.path
            guard !seen.contains(path),
                  isFile(directory.appendingPathComponent(AgentAccountDefaults.codexAuthMarker))
            else { return }

            seen.insert(path)
            accounts.append(makeAccount(
                provider: .codex,
                handle: handle,
                directory: directory,
                aliases: aliases
            ))
        }

        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            admit(
                handle: AgentAccountDefaults.defaultHandle,
                directory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            )
        } else {
            admit(
                handle: AgentAccountDefaults.defaultHandle,
                directory: home.appendingPathComponent(AgentAccountDefaults.codexDefaultDirectory)
            )
        }

        for directory in alternateDirectories(prefix: AgentAccountDefaults.codexDirectoryPrefix) {
            admit(handle: handle(for: directory), directory: directory)
        }

        return accounts
    }

    // MARK: - Private Methods

    /// Home-directory entries matching a prefix, in a stable order.
    private static func alternateDirectories(prefix: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .filter { isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func makeAccount(
        provider: AgentKind,
        handle: String,
        directory: URL,
        aliases: [String: String]
    ) -> AgentAccount {
        let path = directory.standardizedFileURL.path
        let isDefault = handle == AgentAccountDefaults.defaultHandle
        let accountID = AgentAccount.identifier(provider: provider, handle: handle)
        let preferences = AccountPreferencesStore.shared

        // Naming precedence: an explicit override, then the user's own shell alias, then
        // the directory-derived handle.
        let displayName = preferences.displayNameOverride(for: accountID)
            ?? aliases[path]
            ?? (isDefault ? AgentAccountDefaults.defaultDisplayName : handle)

        return AgentAccount(
            provider: provider,
            handle: handle,
            configPath: path,
            displayName: displayName,
            emoji: preferences.emoji(for: accountID)
        )
    }

    /// The directory name minus its leading dot, e.g. `.claude-dblock` becomes `claude-dblock`.
    private static func handle(for directory: URL) -> String {
        String(directory.lastPathComponent.dropFirst())
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
