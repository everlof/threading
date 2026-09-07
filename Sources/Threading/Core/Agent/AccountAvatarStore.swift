import AppKit
import CryptoKit

// MARK: - Account Avatar Store

/// Discovers and holds avatars for agent accounts, looked up from the account's own login
/// email: **Gravatar** first — the canonical email→avatar service, where `d=404` makes a
/// miss a clean 404 — then GitHub's user search, which matches only accounts whose
/// *public* profile email is this one. Coverage is honest rather than complete: most
/// emails resolve nowhere, and a miss simply leaves the existing emoji → badge →
/// brand-mark chain in place.
///
/// Unlike project icons, a person's avatar is exactly right here: an account *is* a
/// person's identity, and different logins carry different emails, so the avatar
/// distinguishes — the same reasoning that bans faces from project rows demands them
/// on accounts.
///
/// Emails come from what the CLIs already store — Claude's `.claude.json`
/// (`oauthAccount.emailAddress`) and the `email` claim of Codex's `id_token`, decoded
/// locally without the token's value ever being used or sent. Only a hash of the email
/// (Gravatar) or the email as a search term (GitHub) leaves the machine, and only while
/// the discovery setting is on.
enum AccountAvatarStore {

    // MARK: - Properties

    /// Composed, rounded avatars keyed by account id, for the sidebar's frequent configures.
    @MainActor private static let composedCache = NSCache<NSString, NSImage>()

    /// Accounts tried this run, hit or miss, so rows do not re-trigger lookups.
    @MainActor private static var attempted: Set<AccountID> = []

    /// Login addresses resolved this run, keyed by account id. The optional is stored
    /// rather than dropped, so an account with no readable email is answered from memory
    /// too instead of re-reading the file on every row configure.
    @MainActor private static var emailCache: [AccountID: String?] = [:]

    private static let queue = DispatchQueue(label: "codes.threading.account-avatars", qos: .utility)

