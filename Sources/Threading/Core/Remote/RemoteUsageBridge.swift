import CryptoKit
import Foundation
import ThreadingRemoteKit

/// Maps the app's bounded semantic projection onto the public wire contract. This boundary owns
/// the tighter relay budgets; it never receives raw transcript cells or constructs iOS views.
enum RemoteUsageBridge {
    static let defaultLimitPageSize = 48
    static let maximumLimitPageSize = 64
    static let maximumBreakdownRowsPerKind = 64
    static let maximumOverviewResponseBytes = 384 * 1_024
    static let maximumLimitResponseBytes = 192 * 1_024

    nonisolated static func dashboard(
        overview: UsageDashboardOverviewProjection?,
        limitIndex: UsageLimitDashboardIndexProjection,
        isBuilding: Bool,
        limitOffset: Int,
        limitCount: Int
    ) -> RemoteUsageDashboardDTO {
        let offset = min(max(0, limitOffset), limitIndex.series.count)
        let count = min(max(1, limitCount), maximumLimitPageSize)
        let end = min(limitIndex.series.count, offset + count)
        let page = limitIndex.series[offset..<end].map(limitSummary)
        let nextCursor = end < limitIndex.series.count ? String(end) : nil

        return RemoteUsageDashboardDTO(
            isBuilding: isBuilding,
            builtAt: overview?.builtAt.timeIntervalSince1970,
            pricingCatalogVersion: overview?.pricingCatalogVersion,
            ranges: overview?.ranges.map(range) ?? [],
            coverage: overview?.coverage.map {
                RemoteUsageCoverageDTO(
                    runtimeID: $0.runtimeID,
                    runtimeName: $0.runtimeName,
                    state: RemoteUsageCoverageState(rawValue: $0.state.rawValue),
                    sourceCount: $0.sourceCount,
                    recordCount: $0.recordCount,
                    detail: $0.detail
                )
            } ?? [],
            limitSeries: page,
            nextLimitCursor: nextCursor,
            omittedLimitSeriesCount: limitIndex.omittedSeriesCount,
            preparedAt: limitIndex.preparedAt.timeIntervalSince1970
        )
    }

    nonisolated static func limit(
        series: UsageLimitDashboardSeries,
        days: Int,
        preparedAt: Date
    ) -> RemoteUsageLimitDTO? {
        guard let selected = series.range(days: days) else { return nil }
        let projected = series.projection.map {
            RemoteUsageLimitProjectionDTO(
                observedAt: $0.observedAt.timeIntervalSince1970,
                observedFraction: $0.observedFraction,
                resetsAt: $0.resetsAt.timeIntervalSince1970,
                projectedFractionAtReset: $0.projectedFractionAtReset,
                projectedExhaustionAt: $0.projectedExhaustionAt?.timeIntervalSince1970,
                bankedResetExpiresAt: $0.resetCreditExpiresAt?.timeIntervalSince1970
            )
        }
        return RemoteUsageLimitDTO(
            series: limitSummary(series),
            days: selected.days,
            start: selected.start.timeIntervalSince1970,
            end: selected.end.timeIntervalSince1970,
            observed: selected.observed.map {
                RemoteUsageLimitPointDTO(
                    at: $0.sample.at.timeIntervalSince1970,
                    fraction: $0.sample.fraction,
                    segment: $0.segment
                )
            },
            resets: selected.resetMarkers.map {
                RemoteUsageLimitResetDTO(
                    id: $0.id,
                    detectedAt: $0.detectedAt.timeIntervalSince1970,
                    previousObservedAt: $0.previousObservedAt.timeIntervalSince1970,
                    cause: RemoteUsageLimitResetCause(rawValue: $0.cause.rawValue),
                    restoredFraction: $0.restoredFraction,
                    elapsedFraction: $0.elapsedFraction,
                    paceGainFraction: $0.paceGainFraction
                )
            },
            recordedResetCount: selected.resetCount,
            restoredPaceFraction: selected.restoredPaceFraction,
            projection: projected,
            preparedAt: preparedAt.timeIntervalSince1970
        )
    }

