import Foundation
import Security

// MARK: - Agent Account Token

/// A long-lived sign-in token for one login: what `claude setup-token` prints, which lasts a
/// year where the browser sign-in has to be repeated about monthly.
///
/// This is the one credential Threading keeps. The CLI never stores a setup token — it prints it
/// and leaves keeping it to whoever asked — so a login that should not need a monthly sign-in has
/// to have its token held by someone. It lives in Threading's own Keychain item, reaches only the
/// login it was saved for, and only as an environment entry of that login's processes. It is
/// never a command word, a log line or a preference. See
/// [`accounts.md`](../../../../docs/architecture/accounts.md).
struct AgentAccountToken: Equatable, Sendable {
    let value: String
    let savedAt: Date

    /// `setup-token` states a one-year lifetime. The token is opaque, so expiry is counted from
    /// when it was saved: one pasted a week after it was minted expires a week sooner than this
    /// says, which is why the warning starts well ahead of the date.
    static let lifetime: TimeInterval = 365 * 24 * 60 * 60
    static let expiryWarningLead: TimeInterval = 21 * 24 * 60 * 60

    var expiresAt: Date { savedAt.addingTimeInterval(Self.lifetime) }

    func isNearExpiry(at now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-Self.expiryWarningLead)
    }
}

extension AgentAccountToken: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    // A token interpolated into a log line or dumped by a test failure says when it was saved
    // and nothing else.
    var description: String { "AgentAccountToken(savedAt: \(savedAt), value: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["savedAt": savedAt]) }
}

// MARK: - Token Format

/// What a pasted token has to look like before it is kept.
///
/// Only the shape is checked here. `claude auth status` accepts any string as a token, so no
/// local command can say whether one actually works; the first conversation on the login does.
enum AgentAccountTokenFormat {
    enum Problem: Error, Equatable, Sendable {
        case empty
        /// Something else was pasted — an API key, a sign-in link, an authorization code.
        case notThisRuntimesToken
        case malformed
    }

    static let minimumBodyLength = 32
    static let maximumLength = 512

    /// Whitespace anywhere is dropped first: a token copied from a terminal that wrapped it
    /// arrives with a newline or a space at each wrap point, and no token contains whitespace.
    static func normalized(
        _ raw: String,
        for spec: AgentLongLivedTokenSpec
    ) -> Result<String, Problem> {
        let token = String(raw.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
        guard !token.isEmpty else { return .failure(.empty) }
        guard token.hasPrefix(spec.prefix) else { return .failure(.notThisRuntimesToken) }
        let body = token.dropFirst(spec.prefix.count)
        guard token.count <= maximumLength,
              body.count >= minimumBodyLength,
              body.unicodeScalars.allSatisfy(isTokenScalar) else {
            return .failure(.malformed)
        }
        return .success(token)
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }
}

// MARK: - Keychain Store

/// Threading's Keychain item for long-lived tokens, one entry per login.
///
/// The entry's secret is a small versioned JSON document carrying the token and when it was
/// saved, so the date travels with the secret and cannot drift from it in a second store.
/// Access is serialized by `AgentAccountTokenVault`; nothing else calls this.
final class AgentAccountTokenStore: @unchecked Sendable {

    enum Defaults {
        static let service = "codes.threading.agent-account-token.v1"
        static let payloadVersion = 1
        static let maximumPayloadBytes = 4 * 1_024
    }

    private struct Payload: Codable {
        let version: Int
        let token: String
        let savedAt: Date
    }

    private let keychain: KeychainItemAccessing
    private let service: String
    private let dataProtection: () -> Bool

    init(
        keychain: KeychainItemAccessing = SystemKeychainItemAccess(),
        service: String = KeychainStoragePolicy.remoteService(Defaults.service),
        // A closure because the policy probes the Keychain the first time it is asked, and the
        // store may be created on the main actor.
        dataProtection: @escaping () -> Bool = { KeychainStoragePolicy.usesDataProtectionKeychain }
    ) {
        self.keychain = keychain
        self.service = service
        self.dataProtection = dataProtection
    }

    func token(for id: AccountID) -> AgentAccountToken? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = keychain.data(matching: query)
        guard result.status == errSecSuccess,
              let data = result.data,
              data.count <= Defaults.maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Defaults.payloadVersion,
              !payload.token.isEmpty else { return nil }
        return AgentAccountToken(value: payload.token, savedAt: payload.savedAt)
    }

