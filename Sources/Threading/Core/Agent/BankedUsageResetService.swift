import Darwin
import Foundation

// MARK: - Public Core Contract

/// The account and exact credit facts a person confirms before one irreversible redemption.
struct BankedUsageResetOffer: Equatable, Sendable {
    let accountID: AccountID
    let accountName: String
    /// Backend identity captured by the authoritative prepare read. Never crosses the remote
    /// boundary in plaintext; it binds a later consume to the login the person reviewed.
    let providerAccountID: String
    let availableCount: Int
    let selectedCreditID: String?
    let selectedCreditTitle: String?
    let selectedCreditExpiresAt: Date?
    /// True when the backend reported inventory but withheld the selectable detail rows.
    let letsProviderChooseCredit: Bool
    let eligibleWindowLabels: [String]
    let owedContinuationCount: Int

    init(
        accountID: AccountID,
        accountName: String,
        providerAccountID: String = "",
        availableCount: Int,
        selectedCreditID: String?,
        selectedCreditTitle: String?,
        selectedCreditExpiresAt: Date?,
        letsProviderChooseCredit: Bool,
        eligibleWindowLabels: [String],
        owedContinuationCount: Int
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.providerAccountID = providerAccountID
        self.availableCount = availableCount
        self.selectedCreditID = selectedCreditID
        self.selectedCreditTitle = selectedCreditTitle
        self.selectedCreditExpiresAt = selectedCreditExpiresAt
        self.letsProviderChooseCredit = letsProviderChooseCredit
        self.eligibleWindowLabels = eligibleWindowLabels
        self.owedContinuationCount = owedContinuationCount
    }
}

enum BankedUsageResetOutcome: String, Codable, Equatable, Sendable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

struct BankedUsageResetResult: Equatable, Sendable {
    let outcome: BankedUsageResetOutcome
    let remainingCreditCount: Int?
    let releasedContinuationCount: Int
    let authoritativeRefreshAccepted: Bool
    let hasVerifiedHeadroom: Bool
    let continuationReleaseFailed: Bool
}

enum BankedUsageResetError: LocalizedError, Equatable, Sendable {
    case unsupportedAccount
    case noCredit
    case offerChanged
    case accountIdentityUnavailable
    case accountMismatch
    case updateCodex
    case busy
    case transport(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedAccount:
            return "Banked usage resets are available for signed-in Codex accounts."
        case .noCredit:
            return "This account has no banked reset available."
        case .offerChanged:
            return "The available reset changed. Review the refreshed details and confirm again."
        case .accountIdentityUnavailable:
            return "Threading could not verify which Codex account is signed in."
        case .accountMismatch:
            return "Codex opened a different account, so Threading did not use the reset."
        case .updateCodex:
            return "This Codex installation cannot use banked resets. Update Codex and try again."
        case .busy:
            return "A banked reset is already being handled for this account."
        case .transport(let detail):
            return detail.isEmpty ? "Codex could not confirm the banked reset." : detail
        case .malformedResponse:
            return "Codex returned an unrecognized banked-reset response."
        }
    }
}

@MainActor
protocol BankedUsageResetAdapter: Sendable {
    func prepare(account: AgentAccount, owedContinuationCount: Int) async throws
        -> BankedUsageResetOffer
    func redeem(
        account: AgentAccount,
        offer: BankedUsageResetOffer,
        idempotencyKey: String
    ) async throws -> BankedUsageResetAdapterResult
}

struct BankedUsageResetAdapterResult: Sendable {
    let outcome: BankedUsageResetOutcome
    let authoritativeUsage: AccountUsage
}

// MARK: - Service

/// Owns account single-flight, authoritative usage publication, and account-wide continuation
/// release. Presentation owns confirmation; no caller can make this service remember an answer.
@MainActor
final class BankedUsageResetService {
    typealias AdapterProvider = @MainActor @Sendable (AgentKind)
        -> (any BankedUsageResetAdapter)?
    typealias OwedSessionsProvider = @MainActor @Sendable (AccountID) -> Set<SessionID>
    typealias ContinuationReleaser = @MainActor @Sendable (Set<SessionID>, Date) -> Int?
    typealias AuthoritativePublisher = @MainActor @Sendable (AccountUsage, AgentAccount) -> Void

