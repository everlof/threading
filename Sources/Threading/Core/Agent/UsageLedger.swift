import Foundation

// MARK: - Usage Token Counts

/// Provider-neutral token accounting for one priced model response.
///
/// The five fields stay separate all the way to presentation. Cached input is not free, cache
/// creation can have its own rate, and reasoning is a subset of output rather than another pile
/// of tokens to add to it. Collapsing these at ingestion would make both cost and cache-savings
/// impossible to recover honestly later.
struct UsageTokenCounts: Codable, Equatable, Sendable {
    var uncachedInput: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    init(
        uncachedInput: Int64 = 0,
        cachedInput: Int64 = 0,
        cacheWrite: Int64 = 0,
        output: Int64 = 0,
        reasoning: Int64 = 0
    ) {
        self.uncachedInput = max(0, uncachedInput)
        self.cachedInput = max(0, cachedInput)
        self.cacheWrite = max(0, cacheWrite)
        self.output = max(0, output)
        self.reasoning = min(max(0, reasoning), max(0, output))
    }

    /// Some providers report input inclusive of the cached portion. This initializer names that
    /// fact at the adapter boundary so shared code never has to remember which provider does.
    init(
        inputIncludingCached: Int64,
        cachedInput: Int64,
        cacheWrite: Int64 = 0,
        output: Int64,
        reasoning: Int64 = 0
    ) {
        self.init(
            uncachedInput: max(0, inputIncludingCached - cachedInput - cacheWrite),
            cachedInput: cachedInput,
            cacheWrite: cacheWrite,
            output: output,
            reasoning: reasoning
        )
    }

    /// Everything processed by the model. Reasoning is already included in output.
    var processed: Int64 { uncachedInput + cachedInput + cacheWrite + output }

    /// The historical Usage page's definition, retained for window-spend summaries.
    var legacyBilled: Int64 { uncachedInput + cacheWrite + output }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

// MARK: - Ledger Provenance

/// How the monetary value beside a record was obtained.
enum UsageCostSource: String, Codable, Sendable {
    /// The runtime or billing route stated the amount for this response.
    case providerReported
    /// Threading applied one exact, versioned model rate from an official provider source.
    case catalogPriced
    /// Tokens are known but no exact, authoritative rate matched.
    case unpriced
}

/// One runtime may route to a different company for inference. OpenCode using OpenRouter is the
/// motivating case: the runtime owns the session and transcript while OpenRouter owns the bill.
struct UsageOrigin: Codable, Equatable, Hashable, Sendable {
    let runtimeID: String
    let runtimeName: String
    let billingProviderID: String
    let billingProviderName: String

    var seriesID: String { "\(runtimeID)|\(billingProviderID)" }

    var seriesName: String {
        if isDirectRuntimeRoute || runtimeID == billingProviderID { return runtimeName }
        if runtimeID == AgentKind.openCode.rawValue { return billingProviderName }
        return "\(runtimeName) · \(billingProviderName)"
    }

    private var isDirectRuntimeRoute: Bool {
        switch AgentKind(rawValue: runtimeID) {
        case .claude: return billingProviderID == "anthropic"
        case .codex: return billingProviderID == "openai"
        case .grok: return billingProviderID == "xai"
        case .openCode: return billingProviderID == "opencode"
        case nil: return false
        }
    }

    static func direct(_ runtime: AgentKind) -> Self {
        let billing: (String, String)
        switch runtime {
        case .claude: billing = ("anthropic", "Claude")
        case .codex: billing = ("openai", "Codex")
        case .grok: billing = ("xai", "Grok")
        case .openCode: billing = ("opencode", "OpenCode")
        }
        return Self(
            runtimeID: runtime.rawValue,
            runtimeName: runtime.displayName,
            billingProviderID: billing.0,
            billingProviderName: billing.1
        )
    }

