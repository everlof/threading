import XCTest
@testable import Threading

final class UsageLedgerTests: XCTestCase {
    func testReasoningIsAnOutputSubsetAndNotDoubleCounted() {
        let tokens = UsageTokenCounts(
            uncachedInput: 100,
            cachedInput: 200,
            cacheWrite: 300,
            output: 400,
            reasoning: 250
        )

        XCTAssertEqual(tokens.processed, 1_000)
        XCTAssertEqual(tokens.legacyBilled, 800)
        XCTAssertEqual(tokens.reasoning, 250)
    }

    func testInclusiveInputIsNormalizedAtTheAdapterBoundary() {
        let tokens = UsageTokenCounts(
            inputIncludingCached: 1_000,
            cachedInput: 600,
            cacheWrite: 100,
            output: 80,
            reasoning: 20
        )

        XCTAssertEqual(tokens.uncachedInput, 300)
        XCTAssertEqual(tokens.processed, 1_080)
    }

    func testLegacyTokenCountsDecodeWithoutCacheWriteDurationDetail() throws {
        let legacy = Data(#"{"uncachedInput":10,"cachedInput":20,"cacheWrite":30,"output":40,"reasoning":5}"#.utf8)

        let decoded = try JSONDecoder().decode(UsageTokenCounts.self, from: legacy)

        XCTAssertEqual(decoded.cacheWrite, 30)
        XCTAssertEqual(decoded.cacheWrite1h, 0)
    }

    func testOpenCodeRuntimeAndOpenRouterBillingStayDistinct() {
        let direct = UsageOrigin.direct(.openCode)
        let routed = UsageOrigin.openCode(providerID: "openrouter")

        XCTAssertEqual(routed.runtimeID, AgentKind.openCode.rawValue)
        XCTAssertEqual(routed.billingProviderID, "openrouter")
        XCTAssertEqual(routed.seriesName, "OpenRouter")
        XCTAssertNotEqual(direct.seriesID, routed.seriesID)
    }

    func testDirectRuntimeRoutesUseConciseLegendNames() {
        XCTAssertEqual(UsageOrigin.direct(.claude).seriesName, "Claude Code")
        XCTAssertEqual(UsageOrigin.direct(.codex).seriesName, "Codex")
        XCTAssertEqual(UsageOrigin.direct(.grok).seriesName, "Grok")
        XCTAssertEqual(UsageOrigin.direct(.openCode).seriesName, "OpenCode")
    }

    func testProviderReportedCostWinsOverCatalog() throws {
        let record = makeRecord(
            identity: "one",
            model: "gpt-5.4",
            tokens: .init(uncachedInput: 1_000_000),
            reportedCostUSD: 7.25
        )

        let priced = UsagePricingCatalog.price(record)

        XCTAssertEqual(priced.costSource, .providerReported)
        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 7.25, accuracy: 0.000_001)
    }

