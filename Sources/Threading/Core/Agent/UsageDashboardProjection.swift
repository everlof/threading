import Foundation

/// Named output budgets for the Usage presentation boundary. Source scans may be much larger,
/// but neither AppKit nor a future wire bridge receives those externally-sized collections.
enum UsageDashboardProjectionDefaults {
    static let overviewRanges = [7, 30, 90]
    static let maximumBreakdownRows = 500
    static let maximumLimitSeries = 256
    static let maximumLimitSamplesPerRange = 280
    static let maximumLimitMarkersPerRange = 118
    static let cancellationStride = 4_096
}

enum UsageDashboardMetric: Int, CaseIterable, Sendable {
    case cost
    case tokens
}

enum UsageDashboardBreakdownKind: Int, CaseIterable, Sendable {
    case models
    case projects
    case accounts
    case providers
}

struct UsageDashboardBreakdownRowProjection: Equatable, Sendable {
    let title: String
    let tokens: Int64
    let costUSD: Double
    let records: Int
}

struct UsageDashboardBreakdownProjection: Equatable, Sendable {
    let rows: [UsageDashboardBreakdownRowProjection]
    let omittedRowCount: Int
    let omittedTokens: Int64
    let omittedCostUSD: Double
    let omittedRecords: Int
}

struct UsageDashboardProviderProjection: Equatable, Sendable {
    let origin: UsageOrigin
    let tokens: UsageTokenCounts
    let costUSD: Double
    let records: Int
    let styleIndex: Int
}

struct UsageDashboardChartPointProjection: Equatable, Sendable {
    let at: Date
    let value: Double
}

struct UsageDashboardChartSeriesProjection: Equatable, Sendable {
    let id: String
    let title: String?
    let isOther: Bool
    let styleIndex: Int
    let points: [UsageDashboardChartPointProjection]
}

struct UsageDashboardMetricProjection: Equatable, Sendable {
    let providers: [UsageDashboardProviderProjection]
    let chartSeries: [UsageDashboardChartSeriesProjection]
}

struct UsageDashboardRangeProjection: Equatable, Sendable {
    let days: Int
    let start: Date
    let end: Date
    let tokens: UsageTokenCounts
    let records: Int
    let cost: UsageReportSelection.CostQuality
    let activeDayCount: Int
    let costMetric: UsageDashboardMetricProjection
    let tokenMetric: UsageDashboardMetricProjection
    let breakdowns: [UsageDashboardBreakdownKind: UsageDashboardBreakdownProjection]

    func metric(_ metric: UsageDashboardMetric) -> UsageDashboardMetricProjection {
        switch metric {
        case .cost: return costMetric
        case .tokens: return tokenMetric
        }
    }

    func breakdown(_ kind: UsageDashboardBreakdownKind) -> UsageDashboardBreakdownProjection {
        breakdowns[kind] ?? .init(
            rows: [],
            omittedRowCount: 0,
            omittedTokens: 0,
            omittedCostUSD: 0,
            omittedRecords: 0
        )
    }
}

/// Immutable, Foundation-only Overview input. Preparing it is O(report cells) on a utility task;
/// presenting or changing metric/range is O(the bounded values retained here).
struct UsageDashboardOverviewProjection: Equatable, Sendable {
    let ranges: [UsageDashboardRangeProjection]
    let coverage: [UsageSourceCoverage]
    let builtAt: Date
    let pricingCatalogVersion: String

    func range(days: Int) -> UsageDashboardRangeProjection? {
        ranges.first { $0.days == days }
    }
}

struct UsageLimitDashboardRangeProjection: Equatable, Sendable {
    let days: Int
    let start: Date
    let end: Date
    let observed: [UsageLimitChartPoint]
    let resetMarkers: [UsageLimitResetEvent]
    let resetCount: Int
    let restoredPaceFraction: Double
}

/// The dashboard's provider-neutral, bounded view of one metered window. Observations and
/// classified events are prepared off-main; the chart only decides how to ink them.
struct UsageLimitDashboardSeries: Equatable, Sendable, Identifiable {
    let id: String
    let runtimeName: String
    let accountName: String
    let windowLabel: String
    let ranges: [UsageLimitDashboardRangeProjection]
    let projection: UsageLimitProjection?
    let currentFraction: Double?
    let resetsAt: Date?
    let resetCreditCount: Int?
    let nextResetCreditExpiresAt: Date?

