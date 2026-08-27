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
    /// The one-hour portion of `cacheWrite`; the remainder uses the ordinary five-minute rate.
    /// Kept as a subset so presentation and transport can retain one aggregate cache-write total.
    var cacheWrite1h: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    init(
        uncachedInput: Int64 = 0,
        cachedInput: Int64 = 0,
        cacheWrite: Int64 = 0,
        cacheWrite1h: Int64 = 0,
        output: Int64 = 0,
        reasoning: Int64 = 0
    ) {
        self.uncachedInput = max(0, uncachedInput)
        self.cachedInput = max(0, cachedInput)
        self.cacheWrite = max(0, cacheWrite)
        self.cacheWrite1h = min(max(0, cacheWrite1h), self.cacheWrite)
        self.output = max(0, output)
        self.reasoning = min(max(0, reasoning), max(0, output))
    }

    /// Some providers report input inclusive of the cached portion. This initializer names that
    /// fact at the adapter boundary so shared code never has to remember which provider does.
    init(
        inputIncludingCached: Int64,
        cachedInput: Int64,
        cacheWrite: Int64 = 0,
        cacheWrite1h: Int64 = 0,
        output: Int64,
        reasoning: Int64 = 0
    ) {
        self.init(
            uncachedInput: max(0, inputIncludingCached - cachedInput - cacheWrite),
            cachedInput: cachedInput,
            cacheWrite: cacheWrite,
            cacheWrite1h: cacheWrite1h,
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
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    /// Streaming providers may repeat one response identity while its counters are still growing.
    /// Component-wise maxima retain the completed counters without assuming every field changes
    /// in lockstep or allowing a later copied partial to reduce an already observed total.
    func mergingMaximums(with other: Self) -> Self {
        Self(
            uncachedInput: max(uncachedInput, other.uncachedInput),
            cachedInput: max(cachedInput, other.cachedInput),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
            output: max(output, other.output),
            reasoning: max(reasoning, other.reasoning)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case uncachedInput
        case cachedInput
        case cacheWrite
        case cacheWrite1h
        case output
        case reasoning
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uncachedInput: try values.decodeIfPresent(Int64.self, forKey: .uncachedInput) ?? 0,
            cachedInput: try values.decodeIfPresent(Int64.self, forKey: .cachedInput) ?? 0,
            cacheWrite: try values.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0,
            cacheWrite1h: try values.decodeIfPresent(Int64.self, forKey: .cacheWrite1h) ?? 0,
            output: try values.decodeIfPresent(Int64.self, forKey: .output) ?? 0,
            reasoning: try values.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(uncachedInput, forKey: .uncachedInput)
        try values.encode(cachedInput, forKey: .cachedInput)
        try values.encode(cacheWrite, forKey: .cacheWrite)
        try values.encode(cacheWrite1h, forKey: .cacheWrite1h)
        try values.encode(output, forKey: .output)
        try values.encode(reasoning, forKey: .reasoning)
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
        case .cursor: return billingProviderID == "cursor"
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
        case .cursor: billing = ("cursor", "Cursor")
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

    /// Preserve last-wins provenance while making repeated streaming counters monotonic.
    func mergingUsageMaximums(with later: Self) -> Self {
        precondition(identity == later.identity)
        let reported = [reportedCostUSD, later.reportedCostUSD]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 >= 0 }
            .max()

        return Self(
            identity: later.identity,
            sessionID: later.sessionID,
            at: later.at,
            origin: later.origin,
            accountID: later.accountID,
            accountName: later.accountName,
            model: later.model,
            workingDirectory: later.workingDirectory,
            tokens: tokens.mergingMaximums(with: later.tokens),
            reportedCostUSD: reported
        )
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
    let cacheWrite1h: Double?
    let output: Double
    let longContextThreshold: Int64?

    init(
        providerID: String,
        model: String,
        input: Double,
        cachedInput: Double?,
        cacheWrite: Double?,
        cacheWrite1h: Double? = nil,
        output: Double,
        longContextThreshold: Int64? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
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
    static let version = "2026-08-28"
    static let sourceDescription = "Official provider list prices checked 28 Aug 2026"

    /// Standard, global-processing rows from the providers' official API pricing pages. The
    /// exact-match rule below also accepts their dated snapshots without accepting feature names.
    private static let rates: [UsageModelRate] = [
        anthropicRate(model: "claude-fable-5", input: 10, output: 50),
        anthropicRate(model: "claude-mythos-5", input: 10, output: 50),
        anthropicRate(model: "claude-opus-5", input: 5, output: 25),
        anthropicRate(model: "claude-opus-4-8", input: 5, output: 25),
        anthropicRate(model: "claude-opus-4-7", input: 5, output: 25),
        anthropicRate(model: "claude-opus-4-6", input: 5, output: 25),
        anthropicRate(model: "claude-opus-4-5", input: 5, output: 25),
        anthropicRate(model: "claude-opus-4-1", input: 15, output: 75),
        anthropicRate(model: "claude-opus-4", input: 15, output: 75),
        anthropicRate(model: "claude-sonnet-5", input: 2, output: 10),
        anthropicRate(model: "claude-sonnet-4-6", input: 3, output: 15),
        anthropicRate(model: "claude-sonnet-4-5", input: 3, output: 15),
        anthropicRate(model: "claude-sonnet-4", input: 3, output: 15),
        anthropicRate(model: "claude-haiku-4-5", input: 1, output: 5),
        anthropicRate(model: "claude-3-5-haiku", input: 0.8, output: 4),
        .init(providerID: "openai", model: "gpt-5.6-sol", input: 4, cachedInput: 0.4, cacheWrite: 5, output: 20, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.6-terra", input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 12, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.6-luna", input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 1.2, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.5", input: 5, cachedInput: 0.5, cacheWrite: nil, output: 30, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.4", input: 2.5, cachedInput: 0.25, cacheWrite: nil, output: 15, longContextThreshold: 272_000),
        .init(providerID: "openai", model: "gpt-5.4-mini", input: 0.75, cachedInput: 0.075, cacheWrite: nil, output: 4.5),
        .init(providerID: "openai", model: "gpt-5.4-nano", input: 0.2, cachedInput: 0.02, cacheWrite: nil, output: 1.25),
        .init(providerID: "openai", model: "gpt-5.3-codex", input: 1.75, cachedInput: 0.175, cacheWrite: nil, output: 14),
        .init(providerID: "openai", model: "gpt-5.2-codex", input: 1.75, cachedInput: 0.175, cacheWrite: nil, output: 14),
        .init(providerID: "openai", model: "gpt-5.2", input: 1.75, cachedInput: 0.175, cacheWrite: nil, output: 14),
        .init(providerID: "openai", model: "gpt-5.1-codex-max", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-5.1-codex-mini", input: 0.25, cachedInput: 0.025, cacheWrite: nil, output: 2),
        .init(providerID: "openai", model: "gpt-5.1-codex", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-5.1", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
        .init(providerID: "openai", model: "gpt-5-codex", input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10),
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

    private static func anthropicRate(
        model: String,
        input: Double,
        output: Double
    ) -> UsageModelRate {
        UsageModelRate(
            providerID: "anthropic",
            model: model,
            input: input,
            cachedInput: input * 0.1,
            cacheWrite: input * 1.25,
            cacheWrite1h: input * 2,
            output: output
        )
    }

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
        let oneHourWrites = record.tokens.cacheWrite1h
        let ordinaryWrites = record.tokens.cacheWrite - oneHourWrites
        let writes = (
            Double(ordinaryWrites) * cacheWriteRate
                + Double(oneHourWrites) * (rate.cacheWrite1h ?? cacheWriteRate)
        ) * inputMultiplier / million
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
        let suffix = candidate.dropFirst(prefix.count)
        if suffix.count == 8, suffix.utf8.allSatisfy({ byte in byte >= 48 && byte <= 57 }) {
            return true
        }
        let components = suffix.split(separator: "-", omittingEmptySubsequences: false)
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
