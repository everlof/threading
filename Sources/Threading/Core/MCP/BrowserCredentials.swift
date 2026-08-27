import Foundation
import Security

/// Where a sign-in value comes from when an agent asks the browser to fill one.
///
/// The three cases are not three implementations of one idea. `.systemAutoFill` keeps the promise
/// this app shipped with — Threading never sees a password, and a human completes every sign-in —
/// while the other two deliberately relax it for **test accounts**. The setting is what the user
/// relaxes it with, so it is named on the Tools page in those words.
///
/// The choice is global rather than per origin. That is a scope decision, not a constraint: the
/// live origin is derived either way, so per-origin selection is perfectly implementable and was
/// rejected only because a person keeping throwaway logins has one habit, not one per host.
enum BrowserCredentialProvider: String, CaseIterable, Sendable {

    /// WebKit and macOS AutoFill, Apple Passwords, or a password manager's own universal fill —
    /// reached by handing the user the focused field. Threading reads no vault and holds no value.
    case systemAutoFill = "system"

    /// Threading's own test-account vault. Deliberately weaker than a real password manager, and
    /// named so that what belongs in it is obvious.
    case threadingVault = "vault"

    /// The 1Password CLI against a user-supplied `op://` item reference.
    ///
    /// Worth being honest about in one place: `op read` is exactly as available from the agent's
    /// own shell as it is from Threading, so this provider buys convenience and a
    /// no-plaintext-at-rest story — **not a new boundary**. The fence is 1Password's own
    /// per-process authorization, and the login shell that finds `op` also puts the user's rc
    /// files on the value path.
    case onePassword = "onePassword"

    /// The behaviour the app shipped with, and the one that promises the most.
    static let fallback: BrowserCredentialProvider = .systemAutoFill
}

// MARK: - Preference

/// The user's provider choice.
///
/// Through `PreferenceStore` rather than `.standard` because it records a *choice*: a hosted test
/// that set it on `.standard` would change which provider the developer's own app launched with.
///
/// **A known limit, written down rather than claimed away.** This is `UserDefaults`, so an agent
/// with shell access can `defaults write` it — as it can the persistent origin grants in
/// `BrowserAccessStore`. Neither hole is new, and neither yields a password: the vault itself is
/// out of the shell's reach (see `BrowserCredentialStore`), and an entry has to exist before a
/// provider choice means anything. It matters because it sets the bar for anything built on top:
/// a future per-origin "don't confirm submissions here" must **not** live here, or one
/// `defaults write` plus one prompt injection becomes fill-and-submit with nobody watching.
enum BrowserCredentialPreference {

    private static let key = "browser.credentialProvider"

