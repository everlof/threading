import Foundation

enum UsageLimitSampleSource: String, Codable, Sendable {
    case claudeAPI
    case claudeLocalCache
    case codexAPI
    case codexRollout
    case grokRuntime
    case openCodeRuntime
    case cursorRuntime
}

enum UsageLimitResetCause: String, Codable, Sendable {
    case scheduled
    case bankedCredit
    case provider
}

/// A reset proven by the two surrounding provider observations. The exact reset happened
/// somewhere between `previousObservedAt` and `detectedAt`; the model says that explicitly.
struct UsageLimitResetEvent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let runtimeID: String
    let accountID: String
    let accountName: String
    let windowID: String
    let windowLabel: String
    let previousObservedAt: Date
    let detectedAt: Date
    let oldScheduledResetAt: Date
    let newScheduledResetAt: Date
    let restoredFraction: Double
    let elapsedFraction: Double
    let secondsEarly: TimeInterval
    let cause: UsageLimitResetCause

    var seriesID: String { "\(runtimeID)|\(accountID)|\(windowID)" }
    var paceGainFraction: Double { max(0, restoredFraction - elapsedFraction) }
    var isEarly: Bool { secondsEarly >= UsageLimitHistoryDefaults.scheduledResetTolerance }
}

struct UsageLimitProjection: Equatable, Sendable {
    let observedAt: Date
    let observedFraction: Double
    let resetsAt: Date
    let projectedFractionAtReset: Double
    let projectedExhaustionAt: Date?
    let resetCreditExpiresAt: Date?

    var endpointAt: Date { projectedExhaustionAt ?? resetsAt }
    var endpointFraction: Double { projectedExhaustionAt == nil ? projectedFractionAtReset : 1 }
}

struct UsageLimitHistorySnapshot: Equatable, Sendable {
    let samples: [UsageSample]
    let resets: [UsageLimitResetEvent]
    let loadedAt: Date

    static let empty = Self(samples: [], resets: [], loadedAt: .distantPast)
}

enum UsageLimitHistoryRange: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var label: String { "\(rawValue)d" }

    func start(endingAt end: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: -rawValue, to: end)
            ?? end.addingTimeInterval(TimeInterval(-rawValue * 86_400))
    }
}

struct UsageLimitChartPoint: Equatable, Sendable {
    let sample: UsageSample
    let segment: Int
}

enum UsageLimitHistoryAnalysis {
    /// Require a sharp clear and a moved provider reset. An early Codex clear additionally
    /// requires the banked-credit count to fall; rolling weekly capacity alone is not a reset.
    static func reset(
        between previous: UsageSample,
        and current: UsageSample
    ) -> UsageLimitResetEvent? {
        classifiedReset(
            between: previous,
            and: current,
            acceptsUncreditedCodexProviderClear: false
        )
    }

    /// Evidence strong enough to stop a curfew explicitly armed for this exact series.
    ///
    /// The durable dashboard remains conservative about an early Codex clear with no spent
    /// banked credit because a rolling window can resemble one in long history. A curfew already
    /// names the exact account and window, though, and its job is deliberately stricter: when
    /// that selected counter sharply clears and its provider boundary advances, stop before the
    /// newly restored capacity is spent. The event is delivered live but is not added to the
    /// historical reset ledger unless `reset(between:and:)` also accepts it.
    static func curfewReset(
        between previous: UsageSample,
        and current: UsageSample
    ) -> UsageLimitResetEvent? {
        classifiedReset(
            between: previous,
            and: current,
            acceptsUncreditedCodexProviderClear: true
        )
    }

