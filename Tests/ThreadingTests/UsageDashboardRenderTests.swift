import AppKit
import XCTest
@testable import Threading

/// Visual stories for the dense dashboard, rendered in neutral System, two deliberately
/// dissimilar authored themes, and the spectrum-chart player material. Geometry assertions guard
/// the facts an image cannot: charts remain bounded and the long breakdown remains virtualized.
@MainActor
final class UsageDashboardRenderTests: XCTestCase {
    private struct Fixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    private let now = Date()

    func testRendersFullUsageDashboardAcrossSystemAndCustomThemes() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }

        let fixtures = [
            Fixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            Fixture(name: "system-light", theme: .system, appearance: .aqua),
            Fixture(name: "cyberpunk", theme: AppThemeStyles.cyberpunk, appearance: .darkAqua),
            Fixture(name: "neo-brutalism", theme: AppThemeStyles.neoBrutalism, appearance: .aqua),
            Fixture(name: "classic-player", theme: AppThemeStyles.classicPlayer, appearance: .darkAqua)
        ]
        let report = reportFixture()
        let recordsByModel = Dictionary(grouping: report.cells, by: \.model)
            .mapValues { cells in cells.reduce(0) { $0 + $1.records } }
        XCTAssertEqual(
            Set(recordsByModel.values).count,
            recordsByModel.count,
            "the visual fixture gives every model the same request count"
        )
        var files: [URL] = []

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            let dashboard = UsageDashboardView()
            dashboard.update(
                report: report,
                limits: limitFixtures(),
                isBuilding: false,
                animated: false
            )
            dashboard.selectLimitRangeForTesting(days: 7)
            let host = laidOut(dashboard, appearance: appearance)
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(
                dashboard.usageRenderedPointCountForTesting,
                4 * Design.Chart.maximumRenderedPoints
            )
            XCTAssertLessThanOrEqual(
                dashboard.limitRenderedPointCountForTesting,
                Design.Chart.maximumRenderedPoints + 2
            )
            XCTAssertEqual(dashboard.topToolCountForTesting, 4)
            XCTAssertEqual(dashboard.selectedDashboardSectionForTesting, .consumption)
            XCTAssertEqual(dashboard.visibleDashboardSectionCountForTesting, 1)
            XCTAssertEqual(dashboard.usageChartCompositionForTesting, .stackedBands)
            XCTAssertEqual(dashboard.limitChartCompositionForTesting, .independent)
            XCTAssertGreaterThan(dashboard.breakdownVisibleSubviewCountForTesting, 0)
            XCTAssertLessThan(dashboard.breakdownVisibleSubviewCountForTesting, 20)

            var payload: Data?
            appearance.performAsCurrentDrawingAppearance {
                payload = png(of: host)
            }
            let url = directory.appendingPathComponent(
                "usage-dashboard-\(fixture.name).png"
            )
            try XCTUnwrap(payload, "No Usage render for \(fixture.name)").write(to: url)
            files.append(url)

            // After the draw, deliberately: a column fits itself to the clip the scroll view
            // settles during its own tile, so what the columns are is only finally true once
            // the page has been asked to draw itself.
            XCTAssertEqual(
                dashboard.breakdownColumnTitlesForTesting,
                [
                    L10n.string("Model"),
                    L10n.string("Cost"),
                    L10n.string("Share"),
                    L10n.string("Tokens"),
                    L10n.string("Requests")
                ],
                "the wide page has room for every column, headed by the row's own subject"
            )
            XCTAssertGreaterThan(
                dashboard.breakdownProviderMarkCountForTesting,
                0,
                "every model in this fixture came through exactly one runtime"
            )
            print("usage-breakdown \(fixture.name) \(dashboard.breakdownDebugGeometryForTesting)")
            let fit = dashboard.breakdownColumnFitForTesting
            XCTAssertLessThanOrEqual(
                fit.occupied,
                fit.available + 0.5,
                "the breakdown's columns hang \(fit.occupied - fit.available)pt outside the table"
            )
            XCTAssertTrue(
                dashboard.statBandDetailsFitForTesting,
                "a stat's detail line is truncated at the page's own width"
            )
        }

        // Limit history is a separate dashboard state, not another block above Consumption.
        // One canonical render proves the switch and the retained limit chart without multiplying
        // that state through the theme matrix already exercised by the default tab.
        let limitFixture = fixtures[0]
        AppThemePalette.set(limitFixture.theme)
        let limitAppearance = try XCTUnwrap(NSAppearance(named: limitFixture.appearance))
        let limitDashboard = UsageDashboardView()
        limitDashboard.update(
            report: report,
            limits: limitFixtures(),
            isBuilding: false,
            animated: false
        )
        limitDashboard.selectLimitRangeForTesting(days: 7)
        limitDashboard.selectDashboardSectionForTesting(.limitHistory)
        let limitHost = laidOut(limitDashboard, appearance: limitAppearance)
        AppThemeRefresh.repaint(limitHost)
        limitHost.layoutSubtreeIfNeeded()
        var limitPayload: Data?
        limitAppearance.performAsCurrentDrawingAppearance {
            limitPayload = png(of: limitHost)
        }
        let limitURL = directory.appendingPathComponent(
            "usage-dashboard-limit-history-system-dark.png"
        )
        try XCTUnwrap(limitPayload, "No Usage Limit history render").write(to: limitURL)
        files.append(limitURL)
        XCTAssertEqual(limitDashboard.selectedDashboardSectionForTesting, .limitHistory)
        XCTAssertEqual(limitDashboard.visibleDashboardSectionCountForTesting, 1)

        print("Rendered Usage dashboard fixtures to \(directory.path)")
        XCTAssertEqual(files.count, fixtures.count + 1)
    }

    func testLimitHistoryChartDoesNotStretchToALaterBankedResetExpiry() throws {
        let selected = try XCTUnwrap(limitFixtures().first)
        let dashboard = UsageDashboardView()
        dashboard.update(
            report: reportFixture(),
            limits: [selected],
            isBuilding: false,
            animated: false
        )
        dashboard.selectLimitRangeForTesting(days: 7)

        let selectedRange = try XCTUnwrap(selected.range(days: 7))
        let chartRange = try XCTUnwrap(dashboard.limitChartXRangeForTesting)
        let expiry = try XCTUnwrap(selected.nextResetCreditExpiresAt)
        let expectedEnd = [
            selectedRange.end,
            selected.projection?.endpointAt,
            selected.resetsAt
        ].compactMap { $0 }.max()

        XCTAssertEqual(
            chartRange.upperBound.timeIntervalSinceReferenceDate,
            try XCTUnwrap(expectedEnd).timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            chartRange.upperBound,
            expiry,
            "a later banked-reset expiry compressed the selected history into the chart's edge"
        )
    }

    /// The page before it has numbers: a scan in flight, and a scan that found nothing.
    ///
    /// Rendered because this is exactly the kind of bug an assertion does not catch. The state
    /// this replaces passed every test it had while drawing one grey sentence through the middle
    /// grid rule of a value axis labelled 0 to 1, over a dashboard that repeated that same
    /// sentence under five dashes.
    func testRendersTheWaitingAndEmptyDashboards() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            AppThemePalette.set(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        // The ghost's breath is a layer animation, so an offscreen render would catch it at an
        // arbitrary opacity. Reduce Motion pins it to the still silhouette it must remain legible
        // as anyway.
        Design.Motion.reduceMotionOverrideForTesting = true

        let reading = UsageScanProgress(
            sourceName: "Claude Code",
            completedSources: 128,
            totalSources: 402
        )
        let states: [(name: String, report: TranscriptUsageReport?, progress: UsageScanProgress?, isBuilding: Bool)] = [
            ("counting", nil, nil, true),
            ("reading", nil, reading, true),
            ("empty", nil, nil, false),
            // A rescan behind a report says so beside the controls and leaves the chart alone.
            ("rescanning", reportFixture(), reading, true)
        ]
        let fixtures = [
            Fixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            Fixture(name: "system-light", theme: .system, appearance: .aqua),
            Fixture(name: "cyberpunk", theme: AppThemeStyles.cyberpunk, appearance: .darkAqua)
        ]

        var files: [URL] = []
        for fixture in fixtures {
            for state in states {
                AppThemePalette.set(fixture.theme)
                let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
                let dashboard = UsageDashboardView()
                dashboard.update(
                    report: state.report,
                    limits: [],
                    isBuilding: state.isBuilding,
                    scanProgress: state.progress,
                    animated: false
                )
                let host = laidOut(dashboard, appearance: appearance)
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                if state.report == nil {
                    XCTAssertEqual(dashboard.usageRenderedPointCountForTesting, 0)
                    XCTAssertFalse(dashboard.scanStripForTesting.isVisible)
                } else {
                    XCTAssertTrue(dashboard.scanStripForTesting.isVisible)
                }

                var payload: Data?
                appearance.performAsCurrentDrawingAppearance {
                    payload = png(of: host)
                }
                let url = directory.appendingPathComponent(
                    "usage-dashboard-\(state.name)-\(fixture.name).png"
                )
                try XCTUnwrap(payload, "No Usage \(state.name) render for \(fixture.name)")
                    .write(to: url)
                files.append(url)
            }
        }

        print("Rendered Usage waiting fixtures to \(directory.path)")
        XCTAssertEqual(files.count, fixtures.count * states.count)
    }

    /// The same page in the pane squeezed to its floor.
    ///
    /// A squeezed window can still take the shared Settings canvas to
    /// `Design.UsageDashboard.minimumContentWidth`. The floor is where the columns have to give
    /// something up, and this says which.
    func testRendersTheDashboardSqueezedToItsNarrowestPane() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }

        let fixtures = [
            Fixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            Fixture(name: "system-light", theme: .system, appearance: .aqua)
        ]
        let report = reportFixture()
        var files: [URL] = []

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            let dashboard = UsageDashboardView()
            dashboard.update(
                report: report,
                limits: limitFixtures(),
                isBuilding: false,
                animated: false
            )
            let host = laidOut(
                dashboard,
                appearance: appearance,
                width: Design.UsageDashboard.minimumContentWidth
            )
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(dashboard.breakdownVisibleSubviewCountForTesting, 0)

            var payload: Data?
            appearance.performAsCurrentDrawingAppearance {
                payload = png(of: host)
            }
            let url = directory.appendingPathComponent(
                "usage-dashboard-narrow-\(fixture.name).png"
            )
            try XCTUnwrap(payload, "No narrow Usage render for \(fixture.name)").write(to: url)
            files.append(url)

            XCTAssertEqual(
                dashboard.breakdownColumnTitlesForTesting,
                [
                    L10n.string("Model"),
                    L10n.string("Cost"),
                    L10n.string("Share"),
                    L10n.string("Tokens")
                ],
                "at the floor the request count stands down rather than the table scrolling sideways"
            )
            let fit = dashboard.breakdownColumnFitForTesting
            XCTAssertLessThanOrEqual(
                fit.occupied,
                fit.available + 0.5,
                "the breakdown's columns hang \(fit.occupied - fit.available)pt outside the table"
            )
        }

        print("Rendered narrow Usage fixtures to \(directory.path)")
        XCTAssertEqual(files.count, fixtures.count)
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingUsageRenders", isDirectory: true)
    }

    /// The dashboard at the content width every Settings page actually has; the floor is what a
    /// squeezed window leaves.
    private func laidOut(
        _ dashboard: UsageDashboardView,
        appearance: NSAppearance,
        width: CGFloat = Design.Size.settingsContentWidth
    ) -> NSView {
        let dashboardWidth = width
        let fleet = AccountUsageFleetView(scrollHost: .nestedPage)
        fleet.show(fleetFixture())
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        dashboard.widthAnchor.constraint(equalToConstant: dashboardWidth).isActive = true
        let section = SettingsUI.section("Current capacity", fleet)
        let stack = NSStackView(views: [dashboard, section])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false
        section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dashboard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let dashboardHeight = stack.fittingSize.height
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: dashboardWidth + Design.Spacing.large * 2,
            height: dashboardHeight + Design.Spacing.large * 2
        ))
        host.appearance = appearance
        host.wantsLayer = true
        appearance.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
        }
        stack.appearance = appearance
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.large),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.large),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Spacing.large)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func fleetFixture() -> [AccountUsageFleetItem] {
        let values: [(AgentKind, String, String, [Double?], Bool)] = [
            (.claude, "default", "Default", [0.75, 0.38], true),
            (.claude, "nhartley", "nhartley", [0.02, 0.20], false),
            (.claude, "ikeller", "ikeller", [0.26, 0.03], false),
            (.codex, "work", "Work", [0.41, nil], false),
            (.codex, "personal", "Personal", [0.94, 0.67], false)
        ]
        return values.map { provider, handle, name, fractions, current in
            let account = AgentAccount(
                provider: provider,
                handle: AccountHandle(storedName: handle),
                configPath: "/tmp/usage-\(handle)",
                displayName: name
            )
            let windows = fractions.enumerated().map { index, fraction in
                AccountUsage.Window(
                    id: index == 0 ? "5h" : "7d",
                    label: index == 0 ? "5-hour" : "Weekly",
                    fraction: fraction,
                    resetsAt: now.addingTimeInterval(index == 0 ? 14_100 : 5 * 86_400),
                    windowDuration: index == 0 ? 5 * 3_600 : 7 * 86_400
                )
            }
            return AccountUsageFleetItem(
                account: account,
                reading: .current(AccountUsage(
                    windows: windows,
                    planLabel: provider == .claude ? "Max" : "Pro",
                    observedAt: now,
                    source: .api
                )),
                isCurrent: current,
                allowsHandoff: !current && provider == .claude
            )
        }
    }

    private func png(of host: NSView) -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func reportFixture() -> TranscriptUsageReport {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let origins: [UsageOrigin] = [
            .direct(.claude),
            .direct(.codex),
            .direct(.grok),
            .direct(.openCode),
            .openCode(providerID: "openrouter")
        ]
        var cells: [TranscriptUsageReport.Cell] = []
        for dayIndex in 0..<90 {
            let day = calendar.date(byAdding: .day, value: -dayIndex, to: today)!
            for (routeIndex, origin) in origins.enumerated() {
                let spike = [18, 19, 20, 47, 48, 72, 73].contains(dayIndex) ? 4.8 : 1
                let wave = 0.55 + Double((dayIndex * (routeIndex + 3)) % 11) / 14
                let cost = spike * wave * Double(routeIndex + 1) * 0.9
                cells.append(TranscriptUsageReport.Cell(
                    day: day,
                    origin: origin,
                    accountID: "\(origin.runtimeID):fixture",
                    accountName: "Personal",
                    model: modelName(for: origin, index: routeIndex),
                    checkoutPath: "/Users/example/repo/project-\(dayIndex % 18)",
                    checkoutLabel: "Project \(dayIndex % 18)",
                    tokens: .init(
                        uncachedInput: Int64(cost * 160_000),
                        cachedInput: Int64(cost * 480_000),
                        cacheWrite: Int64(cost * 32_000),
                        output: Int64(cost * 72_000),
                        reasoning: Int64(cost * 9_000)
                    ),
                    providerReportedCostUSD: origin.billingProviderID == "openrouter" ? cost : 0,
                    catalogCostUSD: origin.billingProviderID == "openrouter" ? 0 : cost,
                    unpricedTokens: origin.runtimeID == AgentKind.grok.rawValue
                        ? Int64(cost * 20_000) : 0,
                    cacheSavingsUSD: cost * 2.4,
                    records: 4 + (dayIndex * (routeIndex + 2) + routeIndex * 7) % 29
                ))
            }
        }
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.sourceFiles = 246
        scan.cacheHits = 239
        scan.cacheMisses = 7
        scan.rawRecords = 18_420
        scan.distinctRecords = 18_105
        scan.duration = 0.28
        return TranscriptUsageReport(
            cells: cells,
            coverage: coverageFixture,
            scan: scan,
            builtAt: now
        )
    }

    private var coverageFixture: [UsageSourceCoverage] {
        [
            .init(runtimeID: "claude", runtimeName: "Claude Code", state: .complete, sourceCount: 82, recordCount: 7_400, detail: "Local transcripts"),
            .init(runtimeID: "codex", runtimeName: "Codex", state: .complete, sourceCount: 64, recordCount: 6_980, detail: "Local rollout files"),
            .init(runtimeID: "grok", runtimeName: "Grok", state: .partial, sourceCount: 0, recordCount: 0, detail: "Context occupancy only"),
            .init(runtimeID: "opencode", runtimeName: "OpenCode", state: .complete, sourceCount: 100, recordCount: 3_725, detail: "Supported local exports"),
            .init(runtimeID: "openrouter", runtimeName: "OpenRouter via OpenCode", state: .complete, sourceCount: 31, recordCount: 1_264, detail: "Billing route from OpenCode")
        ]
    }

    private func modelName(for origin: UsageOrigin, index: Int) -> String {
        switch origin.billingProviderID {
        case "anthropic": return index.isMultiple(of: 2) ? "claude-opus-4" : "claude-sonnet-4"
        case "openai": return "gpt-5.4"
        case "xai": return "grok-4"
        case "openrouter": return "openrouter/auto"
        default: return "opencode/zen"
        }
    }

    private func limitFixtures() -> [UsageLimitDashboardSeries] {
        let start = now.addingTimeInterval(-30 * 86_400)
        let interval: TimeInterval = 6 * 3_600
        var samples: [UsageSample] = []
        var events: [UsageLimitResetEvent] = []

        for index in 0...120 {
            let at = start.addingTimeInterval(Double(index) * interval)
            let cycle = index / 28
            let step = index % 28
            let reset = start.addingTimeInterval(Double((cycle + 1) * 28) * interval)
            samples.append(UsageSample(
                at: at,
                fraction: min(0.94, Double(step) * 0.033),
                resetsAt: reset,
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:personal",
                accountName: "Personal",
                windowID: "weekly",
                windowLabel: "Weekly",
                windowDuration: 7 * 86_400,
                source: .codexAPI,
                nextResetCreditExpiresAt: now.addingTimeInterval(28 * 86_400),
                resetCreditCount: 3
            ))
            if step == 0, index > 0 {
                events.append(UsageLimitResetEvent(
                    id: "reset-\(cycle)",
                    runtimeID: AgentKind.codex.rawValue,
                    accountID: "codex:personal",
                    accountName: "Personal",
                    windowID: "weekly",
                    windowLabel: "Weekly",
                    previousObservedAt: at.addingTimeInterval(-interval),
                    detectedAt: at,
                    oldScheduledResetAt: at,
                    newScheduledResetAt: reset,
                    restoredFraction: 0.89,
                    elapsedFraction: 1,
                    secondsEarly: 0,
                    cause: .scheduled
                ))
            }
        }
        let latest = samples.last!
        return [UsageLimitDashboardSeries(
            id: "codex|personal|weekly",
            runtimeName: "Codex",
            accountName: "Personal",
            windowLabel: "Weekly",
            samples: samples,
            resets: events,
            projection: UsageLimitHistoryAnalysis.weeklyProjection(for: samples),
            currentFraction: latest.fraction,
            resetsAt: latest.resetsAt,
            resetCreditCount: 3,
            nextResetCreditExpiresAt: now.addingTimeInterval(28 * 86_400)
        )]
    }
}