    static var provider: BrowserCredentialProvider {
        get {
            PreferenceStore.shared.string(forKey: key)
                .flatMap(BrowserCredentialProvider.init(rawValue:))
                ?? .fallback
        }
        set { PreferenceStore.shared.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - Entries

/// One stored credential, without its secret.
///
/// Listing the vault must never read a password, so the type the Settings list is built from
/// cannot carry one. `BrowserCredentialSecret` is a separate value fetched only at the moment of
/// a fill.
struct BrowserCredentialIdentity: Hashable, Sendable {

    /// `BrowserOrigin.key` — scheme, host and port. Never an eTLD+1 and never a suffix.
    let originKey: String

    /// The user's own name for the account: "admin", "read-only reviewer". Shown to the agent to
    /// disambiguate two accounts on one origin, so it is not a secret — but it is user-authored,
    /// which is why nothing else about the entry is.
    let label: String

    /// Keychain accounts are one string, so the two fields share one.
    ///
    /// Split on the **first** separator: an origin key cannot contain one (it is
    /// `scheme://host:port`), while a label is free text the user typed and may.
    var account: String { "\(originKey)|\(label)" }

    init(originKey: String, label: String) {
        self.originKey = originKey
        self.label = label
    }

    init?(account: String) {
        guard let separator = account.firstIndex(of: "|") else { return nil }
        originKey = String(account[account.startIndex..<separator])
        label = String(account[account.index(after: separator)...])
        guard !originKey.isEmpty, !label.isEmpty else { return nil }
    }
}

/// The values themselves, alive only between a Keychain read and a single fill.
struct BrowserCredentialSecret: Sendable {
    /// Absent for a password-only entry — some staging sign-ins take one field.
    let username: String?
    let password: String
}

// MARK: - Store

/// The test-account vault.
///
/// Deliberately **not** an extension of `KeychainManager`. That type stores the user's API keys in
/// the file-based login keychain, and moving those items to the data-protection keychain to share
/// one implementation would orphan every key already saved. Two stores with different guarantees
/// is the honest shape.
///
/// Three properties are load-bearing:
///
/// **`kSecUseDataProtectionKeychain`, when the build can have it.** In the login keychain the
/// agent's own shell — this app launches agents with an unrestricted terminal — can create items
/// with `security add-generic-password` and remove them with `security delete-generic-password`,
/// neither of which prompts; the data-protection keychain is not reachable from that tool at all.
/// But it needs an entitlement an ad-hoc-signed build does not have, so which keychain is in use
/// is *probed*, not assumed, and `isShellReachable` reports the answer rather than letting the
/// stronger claim stand for every build. Reads prompt either way, so an agent cannot learn a
/// stored password in either keychain — the difference is whether it can plant or delete one.
///
/// **No `SecAccessControl`.** There is no biometric gate, on purpose: unattended filling is the
/// entire point, and a vault that asks for Touch ID per fill is the takeover flow with extra
/// steps. This is the "less secure" the feature is named for, and it is a stated trade rather
/// than an omission — which is also why the UI never calls this a password manager.
///
/// **Listing never reads data.** `identities()` asks for attributes and not `kSecReturnData`, so
/// drawing the Settings list touches no secret. An index kept alongside in `UserDefaults` would
/// have been cheaper and could drift out of step with the keychain; the keychain is the index.
struct BrowserCredentialStore: Sendable {

    // MARK: - Service

    static let defaultService = "codes.threading.browser.credential"

    /// A scratch service under a hosted test bundle, for the reason `PreferenceStore` gives one
    /// store over: `ThreadingTests` runs inside the shipping app, so a round-trip test against the
    /// real service name would leave real items — and possibly a prompt — on the developer's own
    /// machine.
    static let hostedTestService = "codes.threading.browser.credential.hosted-tests"

    static var resolvedService: String {
        NSClassFromString("XCTestCase") != nil ? hostedTestService : defaultService
    }

    /// Whether this process redirects, so a test can assert the redirect rather than the
    /// developer's luck.
    static var isRedirected: Bool { resolvedService != defaultService }

    // MARK: - Which Keychain

    /// Whether the data-protection keychain is usable in this build, **probed rather than
    /// assumed**.
    ///
    /// It needs a `keychain-access-groups` entitlement backed by a real team identity. A Debug
    /// build is ad-hoc signed, so every write returns `errSecMissingEntitlement` (-34018) — which
    /// is how this was found: the whole vault worked in principle and stored nothing in practice.
    ///
    /// The fallback is the file-based login keychain, and it is a **weaker vault, not the same
    /// one**: `security add-generic-password` and `security delete-generic-password` can create
    /// and remove items there without a prompt, and this app hands agents an unrestricted shell.
    /// Reads still prompt, so an agent cannot *learn* a stored password either way — but it can
    /// plant or delete one. `isShellReachable` exists so that difference is stated in the UI and
    /// the docs instead of being a promise only some builds keep.
    static var usesDataProtectionKeychain: Bool {
        KeychainStoragePolicy.usesDataProtectionKeychain
    }

    /// Whether the agent's own shell could plant or delete an entry. True on a build without the
    /// entitlement — see above.
    static var isShellReachable: Bool { KeychainStoragePolicy.isShellReachable }

    private let service: String
    private let dataProtection: Bool

    init(service: String? = nil, dataProtection: Bool? = nil) {
        self.service = service ?? Self.resolvedService
        self.dataProtection = dataProtection ?? Self.usesDataProtectionKeychain
    }

    /// The class, service and keychain every query in this type shares.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
    }

    // MARK: - Errors

    enum StoreError: LocalizedError {
        case writeFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case malformedEntry

        var errorDescription: String? {
            switch self {
            case .writeFailed(let status):
                return L10n.format("Could not save the test credential (%lld).", Int64(status))
            case .readFailed(let status):
                return L10n.format("Could not read the test credential (%lld).", Int64(status))
            case .deleteFailed(let status):
                return L10n.format("Could not delete the test credential (%lld).", Int64(status))
            case .malformedEntry:
                return L10n.string("The stored test credential could not be read.")
            }
        }
    }

    /// The stored shape. A single item per entry, so a half-written credential is not a state the
    /// store can be in.
    private struct StoredSecret: Codable {
        let username: String?
        let password: String
    }

    // MARK: - Reading

    /// Every entry, without touching a secret.
    func identities() -> [BrowserCredentialIdentity] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap(BrowserCredentialIdentity.init(account:))
            .sorted { ($0.originKey, $0.label) < ($1.originKey, $1.label) }
    }

    /// The entries for one exact origin.
    ///
    /// Exact-match by `BrowserOrigin.key` and nothing looser. A host-suffix or eTLD+1 comparison
    /// here would undo the parse hardening `BrowserOrigin` exists to provide — `127.evil.com` is
    /// a registrable domain, and a credential for the loopback must not be reachable from it.
    func identities(for origin: BrowserOrigin) -> [BrowserCredentialIdentity] {
        identities().filter { $0.originKey == origin.key }
    }

    func hasIdentities(for origin: BrowserOrigin) -> Bool {
        !identities(for: origin).isEmpty
    }

    /// The one call that reads a password, made once per fill.
    func secret(for identity: BrowserCredentialIdentity) throws -> BrowserCredentialSecret {
        var query = baseQuery
        query[kSecAttrAccount as String] = identity.account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw StoreError.readFailed(status) }
        guard let data = result as? Data,
              let stored = try? JSONDecoder().decode(StoredSecret.self, from: data) else {
            throw StoreError.malformedEntry
        }
        return BrowserCredentialSecret(username: stored.username, password: stored.password)
    }

