import AppKit
import XCTest
@testable import Threading

/// Deterministic scale regressions for the Usage dashboard's complete data path.
///
/// The default sizes are large enough to catch accidental quadratic work on every fast run.
/// `scripts/profile_usage_dashboard.sh` raises the ledger to one million responses and repeats
/// chart transitions more aggressively for an explicit profiling pass.
@MainActor
final class UsageDashboardPerformanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testHundredThousandResponseLedgerAggregationStaysInteractive() {
        let recordCount = stressValue(
            key: "THREADING_USAGE_STRESS_RECORDS",
            normal: 100_000,
            stressed: 1_000_000
        )
        let origins: [UsageOrigin] = [
            .direct(.claude),
            .direct(.codex),
            .direct(.grok),
            .direct(.openCode),
            .openCode(providerID: "openrouter")
        ]
        let records = (0..<recordCount).map { index in
            let origin = origins[index % origins.count]
            return UsageLedgerRecord(
                identity: "response-\(index)",
                sessionID: "session-\(index % 2_000)",
                at: now.addingTimeInterval(TimeInterval(-(index % (89 * 24 * 4))) * 900),
                origin: origin,
                accountID: "account-\(index % 20)",
                accountName: "Account \(index % 20)",
                model: origin.billingProviderID == "openai" ? "gpt-5.4" : "model-\(index % 40)",
                workingDirectory: "",
                tokens: .init(
                    uncachedInput: Int64(500 + index % 100),
                    cachedInput: Int64(index % 400),
                    output: Int64(80 + index % 40),
                    reasoning: Int64(index % 20)
                ),
                reportedCostUSD: origin.billingProviderID == "openrouter" ? 0.002 : nil
            )
        }
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.rawRecords = recordCount

        let started = CFAbsoluteTimeGetCurrent()
        let report = UsageLedgerBuilder.build(
            records: records,
            coverage: [],
            projects: [],
            scan: scan,
            now: now,
            calendar: fixedCalendar
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(report.scan.distinctRecords, recordCount)
        XCTAssertEqual(report.turns, recordCount)
        XCTAssertLessThanOrEqual(report.cells.count, 90 * origins.count * 20 * 40)
        XCTAssertLessThan(elapsed, isStressRun ? 45 : 10, "Ledger aggregation took \(elapsed)s")
    }

    func testMaximumJournalHistoryDownsamplingIsBoundedUnderFrequentClears() {
        let count = UsageLimitHistoryDefaults.maximumLoadedRecords
        let samples = (0..<count).map { index in
            UsageSample(
                at: now.addingTimeInterval(TimeInterval(index)),
                fraction: index.isMultiple(of: 2) ? 0.92 : 0.02,
                resetsAt: now.addingTimeInterval(7 * 86_400),
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:performance",
                accountName: "Performance",
                windowID: "weekly",
                windowLabel: "Weekly",
                windowDuration: 7 * 86_400,
                source: .codexAPI
            )
        }

        let started = CFAbsoluteTimeGetCurrent()
        let bounded = UsageLimitHistoryAnalysis.downsample(samples)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let preparationStarted = CFAbsoluteTimeGetCurrent()
        let prepared = UsageHistoryStore.prepareJournalSnapshot(
            UsageLimitHistorySnapshot(samples: samples, resets: [], loadedAt: now),
            includeIdentities: false
        )
        let preparationElapsed = CFAbsoluteTimeGetCurrent() - preparationStarted

        XCTAssertLessThanOrEqual(bounded.count, 280)
        XCTAssertEqual(bounded.first?.at, samples.first?.at)
        XCTAssertEqual(bounded.last?.at, samples.last?.at)
        XCTAssertTrue(bounded.contains { $0.fraction == 0.92 })
        XCTAssertTrue(bounded.contains { $0.fraction == 0.02 })
        XCTAssertLessThan(elapsed, isStressRun ? 20 : 8, "History downsampling took \(elapsed)s")
        XCTAssertEqual(prepared.samplesBySeries["codex|codex:performance|weekly"]?.count, UsageHistoryDefaults.maximumSamples)
        XCTAssertLessThan(
            preparationElapsed,
            isStressRun ? 20 : 8,
            "Journal bootstrap preparation took \(preparationElapsed)s"
        )
    }

