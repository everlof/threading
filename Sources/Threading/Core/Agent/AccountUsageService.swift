import Foundation

// MARK: - Usage Fetch Error

enum UsageFetchError: Error, Equatable, Sendable {
    case noCredential(String)
    case tokenExpired
    /// The usage endpoint itself said "too fast". Carries its `Retry-After` when one was
    /// sent, so the service can wait exactly as long as it was told to.
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network(String)
    case decoding

    /// One line for the pill's tooltip. Recovery is always "let the CLI sort it out":
    /// Threading only ever reads the tokens the official CLIs maintain, so a stale login is
    /// theirs to refresh.
    var message: String {
        switch self {
        case .noCredential(let detail):
            return detail
        case .tokenExpired:
            return "The account's login has expired. Run the CLI to refresh it."
        case .rateLimited:
            return "The usage service asked for a pause. Trying again later."
        case .http(let status):
            return "The usage service answered with status \(status)."
        case .network(let detail):
            return "Usage could not be fetched: \(detail)"
        case .decoding:
            return "The usage response was not in a recognized shape."
        }
    }
}

// MARK: - Cached Reading

/// The result currently known for one account.
///
/// The last good value deliberately survives a failed refresh, but that is not the same state
/// as either a fresh value or a first fetch that failed. Naming all four states keeps consumers
/// from reconstructing them from two independent optionals.
enum AccountUsageReading: Equatable {
    case notFetched
    case current(AccountUsage)
    case stale(AccountUsage, error: UsageFetchError)
    case failed(UsageFetchError)

    var usage: AccountUsage? {
        switch self {
        case .notFetched, .failed: nil
        case .current(let usage), .stale(let usage, _): usage
        }
    }

    var error: UsageFetchError? {
        switch self {
        case .notFetched, .current: nil
        case .stale(_, let error), .failed(let error): error
        }
    }

    var hasResult: Bool {
        if case .notFetched = self { return false }
        return true
    }

    func recording(
        _ result: Result<AccountUsage, UsageFetchError>
    ) -> AccountUsageReading {
        switch result {
        case .success(let usage):
            return .current(usage)
        case .failure(let error):
            guard let usage else { return .failed(error) }
            return .stale(usage, error: error)
        }
    }
}

// MARK: - Account Usage Service

/// Fetches and caches rate-limit usage per agent account.
///
/// The design follows `~/repo/claudex`: read whatever short-lived access token the official
/// CLI already keeps, use it read-only, and when it is stale say so rather than refreshing
/// it — the CLI owns the login. On-disk tokens are read freely; the Keychain only with the
/// user's standing opt-in (`readsClaudeLoginFromKeychain`), and never with a prompt — see
/// `ClaudeKeychainCredentials` for both halves of that promise.
///
/// Refreshes are paced from three directions so the usage endpoints are never hammered:
/// a per-account floor however eagerly the UI asks, a `notBefore` the endpoint itself sets
/// through 429/`Retry-After` (which even `force` respects — a user clicking refresh must not
/// be a way to spend a rate limit faster), and an event-driven path that asks *when a turn
/// ends*, which is the only moment the numbers actually move. The last is what CodexBar calls
/// agent-aware refresh, done with certainty instead of guesswork: Threading is told about the
/// turn boundary rather than inferring one.
///
/// State is touched only on the main queue, like everything else stateful in the app.
/// Fetches run detached and hop back to publish.
@MainActor
final class AccountUsageService {

    typealias Fetcher = @Sendable (AgentAccount) async throws -> AccountUsage

    // MARK: - Properties

    static let shared = AccountUsageService()

    /// A cached reading beside its bookkeeping. A failed fetch keeps the last good value —
    /// stale usage beside an error message beats a pill that blanks on every network blip.
    private struct Entry {
        var reading: AccountUsageReading = .notFetched
        var lastAttemptAt: Date?
        /// Set when the endpoint answered 429: no request before this moment, forced or not.
        var notBefore: Date?
        /// Consecutive 429s, for the backoff that answers a `Retry-After`-less refusal.
        var consecutiveRateLimits = 0
    }

    private var entries: [AccountID: Entry] = [:]
    /// Scheduled and active work share this set, so another caller joins the one promised result
    /// even when that account is waiting behind the global concurrency gate.
    private var inFlight: Set<AccountID> = []
    private var activeRefreshes: Set<AccountID> = []
    private var pendingAccounts: [AccountID: AgentAccount] = [:]
    private var pendingOrder: [AccountID] = []
    private var nextPendingIndex = 0
    private let maximumConcurrentRefreshes: Int
    private let fetcher: Fetcher

