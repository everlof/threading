import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main queue when an account's usage entry changes; `object` is the
    /// typed account identifier.
    static let accountUsageDidChange = Notification.Name("SkalmanAccountUsageDidChange")
}

// MARK: - Usage Fetch Error

enum UsageFetchError: Error {
    case noCredential(String)
    case tokenExpired
    case http(status: Int)
    case network(String)
    case decoding

    /// One line for the pill's tooltip. Recovery is always "let the CLI sort it out":
    /// Skalman only ever reads the tokens the official CLIs maintain, so a stale login is
    /// theirs to refresh.
    var message: String {
        switch self {
        case .noCredential(let detail):
            return detail
        case .tokenExpired:
            return "The account's login has expired. Run the CLI to refresh it."
        case .http(let status):
            return "The usage service answered with status \(status)."
        case .network(let detail):
            return "Usage could not be fetched: \(detail)"
        case .decoding:
            return "The usage response was not in a recognized shape."
        }
    }
}

// MARK: - Account Usage Service

/// Fetches and caches rate-limit usage per agent account.
///
/// The design follows `~/repo/claudex`: read whatever short-lived access token the official
/// CLI already keeps on disk, use it read-only, and when it is stale say so rather than
/// refreshing it — the CLI owns the login. The Keychain is never read: its `Claude
/// Code-credentials` items do not say which config directory they belong to, and an
/// unbundled `swift build` binary would re-prompt on every rebuild.
///
/// State is touched only on the main queue, like everything else stateful in the app.
/// Fetches run detached and hop back to publish.
@MainActor
final class AccountUsageService {

    // MARK: - Properties

    static let shared = AccountUsageService()

    /// A cached reading beside its bookkeeping. A failed fetch keeps the last good value —
    /// stale usage beside an error message beats a pill that blanks on every network blip.
    private struct Entry {
        var usage: AccountUsage?
        var errorMessage: String?
        var lastAttemptAt: Date?
    }

    private var entries: [AccountID: Entry] = [:]
    private var inFlight: Set<AccountID> = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func usage(for account: AgentAccount) -> AccountUsage? {
        entries[account.id]?.usage
    }

    func errorMessage(for account: AgentAccount) -> String? {
        entries[account.id]?.errorMessage
    }

    /// Fetches when the cached value has aged out, or sooner when `force` asks — though
    /// never more often than the per-account floor, so an eager UI cannot hammer the APIs.
    func refresh(_ account: AgentAccount, force: Bool = false) {
        guard account.provider != .shell else { return }

        let id = account.id
        guard !inFlight.contains(id) else { return }

        let now = Date()
        if let lastAttempt = entries[id]?.lastAttemptAt {
            guard now.timeIntervalSince(lastAttempt) >= spacing(for: id, force: force) else {
                return
            }
        }

        inFlight.insert(id)
        entries[id, default: Entry()].lastAttemptAt = now

        Task.detached(priority: .utility) {
            let result: Result<AccountUsage, UsageFetchError>
            do {
                result = .success(try await Self.fetchUsage(for: account))
            } catch let error as UsageFetchError {
                result = .failure(error)
            } catch {
                result = .failure(.network(error.localizedDescription))
            }

            await MainActor.run {
                AccountUsageService.shared.finish(accountID: id, result: result)
            }
        }
    }

    // MARK: - Private Methods

    /// How long the current entry satisfies requests before another fetch runs. A local
    /// file re-reads cheaply and often; a network reading is held longer; `force` only
    /// tightens either to the shared floor.
    private func spacing(for accountID: AccountID, force: Bool) -> TimeInterval {
        if force { return UsageDefaults.minimumRefreshSpacing }

        return entries[accountID]?.usage?.source == .localCache
            ? UsageDefaults.localCacheRefreshInterval
            : UsageDefaults.refreshInterval
    }

    private func finish(accountID: AccountID, result: Result<AccountUsage, UsageFetchError>) {
        inFlight.remove(accountID)

        var entry = entries[accountID] ?? Entry()
        switch result {
        case .success(let usage):
            entry.usage = usage
            entry.errorMessage = nil
        case .failure(let error):
            // The last good reading survives a failed refresh.
            entry.errorMessage = error.message
            SkalmanLogger.agent.info(
                "Usage fetch failed for \(accountID, privacy: .public): \(error.message, privacy: .public)"
            )
        }
        entries[accountID] = entry

        NotificationCenter.default.post(name: .accountUsageDidChange, object: accountID)
    }

    private static func fetchUsage(for account: AgentAccount) async throws -> AccountUsage {
        switch account.provider {
        case .claude: return try await ClaudeUsageFetcher.fetch(account: account)
        case .codex: return try await CodexUsageFetcher.fetch(account: account)
        case .shell: throw UsageFetchError.noCredential("Shells have no usage.")
        }
    }
}

// MARK: - Shared HTTP

enum UsageHTTP {

    /// One ephemeral session for all usage calls: nothing here is worth a cookie or a cache.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UsageDefaults.requestTimeout
        return URLSession(configuration: configuration)
    }()

    static func getJSON<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type,
        decoder: JSONDecoder
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageFetchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.network("No HTTP response.")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw UsageFetchError.tokenExpired
        default:
            throw UsageFetchError.http(status: http.statusCode)
        }

        guard let decoded = try? decoder.decode(Response.self, from: data) else {
            throw UsageFetchError.decoding
        }
        return decoded
    }

    static func snakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// `resets_at` arrives ISO-8601, sometimes with fractional seconds.
    static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