    @MainActor
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(AccountAvatarDefaults.directoryName)
    }

    // MARK: - Public Methods

    /// The rounded avatar for an account, or nil while none is known.
    ///
    /// Cheap enough for row configure: memory cache, then disk. The first miss primes one
    /// background lookup; a hit lands on disk and refreshes the sidebar through the same
    /// notification an emoji change uses. Main-thread only, like the stores.
    @MainActor
    static func avatar(for account: AgentAccount) -> NSImage? {
        guard AppSettings.shared.discoversAccountAvatars else { return nil }

        let key = account.id.rawValue as NSString
        if let cached = composedCache.object(forKey: key) {
            return cached
        }

        if let data = try? BoundedFileReader.read(
            cachedImageURL(for: account),
            maximumBytes: ProjectIconDefaults.maximumSourceBytes
        ), let stored = NSImage(data: data), stored.isValid {
            let composed = ProjectIconStore.roundedDisplay(stored)
            composedCache.setObject(composed, forKey: key)
            return composed
        }

        discoverIfNeeded(account)
        return nil
    }

    /// Forgets this run's attempts, for the settings toggle switching back on.
    @MainActor
    static func retryAll() {
        attempted.removeAll()
    }

    /// The account's login email, read from the CLI's own records.
    static func email(for account: AgentAccount) -> String? {
        switch account.provider {
        case .claude: return claudeEmail(configPath: account.configPath)
        case .codex: return codexEmail(configPath: account.configPath)
        case .grok, .openCode, .cursor: return nil
        }
    }

    /// The same address, memoized. `AccountBadge` asks for it on every row configure — and
    /// rows reconfigure constantly while an agent works — where the uncached answer is a
    /// file read and a JWT decode for a value that does not change while the app runs.
    /// A miss is cached too, since a missing address is just as stable as a present one.
    /// Main-thread only, like `avatar(for:)`.
    @MainActor
    static func cachedEmail(for account: AgentAccount) -> String? {
        if let cached = emailCache[account.id] {
            return cached
        }

        let resolved = email(for: account)
        emailCache[account.id] = resolved
        return resolved
    }

    /// A JWT's payload claims, decoded locally. No verification and no use of the token —
    /// the claims are the only thing read.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The Gravatar probe for an email: SHA-256 of the normalised address, with `d=404`
    /// so absence is an HTTP status rather than a placeholder image.
    static func gravatarURL(for email: String) -> URL? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: AccountAvatarDefaults.gravatarURLString(hash: digest))
    }

    // MARK: - Private Methods

    @MainActor
    static func cachedImageURL(for account: AgentAccount) -> URL {
        directory.appendingPathComponent(fileName(for: account), isDirectory: false)
    }

    /// Account handles normally come from directory names, but old session state can carry any
    /// string. Preserve readable legacy names when they are one safe component and fall back to
    /// a stable digest otherwise; an identity is never a relative path into Application Support.
    static func fileName(for account: AgentAccount) -> String {
        let legacy = account.id.rawValue.replacingOccurrences(of: ":", with: "-")
            + "." + ProjectIconDefaults.storedExtension
        if ProjectIconStore.isSafeFileName(legacy) { return legacy }

        let digest = SHA256.hash(data: Data(account.id.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest + "." + ProjectIconDefaults.storedExtension
    }

    @MainActor
    static func discoverIfNeeded(_ account: AgentAccount) {
        guard !attempted.contains(account.id) else { return }
        attempted.insert(account.id)

        let target = cachedImageURL(for: account)
        let targetDirectory = directory
        ThreadingLogger.agent.debug(
            "Account avatar discovery started provider=\(account.provider.rawValue, privacy: .public) account=\(account.id.rawValue, privacy: .private(mask: .hash))"
        )

        queue.async {
            guard let email = email(for: account) else {
                ThreadingLogger.agent.debug(
                    "Account avatar discovery completed provider=\(account.provider.rawValue, privacy: .public) account=\(account.id.rawValue, privacy: .private(mask: .hash)) result=no_email"
                )
                return
            }
            guard let data = lookupAvatar(email: email) else {
                ThreadingLogger.agent.debug(
                    "Account avatar discovery completed provider=\(account.provider.rawValue, privacy: .public) account=\(account.id.rawValue, privacy: .private(mask: .hash)) result=not_found"
                )
                return
            }
            guard let png = ProjectIconStore.normalizedPNGData(from: data) else {
                ThreadingLogger.agent.warning(
                    "Account avatar discovery failed provider=\(account.provider.rawValue, privacy: .public) account=\(account.id.rawValue, privacy: .private(mask: .hash)) reason=invalid_image"
                )
                return
            }

            do {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                try png.write(to: target, options: .atomic)
            } catch {
                ThreadingLogger.agent.error("Could not store account avatar: \(error.localizedDescription, privacy: .private)")
                return
            }
            DispatchQueue.main.async {
                composedCache.removeObject(forKey: account.id.rawValue as NSString)
                AccountImageStore.avatarDidArrive(for: account)
                NotificationCenter.default.post(AccountPreferencesDidChange())
            }
        }
    }

    // MARK: Email Sources

    private static func claudeEmail(configPath: String) -> String? {
        let url = URL(fileURLWithPath: configPath)
            .appendingPathComponent(AccountAvatarDefaults.claudeConfigFile)
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: AccountAvatarDefaults.maximumAccountDocumentBytes
        ),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object[AccountAvatarDefaults.claudeOAuthKey] as? [String: Any]
        else { return nil }

        return oauth[AccountAvatarDefaults.claudeEmailKey] as? String
    }

    private static func codexEmail(configPath: String) -> String? {
        let url = URL(fileURLWithPath: configPath)
            .appendingPathComponent(AccountAvatarDefaults.codexAuthFile)
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: AccountAvatarDefaults.maximumAccountDocumentBytes
        ),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = object[AccountAvatarDefaults.codexTokensKey] as? [String: Any],
              let idToken = tokens[AccountAvatarDefaults.codexIDTokenKey] as? String,
              let claims = jwtClaims(idToken)
        else { return nil }

        if let email = claims[AccountAvatarDefaults.emailClaim] as? String {
            return email
        }

        // Some token versions nest the profile under an issuer-specific claim.
        let profile = claims[AccountAvatarDefaults.codexProfileClaim] as? [String: Any]
        return profile?[AccountAvatarDefaults.emailClaim] as? String
    }

    // MARK: Lookup

    private static func lookupAvatar(email: String) -> Data? {
        if let url = gravatarURL(for: email),
           let data = ProjectIconDiscovery.fetchImage(url) {
            return data
        }
        return gitHubAvatarByPublicEmail(email)
    }

    /// GitHub's user search matches only emails made public on a profile — a narrow but
    /// legitimate second chance after Gravatar.
    ///
    /// `items` is read per element. Every hit in this response claims the same public email, so
    /// taking the first *readable* one is the same arbitrary pick among equals that taking the
    /// first one always was — while refusing the container meant one unreadable hit cost the
    /// avatar entirely and left the account with a placeholder.
    private static func gitHubAvatarByPublicEmail(_ email: String) -> Data? {
        guard let url = AccountAvatarDefaults.gitHubSearchURL(email: email),
              let data = ProjectIconDiscovery.fetch(url),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = WireList.objects(
                  result[AccountAvatarDefaults.gitHubItemsKey],
                  site: WireListSite.gitHubUserSearchItems,
                  log: ThreadingLogger.github
              )?.first,
              let avatar = first[AccountAvatarDefaults.gitHubAvatarKey] as? String,
              let avatarURL = URL(string: avatar)
        else { return nil }

        return ProjectIconDiscovery.fetchImage(avatarURL)
    }
}

// MARK: - Account Avatar Defaults

enum AccountAvatarDefaults {
    static let directoryName = "AccountAvatars"
    static let maximumAccountDocumentBytes = 1024 * 1024

    static let claudeConfigFile = ".claude.json"
    static let claudeOAuthKey = "oauthAccount"
    static let claudeEmailKey = "emailAddress"

    static let codexAuthFile = "auth.json"
    static let codexTokensKey = "tokens"
    static let codexIDTokenKey = "id_token"
    static let codexProfileClaim = "https://api.openai.com/profile"
    static let emailClaim = "email"

    static func gravatarURLString(hash: String) -> String {
        "https://gravatar.com/avatar/\(hash)?d=404&s=\(ProjectIconDefaults.avatarPixelSize)"
    }

    static func gitHubSearchURL(email: String) -> URL? {
        guard let query = "\(email) in:email".addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return nil }
        return URL(string: "https://api.github.com/search/users?q=\(query)")
    }

    static let gitHubItemsKey = "items"
    static let gitHubAvatarKey = "avatar_url"
}