    /// Callers waiting for an account's reading to be as fresh as it is going to get.
    ///
    /// Only a caller that has to *decide* on the number needs this — the usage-limit escape
    /// refuses to move a conversation onto a login on the strength of a cached figure. Everyone
    /// else draws whatever is cached and redraws on `AccountUsageDidChange`, which stays the
    /// ordinary way to follow a reading.
    private var settlementWaiters: [AccountID: [@MainActor () -> Void]] = [:]

    /// Accounts whose history has already been recovered from disk this launch. The recovery is
    /// a filesystem walk and its answer does not change between readings.
    private var seededHistory: Set<AccountID> = []

    /// Invalidates provider reads that began before an authoritative mutation result landed.
    /// Without this, a slow pre-reset fetch can finish after the post-reset app-server read and
    /// put the spent window back on screen.
    private var authoritativeGenerations: [AccountID: UInt64] = [:]

    /// Last known open-turn fact per session, retained only for the process-exit fallback.
    private let observations = AppEventObservations()
    private var lastOpenTurn: [SessionID: Bool] = [:]

    // MARK: - Initialization

    init(
        maximumConcurrentRefreshes: Int = UsageDefaults.maximumConcurrentRefreshes,
        observesActivity: Bool = true,
        fetcher: @escaping Fetcher = { try await AccountUsageService.fetchUsage(for: $0) }
    ) {
        self.maximumConcurrentRefreshes = max(1, maximumConcurrentRefreshes)
        self.fetcher = fetcher

        guard observesActivity else { return }
        // A turn ending is the freshest possible moment to ask — and the cheapest, because
        // every pacing rule above still applies: the floor, the endpoint's own notBefore,
        // and single-flight. An idle app stops generating turn boundaries and therefore
        // stops generating these refreshes, which is the back-off half of "adaptive".
        observations.observe(SessionRuntimeDidChange.self) { [weak self] event in
            Task { @MainActor in self?.runtimeChanged(event) }
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            Task { @MainActor in self?.sessionEnded(event.sessionID) }
        }
    }

    // MARK: - Public Methods

    func reading(for account: AgentAccount) -> AccountUsageReading {
        entries[account.id]?.reading ?? .notFetched
    }

    func usage(for account: AgentAccount) -> AccountUsage? {
        reading(for: account).usage
    }

    func errorMessage(for account: AgentAccount) -> String? {
        reading(for: account).error?.message
    }

    /// Publishes a provider-authoritative reading produced as part of an account mutation.
    ///
    /// This deliberately bypasses ordinary refresh pacing: the mutation already paid for the
    /// read, and every consumer must see the result before recovery continuations are released.
    func acceptAuthoritative(_ usage: AccountUsage, for account: AgentAccount) {
        let accountID = account.id
        authoritativeGenerations[accountID, default: 0] &+= 1

        var entry = entries[accountID] ?? Entry()
        entry.reading = .current(usage)
        entry.lastAttemptAt = Date()
        entry.notBefore = nil
        entry.consecutiveRateLimits = 0
        entries[accountID] = entry

        UsageHistoryStore.shared.record(usage, for: account)
        seedHistoryIfThin(account, usage: usage)
        NotificationCenter.default.post(AccountUsageDidChange(accountID: accountID))
    }

    /// Fetches when the cached value has aged out, or sooner when `force` asks — though
    /// never more often than the per-account floor, so an eager UI cannot hammer the APIs,
    /// and never before a `notBefore` the endpoint set by answering 429: a pause the server
    /// asked for is not the UI's to decline, forced or not.
    func refresh(_ account: AgentAccount, force: Bool = false) {
        refresh(account, force: force, settled: nil)
    }