    static let shared = BankedUsageResetService()

    private let authoritativePublisher: AuthoritativePublisher
    private let adapterProvider: AdapterProvider
    private let owedSessionsProvider: OwedSessionsProvider
    private let continuationReleaser: ContinuationReleaser
    private let now: @MainActor @Sendable () -> Date
    private var busyAccounts: Set<AccountID> = []

    init(
        usageService: AccountUsageService = .shared,
        adapterProvider: @escaping AdapterProvider = { provider in
            provider.supports(.bankedUsageReset) ? CodexBankedUsageResetAdapter() : nil
        },
        owedSessionsProvider: @escaping OwedSessionsProvider = {
            BankedUsageResetService.liveOwedContinuationSessionIDs(for: $0)
        },
        continuationReleaser: @escaping ContinuationReleaser = {
            ScheduledMessageStore.shared.releaseLimitRecoveryContinuations(for: $0, dueAt: $1)
        },
        authoritativePublisher: AuthoritativePublisher? = nil,
        now: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        self.authoritativePublisher = authoritativePublisher ?? {
            usageService.acceptAuthoritative($0, for: $1)
        }
        self.adapterProvider = adapterProvider
        self.owedSessionsProvider = owedSessionsProvider
        self.continuationReleaser = continuationReleaser
        self.now = now
    }

    func isBusy(_ accountID: AccountID) -> Bool {
        busyAccounts.contains(accountID)
    }

    func prepare(account: AgentAccount) async throws -> BankedUsageResetOffer {
        try begin(account.id)
        defer { end(account.id) }
        guard let adapter = adapterProvider(account.provider) else {
            throw BankedUsageResetError.unsupportedAccount
        }
        return try await adapter.prepare(
            account: account,
            owedContinuationCount: owedSessionsProvider(account.id).count
        )
    }

    func redeem(
        account: AgentAccount,
        offer: BankedUsageResetOffer,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> BankedUsageResetResult {
        guard offer.accountID == account.id else { throw BankedUsageResetError.accountMismatch }
        try begin(account.id)
        defer { end(account.id) }
        guard let adapter = adapterProvider(account.provider) else {
            throw BankedUsageResetError.unsupportedAccount
        }

        let redeemed = try await adapter.redeem(
            account: account,
            offer: offer,
            idempotencyKey: idempotencyKey
        )
        authoritativePublisher(redeemed.authoritativeUsage, account)

        var released = 0
        var releaseFailed = false
        let hasVerifiedHeadroom = Self.hasVerifiedHeadroom(
            redeemed.authoritativeUsage,
            now: now()
        )
        if redeemed.outcome == .reset || redeemed.outcome == .alreadyRedeemed,
           hasVerifiedHeadroom {
            let sessions = owedSessionsProvider(account.id)
            if let count = continuationReleaser(
                sessions,
                now().addingTimeInterval(PresetDefaults.resetPadding)
            ) {
                released = count
            } else {
                releaseFailed = true
            }
        }

        EventLog.shared.record(.limitRecovery, "Banked usage reset completed", [
            "account": account.id.rawValue,
            "outcome": redeemed.outcome.rawValue,
            "releasedContinuations": String(released),
            "continuationReleaseFailed": String(releaseFailed)
        ])
        return BankedUsageResetResult(
            outcome: redeemed.outcome,
            remainingCreditCount: redeemed.authoritativeUsage.resetCredits,
            releasedContinuationCount: released,
            authoritativeRefreshAccepted: true,
            hasVerifiedHeadroom: hasVerifiedHeadroom,
            continuationReleaseFailed: releaseFailed
        )
    }

    private func begin(_ accountID: AccountID) throws {
        guard busyAccounts.insert(accountID).inserted else { throw BankedUsageResetError.busy }
        NotificationCenter.default.post(BankedUsageResetStateDidChange(accountID: accountID))
    }

    private func end(_ accountID: AccountID) {
        busyAccounts.remove(accountID)
        NotificationCenter.default.post(BankedUsageResetStateDidChange(accountID: accountID))
    }

    private static func liveOwedContinuationSessionIDs(
        for accountID: AccountID
    ) -> Set<SessionID> {
        let matchingSessions = Set(ProjectStore.shared.projects.flatMap(\.sessions).compactMap {
            session -> SessionID? in
            guard session.kind == accountID.provider,
                  session.accountHandle == accountID.handle else { return nil }
            return session.id
        })
        return Set(ScheduledMessageStore.shared.all.compactMap { message in
            guard message.isOwedLimitRecoveryContinuation,
                  let sessionID = message.target.sessionID,
                  matchingSessions.contains(sessionID) else { return nil }
            return sessionID
        })
    }

    private static func hasVerifiedHeadroom(_ usage: AccountUsage, now: Date = Date()) -> Bool {
        let currentReadings = usage.allWindows.compactMap { window -> Double? in
            guard !window.isExpired(at: now) else { return nil }
            return window.fraction
        }
        return !currentReadings.isEmpty && currentReadings.allSatisfy { $0 < 1 }
    }
}

struct BankedUsageResetStateDidChange: AppEvent {
    static let name = Notification.Name("ThreadingBankedUsageResetStateDidChange")
    let accountID: AccountID
}

// MARK: - Codex Adapter

@MainActor
struct CodexBankedUsageResetAdapter: BankedUsageResetAdapter {
    typealias ClientFactory = @MainActor @Sendable () -> any CodexAccountAppServerServing
    typealias BackendIdentityProvider = @MainActor @Sendable (AgentAccount) async throws -> String
    private let clientFactory: ClientFactory
    private let backendIdentityProvider: BackendIdentityProvider