    // MARK: - Writing

    /// Saves one entry, or replaces the value of the one already there.
    ///
    /// **Update first, add only when there is nothing to update.** This was delete-then-add, which
    /// is the shape that loses data: correcting the password on a working credential removed it and
    /// then tried to add the replacement, so any failure on the add — a locked keychain, a denied
    /// entitlement — left the account with no credential at all, having had a perfectly good one a
    /// moment earlier. `SecItemUpdate` changes the value in place or reports that the item is
    /// absent, and neither answer can destroy what was there.
    ///
    /// One item per account either way: the account string is the identity, so an update cannot
    /// leave two rows answering for one entry.
    func save(
        username: String?,
        password: String,
        for identity: BrowserCredentialIdentity
    ) throws {
        let stored = StoredSecret(
            username: username?.isEmpty == true ? nil : username,
            password: password
        )
        guard let data = try? JSONEncoder().encode(stored) else {
            throw StoreError.malformedEntry
        }

        var query = baseQuery
        query[kSecAttrAccount as String] = identity.account

        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw StoreError.writeFailed(updated) }

        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData as String] = data
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw StoreError.writeFailed(added) }
    }

    func delete(_ identity: BrowserCredentialIdentity) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = identity.account

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.deleteFailed(status)
        }
    }

    /// Everything, for Advanced ▸ Reset Everything.
    ///
    /// Needed as its own call because keychain items are not under Application Support: the reset
    /// moves the app's directories aside, and without this the vault would survive a reset that
    /// told the user it had removed the app's state.
    func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.deleteFailed(status)
        }
    }
}

// MARK: - Submission Exemptions

/// Origins the user has said may submit a form without being asked again — **for as long as this
/// app run lasts, and no longer**.
///
/// Filling a sign-in and then still asking before the submit gets you about half the value the
/// test-credential vault was built for, so this is the other half. It is also the piece that most
/// deserved to be built last, because it relaxes a different guarantee than the fill does.
///
/// **Why this is process memory and not a preference.** The provider choice and
/// `BrowserAccessStore`'s persistent grants live in `UserDefaults`, which an agent with shell
/// access can rewrite with `defaults write` — a limit that is tolerable for those because neither
/// yields a password. It is *not* tolerable here: a persisted exemption plus a stored credential
/// plus one prompt injection is fill-and-submit with nobody watching, which is unattended account
/// takeover of whatever that origin is. A store the shell cannot reach at all is the only version
/// of this feature worth having, and a process-lifetime one is reachable by nothing but this app.
/// Quitting Threading is therefore a complete revocation, which is a property worth keeping even
/// when someone later asks for it to be remembered.
///
/// **Only origins that already hold a credential may be exempted.** The exemption is an extension
/// of a decision the user already made in Settings for that exact origin; offering it anywhere
/// else would turn one prompt into a general-purpose "stop asking me" for the whole browser.
@MainActor
final class BrowserSubmissionExemptions {

    static let shared = BrowserSubmissionExemptions()

    private var origins: Set<String> = []

    /// Whether this origin may submit without asking. Re-checked at every submission rather than
    /// captured when the exemption was granted, so revoking it in Settings takes effect on the
    /// next submit rather than the next launch.
    func isExempt(_ origin: BrowserOrigin) -> Bool {
        origins.contains(origin.key)
    }

    func exempt(_ origin: BrowserOrigin) {
        origins.insert(origin.key)
    }

    func revoke(key: String) {
        origins.remove(key)
    }

    func revokeAll() {
        origins.removeAll()
    }

    var exemptOriginKeys: [String] {
        origins.sorted()
    }
}