    func testCatalogPricingUsesCachedRateAndReportsSavings() throws {
        let record = makeRecord(
            identity: "one",
            model: "gpt-5.4",
            tokens: .init(uncachedInput: 100_000, cachedInput: 100_000, output: 100_000)
        )

        let priced = UsagePricingCatalog.price(record)

        XCTAssertEqual(priced.costSource, .catalogPriced)
        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 1.775, accuracy: 0.000_001)
        XCTAssertEqual(priced.cacheSavingsUSD, 0.225, accuracy: 0.000_001)
    }

    func testLongContextThresholdIsExclusive() throws {
        let record = makeRecord(
            identity: "boundary",
            model: "gpt-5.6-terra",
            tokens: .init(uncachedInput: 200_000, cachedInput: 72_000, output: 100_000)
        )

        let priced = UsagePricingCatalog.price(record)

        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 1.6144, accuracy: 0.000_001)
        XCTAssertEqual(priced.cacheSavingsUSD, 0.1296, accuracy: 0.000_001)
    }

    func testLongContextTierPricesTheWholeRequestAndSavings() throws {
        let record = makeRecord(
            identity: "long-context",
            model: "gpt-5.6-terra",
            tokens: .init(uncachedInput: 200_001, cachedInput: 72_000, output: 100_000)
        )

        let priced = UsagePricingCatalog.price(record)

        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 2.628804, accuracy: 0.000_001)
        XCTAssertEqual(priced.cacheSavingsUSD, 0.2592, accuracy: 0.000_001)
    }

    func testDatedSnapshotsMatchButAmbiguousModelVariantsRemainUnpriced() throws {
        let dated = makeRecord(
            identity: "dated",
            model: "gpt-5.4-2026-08-09",
            tokens: .init(uncachedInput: 100_000)
        )
        let ambiguous = makeRecord(
            identity: "ambiguous",
            model: "gpt-5.4-pro",
            tokens: .init(uncachedInput: 100_000)
        )

        XCTAssertEqual(
            try XCTUnwrap(UsagePricingCatalog.price(dated).costUSD),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(UsagePricingCatalog.price(ambiguous).costSource, .unpriced)
        XCTAssertNil(UsagePricingCatalog.price(ambiguous).costUSD)
    }

    func testAnthropicCatalogPricesEveryClaudeModelObservedInLocalTranscripts() throws {
        let observed: [(model: String, expected: Double)] = [
            ("claude-fable-5", 60),
            ("claude-opus-5", 30),
            ("claude-opus-4-8", 30),
            ("claude-opus-4-5-20251101", 30),
            ("claude-sonnet-5", 12),
            ("claude-haiku-4-5-20251001", 6)
        ]

        for fixture in observed {
            let priced = UsagePricingCatalog.price(makeRecord(
                identity: fixture.model,
                origin: .direct(.claude),
                model: fixture.model,
                tokens: .init(uncachedInput: 1_000_000, output: 1_000_000)
            ))
            XCTAssertEqual(priced.costSource, .catalogPriced, fixture.model)
            XCTAssertEqual(
                try XCTUnwrap(priced.costUSD, fixture.model),
                fixture.expected,
                accuracy: 0.000_001,
                fixture.model
            )
        }
    }

    func testAnthropicPricingDistinguishesFiveMinuteAndOneHourCacheWrites() throws {
        let record = makeRecord(
            identity: "claude-cache-ttls",
            origin: .direct(.claude),
            model: "claude-opus-5",
            tokens: .init(
                cachedInput: 1_000_000,
                cacheWrite: 2_000_000,
                cacheWrite1h: 1_000_000
            )
        )

        let priced = UsagePricingCatalog.price(record)

        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 16.75, accuracy: 0.000_001)
        XCTAssertEqual(priced.cacheSavingsUSD, 4.5, accuracy: 0.000_001)
    }

    func testBuilderDeduplicatesAcrossSourceCachesBeforeAggregation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-08T12:00:00Z"))
        let duplicated = makeRecord(
            identity: "shared-response",
            at: now,
            tokens: .init(uncachedInput: 10, output: 5)
        )
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.rawRecords = 2

        let report = UsageLedgerBuilder.build(
            records: [duplicated, duplicated],
            coverage: [],
            projects: [],
            scan: scan,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(report.scan.distinctRecords, 1)
        XCTAssertEqual(report.turns, 1)
        XCTAssertEqual(report.billedTokens, 15)
    }

    func testRangeSelectionUsesLocalCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-08T22:30:00Z"))
        let today = calendar.startOfDay(for: now)
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let report = TranscriptUsageReport(cells: [
            makeCell(day: today, records: 2),
            makeCell(day: old, records: 9)
        ])

        XCTAssertEqual(report.selection(days: 7, now: now, calendar: calendar).records, 2)
        XCTAssertEqual(report.selection(days: 8, now: now, calendar: calendar).records, 11)
    }

    private func makeRecord(
        identity: String,
        at: Date? = Date(timeIntervalSince1970: 1_770_000_000),
        origin: UsageOrigin = .direct(.codex),
        model: String = "gpt-5.4",
        tokens: UsageTokenCounts,
        reportedCostUSD: Double? = nil
    ) -> UsageLedgerRecord {
        UsageLedgerRecord(
            identity: identity,
            sessionID: "session",
            at: at,
            origin: origin,
            accountID: "codex:default",
            accountName: "Codex",
            model: model,
            workingDirectory: "/tmp/project",
            tokens: tokens,
            reportedCostUSD: reportedCostUSD
        )
    }

    private func makeCell(day: Date, records: Int) -> TranscriptUsageReport.Cell {
        .init(
            day: day,
            origin: .direct(.codex),
            accountID: "codex:default",
            accountName: "Codex",
            model: "gpt-5.4",
            checkoutPath: "/tmp/project",
            checkoutLabel: "project",
            tokens: .init(uncachedInput: Int64(records)),
            providerReportedCostUSD: 0,
            catalogCostUSD: 0,
            unpricedTokens: 0,
            cacheSavingsUSD: 0,
            records: records
        )
    }
}