    init(
        clientFactory: @escaping ClientFactory = { CodexAccountAppServerClient() },
        backendIdentityProvider: @escaping BackendIdentityProvider = { account in
            try await Task.detached(priority: .utility) {
                try CodexAccountIdentityReader.backendAccountID(for: account)
            }.value
        }
    ) {
        self.clientFactory = clientFactory
        self.backendIdentityProvider = backendIdentityProvider
    }

    func prepare(account: AgentAccount, owedContinuationCount: Int) async throws
        -> BankedUsageResetOffer {
        guard account.provider.supports(.bankedUsageReset) else {
            throw BankedUsageResetError.unsupportedAccount
        }
        let backendAccountID = try await backendIdentity(for: account)
        let snapshot: CodexAccountRateLimitsSnapshot
        do {
            snapshot = try await clientFactory().read(
                account: account,
                expectedBackendAccountID: backendAccountID
            )
        } catch let error as BankedUsageResetError {
            throw error
        } catch let error as CodexAccountAppServerError {
            throw error.bankedResetError
        }
        let resetCredits = snapshot.resetCredits
        let selected = BankedUsageResetCreditSelector.select(from: resetCredits)
        let count = resetCredits?.availableCount ?? 0
        guard count > 0 else { throw BankedUsageResetError.noCredit }
        // Omitting `creditId` is an explicit fallback only when Codex withheld the detail rows.
        // If it supplied rows and none is an available Codex-rate-limit credit, the summary count
        // is not authority to spend some other credit type.
        if resetCredits?.credits != nil, selected == nil {
            throw BankedUsageResetError.noCredit
        }

        return BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            providerAccountID: backendAccountID,
            availableCount: count,
            selectedCreditID: selected?.id,
            selectedCreditTitle: selected?.title,
            selectedCreditExpiresAt: selected?.expiresAt.map(Date.init(timeIntervalSince1970:)),
            letsProviderChooseCredit: resetCredits?.credits == nil,
            eligibleWindowLabels: snapshot.eligibleWindowLabels,
            owedContinuationCount: owedContinuationCount
        )
    }