    private nonisolated static func range(
        _ source: UsageDashboardRangeProjection
    ) -> RemoteUsageRangeDTO {
        RemoteUsageRangeDTO(
            days: source.days,
            start: source.start.timeIntervalSince1970,
            end: source.end.timeIntervalSince1970,
            tokens: tokens(source.tokens),
            records: source.records,
            cost: RemoteUsageCostQualityDTO(
                providerReportedUSD: source.cost.providerReportedUSD,
                catalogPricedUSD: source.cost.catalogPricedUSD,
                unpricedTokens: source.cost.unpricedTokens,
                cacheSavingsUSD: source.cost.cacheSavingsUSD
            ),
            activeDayCount: source.activeDayCount,
            costMetric: metric(source.costMetric),
            tokenMetric: metric(source.tokenMetric),
            breakdowns: UsageDashboardBreakdownKind.allCases.map { kind in
                breakdown(source.breakdown(kind), kind: kind)
            }
        )
    }

    private nonisolated static func metric(
        _ source: UsageDashboardMetricProjection
    ) -> RemoteUsageMetricProjectionDTO {
        RemoteUsageMetricProjectionDTO(
            providers: source.providers.map {
                RemoteUsageProviderDTO(
                    id: $0.origin.seriesID,
                    name: $0.origin.seriesName,
                    tokens: tokens($0.tokens),
                    costUSD: $0.costUSD,
                    records: $0.records,
                    styleIndex: $0.styleIndex
                )
            },
            chartSeries: source.chartSeries.map {
                RemoteUsageChartSeriesDTO(
                    id: $0.id,
                    title: $0.title,
                    isOther: $0.isOther,
                    styleIndex: $0.styleIndex,
                    points: $0.points.map {
                        RemoteUsageChartPointDTO(
                            at: $0.at.timeIntervalSince1970,
                            value: $0.value
                        )
                    }
                )
            }
        )
    }

    private nonisolated static func breakdown(
        _ source: UsageDashboardBreakdownProjection,
        kind: UsageDashboardBreakdownKind
    ) -> RemoteUsageBreakdownDTO {
        let retained = source.rows.prefix(maximumBreakdownRowsPerKind)
        let additionallyOmitted = source.rows.dropFirst(retained.count)
        return RemoteUsageBreakdownDTO(
            kind: remoteBreakdownKind(kind),
            rows: retained.map {
                RemoteUsageBreakdownRowDTO(
                    title: $0.title,
                    tokens: $0.tokens,
                    costUSD: $0.costUSD,
                    records: $0.records
                )
            },
            omittedRowCount: source.omittedRowCount + additionallyOmitted.count,
            omittedTokens: source.omittedTokens
                + additionallyOmitted.reduce(0) { $0 + $1.tokens },
            omittedCostUSD: source.omittedCostUSD
                + additionallyOmitted.reduce(0) { $0 + $1.costUSD },
            omittedRecords: source.omittedRecords
                + additionallyOmitted.reduce(0) { $0 + $1.records }
        )
    }

    private nonisolated static func remoteBreakdownKind(
        _ kind: UsageDashboardBreakdownKind
    ) -> RemoteUsageBreakdownKindDTO {
        switch kind {
        case .models: return .models
        case .projects: return .projects
        case .accounts: return .accounts
        case .providers: return .providers
        }
    }

    private nonisolated static func tokens(
        _ source: UsageTokenCounts
    ) -> RemoteUsageTokenCountsDTO {
        RemoteUsageTokenCountsDTO(
            uncachedInput: source.uncachedInput,
            cachedInput: source.cachedInput,
            cacheWrite: source.cacheWrite,
            output: source.output,
            reasoning: source.reasoning
        )
    }

