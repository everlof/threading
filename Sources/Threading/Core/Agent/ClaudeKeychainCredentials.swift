import CryptoKit
import Foundation
import Security

// MARK: - Claude Keychain Credentials

/// Reads the OAuth token the Claude CLI keeps in the login keychain, so live usage can be
/// fetched for accounts that have no `.credentials.json` on disk — which is every macOS login.
///
/// **The item layout was probed, not assumed** (2026-07-31, attributes-only query). The CLI
/// names its item per config directory: the default login owns the bare service
/// `Claude Code-credentials`, and an alternate started with `CLAUDE_CONFIG_DIR` owns
/// `Claude Code-credentials-<prefix>`, where the prefix is the first eight hex characters of
/// the SHA-256 of the canonical config path — the same canonicalisation `ClaudeUsageCache`
/// already reproduces for Claudex's profile ids. That recipe was verified byte-for-byte against
/// the three real logins on the machine this was written on; a login that never happened
/// (`~/.claude-science`) correctly has no item. So a token read here is *attributable*: it
/// belongs to exactly the account whose config path named the service.
///
/// **A background read can never put a prompt on screen.** Reads on behalf of the usage
/// fetcher run with keychain user interaction disabled, which was verified to fail closed
/// (`errSecAuthFailed`) rather than prompt when the item's ACL does not admit this app. The
/// one interactive read — the macOS prompt where the user chooses "Always Allow" — happens
/// only in `requestAccess`, which only the Privacy page's own toggle calls. The prompt is a
/// direct consequence of an action the user just took, never a surprise from a poll. This is
/// also what keeps development builds sane: a rebuilt binary that no longer matches the ACL
/// falls back to the local caches silently instead of prompting on every refresh tick.
///
/// **The token is treated as radioactive.** It lives in memory only (keyed by config path,
/// dropped on expiry or on a 401), is never written to disk, never logged, and never carried
/// anywhere but the `Authorization` header of the usage request that
/// `ClaudeUsageFetcher` already sends for on-disk tokens. Threading never refreshes it —
/// the CLI owns the login, and rotates the item in place (the probe found the default item
/// modified the same morning), which is why a 401 invalidates the cache and the next cycle
/// re-reads instead of concluding the login is gone.
enum ClaudeKeychainCredentials {

    // MARK: - Types

    /// A usable reading of one account's keychain item.
    struct Token: Equatable {
        let accessToken: String
        let expiresAt: Date?
        /// The subscription readable off the payload, already display-cased ("Max").
        let plan: String?
    }

    /// What the Privacy page can honestly say about one account, learned without prompting.
    enum Availability: Equatable {
        /// The item exists and its ACL admits Threading — reads are silent from here on.
        case granted
        /// The item exists but reading it would prompt; the toggle's grant flow is the answer.
        case needsGrant
        /// The CLI keeps no login in the keychain for this account.
        case missing
    }

    // MARK: - Properties

    /// Tokens already read, keyed by config path. Guarded by `cacheLock`: the fetcher asks from
    /// a detached task while the Privacy page asks from the main actor.
    private static var cache: [String: Token] = [:]
    private static let cacheLock = NSLock()

    /// All keychain traffic is serialised here because the no-prompt guarantee rests on a
    /// process-global switch (`SecKeychainSetUserInteractionAllowed`); two concurrent reads
    /// toggling it independently could re-enable interaction under the other's feet.
    private static let keychainQueue = DispatchQueue(label: "codes.threading.claude-keychain")

    // MARK: - Public Methods

    /// A token for the usage API, or nil — silently — when the setting is off duty for this
    /// account: no item, no grant yet, an unreadable payload, or a token past its expiry.
    /// Never prompts, whatever the answer.
    static func token(forConfigPath configPath: String) -> Token? {
        guard !isRunningInTests else { return nil }

        if let cached = cachedToken(forConfigPath: configPath) { return cached }

        let (status, data) = copyItemData(
            service: serviceName(forConfigPath: configPath),
            allowingPrompt: false
        )
        guard status == errSecSuccess, let data, let token = parse(data),
              isUsable(token, at: Date())
        else { return nil }

        cacheLock.lock()
        cache[configPath] = token
        cacheLock.unlock()
        return token
    }

    /// The interactive read behind the Privacy page's toggle: lets macOS raise its prompt so
    /// the user can grant Threading standing access ("Always Allow") to this account's item.
    /// Returns whether a usable token came back. Call off the main thread — the read blocks
    /// for as long as the prompt is up.
    static func requestAccess(forConfigPath configPath: String) -> Bool {
        guard !isRunningInTests else { return false }

        let (status, data) = copyItemData(
            service: serviceName(forConfigPath: configPath),
            allowingPrompt: true
        )
        guard status == errSecSuccess, let data, let token = parse(data) else { return false }

        cacheLock.lock()
        cache[configPath] = token
        cacheLock.unlock()
        return true
    }