    private static func classifiedReset(
        between previous: UsageSample,
        and current: UsageSample,
        acceptsUncreditedCodexProviderClear: Bool
    ) -> UsageLimitResetEvent? {
        guard previous.limitSeriesID == current.limitSeriesID,
              let seriesID = previous.limitSeriesID,
              current.at > previous.at,
              let oldReset = previous.resetsAt,
              let newReset = current.resetsAt,
              newReset.timeIntervalSince(oldReset) >= UsageLimitHistoryDefaults.minimumResetAdvance,
              previous.fraction - current.fraction >= UsageLimitHistoryDefaults.minimumResetDrop,
              current.fraction <= max(
                  UsageLimitHistoryDefaults.maximumPostResetFraction,
                  previous.fraction * UsageLimitHistoryDefaults.maximumRemainingRatio
              ),
              let runtimeID = previous.runtimeID,
              let accountID = previous.accountID,
              let windowID = previous.windowID
        else { return nil }

        let duration = normalizedDuration(previous.windowDuration)
            ?? normalizedDuration(current.windowDuration)
            ?? normalizedDuration(newReset.timeIntervalSince(current.at))
        guard let duration else { return nil }

        let earlyBy = max(0, oldReset.timeIntervalSince(current.at))
        let cause: UsageLimitResetCause
        if earlyBy <= UsageLimitHistoryDefaults.scheduledResetTolerance {
            cause = .scheduled
        } else if runtimeID == AgentKind.codex.rawValue {
            if let before = previous.resetCreditCount,
               let after = current.resetCreditCount,
               after < before {
                cause = .bankedCredit
            } else {
                guard acceptsUncreditedCodexProviderClear else { return nil }
                cause = .provider
            }
        } else {
            cause = .provider
        }

        let cycleStart = oldReset.addingTimeInterval(-duration)
        let elapsed = min(max(current.at.timeIntervalSince(cycleStart) / duration, 0), 1)
        let identity = [
            seriesID,
            String(Int(oldReset.timeIntervalSince1970)),
            String(Int(newReset.timeIntervalSince1970))
        ].joined(separator: "|")

        return UsageLimitResetEvent(
            id: stableID(identity),
            runtimeID: runtimeID,
            accountID: accountID,
            accountName: previous.accountName ?? accountID,
            windowID: windowID,
            windowLabel: previous.windowLabel ?? windowID,
            previousObservedAt: previous.at,
            detectedAt: current.at,
            oldScheduledResetAt: oldReset,
            newScheduledResetAt: newReset,
            restoredFraction: previous.fraction,
            elapsedFraction: elapsed,
            secondsEarly: earlyBy,
            cause: cause
        )
    }

    /// A stable weekly projection based on average consumption since the reported cycle start.
    /// Estimated points remain separate from observed samples for honest chart styling.
    static func weeklyProjection(for samples: [UsageSample]) -> UsageLimitProjection? {
        guard let latest = samples.max(by: { $0.at < $1.at }),
              let reset = latest.resetsAt,
              let duration = normalizedDuration(latest.windowDuration),
              UsageLimitHistoryDefaults.weeklyDurationRange.contains(duration),
              reset > latest.at else { return nil }

        let start = reset.addingTimeInterval(-duration)
        let elapsed = latest.at.timeIntervalSince(start)
        guard elapsed >= UsageLimitHistoryDefaults.minimumProjectionSpan else { return nil }

        let rate = latest.fraction / elapsed
        guard rate.isFinite, rate >= 0 else { return nil }
        let atReset = min(1, max(latest.fraction, rate * duration))
        let crossing = rate > 0 ? start.addingTimeInterval(1 / rate) : nil
        let exhaustion = crossing.flatMap { $0 > latest.at && $0 < reset ? $0 : nil }
        let expiry = latest.nextResetCreditExpiresAt.flatMap {
            $0 > latest.at && $0 < reset ? $0 : nil
        }

        return UsageLimitProjection(
            observedAt: latest.at,
            observedFraction: latest.fraction,
            resetsAt: reset,
            projectedFractionAtReset: atReset,
            projectedExhaustionAt: exhaustion,
            resetCreditExpiresAt: expiry
        )
    }