    /// The same refresh, with a receipt: `settled` runs once the cached reading is as current as
    /// this account's pacing allows it to be.
    ///
    /// It fires **immediately** when no fetch was started — a floor, a `notBefore` the endpoint
    /// set, or nothing to fetch with. That is not a failure and must not be reported as one: the
    /// pacing rules are deliberate, `force` already respects the server's own pause, and the
    /// answer for the caller is "this is the freshest reading you may have right now". A caller
    /// that must not act on a stale figure reads `AccountUsageReading` afterwards and decides;
    /// this only says when to look.
    func refresh(
        _ account: AgentAccount,
        force: Bool = false,
        settled: (@MainActor () -> Void)?
    ) {
        let id = account.id
        guard !inFlight.contains(id) else {
            // A fetch is already on its way to the same account. Joining it is both cheaper and
            // more correct than declining: the caller wants the value that lands, not a second
            // request for it.
            if let settled { settlementWaiters[id, default: []].append(settled) }
            return
        }

        let now = Date()
        if let notBefore = entries[id]?.notBefore, now < notBefore {
            settled?()
            return
        }
        if let lastAttempt = entries[id]?.lastAttemptAt,
           now.timeIntervalSince(lastAttempt) < spacing(for: id, force: force) {
            settled?()
            return
        }

        if let settled { settlementWaiters[id, default: []].append(settled) }
        inFlight.insert(id)
        pendingAccounts[id] = account
        pendingOrder.append(id)
        drainRefreshQueue()
    }

    // MARK: - Private Methods

    /// Admits a bounded number of provider reads from the unbounded account queue.
    ///
    /// `pendingOrder` advances an index rather than removing its first element, keeping a fleet
    /// open O(n) instead of making queue maintenance O(n²). It is compacted only after a complete
    /// drain, when no queued identity can still refer to the old storage.
    private func drainRefreshQueue() {
        while activeRefreshes.count < maximumConcurrentRefreshes,
              nextPendingIndex < pendingOrder.count {
            let id = pendingOrder[nextPendingIndex]
            nextPendingIndex += 1
            guard let account = pendingAccounts.removeValue(forKey: id) else { continue }

            activeRefreshes.insert(id)
            entries[id, default: Entry()].lastAttemptAt = Date()
            let fetcher = self.fetcher
            let generation = authoritativeGenerations[id, default: 0]

            Task.detached(priority: .utility) { [self] in
                let result: Result<AccountUsage, UsageFetchError>
                do {
                    result = .success(try await fetcher(account))
                } catch let error as UsageFetchError {
                    result = .failure(error)
                } catch {
                    result = .failure(.network(error.localizedDescription))
                }

                await finish(account: account, result: result, generation: generation)
            }
        }

        if nextPendingIndex == pendingOrder.count {
            pendingOrder.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
        }
    }

    /// How long the current entry satisfies requests before another fetch runs. A local
    /// file re-reads cheaply and often; a network reading is held longer; `force` only
    /// tightens either to the shared floor.
    private func spacing(for accountID: AccountID, force: Bool) -> TimeInterval {
        if force { return UsageDefaults.minimumRefreshSpacing }

        return entries[accountID]?.reading.usage?.source == .localCache
            ? UsageDefaults.localCacheRefreshInterval
            : UsageDefaults.refreshInterval
    }

    private func finish(
        account: AgentAccount,
        result: Result<AccountUsage, UsageFetchError>,
        generation: UInt64
    ) {
        let accountID = account.id
        activeRefreshes.remove(accountID)
        inFlight.remove(accountID)

        guard generation == authoritativeGenerations[accountID, default: 0] else {
            for settled in settlementWaiters.removeValue(forKey: accountID) ?? [] { settled() }
            drainRefreshQueue()
            return
        }

        var entry = entries[accountID] ?? Entry()
        entry.reading = entry.reading.recording(result)
        switch result {
        case .success(let usage):
            entry.notBefore = nil
            entry.consecutiveRateLimits = 0

            // Every reading joins the history, which is the only place a *rate* can come
            // from — a snapshot can say 85% and never say how fast it got there.
            UsageHistoryStore.shared.record(usage, for: account)
            seedHistoryIfThin(account, usage: usage)
        case .failure(let error):
            if case .rateLimited(let retryAfter) = error {
                entry.consecutiveRateLimits += 1
                entry.notBefore = Date().addingTimeInterval(
                    UsageRetrySchedule.delay(
                        retryAfter: retryAfter,
                        consecutiveRateLimits: entry.consecutiveRateLimits
                    )
                )
            } else {
                // These counters describe consecutive 429 responses, not consecutive failures.
                // Any other response breaks the sequence; an expired not-before has no reason
                // to leak into the next refusal's backoff calculation.
                entry.notBefore = nil
                entry.consecutiveRateLimits = 0
            }

            ThreadingLogger.agent.info(
                "Usage fetch failed for \(accountID, privacy: .private(mask: .hash)): \(error.message, privacy: .private(mask: .hash))"
            )
        }
        entries[accountID] = entry

        NotificationCenter.default.post(AccountUsageDidChange(accountID: accountID))

        // After the announcement, so a waiter reading the cache sees exactly what every other
        // observer has already been shown.
        for settled in settlementWaiters.removeValue(forKey: accountID) ?? [] { settled() }
        drainRefreshQueue()
    }