    var title: String { "\(runtimeName) · \(accountName) · \(windowLabel)" }

    func range(days: Int) -> UsageLimitDashboardRangeProjection? {
        ranges.first { $0.days == days }
    }

    /// Compatibility initializer for deterministic design/test fixtures. Production history
    /// uses `UsageDashboardProjector.limits`, which performs this work on a utility task.
    init(
        id: String,
        runtimeName: String,
        accountName: String,
        windowLabel: String,
        samples: [UsageSample],
        resets: [UsageLimitResetEvent],
        projection: UsageLimitProjection?,
        currentFraction: Double?,
        resetsAt: Date?,
        resetCreditCount: Int?,
        nextResetCreditExpiresAt: Date?
    ) {
        self.init(
            id: id,
            runtimeName: runtimeName,
            accountName: accountName,
            windowLabel: windowLabel,
            ranges: UsageDashboardProjector.limitRanges(
                samples: samples,
                resets: resets,
                now: Date()
            ),
            projection: projection,
            currentFraction: currentFraction,
            resetsAt: resetsAt,
            resetCreditCount: resetCreditCount,
            nextResetCreditExpiresAt: nextResetCreditExpiresAt
        )
    }

    init(
        id: String,
        runtimeName: String,
        accountName: String,
        windowLabel: String,
        ranges: [UsageLimitDashboardRangeProjection],
        projection: UsageLimitProjection?,
        currentFraction: Double?,
        resetsAt: Date?,
        resetCreditCount: Int?,
        nextResetCreditExpiresAt: Date?
    ) {
        self.id = id
        self.runtimeName = runtimeName
        self.accountName = accountName
        self.windowLabel = windowLabel
        self.ranges = ranges
        self.projection = projection
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
        self.resetCreditCount = resetCreditCount
        self.nextResetCreditExpiresAt = nextResetCreditExpiresAt
    }
}

struct UsageLimitDashboardProjection: Equatable, Sendable {
    let series: [UsageLimitDashboardSeries]
    let omittedSeriesCount: Int
    let preparedAt: Date

    static let empty = Self(series: [], omittedSeriesCount: 0, preparedAt: .distantPast)
}

struct UsageLimitDashboardSeriesSummaryProjection: Equatable, Sendable, Identifiable {
    let id: String
    let runtimeName: String
    let accountName: String
    let windowLabel: String
    let currentFraction: Double?
    let resetsAt: Date?
    let resetCreditCount: Int?
    let nextResetCreditExpiresAt: Date?

    var title: String { "\(runtimeName) · \(accountName) · \(windowLabel)" }
}

struct UsageLimitDashboardIndexProjection: Equatable, Sendable {
    let series: [UsageLimitDashboardSeriesSummaryProjection]
    let omittedSeriesCount: Int
    let preparedAt: Date
}

