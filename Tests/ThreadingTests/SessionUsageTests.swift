import XCTest
@testable import Threading

final class SessionUsageTests: XCTestCase {
    func testBuilderRetainsLifetimeSessionCellsOutsideDashboardRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-17T12:00:00Z"))
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -120, to: now))

        let report = UsageLedgerBuilder.build(
            records: [
                record(identity: "old", sessionID: "parent", at: old, tokens: .init(uncachedInput: 10)),
                record(identity: "undated", sessionID: "parent", at: nil, tokens: .init(output: 5))
            ],
            coverage: [],
            projects: [],
            scan: .init(),
            now: now,
            calendar: calendar
        )

        XCTAssertTrue(report.cells.isEmpty, "daily dashboard cells should keep their 90-day bound")
        let lifetime = try XCTUnwrap(report.sessionCells)
        XCTAssertEqual(lifetime.count, 1)
        XCTAssertEqual(lifetime[0].tokens.processed, 15)
        XCTAssertEqual(lifetime[0].records, 2)
    }

    func testProjectionReconcilesParentChildrenAndLiveUnindexedDelta() {
        let sessionID = SessionID()
        let report = TranscriptUsageReport(
            sessionCells: [
                cell(sessionID: "parent", tokens: .init(uncachedInput: 80, output: 20), catalogCost: 0.4),
                cell(sessionID: "child-alias", tokens: .init(cachedInput: 150, output: 50), catalogCost: 0.2)
            ],
            builtAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = SessionUsageProjector.Input(
            sessionID: sessionID,
            runtimeID: AgentKind.codex.rawValue,
            mainIdentities: ["parent"],
            children: [
                .init(
                    id: "child",
                    identities: ["child", "child-alias"],
                    observedProcessedTokens: 260
                )
            ]
        )

        let snapshot = SessionUsageProjector.project(report: report, input: input)

        XCTAssertEqual(snapshot.main.processedTokens, 100)
        XCTAssertEqual(snapshot.subagents.processedTokens, 260)
        XCTAssertEqual(snapshot.total.processedTokens, 360)
        XCTAssertEqual(snapshot.total.tokens.processed, 300)
        XCTAssertEqual(snapshot.total.unindexedTokens, 60)
        XCTAssertEqual(snapshot.children["child"]?.processedTokens, 260)
        XCTAssertEqual(snapshot.total.cost.catalogPricedUSD, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.indexedRange, .lifetime)
    }

    func testDurableParentProvenanceIncludesUnobservedChildWithoutInventingNavigatorRow() {
        let report = TranscriptUsageReport(sessionCells: [
            cell(sessionID: "parent", tokens: .init(output: 20)),
            cell(
                sessionID: "unobserved-child",
                tokens: .init(cachedInput: 30, output: 10),
                sessionKind: .subagent,
                parentSessionID: "parent"
            )
        ])
        let input = SessionUsageProjector.Input(
            sessionID: SessionID(),
            runtimeID: AgentKind.claude.rawValue,
            mainIdentities: ["parent"],
            children: []
        )

        let snapshot = SessionUsageProjector.project(report: report, input: input)

        XCTAssertEqual(snapshot.main.processedTokens, 20)
        XCTAssertEqual(snapshot.subagents.processedTokens, 40)
        XCTAssertEqual(snapshot.total.processedTokens, 60)
        XCTAssertTrue(snapshot.children.isEmpty)
    }

    func testLegacyReportStatesNinetyDayRangeInsteadOfClaimingLifetime() {
        let now = Date()
        let report = TranscriptUsageReport(cells: [
            .init(
                day: Calendar.current.startOfDay(for: now),
                origin: .direct(.claude),
                sessionID: "parent",
                accountID: "claude:default",
                accountName: "Claude",
                model: "claude-opus-4-6",
                checkoutPath: "/tmp/project",
                checkoutLabel: "project",
                tokens: .init(output: 25),
                providerReportedCostUSD: 0,
                catalogCostUSD: 0.1,
                unpricedTokens: 0,
                cacheSavingsUSD: 0,
                records: 1
            )
        ])
        let input = SessionUsageProjector.Input(
            sessionID: SessionID(),
            runtimeID: AgentKind.claude.rawValue,
            mainIdentities: ["parent"],
            children: []
        )

        let snapshot = SessionUsageProjector.project(report: report, input: input)

        XCTAssertEqual(snapshot.indexedRange, .lastNinetyDays)
        XCTAssertEqual(snapshot.total.processedTokens, 25)
    }

    func testProjectionCapsModelRowsAfterAggregatingEveryModel() {
        let cells = (0..<(SessionUsageDefaults.maximumModelRows + 3)).map { index in
            cell(
                sessionID: "parent",
                model: "model-\(index)",
                tokens: .init(output: Int64(index + 1))
            )
        }
        let report = TranscriptUsageReport(sessionCells: cells)
        let input = SessionUsageProjector.Input(
            sessionID: SessionID(),
            runtimeID: AgentKind.codex.rawValue,
            mainIdentities: ["parent"],
            children: []
        )

        let snapshot = SessionUsageProjector.project(report: report, input: input)

        XCTAssertEqual(snapshot.total.models.count, SessionUsageDefaults.maximumModelRows)
        XCTAssertEqual(snapshot.total.remainingModelCount, 3)
        XCTAssertEqual(
            snapshot.total.processedTokens,
            Int64((1...(SessionUsageDefaults.maximumModelRows + 3)).reduce(0, +))
        )
    }

    func testReusableIndexIgnoresUnrelatedSessionCells() {
        let unrelated = (0..<10_000).map { index in
            cell(
                sessionID: "other-\(index)",
                model: "model-\(index)",
                tokens: .init(output: 1)
            )
        }
        let report = TranscriptUsageReport(sessionCells: unrelated + [
            cell(sessionID: "", tokens: .init(output: 999)),
            cell(sessionID: "parent", tokens: .init(output: 12)),
            cell(sessionID: "child", tokens: .init(output: 8))
        ])
        let index = SessionUsageProjector.Index(report: report)
        let input = SessionUsageProjector.Input(
            sessionID: SessionID(),
            runtimeID: AgentKind.codex.rawValue,
            mainIdentities: ["", "parent"],
            children: [.init(id: "child", identities: ["child"])]
        )

        let snapshot = SessionUsageProjector.project(index: index, input: input)

        XCTAssertEqual(snapshot.main.processedTokens, 12)
        XCTAssertEqual(snapshot.subagents.processedTokens, 8)
        XCTAssertEqual(snapshot.total.processedTokens, 20)
        XCTAssertEqual(snapshot.total.models.count, 1)
    }

    private func record(
        identity: String,
        sessionID: String,
        at: Date?,
        tokens: UsageTokenCounts
    ) -> UsageLedgerRecord {
        UsageLedgerRecord(
            identity: identity,
            sessionID: sessionID,
            at: at,
            origin: .direct(.codex),
            accountID: "codex:default",
            accountName: "Codex",
            model: "gpt-5.6-terra",
            workingDirectory: "/tmp/project",
            tokens: tokens
        )
    }

    private func cell(
        sessionID: String,
        model: String = "gpt-5.6-terra",
        tokens: UsageTokenCounts,
        catalogCost: Double = 0,
        sessionKind: UsageSessionKind? = nil,
        parentSessionID: String? = nil
    ) -> TranscriptUsageReport.SessionCell {
        .init(
            sessionID: sessionID,
            origin: .direct(.codex),
            accountID: "codex:default",
            accountName: "Codex",
            model: model,
            tokens: tokens,
            providerReportedCostUSD: 0,
            catalogCostUSD: catalogCost,
            unpricedTokens: 0,
            cacheSavingsUSD: 0,
            records: 1,
            sessionKind: sessionKind,
            parentSessionID: parentSessionID
        )
    }
}
