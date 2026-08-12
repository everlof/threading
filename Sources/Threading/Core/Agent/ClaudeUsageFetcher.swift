import Foundation

// MARK: - Wire Types

/// `<config>/.credentials.json`, the CLI's on-disk token store on Linux-style setups.
private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: OAuth?

    struct OAuth: Decodable {
        let accessToken: String?
        /// Epoch **milliseconds**, unlike everything Codex stamps.
        let expiresAt: Double?
        let subscriptionType: String?
    }
}

// MARK: - Claude Usage Fetcher

/// Reads Claude usage, preferring a live API read and falling back to the local status-line
/// cache when no credentials file exists — which is the normal macOS layout, where Claude
/// Code keeps its token in the Keychain instead.
///
/// Four sources, ordered by freshness: the API against a token on disk, the API against the
/// Keychain token, the status-line cache Claude Code pushes on every turn, then the CLI's own
/// `cachedUsageUtilization`. A live read carries its model-scoped windows itself — the
/// endpoint's document names them in `limits[]` (`ClaudeUtilization`) — and the last source is
/// *merged into* a winner that arrived without any, which is the status-line feed's case; see
/// `ClaudeUsageProfileCache`.
///
/// **A source that cannot serve hands the question down; it does not answer for the chain.**
/// That rule was learnt from the opposite: a stale `<config>/.credentials.json` threw from
/// outside the fall-through, so an account whose CLI was mid-turn — refreshing its Keychain
/// item happily, with a status-line reading minutes old on disk — showed "the account's login
/// has expired". Only the last source left may name the failure.
enum ClaudeUsageFetcher {

    // MARK: - Types

    /// What one token source can offer this cycle.
    enum CredentialSource: Equatable {
        case usable(token: String, plan: String?)
        /// Present but unable to serve. Carries what to say if no later source serves either.
        case unusable(reason: UsageFetchError)
        /// This login keeps no token here — which says nothing about the ones it keeps
        /// elsewhere.
        case absent
    }

    // MARK: - Public Methods

    static func fetch(account: AgentAccount) async throws -> AccountUsage {
        let profile = ClaudeUsageProfileCache.read(account: account)

        /// The most specific reason a *token* source declined, kept for the throw at the end
        /// and used only if every later source also comes up empty.
        var refusal: UsageFetchError?

        // 1. The credentials file — the Linux-style layout, and on macOS sometimes a leftover
        //    that has gone stale beside a Keychain login that is perfectly current.
        switch readCredentialsFile(account: account) {
        case .usable(let token, let plan):
            do {
                return withModelWindows(
                    from: profile,
                    on: try await fetchFromAPI(credentials: (token, plan))
                )
            } catch UsageFetchError.tokenExpired {
                refusal = .tokenExpired
            }
        case .unusable(let reason):
            refusal = reason
        case .absent:
            break
        }

        // 2. The keychain is where macOS logins actually keep the token. Only with the user's
        //    standing opt-in, and never with a prompt: an ungranted read fails closed inside
        //    `ClaudeKeychainCredentials` and reads here as no token at all.
        if let credentials = await keychainCredentials(for: account) {
            do {
                return withModelWindows(from: profile, on: try await fetchFromAPI(credentials: credentials))
            } catch UsageFetchError.tokenExpired {
                // The CLI rotates the item in place, so a refused token is dropped and the
                // next cycle re-reads the keychain rather than concluding the login is gone.
                ClaudeKeychainCredentials.invalidate(configPath: account.configPath)
                refusal = .tokenExpired
            }
        }

        // 3. The status-line feed, which needs no credential at all — so a login whose tokens
        //    are all unreadable from here still reports the number Claude Code last pushed.
        if let cached = ClaudeUsageCache.read(account: account) {
            return withModelWindows(from: profile, on: cached)
        }

        // 4. The CLI's own last API reading, staler still.
        if let profile { return profile }

        throw refusal ?? .noCredential("No readable usage source for this Claude account.")
    }

    // MARK: - Internal Methods (pure, testable)

