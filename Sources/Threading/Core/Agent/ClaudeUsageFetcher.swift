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

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    struct Window: Decodable {
        /// Percent 0–100.
        let utilization: Double?
        let resetsAt: String?
    }
}

// MARK: - Claude Usage Fetcher

/// Reads Claude usage, preferring a live API read and falling back to the local status-line
/// cache when no credentials file exists — which is the normal macOS layout, where Claude
/// Code keeps its token in the Keychain instead.
///
/// Three sources, ordered by freshness: the API when there is a token on disk to call it with,
/// then the status-line cache Claude Code pushes on every turn, then the CLI's own
/// `cachedUsageUtilization`. The last one is also *merged into* whichever won, because it is
/// the only one that names a model-scoped window — see `ClaudeUsageProfileCache`.
enum ClaudeUsageFetcher {

    // MARK: - Public Methods

    static func fetch(account: AgentAccount) async throws -> AccountUsage {
        let profile = ClaudeUsageProfileCache.read(account: account)

        if let credentials = try readCredentialsFile(account: account) {
            do {
                return withModelWindows(from: profile, on: try await fetchFromAPI(credentials: credentials))
            } catch UsageFetchError.tokenExpired {
                // A stale file token can still be beaten by the local cache.
                if let cached = ClaudeUsageCache.read(account: account) {
                    return withModelWindows(from: profile, on: cached)
                }
                if let profile { return profile }
                throw UsageFetchError.tokenExpired
            }
        }

        if let cached = ClaudeUsageCache.read(account: account) {
            return withModelWindows(from: profile, on: cached)
        }

        if let profile { return profile }

        throw UsageFetchError.noCredential(
            "No readable usage source for this Claude account."
        )
    }

    // MARK: - Private Methods

    /// Carries the profile cache's model-scoped windows onto a reading taken from a fresher
    /// source, which has the account's own windows but never the scoped ones.
    private static func withModelWindows(
        from profile: AccountUsage?,
        on usage: AccountUsage
    ) -> AccountUsage {
        guard let profile, !profile.modelWindows.isEmpty else { return usage }

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

        let response = try await UsageHTTP.getJSON(
            request,
            as: ClaudeUsageResponse.self,
            decoder: UsageHTTP.snakeCaseDecoder()
        )

        var windows: [AccountUsage.Window] = []
        if let window = normalize(
            response.fiveHour,
            id: UsageDefaults.fiveHourWindowID,
            label: UsageDefaults.fiveHourLabel
        ) {
            windows.append(window)
        }
        if let window = normalize(
            response.sevenDay,
            id: UsageDefaults.weeklyWindowID,
            label: UsageDefaults.weeklyLabel
        ) {
            windows.append(window)
        }

        guard !windows.isEmpty else { throw UsageFetchError.decoding }

        return AccountUsage(
            windows: windows,
            planLabel: credentials.plan,
            observedAt: Date(),
            source: .api
        )
    }

    private static func normalize(
        _ window: ClaudeUsageResponse.Window?,
        id: String,
        label: String
    ) -> AccountUsage.Window? {
        guard let window else { return nil }
        return AccountUsage.Window(
            id: id,
            label: label,
            fraction: window.utilization.map { min(max($0 / 100, 0), 1) },
            resetsAt: window.resetsAt.flatMap(UsageHTTP.parseISO8601),
            windowDuration: UsageDefaults.duration(forWindowID: id)
        )
    }

    /// Nil when the file simply is not there; throws when it exists but cannot serve.
    private static func readCredentialsFile(
        account: AgentAccount
    ) throws -> (token: String, plan: String?)? {
        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(ClaudeUsageDefaults.credentialsFileName)

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url),
              data.count <= ClaudeUsageDefaults.credentialsMaxBytes,
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let oauth = file.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else {
            throw UsageFetchError.noCredential("The account's credentials file is unreadable.")
        }

        if let expiresAt = oauth.expiresAt {
            let expiry = Date(timeIntervalSince1970: expiresAt / 1000)
            guard expiry > Date().addingTimeInterval(ClaudeUsageDefaults.expirySkew) else {
                throw UsageFetchError.tokenExpired
            }
        }

        let plan = oauth.subscriptionType?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        return (token, plan)
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
