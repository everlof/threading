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
            Fixture(name: "cyberpunk", theme: AppThemeStyles.cyberpunk, appearance: .darkAqua),
            Fixture(name: "neo-brutalism", theme: AppThemeStyles.neoBrutalism, appearance: .aqua),
            Fixture(name: "classic-player", theme: AppThemeStyles.classicPlayer, appearance: .darkAqua)
        ]
        var files: [URL] = []

        for fixture in fixtures {
            for tab in UsageDashboardView.DashboardTab.allCases {
                AppThemePalette.set(fixture.theme)
                let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
                let dashboard = UsageDashboardView()
                dashboard.update(
                    report: reportFixture(),
                    limits: limitFixtures(),
                    isBuilding: false,
                    animated: false
                )
                dashboard.selectTabForTesting(tab)
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
                XCTAssertEqual(dashboard.visibleTabForTesting, tab)
                XCTAssertEqual(dashboard.topToolCountForTesting, 3)
                XCTAssertEqual(dashboard.usageChartCompositionForTesting, .stackedBands)
                XCTAssertEqual(dashboard.limitChartCompositionForTesting, .independent)
                if tab == .overview {
                    XCTAssertGreaterThan(dashboard.breakdownVisibleSubviewCountForTesting, 0)
                    XCTAssertLessThan(dashboard.breakdownVisibleSubviewCountForTesting, 20)
                }

                var payload: Data?
                appearance.performAsCurrentDrawingAppearance {
                    payload = png(of: host)
                }
                let tabName = tab == .overview ? "overview" : "limits"
                let url = directory.appendingPathComponent(
                    "usage-dashboard-\(tabName)-\(fixture.name).png"
                )
                try XCTUnwrap(payload, "No Usage \(tabName) render for \(fixture.name)")
                    .write(to: url)
                files.append(url)
            }
        }

        print("Rendered Usage dashboard fixtures to \(directory.path)")
        XCTAssertEqual(files.count, fixtures.count * UsageDashboardView.DashboardTab.allCases.count)
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingUsageRenders", isDirectory: true)
    }

    private func laidOut(_ dashboard: UsageDashboardView, appearance: NSAppearance) -> NSView {
        let dashboardWidth: CGFloat = 932
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        dashboard.widthAnchor.constraint(equalToConstant: dashboardWidth).isActive = true
        let dashboardHeight = dashboard.fittingSize.height
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
        dashboard.appearance = appearance
        host.addSubview(dashboard)
        NSLayoutConstraint.activate([
            dashboard.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.large),
            dashboard.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.Spacing.large),
            dashboard.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.large),
            dashboard.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Spacing.large)
        ])
        host.layoutSubtreeIfNeeded()
        return host
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
                    records: 12 + dayIndex % 28
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
                nextResetCreditExpiresAt: now.addingTimeInterval(4 * 86_400),
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
            nextResetCreditExpiresAt: now.addingTimeInterval(4 * 86_400)
        )]
    }
}