    func redeem(
        account: AgentAccount,
        offer: BankedUsageResetOffer,
        idempotencyKey: String
    ) async throws -> BankedUsageResetAdapterResult {
        let backendAccountID = try await backendIdentity(for: account)
        guard backendAccountID == offer.providerAccountID else {
            throw BankedUsageResetError.accountMismatch
        }
        do {
            return try await redeemOnce(
                account: account,
                offer: offer,
                backendAccountID: backendAccountID,
                idempotencyKey: idempotencyKey,
                isIdempotentRetry: false
            )
        } catch let error as CodexAccountAppServerError where error.mayHaveSentConsume {
            // A lost response is the reason OpenAI's idempotency key exists. A new process and
            // the same key either completes the original attempt or reports already redeemed.
            do {
                return try await redeemOnce(
                    account: account,
                    offer: offer,
                    backendAccountID: backendAccountID,
                    idempotencyKey: idempotencyKey,
                    isIdempotentRetry: true
                )
            } catch let retryError as CodexAccountAppServerError {
                throw retryError.bankedResetError
            }
        } catch let error as CodexAccountAppServerError {
            throw error.bankedResetError
        }
    }

    private func redeemOnce(
        account: AgentAccount,
        offer: BankedUsageResetOffer,
        backendAccountID: String,
        idempotencyKey: String,
        isIdempotentRetry: Bool
    ) async throws -> BankedUsageResetAdapterResult {
        do {
            let response = try await clientFactory().consume(
                account: account,
                expectedBackendAccountID: backendAccountID,
                offer: offer,
                idempotencyKey: idempotencyKey,
                isIdempotentRetry: isIdempotentRetry
            )
            return BankedUsageResetAdapterResult(
                outcome: response.outcome,
                authoritativeUsage: try response.snapshot.normalizedUsage()
            )
        } catch let error as BankedUsageResetError {
            throw error
        }
    }

    private func backendIdentity(for account: AgentAccount) async throws -> String {
        do {
            return try await backendIdentityProvider(account)
        } catch let error as BankedUsageResetError {
            throw error
        } catch {
            throw BankedUsageResetError.accountIdentityUnavailable
        }
    }
}

enum BankedUsageResetCreditSelector {
    static func select(
        from summary: CodexAccountRateLimitsSnapshot.ResetCredits?
    ) -> CodexAccountRateLimitsSnapshot.ResetCredit? {
        summary?.credits?
            .filter { $0.status == "available" && $0.resetType == "codexRateLimits" }
            .sorted { left, right in
                switch (left.expiresAt, right.expiresAt) {
                case let (left?, right?) where left != right: return left < right
                case (nil, .some): return false
                case (.some, nil): return true
                default:
                    if left.grantedAt != right.grantedAt { return left.grantedAt < right.grantedAt }
                    return left.id < right.id
                }
            }
            .first
    }
}

// MARK: - Codex Wire