    func testWarmCacheAcrossHundredsOfFilesAvoidsEveryParser() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-usage-performance-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("sources")
        let cacheDirectory = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileCount = stressValue(
            key: "THREADING_USAGE_STRESS_FILES",
            normal: 500,
            stressed: 2_000
        )
        let sources = try (0..<fileCount).map { index -> URL in
            let url = sourceDirectory.appendingPathComponent("session-\(index).jsonl")
            try Data("fixture-\(index)".utf8).write(to: url)
            return url
        }
        var parserCalls = 0
        let coldCache = UsageScanCache(directory: cacheDirectory)

        let coldStarted = CFAbsoluteTimeGetCurrent()
        coldCache.beginScan()
        for (index, source) in sources.enumerated() {
            let result = coldCache.records(for: source, parserID: "performance-v1") {
                parserCalls += 1
                return [record(identity: "cached-\(index)")]
            }
            XCTAssertFalse(result.wasCacheHit)
        }
        coldCache.finishScan()
        let coldElapsed = CFAbsoluteTimeGetCurrent() - coldStarted

        let warmCache = UsageScanCache(directory: cacheDirectory)
        let warmStarted = CFAbsoluteTimeGetCurrent()
        warmCache.beginScan()
        for source in sources {
            let result = warmCache.records(for: source, parserID: "performance-v1") {
                parserCalls += 1
                return []
            }
            XCTAssertTrue(result.wasCacheHit)
        }
        warmCache.finishScan()
        let warmElapsed = CFAbsoluteTimeGetCurrent() - warmStarted

