import XCTest
@testable import Threading

final class UsageLimitHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)
    private let week: TimeInterval = 7 * 86_400

    func testEarlyCodexClearRequiresAndClassifiesSpentBankedReset() throws {
        let previous = sample(day: 2, fraction: 0.80, resetDay: 7, credits: 3)
        let current = sample(day: 2.1, fraction: 0.03, resetDay: 14, credits: 2)

        let event = try XCTUnwrap(UsageLimitHistoryAnalysis.reset(
            between: previous,
            and: current
        ))

        XCTAssertEqual(event.cause, .bankedCredit)
        XCTAssertTrue(event.isEarly)
        XCTAssertEqual(event.restoredFraction, 0.80, accuracy: 0.001)
        XCTAssertEqual(event.secondsEarly, 4.9 * 86_400, accuracy: 1)
        XCTAssertEqual(event.elapsedFraction, 2.1 / 7, accuracy: 0.001)
        XCTAssertGreaterThan(event.paceGainFraction, 0.49)
    }

    func testEarlyCodexClearWithoutSpentCreditIsNotCalledAReset() {
        let previous = sample(day: 2, fraction: 0.80, resetDay: 7, credits: 3)
        let current = sample(day: 2.1, fraction: 0.03, resetDay: 14, credits: 3)

        XCTAssertNil(UsageLimitHistoryAnalysis.reset(between: previous, and: current))
    }

    func testEarlyCodexClearWithoutSpentCreditIsLiveCurfewEvidence() throws {
        let previous = sample(day: 2, fraction: 0.80, resetDay: 7, credits: 3)
        let current = sample(day: 2.1, fraction: 0.03, resetDay: 14, credits: 3)

        let event = try XCTUnwrap(UsageLimitHistoryAnalysis.curfewReset(
            between: previous,
            and: current
        ))

        XCTAssertEqual(event.windowID, try XCTUnwrap(previous.windowID))
        XCTAssertEqual(event.cause, .provider)
        XCTAssertTrue(event.isEarly)
    }

    func testClearAtScheduledBoundaryIsClassifiedAsScheduled() throws {
        let previous = sample(day: 6.98, fraction: 0.91, resetDay: 7, credits: nil)
        let current = sample(day: 6.995, fraction: 0.02, resetDay: 14, credits: nil)

        let event = try XCTUnwrap(UsageLimitHistoryAnalysis.reset(
            between: previous,
            and: current
        ))
        XCTAssertEqual(event.cause, .scheduled)
        XCTAssertFalse(event.isEarly)
    }

    func testCorrectionWithoutResetAdvanceDoesNotCreateEvent() {
        let previous = sample(day: 2, fraction: 0.80, resetDay: 7, credits: 2)
        let current = sample(day: 2.1, fraction: 0.03, resetDay: 7, credits: 2)

        XCTAssertNil(UsageLimitHistoryAnalysis.reset(between: previous, and: current))
    }

    func testWeeklyProjectionSeparatesEstimateAndCreditExpiryFromObservations() throws {
        let expiry = start.addingTimeInterval(4 * 86_400)
        let latest = UsageSample(
            at: start.addingTimeInterval(3 * 86_400),
            fraction: 0.60,
            resetsAt: start.addingTimeInterval(week),
            runtimeID: AgentKind.codex.rawValue,
            accountID: "codex:work",
            accountName: "Work",
            windowID: "weekly",
            windowLabel: "Weekly",
            windowDuration: week,
            source: .codexAPI,
            nextResetCreditExpiresAt: expiry,
            resetCreditCount: 1
        )

        let projection = try XCTUnwrap(
            UsageLimitHistoryAnalysis.weeklyProjection(for: [latest])
        )

        XCTAssertEqual(projection.projectedFractionAtReset, 1, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(projection.projectedExhaustionAt).timeIntervalSince(start),
            5 * 86_400,
            accuracy: 1
        )
        XCTAssertEqual(projection.resetCreditExpiresAt, expiry)
        XCTAssertEqual(latest.fraction, 0.60, "projection must not mutate observed history")
    }

    func testDownsamplingPreservesBoundsExtremaAndResetDiscontinuity() {
        let reset = start.addingTimeInterval(week)
        var samples = (0..<3_600).map { index in
            sample(
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                fraction: 0.2 + Double(index % 100) / 500,
                resetsAt: reset
            )
        }
        samples[321] = sample(at: samples[321].at, fraction: 1, resetsAt: reset)
        samples[322] = sample(at: samples[322].at, fraction: 0, resetsAt: reset)
        samples[1_999] = sample(at: samples[1_999].at, fraction: 0.96, resetsAt: reset)
        samples[2_000] = sample(
            at: samples[2_000].at,
            fraction: 0.02,
            resetsAt: reset.addingTimeInterval(week)
        )

        let result = UsageLimitHistoryAnalysis.downsample(samples, maximumCount: 280)

        XCTAssertLessThanOrEqual(result.count, 280)
        XCTAssertEqual(result.first, samples.first)
        XCTAssertEqual(result.last, samples.last)
        XCTAssertTrue(result.contains(samples[321]))
        XCTAssertTrue(result.contains(samples[322]))
        XCTAssertTrue(result.contains(samples[1_999]))
        XCTAssertTrue(result.contains(samples[2_000]))

        let points = UsageLimitHistoryAnalysis.segmented(result)
        XCTAssertGreaterThan(points.last?.segment ?? 0, 0)
        XCTAssertNotEqual(
            points.first(where: { $0.sample == samples[1_999] })?.segment,
            points.first(where: { $0.sample == samples[2_000] })?.segment
        )
    }

    @MainActor
    func testRecordingHistoryPublishesTheTypedHistoryEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-history-event-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(directory: directory)
        let observations = AppEventObservations()
        var deliveries = 0
        observations.observe(UsageLimitHistoryDidChange.self) { _ in deliveries += 1 }
        let account = AgentAccount(
            provider: .codex,
            handle: AccountHandle(storedName: "history-event"),
            configPath: directory.path,
            displayName: "History Event"
        )
        let usage = AccountUsage(
            windows: [AccountUsage.Window(
                id: "weekly",
                label: "Weekly",
                fraction: 0.42,
                resetsAt: start.addingTimeInterval(week),
                windowDuration: week
            )],
            planLabel: "Pro",
            observedAt: start,
            source: .api
        )

        store.record(usage, for: account)

        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testRecordingPublishesUncreditedCodexClearForCurfewButNotHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-history-curfew-reset-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(directory: directory)
        let observations = AppEventObservations()
        var evidence: [UsageLimitResetEvent] = []
        observations.observe(UsageLimitHistoryDidChange.self) {
            evidence.append(contentsOf: $0.resetEvents)
        }
        let account = AgentAccount(
            provider: .codex,
            handle: AccountHandle(storedName: "curfew-reset"),
            configPath: directory.path,
            displayName: "Curfew Reset"
        )

        var before = AccountUsage(
            windows: [AccountUsage.Window(
                id: UsageDefaults.weeklyWindowID,
                label: UsageDefaults.weeklyLabel,
                fraction: 0.80,
                resetsAt: start.addingTimeInterval(7 * 86_400),
                windowDuration: week
            )],
            planLabel: "Pro",
            observedAt: start.addingTimeInterval(2 * 86_400),
            source: .api
        )
        before.resetCredits = 3
        var after = AccountUsage(
            windows: [AccountUsage.Window(
                id: UsageDefaults.weeklyWindowID,
                label: UsageDefaults.weeklyLabel,
                fraction: 0.03,
                resetsAt: start.addingTimeInterval(14 * 86_400),
                windowDuration: week
            )],
            planLabel: "Pro",
            observedAt: start.addingTimeInterval(2.1 * 86_400),
            source: .api
        )
        after.resetCredits = 3

        store.record(before, for: account)
        store.record(after, for: account)

        XCTAssertEqual(evidence.map(\.windowID), [UsageDefaults.weeklyWindowID])
        XCTAssertEqual(evidence.map(\.cause), [.provider])
        XCTAssertTrue(
            store.snapshot(since: start).resets.isEmpty,
            "the dashboard retained evidence its conservative history rule rejected"
        )
    }

    private func sample(
        day: Double,
        fraction: Double,
        resetDay: Double,
        credits: Int?
    ) -> UsageSample {
        sample(
            at: start.addingTimeInterval(day * 86_400),
            fraction: fraction,
            resetsAt: start.addingTimeInterval(resetDay * 86_400),
            credits: credits
        )
    }

    private func sample(
        at: Date,
        fraction: Double,
        resetsAt: Date?,
        credits: Int? = nil
    ) -> UsageSample {
        UsageSample(
            at: at,
            fraction: fraction,
            resetsAt: resetsAt,
            runtimeID: AgentKind.codex.rawValue,
            accountID: "codex:work",
            accountName: "Work",
            windowID: "weekly",
            windowLabel: "Weekly",
            windowDuration: week,
            source: .codexAPI,
            resetCreditCount: credits
        )
    }
}