    static func openCode(providerID: String) -> Self {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = normalized.isEmpty ? "opencode" : normalized
        let name: String
        switch id {
        case "openrouter": name = "OpenRouter"
        case "anthropic": name = "Anthropic via OpenCode"
        case "openai": name = "OpenAI via OpenCode"
        case "xai": name = "xAI via OpenCode"
        case "opencode", "zen": name = "OpenCode"
        default: name = providerID.isEmpty ? "OpenCode" : providerID
        }
        return Self(
            runtimeID: AgentKind.openCode.rawValue,
            runtimeName: AgentKind.openCode.displayName,
            billingProviderID: id,
            billingProviderName: name
        )
    }
}

/// One distinct model response before aggregation.
///
/// Cached file records retain `identity`; global deduplication is deliberately performed after
/// all cache hits and misses have been joined. That is what makes an incremental scan as exact as
/// a cold scan when Claude copied a response into a resume, compaction, or fork.
struct UsageLedgerRecord: Codable, Equatable, Sendable {
    let identity: String
    let sessionID: String
    let at: Date?
    let origin: UsageOrigin
    let accountID: String
    let accountName: String
    let model: String
    let workingDirectory: String
    let tokens: UsageTokenCounts
    let reportedCostUSD: Double?

    var costUSD: Double?
    var costSource: UsageCostSource
    var cacheSavingsUSD: Double

    init(
        identity: String,
        sessionID: String,
        at: Date?,
        origin: UsageOrigin,
        accountID: String,
        accountName: String,
        model: String,
        workingDirectory: String,
        tokens: UsageTokenCounts,
        reportedCostUSD: Double? = nil,
        costUSD: Double? = nil,
        costSource: UsageCostSource = .unpriced,
        cacheSavingsUSD: Double = 0
    ) {
        self.identity = identity
        self.sessionID = sessionID
        self.at = at
        self.origin = origin
        self.accountID = accountID
        self.accountName = accountName
        self.model = model
        self.workingDirectory = workingDirectory
        self.tokens = tokens
        self.reportedCostUSD = reportedCostUSD
        self.costUSD = costUSD
        self.costSource = costSource
        self.cacheSavingsUSD = max(0, cacheSavingsUSD)
    }
}

// MARK: - Coverage

enum UsageCoverageState: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
    case failed
}

/// The report never hides a runtime merely because no authoritative token source exists. A
/// partial or unavailable source is itself useful information and prevents a plausible-looking
/// total from being mistaken for whole-machine spend.
struct UsageSourceCoverage: Codable, Equatable, Sendable {
    let runtimeID: String
    let runtimeName: String
    var state: UsageCoverageState
    var sourceCount: Int
    var recordCount: Int
    var detail: String?
}

// MARK: - Pricing

/// One official list-price row, in US dollars per million tokens.
struct UsageModelRate: Equatable, Sendable {
    let providerID: String
    let model: String
    let input: Double
    let cachedInput: Double?
    let cacheWrite: Double?
    let output: Double
    let longContextThreshold: Int64?

    init(
        providerID: String,
        model: String,
        input: Double,
        cachedInput: Double?,
        cacheWrite: Double?,
        output: Double,
        longContextThreshold: Int64? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
        self.longContextThreshold = longContextThreshold
    }
}

/// Original, small and explicit price catalog.
///
/// This is intentionally not a copied community rate dump. Exact identifiers are maintained
/// from official provider pricing and ambiguous aliases remain unpriced. The version appears in
/// the Usage page so an estimate never masquerades as an invoice.
enum UsagePricingCatalog {
    static let version = "2026-08-09"
    static let sourceDescription = "Official provider list prices checked 9 Aug 2026"