    /// Bounds main-thread chart work while keeping endpoints, local extrema and both sides of
    /// reset discontinuities. It is deterministic so fixture and performance tests can compare.
    static func downsample(_ samples: [UsageSample], maximumCount: Int = 280) -> [UsageSample] {
        guard maximumCount >= 6, samples.count > maximumCount else { return samples }
        let sorted = samples.sorted { $0.at < $1.at }
        var required = Set([0, sorted.count - 1])
        var discontinuities: [(before: Int, after: Int)] = []

        for index in 1..<sorted.count {
            if isDiscontinuity(sorted[index - 1], sorted[index]) {
                discontinuities.append((index - 1, index))
            }
        }

        // A corrupt or synthetic journal can clear on nearly every reading. Keeping every side
        // of every clear would defeat the point budget and move unbounded geometry work onto the
        // main thread. Retain evenly-spaced complete boundary pairs instead; ordinary histories
        // keep every reset because their event count is far below this budget.
        let maximumBoundaryPairs = max(1, (maximumCount - required.count) / 2)
        for pair in evenlySpaced(discontinuities, maximumCount: maximumBoundaryPairs) {
            required.insert(pair.before)
            required.insert(pair.after)
        }

        let available = max(2, maximumCount - required.count)
        let bucketSize = max(1, Int(ceil(Double(sorted.count - 2) / Double(max(1, available / 4)))))
        var lower = 1
        while lower < sorted.count - 1, required.count < maximumCount {
            let upper = min(sorted.count - 1, lower + bucketSize)
            let range = lower..<upper
            let minimum = range.min { sorted[$0].fraction < sorted[$1].fraction } ?? lower
            let maximum = range.max { sorted[$0].fraction < sorted[$1].fraction } ?? lower
            for index in [lower, minimum, maximum, upper - 1] where required.count < maximumCount {
                required.insert(index)
            }
            lower = upper
        }

        return required.sorted().map { sorted[$0] }
    }

    private static func evenlySpaced<Element>(
        _ values: [Element],
        maximumCount: Int
    ) -> [Element] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return [values[values.count / 2]] }

        let last = values.count - 1
        return (0..<maximumCount).map { position in
            let index = Int(
                (Double(position) * Double(last) / Double(maximumCount - 1)).rounded()
            )
            return values[index]
        }
    }

    static func segmented(_ samples: [UsageSample]) -> [UsageLimitChartPoint] {
        let sorted = samples.sorted { $0.at < $1.at }
        var segment = 0
        return sorted.enumerated().map { index, sample in
            if index > 0, isDiscontinuity(sorted[index - 1], sample) { segment += 1 }
            return UsageLimitChartPoint(sample: sample, segment: segment)
        }
    }

    static func isDiscontinuity(_ previous: UsageSample, _ current: UsageSample) -> Bool {
        let cleared = previous.fraction - current.fraction
            >= UsageLimitHistoryDefaults.chartClearDrop
        guard cleared else { return false }
        let resetMoved = zip([previous.resetsAt], [current.resetsAt]).contains { old, new in
            guard let old, let new else { return false }
            return new.timeIntervalSince(old) >= UsageLimitHistoryDefaults.minimumResetAdvance
        }
        return resetMoved || current.fraction <= UsageLimitHistoryDefaults.chartPostClearFraction
    }

    private static func normalizedDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite,
              value > 0,
              value <= UsageLimitHistoryDefaults.maximumWindowDuration else { return nil }
        return value
    }

    private static func stableID(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

enum UsageLimitHistoryDefaults {
    static let retentionDays = 180
    static let maximumLoadedRecords = 250_000
    static let maximumDailyFileBytes = 8 * 1024 * 1024
    static let directoryName = "UsageLimitHistory"
    static let minimumResetAdvance: TimeInterval = 4 * 60
    static let scheduledResetTolerance: TimeInterval = 20 * 60
    static let minimumResetDrop = 0.05
    static let maximumPostResetFraction = 0.08
    static let maximumRemainingRatio = 0.35
    static let chartClearDrop = 0.12
    static let chartPostClearFraction = 0.10
    static let minimumProjectionSpan: TimeInterval = 30 * 60
    static let weeklyDurationRange = (6.0 * 86_400)...(8.0 * 86_400)
    static let maximumWindowDuration: TimeInterval = 365 * 86_400
}