struct CodexAccountRateLimitsSnapshot: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    struct Credits: Decodable, Sendable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: String?
    }

    struct Bucket: Decodable, Sendable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }

    struct ResetCredit: Decodable, Sendable {
        let id: String
        let title: String?
        let description: String?
        let grantedAt: Double
        let expiresAt: Double?
        let resetType: String
        let status: String
    }

    struct ResetCredits: Decodable, Sendable {
        let availableCount: Int
        let credits: [ResetCredit]?
    }

    let accountId: String?
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: ResetCredits?

    var resetCredits: ResetCredits? { rateLimitResetCredits }

    var eligibleWindowLabels: [String] {
        var labels = [rateLimits.primary, rateLimits.secondary]
            .compactMap(Self.normalize)
            .map(\.label)
        for bucket in (rateLimitsByLimitId ?? [:]).values {
            guard let scope = bucket.limitName, !scope.isEmpty else { continue }
            for window in [bucket.primary, bucket.secondary].compactMap(Self.normalize) {
                labels.append("\(window.label) · \(scope)")
            }
        }
        return Array(Set(labels)).sorted()
    }

    func normalizedUsage() throws -> AccountUsage {
        let windows = [rateLimits.primary, rateLimits.secondary].compactMap(Self.normalize)
        guard !windows.isEmpty else { throw BankedUsageResetError.malformedResponse }

        var usage = AccountUsage(
            windows: windows,
            planLabel: rateLimits.planType?.replacingOccurrences(of: "_", with: " ").capitalized,
            observedAt: Date(),
            source: .api
        )
        usage.modelWindows = (rateLimitsByLimitId ?? [:]).sorted { $0.key < $1.key }
            .compactMap { key, bucket in
                guard bucket.limitId != rateLimits.limitId,
                      let name = bucket.limitName,
                      !name.isEmpty,
                      let window = Self.normalize(bucket.primary) else { return nil }
                return AccountUsage.Window(
                    id: name,
                    label: "\(window.label)\(UsageDefaults.segmentSeparator)\(name)",
                    fraction: window.fraction,
                    resetsAt: window.resetsAt,
                    windowDuration: window.windowDuration,
                    scopeName: name
                )
            }
        usage.resetCredits = rateLimitResetCredits?.availableCount
        usage.resetCreditDetails = (rateLimitResetCredits?.credits ?? []).map { credit in
            AccountUsage.ResetCredit(
                id: credit.id,
                title: credit.title ?? "Limit reset",
                description: credit.description,
                grantedAt: Date(timeIntervalSince1970: credit.grantedAt),
                expiresAt: credit.expiresAt.map(Date.init(timeIntervalSince1970:)),
                status: credit.status,
                resetType: credit.resetType
            )
        }
        if rateLimits.credits?.hasCredits == true,
           let balance = rateLimits.credits?.balance {
            usage.creditBalance = balance
        }
        return usage
    }

    private static func normalize(_ window: Window?) -> AccountUsage.Window? {
        guard let window else { return nil }
        let seconds = window.windowDurationMins.map { $0 * 60 }
        let identity = windowIdentity(seconds: seconds)
        return AccountUsage.Window(
            id: identity.id,
            label: identity.label,
            fraction: min(max(window.usedPercent / 100, 0), 1),
            resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowDuration: seconds
        )
    }

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
        if seconds >= 86_400 {
            let days = Int((seconds / 86_400).rounded())
            return ("\(days)d", "\(days)-day")
        }
        let hours = max(1, Int((seconds / 3_600).rounded()))
        return ("\(hours)h", "\(hours)-hour")
    }
}

enum CodexAccountIdentityReader {
    private struct AuthFile: Decodable {
        struct Tokens: Decodable { let accountId: String? }
        let tokens: Tokens?
    }

    nonisolated static func backendAccountID(for account: AgentAccount) throws -> String {
        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentAccountDefaults.codexAuthMarker)
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: CodexUsageDefaults.authMaxBytes
        ), let auth = try? UsageHTTP.snakeCaseDecoder().decode(AuthFile.self, from: data),
           let id = auth.tokens?.accountId, !id.isEmpty else {
            throw BankedUsageResetError.accountIdentityUnavailable
        }
        return id
    }
}

// MARK: - Short-lived App Server

enum CodexAccountAppServerError: Error, Equatable, Sendable {
    case spawn(String)
    case transport(String, consumeMayHaveBeenSent: Bool)
    case timedOut(consumeMayHaveBeenSent: Bool)
    case exited(Int32, consumeMayHaveBeenSent: Bool)
    case malformed
    case rpc(String)

    var mayHaveSentConsume: Bool {
        switch self {
        case .transport(_, let sent), .timedOut(let sent), .exited(_, let sent): return sent
        case .spawn, .malformed, .rpc: return false
        }
    }

    var bankedResetError: BankedUsageResetError {
        switch self {
        case .rpc(let message) where message.localizedCaseInsensitiveContains("method not found"):
            return .updateCodex
        case .rpc(let message): return .transport(message)
        case .spawn(let message), .transport(let message, _): return .transport(message)
        case .timedOut: return .transport("Codex did not confirm the banked reset in time.")
        case .exited(let status, _): return .transport("Codex exited before confirming the reset (status \(status)).")
        case .malformed: return .malformedResponse
        }
    }
}

struct CodexAccountConsumeResult: Sendable {
    let outcome: BankedUsageResetOutcome
    let snapshot: CodexAccountRateLimitsSnapshot
}

/// Parses the small account RPC vocabulary completely on the transport's bounded worker. The
/// main actor receives only typed Sendable values; it never re-encodes an app-server dictionary
/// merely to decode it again.
enum CodexAccountAppServerEnvelope: Sendable {
    enum Result: Sendable {
        case initialized
        case snapshot(CodexAccountRateLimitsSnapshot)
        case consumed(BankedUsageResetOutcome)
    }