enum UsageDashboardProjector {
    nonisolated static func overview(
        report: TranscriptUsageReport,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageDashboardOverviewProjection? {
        var ranges: [UsageDashboardRangeProjection] = []
        ranges.reserveCapacity(UsageDashboardProjectionDefaults.overviewRanges.count)
        for days in UsageDashboardProjectionDefaults.overviewRanges {
            guard !Task.isCancelled else { return nil }
            let selection = report.selection(days: days, now: now, calendar: calendar)
            ranges.append(overviewRange(selection, calendar: calendar))
        }
        return UsageDashboardOverviewProjection(
            ranges: ranges,
            coverage: report.coverage,
            builtAt: report.builtAt,
            pricingCatalogVersion: report.pricingCatalogVersion
        )
    }

    nonisolated static func limits(
        from snapshot: UsageLimitHistorySnapshot,
        now: Date? = nil
    ) -> UsageLimitDashboardProjection {
        let preparedAt = now ?? snapshot.loadedAt
        var samplesBySeries: [String: [UsageSample]] = [:]
        for (index, sample) in snapshot.samples.enumerated() {
            if index.isMultiple(of: UsageDashboardProjectionDefaults.cancellationStride),
               Task.isCancelled { return .empty }
            guard let id = sample.limitSeriesID else { continue }
            samplesBySeries[id, default: []].append(sample)
        }

        let candidates = samplesBySeries.compactMap { id, samples -> (String, [UsageSample], Date)? in
            guard let latest = samples.max(by: { $0.at < $1.at }) else { return nil }
            return (id, samples, latest.at)
        }.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0 < rhs.0
        }
        let retained = Array(candidates.prefix(UsageDashboardProjectionDefaults.maximumLimitSeries))
        let retainedIDs = Set(retained.map(\.0))

        var resetsBySeries: [String: [UsageLimitResetEvent]] = [:]
        for (index, event) in snapshot.resets.enumerated() {
            if index.isMultiple(of: UsageDashboardProjectionDefaults.cancellationStride),
               Task.isCancelled { return .empty }
            guard retainedIDs.contains(event.seriesID) else { continue }
            resetsBySeries[event.seriesID, default: []].append(event)
        }

        var result: [UsageLimitDashboardSeries] = []
        result.reserveCapacity(retained.count)
        for (index, candidate) in retained.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return .empty }
            let (id, rawSamples, _) = candidate
            let samples = rawSamples.sorted { $0.at < $1.at }
            guard let latest = samples.last,
                  let runtimeID = latest.runtimeID,
                  let accountID = latest.accountID,
                  let windowID = latest.windowID else { continue }
            let events = (resetsBySeries[id] ?? []).sorted { $0.detectedAt < $1.detectedAt }
            result.append(UsageLimitDashboardSeries(
                id: id,
                runtimeName: AgentKind(rawValue: runtimeID)?.displayName ?? runtimeID,
                accountName: latest.accountName ?? accountID,
                windowLabel: latest.windowLabel ?? windowID,
                ranges: limitRanges(samples: samples, resets: events, now: preparedAt),
                projection: UsageLimitHistoryAnalysis.weeklyProjection(for: samples),
                currentFraction: latest.fraction,
                resetsAt: latest.resetsAt,
                resetCreditCount: latest.resetCreditCount,
                nextResetCreditExpiresAt: latest.nextResetCreditExpiresAt
            ))
        }

        return UsageLimitDashboardProjection(
            series: result.sorted { $0.title < $1.title },
            omittedSeriesCount: max(0, candidates.count - retained.count),
            preparedAt: preparedAt
        )
    }

    /// Prepares only the bounded account/window chooser used by the remote overview response.
    /// It deliberately does not construct chart samples for entries the client has not opened.
    nonisolated static func limitIndex(
        from snapshot: UsageLimitHistorySnapshot,
        now: Date? = nil
    ) -> UsageLimitDashboardIndexProjection {
        let preparedAt = now ?? snapshot.loadedAt
        var latestBySeries: [String: UsageSample] = [:]
        for (index, sample) in snapshot.samples.enumerated() {
            if index.isMultiple(of: UsageDashboardProjectionDefaults.cancellationStride),
               Task.isCancelled {
                return .init(series: [], omittedSeriesCount: 0, preparedAt: preparedAt)
            }
            guard let id = sample.limitSeriesID else { continue }
            if let existing = latestBySeries[id], existing.at >= sample.at { continue }
            latestBySeries[id] = sample
        }

        let candidates = latestBySeries.compactMap { id, latest
            -> UsageLimitDashboardSeriesSummaryProjection? in
            guard let runtimeID = latest.runtimeID,
                  let accountID = latest.accountID,
                  let windowID = latest.windowID else { return nil }
            return UsageLimitDashboardSeriesSummaryProjection(
                id: id,
                runtimeName: AgentKind(rawValue: runtimeID)?.displayName ?? runtimeID,
                accountName: latest.accountName ?? accountID,
                windowLabel: latest.windowLabel ?? windowID,
                currentFraction: latest.fraction,
                resetsAt: latest.resetsAt,
                resetCreditCount: latest.resetCreditCount,
                nextResetCreditExpiresAt: latest.nextResetCreditExpiresAt
            )
        }.sorted { lhs, rhs in
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
        let retained = Array(candidates.prefix(
            UsageDashboardProjectionDefaults.maximumLimitSeries
        ))
        return UsageLimitDashboardIndexProjection(
            series: retained,
            omittedSeriesCount: max(0, candidates.count - retained.count),
            preparedAt: preparedAt
        )
    }

    /// Prepares one selected account/window. The source scan is off-main and the returned range
    /// stays within the same sample/marker budgets as the macOS renderer.
    nonisolated static func limitSeries(
        from snapshot: UsageLimitHistorySnapshot,
        seriesID: String,
        now: Date? = nil
    ) -> UsageLimitDashboardSeries? {
        let preparedAt = now ?? snapshot.loadedAt
        var samples: [UsageSample] = []
        for (index, sample) in snapshot.samples.enumerated() {
            if index.isMultiple(of: UsageDashboardProjectionDefaults.cancellationStride),
               Task.isCancelled { return nil }
            guard sample.limitSeriesID == seriesID else { continue }
            samples.append(sample)
        }
        samples.sort { $0.at < $1.at }
        guard let latest = samples.last,
              let runtimeID = latest.runtimeID,
              let accountID = latest.accountID,
              let windowID = latest.windowID else { return nil }

        var resets: [UsageLimitResetEvent] = []
        for (index, event) in snapshot.resets.enumerated() {
            if index.isMultiple(of: UsageDashboardProjectionDefaults.cancellationStride),
               Task.isCancelled { return nil }
            guard event.seriesID == seriesID else { continue }
            resets.append(event)
        }
        resets.sort { $0.detectedAt < $1.detectedAt }

        return UsageLimitDashboardSeries(
            id: seriesID,
            runtimeName: AgentKind(rawValue: runtimeID)?.displayName ?? runtimeID,
            accountName: latest.accountName ?? accountID,
            windowLabel: latest.windowLabel ?? windowID,
            ranges: limitRanges(samples: samples, resets: resets, now: preparedAt),
            projection: UsageLimitHistoryAnalysis.weeklyProjection(for: samples),
            currentFraction: latest.fraction,
            resetsAt: latest.resetsAt,
            resetCreditCount: latest.resetCreditCount,
            nextResetCreditExpiresAt: latest.nextResetCreditExpiresAt
        )
    }

    fileprivate nonisolated static func limitRanges(
        samples: [UsageSample],
        resets: [UsageLimitResetEvent],
        now: Date
    ) -> [UsageLimitDashboardRangeProjection] {
        UsageDashboardProjectionDefaults.overviewRanges.map { days in
            let start = now.addingTimeInterval(TimeInterval(-days) * 86_400)
            let observed = UsageLimitHistoryAnalysis.downsample(
                samples.filter { $0.at >= start && $0.at <= now },
                maximumCount: UsageDashboardProjectionDefaults.maximumLimitSamplesPerRange
            )
            let events = resets.filter { $0.detectedAt >= start && $0.detectedAt <= now }
            return UsageLimitDashboardRangeProjection(
                days: days,
                start: start,
                end: now,
                observed: UsageLimitHistoryAnalysis.segmented(observed),
                resetMarkers: evenlySpaced(
                    events,
                    maximumCount: UsageDashboardProjectionDefaults.maximumLimitMarkersPerRange
                ),
                resetCount: events.count,
                restoredPaceFraction: events.reduce(0) { $0 + $1.paceGainFraction }
            )
        }
    }

    private nonisolated static func overviewRange(
        _ selection: UsageReportSelection,
        calendar: Calendar
    ) -> UsageDashboardRangeProjection {
        let models = cappedBreakdown(selection.models.map {
            .init(title: $0.name, tokens: $0.tokens.processed, costUSD: $0.costUSD, records: $0.records)
        })
        let accounts = cappedBreakdown(selection.accounts.map {
            .init(title: $0.name, tokens: $0.tokens.processed, costUSD: $0.costUSD, records: $0.records)
        })
        let projects = cappedBreakdown(selection.checkouts.map {
            .init(title: $0.label, tokens: $0.billedTokens, costUSD: $0.costUSD, records: $0.turns)
        })
        let providers = cappedBreakdown(selection.providers.map {
            .init(
                title: $0.origin.seriesName,
                tokens: $0.tokens.processed,
                costUSD: $0.costUSD,
                records: $0.records
            )
        })
        return UsageDashboardRangeProjection(
            days: selection.range,
            start: selection.start,
            end: selection.end,
            tokens: selection.tokens,
            records: selection.records,
            cost: selection.cost,
            activeDayCount: selection.days.count,
            costMetric: metricProjection(.cost, selection: selection, calendar: calendar),
            tokenMetric: metricProjection(.tokens, selection: selection, calendar: calendar),
            breakdowns: [
                .models: models,
                .projects: projects,
                .accounts: accounts,
                .providers: providers
            ]
        )
    }

    private nonisolated static func metricProjection(
        _ metric: UsageDashboardMetric,
        selection: UsageReportSelection,
        calendar: Calendar
    ) -> UsageDashboardMetricProjection {
        let styleByOrigin = Dictionary(uniqueKeysWithValues: selection.providers.enumerated().map {
            ($0.element.origin, $0.offset)
        })
        let ranked = selection.providers.sorted { lhs, rhs in
            let left = metric == .cost ? lhs.costUSD : Double(lhs.tokens.processed)
            let right = metric == .cost ? rhs.costUSD : Double(rhs.tokens.processed)
            if left != right { return left > right }
            return lhs.origin.seriesName < rhs.origin.seriesName
        }
        let providers = ranked.map {
            UsageDashboardProviderProjection(
                origin: $0.origin,
                tokens: $0.tokens,
                costUSD: $0.costUSD,
                records: $0.records,
                styleIndex: styleByOrigin[$0.origin] ?? 0
            )
        }

        let leaders = Array(ranked.prefix(3))
        let remaining = Array(ranked.dropFirst(leaders.count))
        let routes: [(id: String, title: String?, isOther: Bool, origins: Set<UsageOrigin>, style: Int)]
            = leaders.map {
                (
                    id: $0.origin.seriesID,
                    title: $0.origin.seriesName,
                    isOther: false,
                    origins: [$0.origin],
                    style: styleByOrigin[$0.origin] ?? 0
                )
            } + (remaining.isEmpty ? [] : [(
                id: "usage|other",
                title: nil,
                isOther: true,
                origins: Set(remaining.map(\.origin)),
                style: selection.providers.count
            )])

        let dailyByOrigin = Dictionary(grouping: selection.daily, by: \.origin).mapValues { daily in
            Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0) })
        }
        var days: [Date] = []
        days.reserveCapacity(selection.range)
        var day = selection.start
        while day < selection.end, days.count < selection.range {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? selection.end
        }

        let chartSeries = routes.map { route in
            UsageDashboardChartSeriesProjection(
                id: route.id,
                title: route.title,
                isOther: route.isOther,
                styleIndex: route.style,
                points: days.map { day in
                    let value = route.origins.reduce(0.0) { total, origin in
                        guard let daily = dailyByOrigin[origin]?[day] else { return total }
                        return total + (metric == .cost
                            ? daily.costUSD
                            : Double(daily.tokens.processed))
                    }
                    return UsageDashboardChartPointProjection(at: day, value: value)
                }
            )
        }
        return UsageDashboardMetricProjection(providers: providers, chartSeries: chartSeries)
    }

    private nonisolated static func cappedBreakdown(
        _ rows: [UsageDashboardBreakdownRowProjection]
    ) -> UsageDashboardBreakdownProjection {
        let maximum = UsageDashboardProjectionDefaults.maximumBreakdownRows
        guard rows.count > maximum else {
            return .init(
                rows: rows,
                omittedRowCount: 0,
                omittedTokens: 0,
                omittedCostUSD: 0,
                omittedRecords: 0
            )
        }
        let omitted = rows.dropFirst(maximum)
        return .init(
            rows: Array(rows.prefix(maximum)),
            omittedRowCount: omitted.count,
            omittedTokens: omitted.reduce(0) { $0 + $1.tokens },
            omittedCostUSD: omitted.reduce(0) { $0 + $1.costUSD },
            omittedRecords: omitted.reduce(0) { $0 + $1.records }
        )
    }

    private nonisolated static func evenlySpaced<Element>(
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
}