    private nonisolated static func limitSummary(
        _ source: UsageLimitDashboardSeriesSummaryProjection
    ) -> RemoteUsageLimitSeriesSummaryDTO {
        RemoteUsageLimitSeriesSummaryDTO(
            id: source.id,
            runtimeName: source.runtimeName,
            accountName: source.accountName,
            windowLabel: source.windowLabel,
            currentFraction: source.currentFraction,
            resetsAt: source.resetsAt?.timeIntervalSince1970,
            windowDuration: source.windowDuration,
            bankedResetCount: source.resetCreditCount,
            nextBankedResetExpiresAt: source.nextResetCreditExpiresAt?.timeIntervalSince1970,
            canRedeemBankedReset: canRedeemReset(
                runtimeID: source.runtimeID,
                accountID: source.accountID,
                count: source.resetCreditCount
            )
        )
    }

    private nonisolated static func limitSummary(
        _ source: UsageLimitDashboardSeries
    ) -> RemoteUsageLimitSeriesSummaryDTO {
        RemoteUsageLimitSeriesSummaryDTO(
            id: source.id,
            runtimeName: source.runtimeName,
            accountName: source.accountName,
            windowLabel: source.windowLabel,
            currentFraction: source.currentFraction,
            resetsAt: source.resetsAt?.timeIntervalSince1970,
            windowDuration: source.windowDuration,
            bankedResetCount: source.resetCreditCount,
            nextBankedResetExpiresAt: source.nextResetCreditExpiresAt?.timeIntervalSince1970,
            canRedeemBankedReset: canRedeemReset(
                runtimeID: source.runtimeID,
                accountID: source.accountID,
                count: source.resetCreditCount
            )
        )
    }

    nonisolated static func resetOffer(
        _ source: BankedUsageResetOffer,
        seriesID: String
    ) -> RemoteBankedUsageResetOfferDTO {
        RemoteBankedUsageResetOfferDTO(
            seriesID: seriesID,
            accountName: source.accountName,
            availableCount: source.availableCount,
            offerFingerprint: resetOfferFingerprint(source, seriesID: seriesID),
            selectedCreditTitle: source.selectedCreditTitle,
            selectedCreditExpiresAt: source.selectedCreditExpiresAt?.timeIntervalSince1970,
            letsProviderChooseCredit: source.letsProviderChooseCredit,
            eligibleWindowLabels: source.eligibleWindowLabels,
            owedContinuationCount: source.owedContinuationCount
        )
    }

    private nonisolated static func resetOfferFingerprint(
        _ source: BankedUsageResetOffer,
        seriesID: String
    ) -> String {
        let material = [
            seriesID,
            source.accountID.rawValue,
            source.providerAccountID,
            source.selectedCreditID ?? "<provider-choice>",
            String(source.availableCount),
            String(source.letsProviderChooseCredit)
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func resetResult(
        _ source: BankedUsageResetResult
    ) -> RemoteBankedUsageResetResponseDTO {
        let outcome: RemoteBankedUsageResetOutcome
        switch source.outcome {
        case .reset: outcome = .reset
        case .alreadyRedeemed: outcome = .alreadyRedeemed
        case .nothingToReset: outcome = .nothingToReset
        case .noCredit: outcome = .noCredit
        }
        return RemoteBankedUsageResetResponseDTO(
            outcome: outcome,
            remainingCreditCount: source.remainingCreditCount,
            releasedContinuationCount: source.releasedContinuationCount,
            hasVerifiedHeadroom: source.hasVerifiedHeadroom,
            continuationReleaseFailed: source.continuationReleaseFailed
        )
    }

    private nonisolated static func canRedeemReset(
        runtimeID: String?,
        accountID: String?,
        count: Int?
    ) -> Bool {
        guard let runtimeID, let provider = AgentKind(rawValue: runtimeID) else { return false }
        return accountID != nil && provider.supports(.bankedUsageReset) && (count ?? 0) > 0
    }
}
