import AppKit
import XCTest
@testable import Threading
import ThreadingController
import ThreadingUsage

/// Shared fixtures: a Mac transcript report, connected hosts' daily cells and a worker's receipts,
/// all built from the controller's own JSON so the app decodes exactly what a host sends.
enum AgentUsageFixtures {
    static let workerA = "11111111-1111-1111-1111-111111111111"
    static let workerB = "22222222-2222-2222-2222-222222222222"
    static let workerC = "33333333-3333-3333-3333-333333333333"

    static func cell(_ day: String, worker: String, model: String = "claude-sonnet-4-5", cost: Double,
                     uncached: Int64 = 1_000, cached: Int64 = 4_000, output: Int64 = 500, requests: Int64 = 3,
                     executions: Int64 = 1) -> UsageDailyCell {
        let json = """
        {"day":"\(day)","workerID":"\(worker)","account":"ops","model":"\(model)","uncachedInput":\(uncached),\
        "cachedInput":\(cached),"cacheWrite":0,"output":\(output),"reasoning":0,"costUSD":\(cost),\
        "requests":\(requests),"executions":\(executions)}
        """
        return try! JSONDecoder().decode(UsageDailyCell.self, from: Data(json.utf8))
    }

    static func receipt(worker: String = workerA, work: String = UUID().uuidString, endedAt: String,
                        trigger: String? = nil, chain: UUID? = nil, coverage: String = "complete",
                        reason: String? = nil, cost: Double, output: Int64 = 400) -> UsageReceipt {
        let tokens = String(decoding: try! JSONEncoder().encode(UsageTokenCounts(uncachedInput: 2_000, cachedInput: 6_000, output: output)),
                            as: UTF8.self)
        var object = """
        {"executionID":"\(UUID().uuidString)","workID":"\(work)","workerID":"\(worker)","source":"event",\
        "runtime":"claude","account":"ops","coverage":"\(coverage)","endedAt":"\(endedAt)",\
        "cells":[{"model":"claude-sonnet-4-5","tokens":\(tokens),"requests":4,"costUSD":\(cost),"unpricedTokens":0}]
        """
        if let trigger { object += ",\"triggerID\":\"\(trigger)\"" }
        if let chain { object += ",\"chainID\":\"\(chain.uuidString)\"" }
        if let reason { object += ",\"reason\":\"\(reason)\"" }
        object += "}"
        return try! JSONDecoder().decode(UsageReceipt.self, from: Data(object.utf8))
    }

    static func macCell(day: Date, accountID: String, accountName: String, cost: Double, records: Int)
        -> TranscriptUsageReport.Cell {
        .init(day: day, origin: .direct(.claude), accountID: accountID, accountName: accountName,
              model: "claude-opus-4", checkoutPath: "/Users/example/repo", checkoutLabel: "repo",
              tokens: .init(uncachedInput: 10_000, cachedInput: 30_000, output: 2_000),
              providerReportedCostUSD: 0, catalogCostUSD: cost, unpricedTokens: 0, cacheSavingsUSD: 0, records: records)
    }

    static func snapshot(_ cells: [UsageDailyCell], at date: Date, names: [String: String],
                         completeFrom: String? = nil) -> RemoteAgentUsageSnapshot {
        let from = RemoteAgentUsageDay.string(daysBefore: 89, date)
        return RemoteAgentUsageSnapshot(fetchedAt: date, from: from, through: RemoteAgentUsageDay.string(date),
                                        completeFrom: completeFrom ?? from, cells: cells, workerNames: names)
    }

    /// This Mac (a local Claude session and a session mirrored from `devbox`), `devbox`'s workers
    /// read now, `vps` unreachable since an hour ago, and `lab` never read.
    static func scenario(now: Date) -> (report: TranscriptUsageReport, hosts: [RemoteAgentUsageHostState], devbox: RemoteHostID) {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let devbox = RemoteHostID(), vps = RemoteHostID(), lab = RemoteHostID()
        let report = TranscriptUsageReport(cells: [
            macCell(day: today, accountID: "claude:default", accountName: "Default", cost: 2, records: 3),
            macCell(day: today, accountID: UsageReportDefaults.remoteHostAccountPrefix + devbox.description,
                    accountName: "devbox", cost: 1, records: 1)
        ], builtAt: now)
        let day = { (offset: Int) in RemoteAgentUsageDay.string(daysBefore: offset, now) }
        var devboxState = RemoteAgentUsageHostState(hostID: devbox, hostName: "devbox")
        devboxState.snapshot = snapshot([
            cell(day(0), worker: workerA, cost: 0.40),
            // The same (day, worker, account, model) read twice across a page boundary: the
            // later value replaces the earlier, never adds to it.
            cell(day(0), worker: workerA, cost: 0.50),
            cell(day(1), worker: workerA, model: "claude-haiku-4-5", cost: 0.10),
            cell(day(40), worker: workerB, cost: 3.00)
        ], at: now, names: [workerA: "Newsletter triage", workerB: "Release notes"])
        devboxState.lastAttemptAt = now
        var vpsState = RemoteAgentUsageHostState(hostID: vps, hostName: "vps")
        vpsState.snapshot = snapshot([cell(day(1), worker: workerC, cost: 0.25)], at: now.addingTimeInterval(-3_600),
                                     names: [workerC: "Inbox watcher"])
        vpsState.lastFailure = "ssh: connect to host vps: Operation timed out"
        let labState = RemoteAgentUsageHostState(hostID: lab, hostName: "lab")
        return (report, [devboxState, vpsState, labState], devbox)
    }
}