    case response(id: JSONRPCRequestID, result: Result?, error: String?)
    case request(id: JSONRPCRequestID)
    case notification

    static func parse(_ data: Data) -> CodexAccountAppServerEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if object["method"] is String {
            if let id = JSONRPCRequestID(object["id"]) { return .request(id: id) }
            return .notification
        }
        guard let id = JSONRPCRequestID(object["id"]) else { return nil }
        if let error = errorText(object["error"]) {
            return .response(id: id, result: nil, error: error)
        }
        guard let rawResult = object["result"] as? [String: Any] else {
            return .response(id: id, result: nil, error: nil)
        }

        let result: Result?
        switch id {
        case .integer(1):
            result = .initialized
        case .integer(2), .integer(4):
            guard JSONSerialization.isValidJSONObject(rawResult),
                  let encoded = try? JSONSerialization.data(withJSONObject: rawResult),
                  let snapshot = try? JSONDecoder().decode(
                    CodexAccountRateLimitsSnapshot.self,
                    from: encoded
                  ) else { return nil }
            result = .snapshot(snapshot)
        case .integer(3):
            guard let raw = rawResult["outcome"] as? String,
                  let outcome = BankedUsageResetOutcome(rawValue: raw) else { return nil }
            result = .consumed(outcome)
        default:
            result = nil
        }
        return .response(id: id, result: result, error: nil)
    }

    private static func errorText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any] else { return nil }
        return object["message"] as? String ?? JSONRPCLineEnvelope.encodedText(object)
    }
}

@MainActor
protocol CodexAccountAppServerServing: Sendable {
    func read(
        account: AgentAccount,
        expectedBackendAccountID: String
    ) async throws -> CodexAccountRateLimitsSnapshot
    func consume(
        account: AgentAccount,
        expectedBackendAccountID: String,
        offer: BankedUsageResetOffer,
        idempotencyKey: String,
        isIdempotentRetry: Bool
    ) async throws -> CodexAccountConsumeResult
}

@MainActor
final class CodexAccountAppServerClient: CodexAccountAppServerServing {
    private enum Mode {
        case read
        case consume(
            offer: BankedUsageResetOffer,
            idempotencyKey: String,
            isIdempotentRetry: Bool
        )
    }

    private enum Phase {
        case initialize
        case preflight
        case consume
        case postflight
    }

    private enum Output {
        case snapshot(CodexAccountRateLimitsSnapshot)
        case consumed(CodexAccountConsumeResult)
    }

    private var process: CodexAccountChildProcess?
    private var transport: AgentStreamTransport<CodexAccountAppServerEnvelope>?
    private var deadline: ChildProcessDeadline?
    private var continuation: CheckedContinuation<Output, any Error>?
    private var mode: Mode = .read
    private var phase: Phase = .initialize
    private var expectedBackendAccountID = ""
    private var consumeOutcome: BankedUsageResetOutcome?
    private var consumeMayHaveBeenSent = false

    func read(
        account: AgentAccount,
        expectedBackendAccountID: String
    ) async throws -> CodexAccountRateLimitsSnapshot {
        let output = try await perform(
            account: account,
            expectedBackendAccountID: expectedBackendAccountID,
            mode: .read
        )
        guard case .snapshot(let snapshot) = output else {
            throw BankedUsageResetError.malformedResponse
        }
        return snapshot
    }

    func consume(
        account: AgentAccount,
        expectedBackendAccountID: String,
        offer: BankedUsageResetOffer,
        idempotencyKey: String,
        isIdempotentRetry: Bool
    ) async throws -> CodexAccountConsumeResult {
        let output = try await perform(
            account: account,
            expectedBackendAccountID: expectedBackendAccountID,
            mode: .consume(
                offer: offer,
                idempotencyKey: idempotencyKey,
                isIdempotentRetry: isIdempotentRetry
            )
        )
        guard case .consumed(let result) = output else {
            throw BankedUsageResetError.malformedResponse
        }
        return result
    }