    func save(_ token: AgentAccountToken, for id: AccountID) -> Bool {
        let payload = Payload(
            version: Defaults.payloadVersion,
            token: token.value,
            savedAt: token.savedAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let query = baseQuery(for: id)
        let updated = keychain.update(query, attributes: [kSecValueData as String: data])
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Threading sign-in token (\(id.rawValue))"
        return keychain.add(item) == errSecSuccess
    }

    func remove(for id: AccountID) -> Bool {
        let status = keychain.delete(baseQuery(for: id))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every entry, for Reset Everything.
    func removeAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if dataProtection() { query[kSecUseDataProtectionKeychain as String] = true }
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func baseQuery(for id: AccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue
        ]
        if dataProtection() { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

// MARK: - Vault

/// The saved tokens, read from the Keychain once and held in memory, so that a launch — built
/// synchronously on the main actor — never waits on `securityd`.
///
/// `prepare` reads the logins it is given on a utility queue at startup and whenever Settings
/// shows the roster. A launch that somehow beats it reads its one entry inline: a single bounded
/// Keychain item, once per login per process, rather than launching on the wrong credential.
final class AgentAccountTokenVault: @unchecked Sendable {

    /// Both hosted tests and isolated UI scenarios use memory. A disposable Cocoa home does not
    /// isolate Keychain, so the separately launched UI app must use the same redirect too.
    static let shared = AgentAccountTokenVault(
        store: PreferenceStore.isRedirected
            ? AgentAccountTokenStore(keychain: InMemoryKeychainItemAccess(), dataProtection: { false })
            : AgentAccountTokenStore()
    )

    private let store: AgentAccountTokenStore
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "codes.threading.agent-account-token",
        qos: .utility
    )
    private let now: @Sendable () -> Date

    /// Logins whose entry has been read, present or not. A login missing from here has not been
    /// asked yet, which is different from having no token.
    private var read: [AccountID: AgentAccountToken?] = [:]

    init(store: AgentAccountTokenStore = AgentAccountTokenStore(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Reads these logins' entries off the calling thread. Logins already read are skipped.
    func prepare(_ ids: [AccountID], completion: (@Sendable () -> Void)? = nil) {
        let wanted = ids.filter { $0.provider.longLivedToken != nil }
        queue.async { [self] in
            for id in wanted where cachedEntry(for: id) == nil {
                let token = store.token(for: id)
                lock.withLock { if read[id] == nil { read[id] = .some(token) } }
            }
            completion?()
        }
    }

    /// The token saved for this login, or nil when it signs in through the browser.
    func token(for id: AccountID) -> AgentAccountToken? {
        guard id.provider.longLivedToken != nil else { return nil }
        if let entry = cachedEntry(for: id) { return entry }
        let token = store.token(for: id)
        lock.withLock { read[id] = .some(token) }
        return token
    }

    /// Answers from memory only, for a surface that must not touch the Keychain: nil when the
    /// login has not been read yet as well as when it has no token.
    func cachedToken(for id: AccountID) -> AgentAccountToken? {
        cachedEntry(for: id) ?? nil
    }

    /// Validates and keeps a pasted token for this login. The Keychain write happens off the
    /// caller; `completion` runs on the main actor with the outcome.
    func save(
        _ raw: String,
        for id: AccountID,
        completion: @escaping @MainActor @Sendable (Result<AgentAccountToken, SaveError>) -> Void
    ) {
        guard let spec = id.provider.longLivedToken else {
            Task { @MainActor in completion(.failure(.unsupported)) }
            return
        }
        let value: String
        switch AgentAccountTokenFormat.normalized(raw, for: spec) {
        case .success(let normalized): value = normalized
        case .failure(let problem):
            Task { @MainActor in completion(.failure(.format(problem))) }
            return
        }
        let token = AgentAccountToken(value: value, savedAt: now())
        queue.async { [self] in
            let saved = store.save(token, for: id)
            if saved { lock.withLock { read[id] = .some(token) } }
            Task { @MainActor in
                if saved { NotificationCenter.default.post(AgentAccountTokensDidChange()) }
                completion(saved ? .success(token) : .failure(.keychain))
            }
        }
    }

    /// Forgets this login's token, returning it to the browser sign-in.
    func remove(
        for id: AccountID,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            let removed = store.remove(for: id)
            if removed { lock.withLock { read[id] = .some(nil) } }
            Task { @MainActor in
                if removed { NotificationCenter.default.post(AgentAccountTokensDidChange()) }
                completion(removed)
            }
        }
    }

    /// Erases every entry and the memory of them, for Reset Everything.
    func removeAll() throws {
        try store.removeAll()
        lock.withLock { read.removeAll() }
    }

    enum SaveError: Error, Equatable {
        case unsupported
        case format(AgentAccountTokenFormat.Problem)
        case keychain
    }

    private func cachedEntry(for id: AccountID) -> AgentAccountToken?? {
        lock.withLock { read[id] }
    }
}

/// A login's long-lived token was saved or removed.
public struct AgentAccountTokensDidChange: AppEvent {
    public static let name = Notification.Name("agentAccountTokensDidChange")
}

// MARK: - In-Memory Keychain

/// A Keychain stand-in keyed by service and account, for the hosted-test vault and the unit tests.
final class InMemoryKeychainItemAccess: KeychainItemAccessing, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String?
    }

    private let lock = NSLock()
    private var items: [Key: Data] = [:]

    var itemCount: Int { lock.withLock { items.count } }

    func data(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = key(query)
            guard items[key] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            return errSecSuccess
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = key(attributes)
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let target = key(query)
            // A query without an account deletes every item of the service, as SecItemDelete does.
            let matching = items.keys.filter {
                $0.service == target.service && (target.account == nil || $0.account == target.account)
            }
            guard !matching.isEmpty else { return errSecItemNotFound }
            matching.forEach { items.removeValue(forKey: $0) }
            return errSecSuccess
        }
    }

    private func key(_ query: [String: Any]) -> Key {
        Key(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String
        )
    }
}
