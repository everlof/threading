import Foundation

// MARK: - Wire Types

private struct CodexAuthFile: Decodable {
    let tokens: Tokens?

    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?
    }
}

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimit?

    /// Limits belonging to one model rather than the plan — each named, each with a window of
    /// its own. Present on this account for `GPT-5.3-Codex-Spark`.
    let additionalRateLimits: [NamedRateLimit]?

    /// Resets the account has banked, each clearing a spent window early.
    let rateLimitResetCredits: ResetCredits?

    let credits: Credits?

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct NamedRateLimit: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?
    }

    struct ResetCredits: Decodable {
        let availableCount: Int?
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let balance: String?
    }

    struct Window: Decodable {
        /// Percent 0–100.
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        /// Epoch **seconds**.
        let resetAt: Double?
    }
}

// MARK: - Codex Usage Fetcher

/// Reads Codex usage from the ChatGPT backend, authenticated by the tokens the Codex CLI
/// keeps in the account's `auth.json` — the same file whose presence admitted the account
/// during discovery.
enum CodexUsageFetcher {

    // MARK: - Public Methods

    static func fetch(account: AgentAccount) async throws -> AccountUsage {
        let auth = try readAuthFile(account: account)

        guard let endpoint = URL(string: CodexUsageDefaults.usageEndpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(CodexUsageDefaults.originator, forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await UsageHTTP.getJSON(
            request,
            as: CodexUsageResponse.self,
            decoder: UsageHTTP.snakeCaseDecoder()
        )

        // Primary/secondary are positions in the response, not fixed timeframes, so each
        // window is named from its own length.
        let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow]
            .compactMap(normalize)

        guard !windows.isEmpty else { throw UsageFetchError.decoding }

        var usage = AccountUsage(
            windows: windows,
            planLabel: response.planType?.capitalized,
            observedAt: Date(),
            source: .api
        )

        // Named per model, since that is what tells one apart from the plan's own windows —
        // and why they are kept out of `windows`, where they would distort the account's peak.
        usage.modelWindows = (response.additionalRateLimits ?? []).compactMap { limit in
            guard let name = limit.limitName,
                  let window = normalize(limit.rateLimit?.primaryWindow) else { return nil }

            // `window` carries the length's own identity, so the scoped window is named the same
            // way the account's are — long form in a bar, short form in a line — with the model
            // added rather than substituted for the length.
            return AccountUsage.Window(
                id: name,
                label: "\(window.label)\(UsageDefaults.segmentSeparator)\(name)",
                fraction: window.fraction,
                resetsAt: window.resetsAt,
                windowDuration: window.windowDuration,
                scopeName: name
            )
        }

        usage.resetCredits = response.rateLimitResetCredits?.availableCount

        // Only when there is a balance to speak of: "0" is what every account without credits
        // reports, and stating it would be noise on all of them.
        if response.credits?.hasCredits == true, let balance = response.credits?.balance {
            usage.creditBalance = balance
        }

        return usage
    }

    // MARK: - Private Methods

    private static func normalize(_ window: CodexUsageResponse.Window?) -> AccountUsage.Window? {
        guard let window else { return nil }

        let resetsAt = window.resetAt.map { Date(timeIntervalSince1970: $0) }
            ?? window.resetAfterSeconds.map { Date().addingTimeInterval($0) }

        let (id, label) = windowIdentity(seconds: window.limitWindowSeconds)

        return AccountUsage.Window(
            id: id,
            label: label,
            fraction: window.usedPercent.map { min(max($0 / 100, 0), 1) },
            resetsAt: resetsAt,
            windowDuration: window.limitWindowSeconds
        )
    }

    /// Maps a window length onto the shared 5-hour/weekly identities when it matches one,
    /// or derives a plain name so an unfamiliar window still reads sensibly.
    private static func windowIdentity(seconds: Double?) -> (id: String, label: String) {
        guard let seconds, seconds > 0 else {
            return (UsageDefaults.fiveHourWindowID, UsageDefaults.fiveHourLabel)
        }

        if abs(seconds - UsageDefaults.fiveHourSeconds) < CodexUsageDefaults.windowTolerance {
            return (UsageDefaults.fiveHourWindowID, UsageDefaults.fiveHourLabel)
        }
        if abs(seconds - UsageDefaults.sevenDaySeconds) < CodexUsageDefaults.windowTolerance {
            return (UsageDefaults.weeklyWindowID, UsageDefaults.weeklyLabel)
        }

        if seconds >= 24 * 60 * 60 {
            let days = Int((seconds / (24 * 60 * 60)).rounded())
            return ("\(days)d", "\(days)-day")
        }
        let hours = max(1, Int((seconds / (60 * 60)).rounded()))
        return ("\(hours)h", "\(hours)-hour")
    }

    private static func readAuthFile(
        account: AgentAccount
    ) throws -> (token: String, accountID: String) {
        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentAccountDefaults.codexAuthMarker)

        guard let data = try? Data(contentsOf: url) else {
            throw UsageFetchError.noCredential("The account's auth.json could not be read.")
        }

        guard let file = try? UsageHTTP.snakeCaseDecoder().decode(CodexAuthFile.self, from: data),
              let token = file.tokens?.accessToken, !token.isEmpty,
              let accountID = file.tokens?.accountId, !accountID.isEmpty
        else {
            throw UsageFetchError.noCredential("The account's auth.json holds no usable login.")
        }

        return (token, accountID)
    }
}

// MARK: - Codex Usage Defaults

enum CodexUsageDefaults {
    static let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"

    /// The backend gates on known clients; this is the value the Codex app itself sends.
    static let originator = "Codex Desktop"

    /// Slack when matching a reported window length to a known timeframe.
    static let windowTolerance: Double = 15 * 60
}