    /// What the Privacy page's status line reports for one account. Never prompts: a granted
    /// answer comes from the same silent read the fetcher uses (and warms its cache), and a
    /// denied one is the fail-closed error told apart from a missing item by an
    /// attributes-only query, which item ACLs do not gate.
    static func availability(forConfigPath configPath: String) -> Availability {
        guard !isRunningInTests else { return .missing }

        let service = serviceName(forConfigPath: configPath)
        let (status, data) = copyItemData(service: service, allowingPrompt: false)

        if status == errSecSuccess, let data, let token = parse(data) {
            cacheLock.lock()
            cache[configPath] = token
            cacheLock.unlock()
            return .granted
        }
        if status == errSecItemNotFound { return .missing }

        return itemExists(service: service) ? .needsGrant : .missing
    }

    /// Drops a cached token the API just refused — the CLI rotates the item in place, so the
    /// next read may find a fresh one where the stale one was.
    static func invalidate(configPath: String) {
        cacheLock.lock()
        cache.removeValue(forKey: configPath)
        cacheLock.unlock()
    }

    /// For tests.
    static func forgetAll() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Internal Methods (pure, testable)

    /// The CLI's own item-naming recipe: the bare service for the default login, and a suffix
    /// of the first `serviceSuffixLength` hex characters of the SHA-256 of the canonical config
    /// path for an alternate. Canonicalisation must match the CLI's byte-for-byte — it is the
    /// same standardise-and-resolve-symlinks rule `ClaudeUsageCache.profileID` reproduces.
    static func serviceName(forConfigPath configPath: String) -> String {
        let canonical = URL(fileURLWithPath: configPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(KeychainCredentialsDefaults.defaultConfigDirectoryName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        guard canonical != defaultPath else { return KeychainCredentialsDefaults.service }

        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(KeychainCredentialsDefaults.serviceSuffixLength)

        return "\(KeychainCredentialsDefaults.service)-\(digest)"
    }

    /// The payload is the same JSON the CLI writes to `.credentials.json` on Linux-style
    /// setups — `{"claudeAiOauth": {...}}` — but the wrapper is tolerated rather than assumed:
    /// a bare `{"accessToken": ...}` object parses too, so a CLI release that drops the
    /// envelope degrades to a working read instead of a silent nil.
    static func parse(_ data: Data) -> Token? {
        guard data.count <= KeychainCredentialsDefaults.maxItemBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let oauth = json[KeychainCredentialsDefaults.oauthKey] as? [String: Any] ?? json
        guard let accessToken = oauth[KeychainCredentialsDefaults.accessTokenKey] as? String,
              !accessToken.isEmpty
        else { return nil }

        // Epoch milliseconds, like the credentials file.
        let expiresAt = (oauth[KeychainCredentialsDefaults.expiresAtKey] as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1000) }

        let plan = (oauth[KeychainCredentialsDefaults.subscriptionKey] as? String)?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        return Token(accessToken: accessToken, expiresAt: expiresAt, plan: plan)
    }

    /// A token about to expire is already expired, so the API call is not wasted — the same
    /// skew rule the credentials file gets.
    static func isUsable(_ token: Token, at now: Date) -> Bool {
        guard let expiresAt = token.expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(KeychainCredentialsDefaults.expirySkew)
    }

    // MARK: - Private Methods

    private static func cachedToken(forConfigPath configPath: String) -> Token? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let token = cache[configPath] else { return nil }
        guard isUsable(token, at: Date()) else {
            cache.removeValue(forKey: configPath)
            return nil
        }
        return token
    }

    /// The one place secret data is requested. With `allowingPrompt` false the read runs
    /// under keychain user interaction disabled — the deprecated `SecKeychain` switch, kept
    /// deliberately: it is the mechanism *verified* to hold the prompt back for the CLI's
    /// file-based item (`kSecUseAuthenticationUI` documents the same promise but was not
    /// provable without risking a live prompt on the machine doing the proving). The prior
    /// value is restored so an interactive flow elsewhere is never left switched off.
    private static func copyItemData(
        service: String,
        allowingPrompt: Bool
    ) -> (OSStatus, Data?) {
        keychainQueue.sync {
            var restore: DarwinBoolean = true
            if !allowingPrompt {
                SecKeychainGetUserInteractionAllowed(&restore)
                SecKeychainSetUserInteractionAllowed(false)
            }
            defer {
                if !allowingPrompt {
                    SecKeychainSetUserInteractionAllowed(restore.boolValue)
                }
            }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }

    /// Whether the item exists at all — attributes only, which no ACL gates, so this cannot
    /// prompt and cannot see a secret.
    private static func itemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// The keychain is the developer's own; a hosted test must never read it, however
    /// harmlessly. Same detection as `AppDelegate`'s startup skip.
    private static var isRunningInTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

// MARK: - Defaults

enum KeychainCredentialsDefaults {
    /// The CLI's service name for the default login; alternates append `-<hash prefix>`.
    static let service = "Claude Code-credentials"
    static let defaultConfigDirectoryName = ".claude"
    static let serviceSuffixLength = 8

    static let oauthKey = "claudeAiOauth"
    static let accessTokenKey = "accessToken"
    static let expiresAtKey = "expiresAt"
    static let subscriptionKey = "subscriptionType"

    /// Matches `ClaudeUsageDefaults.expirySkew` — one rule for both token sources.
    static let expirySkew: TimeInterval = 30

    /// A credentials payload is a few hundred bytes; anything huge is not one.
    static let maxItemBytes = 64 * 1024
}