/// The Agents breakdown's attribution: sessions by where they ran, workers by host, nothing
/// counted twice, stale and unread hosts said rather than zeroed.
final class AgentUsageProjectionTests: XCTestCase {
    private let now = Date()

    func testAgentsBreakdownJoinsSessionsAndWorkersWithoutCountingAnythingTwice() throws {
        let scenario = AgentUsageFixtures.scenario(now: now)
        let overview = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now))
        let month = try XCTUnwrap(overview.range(days: 30))
        let agents = month.breakdown(.agents)

        let measured = agents.rows.filter { !$0.isUnmeasured }
        let summary = measured.map { "\($0.title)@\($0.location ?? "-")" }
        XCTAssertEqual(summary, ["Sessions@This Mac", "Sessions@devbox", "Newsletter triage@devbox", "Inbox watcher@vps"])
        XCTAssertEqual(measured.map(\.costUSD), [2, 1, 0.60, 0.25].map { $0 }, accuracy: 1e-9)

        // Sessions come only from the transcript ledger and workers only from controller cells:
        // the agents total is exactly their sum, and this Mac's own total is untouched by workers.
        XCTAssertEqual(month.cost.totalUSD, 3, accuracy: 1e-9, "a host's workers are billed to the host, not this Mac")
        XCTAssertEqual(measured.reduce(0) { $0 + $1.costUSD }, 3 + 0.60 + 0.25, accuracy: 1e-9)
        XCTAssertEqual(measured.filter { $0.title == "Sessions" }.reduce(0) { $0 + $1.costUSD },
                       month.cost.totalUSD, accuracy: 1e-9)

        // A mirrored remote session is the host's row, not this Mac's.
        XCTAssertEqual(measured.first { $0.location == "This Mac" }?.records, 3)

        // Freshness is data: vps keeps its numbers with their age, lab is not a zero.
        let vps = try XCTUnwrap(measured.first { $0.location == "vps" })
        XCTAssertEqual(vps.staleSince, now.addingTimeInterval(-3_600))
        XCTAssertNil(measured.first { $0.location == "devbox" && $0.title != "Sessions" }?.staleSince)
        let lab = try XCTUnwrap(agents.rows.last)
        XCTAssertTrue(lab.isUnmeasured)
        XCTAssertEqual(lab.location, "lab")
    }

    func testRangeSelectsWorkerDaysAndATruncatedSummaryIsPartial() throws {
        var scenario = AgentUsageFixtures.scenario(now: now)
        let quarter = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now)?
            .range(days: 90)?.breakdown(.agents))
        XCTAssertEqual(quarter.rows.first { $0.title == "Release notes" }?.costUSD ?? 0, 3, accuracy: 1e-9)
        let week = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now)?
            .range(days: 7)?.breakdown(.agents))
        XCTAssertNil(week.rows.first { $0.title == "Release notes" }, "a cell forty days old is outside the week")

        let snapshot = try XCTUnwrap(scenario.hosts[0].snapshot)
        scenario.hosts[0].snapshot = AgentUsageFixtures.snapshot(snapshot.cells, at: now, names: snapshot.workerNames,
                                                                 completeFrom: RemoteAgentUsageDay.string(daysBefore: 6, now))
        let partial = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now)?
            .range(days: 30)?.breakdown(.agents))
        XCTAssertTrue(partial.rows.first { $0.title == "Newsletter triage" }?.isPartial ?? false)
        let partialWeek = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now)?
            .range(days: 7)?.breakdown(.agents))
        XCTAssertFalse(partialWeek.rows.first { $0.title == "Newsletter triage" }?.isPartial ?? true,
                       "the newest week was read completely")
    }

    /// The phone's wire describes the four ledger breakdowns; worker rows come from this Mac's
    /// owner connections and never reach a paired device through it.
    func testTheAgentsBreakdownStaysOffThePhoneWire() throws {
        let scenario = AgentUsageFixtures.scenario(now: now)
        let overview = try XCTUnwrap(UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now))
        let wire = RemoteUsageBridge.dashboard(
            overview: overview,
            limitIndex: UsageDashboardProjector.limitIndex(from: .empty, now: now),
            isBuilding: false, limitOffset: 0, limitCount: 10)
        let breakdowns = try XCTUnwrap(wire.ranges.first?.breakdowns)
        XCTAssertEqual(breakdowns.count, UsageDashboardBreakdownKind.allCases.count - 1)
        XCTAssertFalse(breakdowns.flatMap(\.rows).contains { $0.title == "Newsletter triage" })
    }

    func testWorkerProjectionSplitsByDayTaskTriggerAndChainWithCoverage() throws {
        let worker = try WorkerID(AgentUsageFixtures.workerA)
        let scenario = AgentUsageFixtures.scenario(now: now)
        let cells = try XCTUnwrap(scenario.hosts[0].snapshot?.cells)
        let today = RemoteAgentUsageDay.string(now)
        let task = UUID().uuidString.lowercased()
        let chain = UUID()
        let receipts = [
            AgentUsageFixtures.receipt(work: task, endedAt: "\(today)T09:00:00Z", trigger: "newsletters", cost: 0.2),
            AgentUsageFixtures.receipt(work: task, endedAt: "\(today)T10:00:00Z", trigger: "newsletters", chain: chain,
                                       coverage: "partial", reason: "line 41 unreadable", cost: 0.1),
            AgentUsageFixtures.receipt(endedAt: "\(today)T11:00:00Z", cost: 0.3),
            // Another worker's receipt never joins this one's page.
            AgentUsageFixtures.receipt(worker: AgentUsageFixtures.workerB, endedAt: "\(today)T11:00:00Z", cost: 9)
        ]
        let projection = RemoteWorkerUsageProjection.make(worker: worker, cells: cells, receipts: receipts + [receipts[0]],
                                                          days: 30, now: now)
        XCTAssertEqual(projection.days.map(\.day), [today, RemoteAgentUsageDay.string(daysBefore: 1, now)])
        XCTAssertEqual(projection.total.costUSD, 0.60, accuracy: 1e-9, "daily cells, deduplicated")
        XCTAssertEqual(projection.receiptsRead, 3, "a receipt read twice is one execution")
        XCTAssertEqual(projection.incompleteReceipts, 1)
        XCTAssertEqual(projection.byTask.first?.key, task)
        XCTAssertEqual(projection.byTask.first?.executions, 2)
        XCTAssertEqual(projection.byTask.first?.incomplete, 1)
        XCTAssertEqual(projection.byTrigger.map(\.key), ["newsletters", ""])
        XCTAssertEqual(projection.byTrigger.first?.costUSD ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(projection.byChain.map(\.key), [chain.uuidString.lowercased()])
        XCTAssertEqual(projection.executions.first?.endedAt, "\(today)T11:00:00Z", "newest first")
        XCTAssertEqual(projection.executions.first { $0.coverage == .partial }?.reason, "line 41 unreadable")
    }

    func testWorkerFoldStaysProportionalToCellsNotHistory() {
        // The stress contract: 100 workers over 90 days in two models is 18,000 cells.
        var cells: [UsageDailyCell] = []
        for worker in 0..<100 {
            let id = String(format: "00000000-0000-0000-0000-%012d", worker)
            for day in 0..<90 {
                for model in ["a", "b"] {
                    cells.append(AgentUsageFixtures.cell(RemoteAgentUsageDay.string(daysBefore: day, now), worker: id,
                                                         model: model, cost: 0.01))
                }
            }
        }
        var state = RemoteAgentUsageHostState(hostID: RemoteHostID(), hostName: "fleet")
        state.snapshot = AgentUsageFixtures.snapshot(cells, at: now, names: [:])
        let report = AgentUsageFixtures.scenario(now: now).report
        let start = Date()
        let overview = UsageDashboardProjector.overview(report: report, agents: [state], now: now)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let rows = overview?.range(days: 90)?.breakdown(.agents).rows ?? []
        XCTAssertEqual(rows.filter { $0.location == "fleet" }.count, 100)
        XCTAssertEqual(rows.filter { $0.location == "fleet" }.reduce(0) { $0 + $1.costUSD }, 180, accuracy: 1e-6)
    }
}