    private func perform(
        account: AgentAccount,
        expectedBackendAccountID: String,
        mode: Mode
    ) async throws -> Output {
        self.mode = mode
        self.phase = .initialize
        self.expectedBackendAccountID = expectedBackendAccountID
        consumeOutcome = nil
        consumeMayHaveBeenSent = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            launch(account: account)
        }
    }

    private func launch(account: AgentAccount) {
        let plan = AgentLauncher.codexAccountAppServerPlan(for: account)
        do {
            let process = try CodexAccountChildProcess.launch(plan: plan)
            self.process = process
            let transport = AgentStreamTransport(
                label: "codes.threading.agent.codex-account",
                input: process.standardInput,
                output: process.standardOutput,
                error: process.standardError,
                maximumErrorBytes: CodexStreamDefaults.maximumErrorBytes,
                parser: { CodexAccountAppServerEnvelope.parse($0) },
                onLine: { [weak self] in self?.route($0) },
                onMalformedLine: { [weak self] in self?.fail(.malformed) },
                onFailure: { [weak self] failure in
                    self?.fail(.transport(
                        failure.userFacingDescription,
                        consumeMayHaveBeenSent: self?.consumeMayHaveBeenSent ?? false
                    ))
                }
            )
            self.transport = transport
            deadline = ChildProcessDeadline(
                child: process.child,
                timeout: CodexAccountAppServerDefaults.timeout,
                terminationGrace: BoundedChildDefaults.terminationGrace
            )
            process.child.observeExit { [weak self, weak process] status in
                Task { @MainActor in
                    guard let self, self.process === process else { return }
                    let timedOut = self.deadline?.complete() == true
                    self.fail(timedOut
                        ? .timedOut(consumeMayHaveBeenSent: self.consumeMayHaveBeenSent)
                        : .exited(status, consumeMayHaveBeenSent: self.consumeMayHaveBeenSent))
                }
            }
            transport.start()
            send(id: 1, method: "initialize", parameters: [
                "clientInfo": [
                    "name": "threading",
                    "title": "Threading",
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "development"
                ]
            ])
        } catch {
            fail(.spawn(error.localizedDescription))
        }
    }

    private func route(_ envelope: CodexAccountAppServerEnvelope) {
        switch envelope {
        case .response(let id, let result, let error):
            handleResponse(id: id, result: result, error: error)
        case .request(let id):
            _ = transport?.writeJSONObject([
                "id": id.foundationValue,
                "error": ["code": -32601, "message": "Client method not supported"]
            ])
        case .notification:
            break
        }
    }

    private func handleResponse(
        id: JSONRPCRequestID,
        result: CodexAccountAppServerEnvelope.Result?,
        error: String?
    ) {
        if let error { return fail(.rpc(error)) }
        guard let result else { return fail(.malformed) }

        switch (phase, id) {
        case (.initialize, .integer(1)):
            guard case .initialized = result else { return fail(.malformed) }
            phase = .preflight
            _ = transport?.writeJSONObject(["method": "initialized", "params": [:]])
            send(id: 2, method: "account/rateLimits/read", parameters: [:])

        case (.preflight, .integer(2)):
            guard case .snapshot(let snapshot) = result else { return fail(.malformed) }
            guard verifyAccount(snapshot) else { return }
            switch mode {
            case .read:
                succeed(.snapshot(snapshot))
            case .consume(let offer, let key, let retry):
                if !retry && !offerStillMatches(offer, snapshot: snapshot) {
                    fail(.rpc(BankedUsageResetError.offerChanged.localizedDescription))
                    return
                }
                var parameters: [String: Any] = ["idempotencyKey": key]
                if let creditID = offer.selectedCreditID { parameters["creditId"] = creditID }
                phase = .consume
                consumeMayHaveBeenSent = true
                send(
                    id: 3,
                    method: "account/rateLimitResetCredit/consume",
                    parameters: parameters
                )
            }

        case (.consume, .integer(3)):
            guard case .consumed(let outcome) = result else { return fail(.malformed) }
            consumeOutcome = outcome
            phase = .postflight
            send(id: 4, method: "account/rateLimits/read", parameters: [:])

        case (.postflight, .integer(4)):
            guard case .snapshot(let snapshot) = result else { return fail(.malformed) }
            guard verifyAccount(snapshot) else { return }
            guard let outcome = consumeOutcome else { return fail(.malformed) }
            succeed(.consumed(CodexAccountConsumeResult(
                outcome: outcome,
                snapshot: snapshot
            )))

        default:
            fail(.malformed)
        }
    }

    private func offerStillMatches(
        _ offer: BankedUsageResetOffer,
        snapshot: CodexAccountRateLimitsSnapshot
    ) -> Bool {
        guard snapshot.resetCredits?.availableCount == offer.availableCount else { return false }
        let selected = BankedUsageResetCreditSelector.select(from: snapshot.resetCredits)
        if offer.letsProviderChooseCredit { return selected == nil }
        return selected?.id == offer.selectedCreditID
    }

    private func verifyAccount(_ snapshot: CodexAccountRateLimitsSnapshot) -> Bool {
        guard let accountID = snapshot.accountId, !accountID.isEmpty else {
            fail(.rpc(BankedUsageResetError.accountIdentityUnavailable.localizedDescription))
            return false
        }
        guard accountID == expectedBackendAccountID else {
            fail(.rpc(BankedUsageResetError.accountMismatch.localizedDescription))
            return false
        }
        return true
    }

    private func send(id: Int64, method: String, parameters: [String: Any]) {
        guard transport?.writeJSONObject([
            "id": id,
            "method": method,
            "params": parameters
        ]) == true else {
            fail(.transport(
                "Codex stopped accepting account requests.",
                consumeMayHaveBeenSent: consumeMayHaveBeenSent
            ))
            return
        }
    }

    private func succeed(_ output: Output) {
        guard let continuation else { return }
        self.continuation = nil
        stopProcess()
        continuation.resume(returning: output)
    }

    private func fail(_ error: CodexAccountAppServerError) {
        guard let continuation else { return }
        self.continuation = nil
        stopProcess()
        if case .rpc(let message) = error {
            if message == BankedUsageResetError.offerChanged.localizedDescription {
                continuation.resume(throwing: BankedUsageResetError.offerChanged)
                return
            }
            if message == BankedUsageResetError.accountMismatch.localizedDescription {
                continuation.resume(throwing: BankedUsageResetError.accountMismatch)
                return
            }
            if message == BankedUsageResetError.accountIdentityUnavailable.localizedDescription {
                continuation.resume(throwing: BankedUsageResetError.accountIdentityUnavailable)
                return
            }
        }
        continuation.resume(throwing: error)
    }

    private func stopProcess() {
        _ = deadline?.complete()
        deadline = nil
        transport?.detach()
        transport = nil
        if let process {
            let escalation = ChildProcessEscalation(child: process.child)
            process.child.observeExit { _ in escalation.complete() }
        }
        process = nil
    }
}