    /// The transition out of `.working` is a turn boundary: tokens were just spent, so the
    /// server's number moved and a refresh right now is worth the most it will ever be.
    /// Everything else — `working → working`, a session waking up — changes nothing upstream
    /// and asks for nothing.
    private func runtimeChanged(_ event: SessionRuntimeDidChange) {
        lastOpenTurn[event.sessionID] = event.transition.current.hasOpenTurn
        if event.transition.endedTurn { refreshAccount(of: event.sessionID) }
    }

    /// An exiting agent is the end of whatever it was doing — the same boundary, minus the
    /// session to keep watching.
    private func sessionEnded(_ sessionID: SessionID) {
        let hadOpenTurn = lastOpenTurn.removeValue(forKey: sessionID) == true
        if hadOpenTurn { refreshAccount(of: sessionID) }
    }

    private func refreshAccount(of sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              )
        else { return }

        refresh(account)
    }

    /// Recovers a Codex account's past week from its own rollouts, once, when the history is
    /// too thin to project from.
    ///
    /// Only Codex: it writes rate limits into its transcripts, so its history exists before
    /// Threading ever looked. Claude's does not, and necessarily starts now.
    private func seedHistoryIfThin(_ account: AgentAccount, usage: AccountUsage) {
        guard account.provider == .codex,
              let window = usage.peakWindow(),
              !seededHistory.contains(account.id),
              UsageHistoryStore.shared.samples(for: account, windowID: window.id).count
                  < UsageHistoryDefaults.thinHistory else { return }

        seededHistory.insert(account.id)

        let configPath = account.configPath
        let windowID = window.id

        DispatchQueue.global(qos: .utility).async {
            let samples = CodexUsageBackfill.samples(forAccountAt: configPath)
            guard !samples.isEmpty else { return }

            Task { @MainActor in
                UsageHistoryStore.shared.seed(samples, for: account, windowID: windowID)
                NotificationCenter.default.post(AccountUsageDidChange(accountID: account.id))
            }
        }
    }

    nonisolated private static func fetchUsage(
        for account: AgentAccount
    ) async throws -> AccountUsage {
        switch account.provider {
        case .claude: return try await ClaudeUsageFetcher.fetch(account: account)
        case .codex: return try await CodexUsageFetcher.fetch(account: account)
        case .grok:
            throw UsageFetchError.noCredential("Grok manages usage in its own TUI.")
        case .openCode:
            throw UsageFetchError.noCredential("OpenCode manages provider usage in its own TUI.")
        case .cursor:
            throw UsageFetchError.noCredential("Cursor reports no usage to Threading.")
        }
    }
}

// MARK: - Retry Schedule

/// When the next attempt may run after the endpoint said "too fast". Pure, so the arithmetic
/// is testable without a clock or a network.
enum UsageRetrySchedule {

    /// `retryAfter` is authoritative when present — the server named its own price — held to
    /// the refresh floor so a mischievous `Retry-After: 1` cannot invite a hammer. Without
    /// one, exponential backoff from the ordinary interval, capped. Jitter stretches the wait
    /// by up to a tenth and never shortens it: three accounts refused together must not come
    /// back together.
    static func delay(
        retryAfter: TimeInterval?,
        consecutiveRateLimits: Int,
        jitter: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        let base: TimeInterval
        if let retryAfter {
            base = max(retryAfter, UsageDefaults.minimumRefreshSpacing)
        } else {
            let doublings = max(0, consecutiveRateLimits - 1)
            let backoff = UsageDefaults.refreshInterval * pow(2, Double(doublings))
            base = min(backoff, UsageDefaults.rateLimitBackoffCap)
        }

        return base * (1 + UsageDefaults.rateLimitJitterFraction * min(max(jitter, 0), 1))
    }

    /// `Retry-After` arrives as delta-seconds or as an HTTP-date; both mean a wait from now.
    static func retryAfter(fromHeader value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }

        if let seconds = TimeInterval(value) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }

        return max(0, date.timeIntervalSince(now))
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
        case 429:
            throw UsageFetchError.rateLimited(
                retryAfter: UsageRetrySchedule.retryAfter(
                    fromHeader: http.value(forHTTPHeaderField: "Retry-After")
                )
            )
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