private func XCTAssertEqual(_ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) { XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line) }
}

/// The Agents breakdown on the Usage page and a worker's usage sheet, light and dark.
@MainActor
final class AgentUsageRenderTests: XCTestCase {
    private let now = Date()

    func testRendersTheAgentsBreakdownLightAndDark() throws {
        let scenario = AgentUsageFixtures.scenario(now: now)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let dashboard = UsageDashboardView()
            dashboard.update(
                overview: UsageDashboardProjector.overview(report: scenario.report, agents: scenario.hosts, now: now),
                limits: [], isBuilding: false, animated: false)
            dashboard.selectBreakdownForTesting(.agents)
            let host = host(dashboard, width: Design.Size.settingsContentWidth, appearance: appearance)

            XCTAssertEqual(dashboard.breakdownColumnTitlesForTesting.first, "Agent")
            let notes = dashboard.breakdownNotesForTesting
            XCTAssertEqual(notes.first ?? nil, "This Mac")
            XCTAssertTrue(notes.contains { $0?.hasPrefix("vps · last read") ?? false }, "\(notes)")
            XCTAssertEqual(notes.last ?? nil, "lab · not read yet")
            XCTAssertEqual(dashboard.breakdownCostsForTesting.last, "—", "an unread host is not a zero")
            XCTAssertGreaterThan(dashboard.breakdownVisibleSubviewCountForTesting, 0)
            let fit = dashboard.breakdownColumnFitForTesting
            XCTAssertLessThanOrEqual(fit.occupied, fit.available + 0.5)
            try write(host, appearance: appearance, name: "usage-agents-breakdown-\(name)")
        }
    }

    func testRendersAWorkersUsageSheetLightAndDark() throws {
        let scenario = AgentUsageFixtures.scenario(now: now)
        let today = RemoteAgentUsageDay.string(now)
        let receipts = [
            AgentUsageFixtures.receipt(endedAt: "\(today)T09:12:00Z", trigger: "newsletters", cost: 0.21),
            AgentUsageFixtures.receipt(endedAt: "\(today)T10:40:00Z", trigger: "newsletters", chain: UUID(),
                                       coverage: "partial", reason: "line 41 unreadable", cost: 0.09),
            AgentUsageFixtures.receipt(endedAt: "\(today)T11:05:00Z", coverage: "unavailable", reason: "no transcript", cost: 0)
        ]
        let budget = try JSONDecoder().decode(WorkerBudget.self, from: Data(
            "{\"workerID\":\"\(AgentUsageFixtures.workerA)\",\"revision\":2,\"tokensPerDay\":250000}".utf8))
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)
        let devboxHost = RemoteAgentUsageHost(
            id: scenario.devbox, name: "devbox",
            endpoint: RemoteAutomationEndpoint(hostID: scenario.devbox, executable: "/usr/bin/c", database: "/var/c.db"),
            destination: RemoteHostDestination(alias: "devbox", configFile: nil))
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for section in [RemoteWorkerUsageViewController.Section.days, .receipts] {
                let controller = RemoteWorkerUsageViewController(host: devboxHost)
                controller.showForTesting(
                    workers: [(AgentUsageFixtures.workerA, "Newsletter triage"), (AgentUsageFixtures.workerB, "Release notes")],
                    state: scenario.hosts[0], receipts: receipts, budget: budget, now: now)
                controller.selectSectionForTesting(section)
                let view = controller.view
                view.appearance = appearance
                view.layoutSubtreeIfNeeded()
                AppThemeRefresh.repaint(view)

                XCTAssertTrue(controller.budgetTextForTesting.contains("250K"), controller.budgetTextForTesting)
                XCTAssertTrue(controller.receiptsTextForTesting.contains("2 are partial"), controller.receiptsTextForTesting)
                let rows = controller.tableForTesting.rowsForTesting
                switch section {
                case .days:
                    XCTAssertEqual(rows.count, 2)
                    XCTAssertEqual(rows.first?.values.first, today)
                case .receipts:
                    XCTAssertEqual(rows.map { $0.values[1] }, ["Unavailable", "Partial", "Complete"])
                    XCTAssertEqual(rows.map(\.warningColumns), [[1], [1], []], "coverage is said and marked per receipt")
                    XCTAssertEqual(rows[1].accessibilityDetail, "line 41 unreadable")
                default: break
                }
                XCTAssertLessThanOrEqual(controller.tableForTesting.visibleCellCount, 10)
                try write(view, appearance: appearance, name: "worker-usage-\(section)-\(name)")
            }
        }
    }

    private func host(_ view: NSView, width: CGFloat, appearance: NSAppearance) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        let height = view.fittingSize.height
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width + Design.Spacing.large * 2,
                                        height: height + Design.Spacing.large * 2))
        host.appearance = appearance
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.large),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.large)
        ])
        host.layoutSubtreeIfNeeded()
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func write(_ view: NSView, appearance: NSAppearance, name: String) throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ThreadingUsageRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            payload = rep.representation(using: .png, properties: [:])
        }
        try XCTUnwrap(payload, "no render for \(name)").write(to: directory.appendingPathComponent("\(name).png"))
    }
}