private final class CodexAccountChildProcess {
    let child: SpawnedChildProcess
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    private init(
        child: SpawnedChildProcess,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.child = child
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    static func launch(plan: AgentLaunchPlan) throws -> CodexAccountChildProcess {
        let input = try ChildPipe()
        guard fcntl(input.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            let code = errno
            input.closeBothEnds()
            throw AgentChildInputError.noSignalProtectionFailed(code: code)
        }
        let output = try ChildPipe(closingOnFailure: [input])
        let error = try ChildPipe(closingOnFailure: [input, output])

        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: plan.executable),
                arguments: plan.arguments,
                environment: plan.launchEnvironment(),
                workingDirectory: nil,
                descriptors: [
                    0: .inherited(input.readEnd),
                    1: .inherited(output.writeEnd),
                    2: .inherited(error.writeEnd)
                ]
            )
        } catch let spawnError {
            [input, output, error].forEach { $0.closeBothEnds() }
            throw spawnError
        }

        input.closeReadEnd()
        output.closeWriteEnd()
        error.closeWriteEnd()
        return CodexAccountChildProcess(
            child: child,
            standardInput: input.takeWriteHandle(),
            standardOutput: output.takeReadHandle(),
            standardError: error.takeReadHandle()
        )
    }
}

enum CodexAccountAppServerDefaults {
    static let timeout: TimeInterval = 25
}
