import Foundation
import os

/// Short-lived discovery results, separated from presentation preferences so editing an
/// account name or emoji is reflected immediately without forcing another filesystem scan.
final class AgentAccountDiscoveryCache: @unchecked Sendable {

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

    /// The accounts a provider *offers*, the default account first.
    ///
    /// Switched-off logins are left out here rather than at each of the thirty call sites that
    /// list accounts, because the failure mode of the other arrangement is silent: one menu
    /// keeps offering the account the user turned off, and nothing says which menu was missed.
    /// The places that must see a disabled account — this pane, and any lookup for a session
    /// already on one — ask for `allAccounts` or go through `account(for:handle:)`.
    static func accounts(for provider: AgentKind) -> [AgentAccount] {
        allAccounts(for: provider).filter(\.isEnabled)
    }

    /// Every account discovered for a provider, switched off or not.
    static func allAccounts(for provider: AgentKind) -> [AgentAccount] {
        let discovered = cache.accounts(for: provider) {
            switch provider {
            case .claude: return claudeAccounts()
            case .codex: return codexAccounts()
            case .grok, .openCode, .cursor: return []
            }
        }

        return discovered.map(applyingPreferences)
    }

    /// Looks up an account by handle, falling back to the provider's default.
    ///
    /// Searches everything discovered: a session records the account it was started on, and a
    /// resume has to route back to it or the conversation id will not be found there. Switching
    /// a login off withdraws it from new work, not from the sessions already living on it.
    ///
    /// A runtime without account routing answers nil *quietly*. Nil was already the answer —
    /// nothing is discovered for one — but it arrived through the not-found warning below, and
    /// the sidebar looks an account up every time it reconfigures a row, which is on every tick
    /// of a working agent. So a Grok or OpenCode session filled the log with the absence of a
    /// feature, in the words Threading uses for a session whose real login has gone missing.
    static func account(for provider: AgentKind, handle: AccountHandle) -> AgentAccount? {
        guard provider.supportsAccounts else { return nil }

        let discovered = allAccounts(for: provider)

        if let match = discovered.first(where: { $0.handle == handle }) {
            return match
        }

        ThreadingLogger.agent.warning(
            "Account \(handle, privacy: .private(mask: .hash)) not found for \(provider.rawValue, privacy: .public); using default"
        )
        return preferredAccount(for: provider)
            ?? discovered.first { $0.isDefault }
            ?? discovered.first
    }

    /// The account a new session starts on when the user has not picked one: the standard login
    /// while it is switched on, else the first that is.
    ///
    /// Without this a disabled default is still what a fresh composer launches, since the
    /// composer's own starting point is the standard handle — the login the user just said to
    /// stop using.
    static func preferredAccount(for provider: AgentKind) -> AgentAccount? {
        preferred(among: allAccounts(for: provider))
    }

    /// The rule on its own, so it can be exercised without a home directory to scan.
    static func preferred(among discovered: [AgentAccount]) -> AgentAccount? {
        let offered = discovered.filter(\.isEnabled)
        return offered.first { $0.isDefault } ?? offered.first
    }

    /// The handle `preferredAccount` names, or the standard one when a provider offers nothing.
    static func preferredHandle(for provider: AgentKind) -> AccountHandle {
        preferredAccount(for: provider)?.handle ?? .standard
    }

    /// Drops the short filesystem cache after an in-app login has created or reverified a
    /// provider home. Preference edits do not need this because they are layered after reads.
    static func invalidate() {
        cache.invalidate()
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

        appendRegisteredAccounts(
            for: .claude,
            aliases: aliases,
            to: &accounts
        )

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

        appendRegisteredAccounts(
            for: .codex,
            aliases: aliases,
            to: &accounts
        )

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

    /// Merges locations verified through Threading's setup flow with marker-based legacy
    /// discovery. This is what keeps a Codex login visible when its CLI uses the OS keyring and
    /// therefore has no `auth.json` marker for a filesystem-only scan to find.
    private static func appendRegisteredAccounts(
        for provider: AgentKind,
        aliases: [String: String],
        to accounts: inout [AgentAccount]
    ) {
        var seen = Set(accounts.map { URL(fileURLWithPath: $0.configPath).standardizedFileURL.path })
        for record in AgentAccountLocationRegistry.shared.records(for: provider) {
            let directory = URL(fileURLWithPath: record.configPath).standardizedFileURL
            guard isDirectory(directory), seen.insert(directory.path).inserted else { continue }
            if provider == .claude, isClaudeScienceDataDirectory(directory) { continue }
            accounts.append(makeAccount(
                provider: provider,
                handle: record.handle,
                directory: directory,
                aliases: aliases
            ))
        }
    }

    private static func applyingPreferences(to account: AgentAccount) -> AgentAccount {
        let preferences = AccountPreferencesStore.shared
        return AgentAccount(
            provider: account.provider,
            handle: account.handle,
            configPath: account.configPath,
            displayName: preferences.displayNameOverride(for: account.id) ?? account.displayName,
            emoji: preferences.emoji(for: account.id),
            isEnabled: preferences.isEnabled(account.id)
        )
    }

    /// The directory name minus its leading dot, e.g. `.claude-nhartley` becomes `claude-nhartley`.
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