    /// OpenAI standard-processing rows from the official API pricing page. The exact-match rule
    /// below also accepts `YYYY-MM-DD` snapshots of these stable model identifiers.
    private static let rates: [UsageModelRate] = [
        .init(providerID: "openai", model: "gpt-5.6-sol", input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 30, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.6-terra", input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 12, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.6-luna", input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 1.2, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.5", input: 5, cachedInput: 0.5, cacheWrite: nil, output: 30, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.4", input: 2.5, cachedInput: 0.25, cacheWrite: nil, output: 15, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.4-mini", input: 0.75, cachedInput: 0.075, cacheWrite: nil, output: 4.5),
        .init(providerID: "openai", model: "gpt-5.4-nano", input: 0.2, cachedInput: 0.02, cacheWrite: nil, output: 1.25),
        .init(providerID: "openai", model: "gpt-5.2", input: 1.75, cachedInput: 0.175, cacheWrite: nil, output: 14),
        .init(providerID: "openai", model: "gpt-5.1", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-5", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-5-mini", input: 0.25, cachedInput: 0.025, cacheWrite: nil, output: 2),
        .init(providerID: "openai", model: "gpt-5-nano", input: 0.05, cachedInput: 0.005, cacheWrite: nil, output: 0.4),
        .init(providerID: "openai", model: "gpt-4.1", input: 2, cachedInput: 0.5, cacheWrite: nil, output: 8),
        .init(providerID: "openai", model: "gpt-4.1-mini", input: 0.4, cachedInput: 0.1, cacheWrite: nil, output: 1.6),
        .init(providerID: "openai", model: "gpt-4.1-nano", input: 0.1, cachedInput: 0.025, cacheWrite: nil, output: 0.4),
        .init(providerID: "openai", model: "gpt-4o", input: 2.5, cachedInput: 1.25, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-4o-mini", input: 0.15, cachedInput: 0.075, cacheWrite: nil, output: 0.6),
        .init(providerID: "openai", model: "o3", input: 2, cachedInput: 0.5, cacheWrite: nil, output: 8),
        .init(providerID: "openai", model: "o4-mini", input: 1.1, cachedInput: 0.275, cacheWrite: nil, output: 4.4)
    ]

    static func price(_ record: UsageLedgerRecord) -> UsageLedgerRecord {
        var priced = record

        if let reported = record.reportedCostUSD, reported.isFinite, reported >= 0 {
            priced.costUSD = reported
            priced.costSource = .providerReported
            // A provider-reported total is authoritative, but it does not reveal the
            // counterfactual uncached price needed for cache savings.
            priced.cacheSavingsUSD = 0
            return priced
        }

        guard let rate = rate(providerID: record.origin.billingProviderID, model: record.model) else {
            priced.costUSD = nil
            priced.costSource = .unpriced
            priced.cacheSavingsUSD = 0
            return priced
        }

        let million = 1_000_000.0
        // OpenAI's 1.05M-context models apply their long-context tier to the whole request when
        // total input (uncached + cached + cache write) exceeds 272K tokens. Consume a remaining
        // allowance instead of summing Int64 values so even malformed, enormous counts cannot
        // overflow while deciding the tier.
        let isLongContext = rate.longContextThreshold.map { threshold in
            exceeds(
                threshold: threshold,
                record.tokens.uncachedInput,
                record.tokens.cachedInput,
                record.tokens.cacheWrite
            )
        } ?? false
        let inputMultiplier = isLongContext ? 2.0 : 1.0
        let outputMultiplier = isLongContext ? 1.5 : 1.0

        let input = Double(record.tokens.uncachedInput) * rate.input * inputMultiplier / million
        let cachedRate = rate.cachedInput ?? rate.input
        let cached = Double(record.tokens.cachedInput) * cachedRate * inputMultiplier / million
        let cacheWriteRate = rate.cacheWrite ?? rate.input
        let writes = Double(record.tokens.cacheWrite) * cacheWriteRate * inputMultiplier / million
        let output = Double(record.tokens.output) * rate.output * outputMultiplier / million

        priced.costUSD = input + cached + writes + output
        priced.costSource = .catalogPriced
        priced.cacheSavingsUSD = max(
            0,
            Double(record.tokens.cachedInput)
                * (rate.input - cachedRate)
                * inputMultiplier
                / million
        )
        return priced
    }

    private static func exceeds(
        threshold: Int64,
        _ uncachedInput: Int64,
        _ cachedInput: Int64,
        _ cacheWrite: Int64
    ) -> Bool {
        var remaining = threshold
        if uncachedInput > remaining { return true }
        remaining -= uncachedInput
        if cachedInput > remaining { return true }
        remaining -= cachedInput
        if cacheWrite > remaining { return true }
        return false
    }

    static func rate(providerID: String, model: String) -> UsageModelRate? {
        let provider = providerID.lowercased()
        let normalizedModel = model.lowercased()

        // Longest exact prefix wins: gpt-5.4-mini must not be priced as gpt-5.4.
        return rates
            .filter { rate in
                rate.providerID == provider
                    && isExactOrDatedSnapshot(normalizedModel, of: rate.model)
            }
            .max { $0.model.count < $1.model.count }
    }

    private static func isExactOrDatedSnapshot(_ candidate: String, of model: String) -> Bool {
        if candidate == model { return true }

        let prefix = model + "-"
        guard candidate.hasPrefix(prefix) else { return false }
        let components = candidate.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2
        else { return false }
        return components.allSatisfy { component in
            component.utf8.allSatisfy { byte in byte >= 48 && byte <= 57 }
        }
    }
}

// MARK: - Date Keys

enum UsageLedgerDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ value: String) -> Date? {
        (try? fractional.parse(value)) ?? (try? plain.parse(value))
    }

    static func dayStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func quarterHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(seconds / 900) * 900)
    }
}
