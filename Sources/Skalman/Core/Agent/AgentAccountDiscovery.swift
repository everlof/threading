import Foundation
import os

/// Short-lived discovery results, separated from presentation preferences so editing an
/// account name or emoji is reflected immediately without forcing another filesystem scan.
final class AgentAccountDiscoveryCache {

    private struct Entry {
        let accounts: [AgentAccount]
        let expiresAt: Date
    }

    private let lifetime: TimeInterval
    private let entries = OSAllocatedUnfairLock(initialState: [AgentKind: Entry]())

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func accounts(
        for provider: AgentKind,
        at now: Date = Date(),
        discover: () -> [AgentAccount]
    ) -> [AgentAccount] {
        if let cached = entries.withLock({ $0[provider] }), cached.expiresAt > now {
            return cached.accounts
        }

        // Discovery performs disk I/O, so do it outside the lock. Two callers can race into
        // the first scan, but either complete result is valid and later reads are lock-cheap.
        let discovered = discover()
        return entries.withLock { entries in
            if let cached = entries[provider], cached.expiresAt > now {
                return cached.accounts
            }

            entries[provider] = Entry(
                accounts: discovered,
                expiresAt: now.addingTimeInterval(lifetime)
            )
            return discovered
        }
    }

    func invalidate() {
        entries.withLock { $0.removeAll() }
    }
}

/// Discovers the agent accounts configured on this machine.
///
/// Accounts are found by scanning for config directories rather than by parsing shell
/// aliases, so they are found whether or not the user has an alias for them. Aliases are
/// consulted only to label an account with the name the user already calls it by.
///
/// Directories are admitted only when they carry proof of a real login, which keeps
/// agent-shaped state that is not an account — notably Claude Science's data root — out of
/// the list.
@MainActor
enum AgentAccountDiscovery {

    private static let cache = AgentAccountDiscoveryCache(
        lifetime: AgentAccountDiscoveryDefaults.cacheLifetime
    )

    // MARK: - Public Methods

    /// All accounts for a provider, the default account first.
    static func accounts(for provider: AgentKind) -> [AgentAccount] {
        let discovered = cache.accounts(for: provider) {
            switch provider {
            case .claude: return claudeAccounts()
            case .codex: return codexAccounts()
            }
        }

        return discovered.map(applyingPreferences)
    }

    /// Looks up an account by handle, falling back to the provider's default.
    static func account(for provider: AgentKind, handle: AccountHandle) -> AgentAccount? {
        let available = accounts(for: provider)

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
                handle: .standard,
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

        func admit(handle: AccountHandle, directory: URL) {
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
                handle: .standard,
                directory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            )
        } else {
            admit(
                handle: .standard,
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
        handle: AccountHandle,
        directory: URL,
        aliases: [String: String]
    ) -> AgentAccount {
        let path = directory.standardizedFileURL.path
        let isDefault = handle.isStandard
        // The cached value contains only discovery-derived presentation. Explicit user
        // preferences are layered onto it after every cache read.
        let displayName = aliases[path]
            ?? (isDefault ? AgentAccountDefaults.defaultDisplayName : handle.name)

        return AgentAccount(
            provider: provider,
            handle: handle,
            configPath: path,
            displayName: displayName
        )
    }

    private static func applyingPreferences(to account: AgentAccount) -> AgentAccount {
        let preferences = AccountPreferencesStore.shared
        return AgentAccount(
            provider: account.provider,
            handle: account.handle,
            configPath: account.configPath,
            displayName: preferences.displayNameOverride(for: account.id) ?? account.displayName,
            emoji: preferences.emoji(for: account.id)
        )
    }

    /// The directory name minus its leading dot, e.g. `.claude-dblock` becomes `claude-dblock`.
    private static func handle(for directory: URL) -> AccountHandle {
        .named(String(directory.lastPathComponent.dropFirst()))
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

enum AgentAccountDiscoveryDefaults {
    static let cacheLifetime: TimeInterval = 7
}