        XCTAssertEqual(parserCalls, fileCount)
        XCTAssertLessThan(warmElapsed, coldElapsed)
        XCTAssertLessThan(warmElapsed, isStressRun ? 15 : 5, "Warm cache scan took \(warmElapsed)s")
    }

    func testDashboardVirtualizesLargeBreakdownAndBoundsChartGeometry() {
        let dashboardNow = Date()
        let cellCount = stressValue(
            key: "THREADING_USAGE_STRESS_CELLS",
            normal: 25_000,
            stressed: 100_000
        )
        let routes: [UsageOrigin] = [
            .direct(.claude),
            .direct(.codex),
            .direct(.grok),
            .direct(.openCode),
            .openCode(providerID: "openrouter")
        ]
        let today = fixedCalendar.startOfDay(for: dashboardNow)
        let cells = (0..<cellCount).map { index in
            TranscriptUsageReport.Cell(
                day: fixedCalendar.date(byAdding: .day, value: -(index % 90), to: today)!,
                origin: routes[index % routes.count],
                accountID: "account-\(index % 50)",
                accountName: "Account \(index % 50)",
                model: "model-\(index)",
                checkoutPath: "/project/\(index % 5_000)",
                checkoutLabel: "Project \(index % 5_000)",
                tokens: .init(uncachedInput: 800, cachedInput: 200, output: 100),
                providerReportedCostUSD: 0.002,
                catalogCostUSD: 0,
                unpricedTokens: 0,
                cacheSavingsUSD: 0.001,
                records: 1
            )
        }
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.sourceFiles = 500
        scan.distinctRecords = cellCount
        let report = TranscriptUsageReport(
            cells: cells,
            coverage: coverage,
            scan: scan,
            builtAt: dashboardNow
        )
        let historyCount = isStressRun ? 250_000 : 50_000
        let historyStart = dashboardNow.addingTimeInterval(-30 * 86_400)
        let historyStep = TimeInterval(30 * 86_400) / Double(historyCount - 1)
        let history = (0..<historyCount).map { index in
            UsageSample(
                at: historyStart.addingTimeInterval(Double(index) * historyStep),
                fraction: Double(index % 1_000) / 1_000,
                resetsAt: dashboardNow.addingTimeInterval(7 * 86_400),
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:performance",
                accountName: "Performance",
                windowID: "weekly",
                windowLabel: "Weekly",
                windowDuration: 7 * 86_400,
                source: .codexAPI,
                nextResetCreditExpiresAt: dashboardNow.addingTimeInterval(2 * 86_400),
                resetCreditCount: 3
            )
        }
        let projection = UsageLimitProjection(
            observedAt: dashboardNow,
            observedFraction: 0.72,
            resetsAt: dashboardNow.addingTimeInterval(7 * 86_400),
            projectedFractionAtReset: 1,
            projectedExhaustionAt: dashboardNow.addingTimeInterval(2 * 86_400),
            resetCreditExpiresAt: dashboardNow.addingTimeInterval(2 * 86_400)
        )
        let resetCount = isStressRun ? 50_000 : 10_000
        let resets = (0..<resetCount).map { index in
            let detectedAt = historyStart.addingTimeInterval(
                Double(index) * TimeInterval(30 * 86_400) / Double(resetCount)
            )
            return UsageLimitResetEvent(
                id: "reset-\(index)",
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:performance",
                accountName: "Performance",
                windowID: "weekly",
                windowLabel: "Weekly",
                previousObservedAt: detectedAt.addingTimeInterval(-60),
                detectedAt: detectedAt,
                oldScheduledResetAt: detectedAt,
                newScheduledResetAt: detectedAt.addingTimeInterval(7 * 86_400),
                restoredFraction: 0.9,
                elapsedFraction: 0.4,
                secondsEarly: 0,
                cause: .scheduled
            )
        }
        let limits = [UsageLimitDashboardSeries(
            id: "codex|performance|weekly",
            runtimeName: "Codex",
            accountName: "Performance",
            windowLabel: "Weekly",
            samples: history,
            resets: resets,
            projection: projection,
            currentFraction: 0.72,
            resetsAt: dashboardNow.addingTimeInterval(7 * 86_400),
            resetCreditCount: 3,
            nextResetCreditExpiresAt: dashboardNow.addingTimeInterval(2 * 86_400)
        )]

        let dashboard = UsageDashboardView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_250))
        let window = NSWindow(
            contentRect: dashboard.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = dashboard

        let started = CFAbsoluteTimeGetCurrent()
        dashboard.update(report: report, limits: limits, isBuilding: false, animated: false)
        dashboard.layoutSubtreeIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThanOrEqual(
            dashboard.usageRenderedPointCountForTesting,
            4 * Design.Chart.maximumRenderedPoints
        )
        XCTAssertLessThanOrEqual(
            dashboard.limitRenderedPointCountForTesting,
            Design.Chart.maximumRenderedPoints + 2
        )
        XCTAssertLessThanOrEqual(
            dashboard.limitRenderedMarkerCountForTesting,
            Design.Chart.maximumRenderedMarkers
        )
        XCTAssertGreaterThan(dashboard.breakdownVisibleSubviewCountForTesting, 0)
        XCTAssertLessThan(dashboard.breakdownVisibleSubviewCountForTesting, 100)
        XCTAssertEqual(dashboard.topToolCountForTesting, 3)
        XCTAssertEqual(dashboard.usageChartCompositionForTesting, .stackedBands)
        XCTAssertEqual(dashboard.limitChartCompositionForTesting, .independent)
        XCTAssertLessThan(elapsed, isStressRun ? 30 : 8, "Dashboard update took \(elapsed)s")
        _ = window
    }

    func testHundredsOfInterruptedChartTransitionsStayBounded() {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        // Five 2,000-point raw series still force ten million source-point visits across the
        // stress loop; retained geometry stays at 1,200 points. The separate dashboard fixture
        // feeds the interaction a full 250,000-sample history before this boundary.
        let pointCount = isStressRun ? 2_000 : 1_000
        let switchCount = isStressRun ? 1_000 : 200
        let chart = ThemedTimeSeriesChartView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 320)
        )
        let window = NSWindow(
            contentRect: chart.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = chart
        chart.setModel(chartModel(seed: 0, pointCount: pointCount), animated: false)

        let started = CFAbsoluteTimeGetCurrent()
        for seed in 1...switchCount {
            chart.setModel(chartModel(seed: seed, pointCount: pointCount), animated: true)
            chart.advanceAnimation(now: CACurrentMediaTime() + Design.Motion.standard / 2)
            XCTAssertLessThanOrEqual(
                chart.renderedPointCount,
                5 * Design.Chart.maximumRenderedPoints
            )
        }
        chart.setModel(chartModel(seed: switchCount + 1, pointCount: pointCount), animated: false)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, isStressRun ? 60 : 12, "Chart transitions took \(elapsed)s")
        _ = window
    }

    func testAnimatedFramesDrawFromBoundedGeometryWithLargeSourceModels() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let pointCount = isStressRun ? 50_000 : 10_000
        let frameCount = isStressRun ? 120 : 30
        let chart = ThemedTimeSeriesChartView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 320)
        )
        let window = NSWindow(
            contentRect: chart.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = chart
        chart.setModel(chartModel(seed: 0, pointCount: pointCount), animated: false)
        chart.setModel(chartModel(seed: 1, pointCount: pointCount), animated: true)
        let animationBase = CACurrentMediaTime()
        let bitmap = try XCTUnwrap(chart.bitmapImageRepForCachingDisplay(in: chart.bounds))

        let started = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frameCount {
            let phase = Double(frame) / Double(max(1, frameCount - 1))
            chart.advanceAnimation(now: animationBase + Design.Motion.standard * phase)
            chart.cacheDisplay(in: chart.bounds, to: bitmap)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThanOrEqual(
            chart.renderedPointCount,
            5 * Design.Chart.maximumRenderedPoints
        )
        XCTAssertLessThan(elapsed, isStressRun ? 20 : 5, "Animated draws took \(elapsed)s")
        _ = window
    }

    func testClassicPlayerStackedSpectrumFramesStayBoundedWithLargeAlignedSources() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }
        let previousTheme = AppThemePalette.current
        AppThemePalette.set(AppThemeStyles.classicPlayer)
        defer { AppThemePalette.set(previousTheme) }

        // This is deliberately much larger than Usage's real 90-day input. It protects both the
        // cumulative-band preparation and Classic Player's segmented analyzer renderer from ever
        // walking provider-sized source arrays on an animation frame.
        let pointCount = isStressRun ? 50_000 : 10_000
        let frameCount = isStressRun ? 120 : 30
        let chart = ThemedStackedBandChartView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 320)
        )
        let window = NSWindow(
            contentRect: chart.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = chart
        chart.setModel(chartModel(seed: 0, pointCount: pointCount), animated: false)
        chart.setModel(chartModel(seed: 1, pointCount: pointCount), animated: true)
        let animationBase = CACurrentMediaTime()
        let bitmap = try XCTUnwrap(chart.bitmapImageRepForCachingDisplay(in: chart.bounds))

        let started = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frameCount {
            let phase = Double(frame) / Double(max(1, frameCount - 1))
            chart.advanceAnimation(now: animationBase + Design.Motion.standard * phase)
            chart.cacheDisplay(in: chart.bounds, to: bitmap)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(chart.composition, .stackedBands)
        XCTAssertLessThanOrEqual(
            chart.renderedPointCount,
            5 * Design.Chart.maximumRenderedPoints
        )
        XCTAssertLessThan(
            elapsed,
            isStressRun ? 25 : 6,
            "Stacked spectrum draws took \(elapsed)s"
        )
        _ = window
    }

    private var isStressRun: Bool {
        ProcessInfo.processInfo.environment["THREADING_USAGE_STRESS"] == "1"
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var coverage: [UsageSourceCoverage] {
        [
            ("claude", "Claude Code"),
            ("codex", "Codex"),
            ("grok", "Grok"),
            ("opencode", "OpenCode"),
            ("openrouter", "OpenRouter via OpenCode")
        ].map {
            UsageSourceCoverage(
                runtimeID: $0.0,
                runtimeName: $0.1,
                state: .complete,
                sourceCount: 100,
                recordCount: 20_000,
                detail: "Performance fixture"
            )
        }
    }

    private func stressValue(key: String, normal: Int, stressed: Int) -> Int {
        if let value = ProcessInfo.processInfo.environment[key].flatMap(Int.init), value > 0 {
            return value
        }
        return isStressRun ? stressed : normal
    }

    private func record(identity: String) -> UsageLedgerRecord {
        UsageLedgerRecord(
            identity: identity,
            sessionID: "session",
            at: now,
            origin: .direct(.claude),
            accountID: "claude:performance",
            accountName: "Performance",
            model: "model",
            workingDirectory: "",
            tokens: .init(uncachedInput: 1)
        )
    }

    private func chartModel(seed: Int, pointCount: Int) -> ThemedChartModel {
        ThemedChartModel(
            title: "Usage performance",
            accessibilitySummary: "Usage performance fixture",
            series: (0..<5).map { seriesIndex in
                ThemedChartSeries(
                    id: "series-\(seriesIndex)",
                    title: "Series \(seriesIndex)",
                    points: (0..<pointCount).map { pointIndex in
                        let wave = Double((pointIndex + seed * (seriesIndex + 1)) % 100) / 100
                        return ThemedChartPoint(
                            at: now.addingTimeInterval(TimeInterval(pointIndex * 60)),
                            value: wave + Double(seriesIndex),
                            segment: pointIndex < pointCount / 2 ? 0 : 1
                        )
                    },
                    style: .categorical(seriesIndex)
                )
            },
            valueFormat: .tokens
        )
    }
}