    /// The expiry rule for a credentials payload, without a file to hold it. A token past its
    /// expiry (or within the skew of it) is `.unusable` rather than fatal: the same account can
    /// hold a current token in the Keychain, which is exactly what the macOS layout does.
    static func credentials(fromFile data: Data, at now: Date) -> CredentialSource {
        guard data.count <= ClaudeUsageDefaults.credentialsMaxBytes,
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let oauth = file.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else {
            return .unusable(reason: .noCredential("The account's credentials file is unreadable."))
        }

        if let expiresAt = oauth.expiresAt {
            let expiry = Date(timeIntervalSince1970: expiresAt / 1000)
            guard expiry > now.addingTimeInterval(ClaudeUsageDefaults.expirySkew) else {
                return .unusable(reason: .tokenExpired)
            }
        }

        let plan = oauth.subscriptionType?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        return .usable(token: token, plan: plan)
    }

    // MARK: - Private Methods

    /// Carries the profile cache's model-scoped windows onto a reading that arrived without
    /// any — the status-line feed's case, which has the account's own windows and nothing
    /// scoped. A reading that brought its own scoped windows keeps them: it is fresher than
    /// the cache by construction.
    private static func withModelWindows(
        from profile: AccountUsage?,
        on usage: AccountUsage
    ) -> AccountUsage {
        guard usage.modelWindows.isEmpty,
              let profile, !profile.modelWindows.isEmpty
        else { return usage }

        var merged = usage
        merged.modelWindows = profile.modelWindows
        return merged
    }

    private static func fetchFromAPI(
        credentials: (token: String, plan: String?)
    ) async throws -> AccountUsage {
        guard let endpoint = URL(string: ClaudeUsageDefaults.usageEndpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeUsageDefaults.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(ClaudeUsageDefaults.userAgent, forHTTPHeaderField: "User-Agent")

        // The endpoint serves the same utilization document the CLI caches in `.claude.json`,
        // scoped limits included — decoding less than all of it is how the Fable window went
        // missing on every account whose CLI had no cache to recover it from.
        let response = try await UsageHTTP.getJSON(
            request,
            as: ClaudeUtilization.self,
            decoder: UsageHTTP.snakeCaseDecoder()
        )

        let windows = response.accountWindows()
        guard !windows.isEmpty else { throw UsageFetchError.decoding }

        var usage = AccountUsage(
            windows: windows,
            planLabel: credentials.plan,
            observedAt: Date(),
            source: .api
        )
        usage.modelWindows = response.modelWindows()
        return usage
    }

    /// The keychain token as the API branch consumes one, or nil when the setting is off or
    /// the read cannot be silent. The setting is read on the main actor, where every other
    /// `AppSettings` access lives; the keychain read stays off it, because a granted read is
    /// still a round trip to `securityd`.
    private static func keychainCredentials(
        for account: AgentAccount
    ) async -> (token: String, plan: String?)? {
        guard await MainActor.run(body: { AppSettings.shared.readsClaudeLoginFromKeychain })
        else { return nil }

        guard let token = ClaudeKeychainCredentials.token(forConfigPath: account.configPath)
        else { return nil }

        return (token.accessToken, token.plan)
    }

    /// `.absent` when the file simply is not there; otherwise whatever the payload can offer.
    static func readCredentialsFile(account: AgentAccount) -> CredentialSource {
        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(ClaudeUsageDefaults.credentialsFileName)

        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }

        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: ClaudeUsageDefaults.credentialsMaxBytes
        ) else {
            return .unusable(reason: .noCredential("The account's credentials file is unreadable."))
        }

        return credentials(fromFile: data, at: Date())
    }
}

// MARK: - Claude Usage Defaults

enum ClaudeUsageDefaults {
    static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    static let credentialsFileName = ".credentials.json"

    /// The endpoint serves the Claude Code OAuth client, so the request identifies as one.
    static let oauthBeta = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.0"

    /// A token about to expire is treated as expired, so the call is not wasted.
    static let expirySkew: TimeInterval = 30

    /// A credentials file is a few hundred bytes; anything huge is not that file.
    static let credentialsMaxBytes = 64 * 1024
}
