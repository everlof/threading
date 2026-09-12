import XCTest
@testable import Threading

final class TriggerEngineTests: XCTestCase {
    func testIngestMatchesOnlyActiveRevisionAndDeduplicatesRedelivery() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let active = try await fixture.trigger(
            sourceID: source.id,
            condition: TriggerCondition(
                attribute: "status",
                comparison: .equals,
                value: .string("needs_review")
            )
        )
        let engine = TriggerEngine(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let event = fixture.event(sourceID: source.id, status: "needs_review")

        let first = try await engine.ingest(event)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.dispatches.map(\.revision.id), [active.revision.id])
        XCTAssertEqual(first.createdRuns.map(\.state), [.received])

        let redelivery = try await engine.ingest(event)
        XCTAssertFalse(redelivery.accepted)
        XCTAssertTrue(redelivery.dispatches.isEmpty)
    }

    func testQuietHoursPersistRunWithoutDispatchingIt() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        _ = try await fixture.trigger(
            sourceID: source.id,
            quietHours: TriggerQuietHours(
                startMinute: 0,
                endMinute: 120,
                timeZoneIdentifier: "UTC"
            )
        )
        let engine = TriggerEngine(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 3_600) }
        )

        let result = try await engine.ingest(fixture.event(sourceID: source.id))
        XCTAssertTrue(result.dispatches.isEmpty)
        XCTAssertEqual(result.createdRuns.first?.state, .queued)
        XCTAssertEqual(result.createdRuns.first?.holdReason, .quietHours)

        let releaseEngine = TriggerEngine(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 10_800) }
        )
        let released = try await releaseEngine.releaseEligibleQueuedRuns()
        XCTAssertEqual(released.map(\.run.state), [.received])
        XCTAssertNil(released.first?.run.holdReason)
    }

    func testConcurrencyHoldReleasesAfterEarlierRunSettles() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        _ = try await fixture.trigger(sourceID: source.id)
        let now = fixture.now
        let engine = TriggerEngine(store: fixture.store, now: { now })

        let first = try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-1"))
        let second = try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-2"))
        XCTAssertEqual(first.createdRuns.first?.state, .received)
        XCTAssertEqual(second.createdRuns.first?.holdReason, .concurrencyLimit)

        var settled = try XCTUnwrap(first.createdRuns.first)
        settled.state = .fixQueued
        settled.sessionID = SessionID()
        settled.result = TriggerRunResult(
            disposition: .straightforwardFix,
            summary: "The change is bounded.",
            changedPaths: [],
            tests: []
        )
        try await fixture.store.updateRun(settled)

        let third = try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-3"))
        XCTAssertEqual(third.createdRuns.first?.holdReason, .concurrencyLimit)

        settled.state = .completed
        settled.settledAt = fixture.now
        try await fixture.store.updateRun(settled)

        let released = try await engine.releaseEligibleQueuedRuns()
        XCTAssertEqual(released.map(\.run.id), second.createdRuns.map(\.id))
    }

    func testPausedSourceAcceptsReceiptWithoutStartingWork() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.remove() }
        var source = try await fixture.source()
        _ = try await fixture.trigger(sourceID: source.id)
        source.enabled = false
        source.health = .disconnected
        source.updatedAt = fixture.now.addingTimeInterval(1)
        try await fixture.store.saveSource(source)

        let result = try await TriggerEngine(store: fixture.store).ingest(
            fixture.event(sourceID: source.id)
        )

        XCTAssertTrue(result.accepted)
        XCTAssertTrue(result.createdRuns.isEmpty)
        XCTAssertTrue(result.dispatches.isEmpty)
    }

    private struct Fixture: Sendable {
        let directory: URL
        let store: TriggerStore
        let now = Date(timeIntervalSince1970: 1_000)

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TriggerEngineTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        }

        func remove() async {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func source() async throws -> TriggerSourceInstallation {
            let source = TriggerSourceInstallation(
                id: TriggerSourceInstallationID(),
                sourceType: "test",
                displayName: "Test source",
                configuration: [:],
                credentialReference: nil,
                enabled: true,
                health: .healthy,
                lastCheckedAt: now,
                lastEventAt: nil,
                boundedDiagnostic: nil,
                createdAt: now,
                updatedAt: now
            )
            try await store.saveSource(source)
            return source
        }

        func trigger(
            sourceID: TriggerSourceInstallationID,
            condition: TriggerCondition? = nil,
            quietHours: TriggerQuietHours? = nil
        ) async throws -> (definition: TriggerDefinition, revision: TriggerRevision) {
            let triggerID = TriggerID()
            let revisionID = TriggerRevisionID()
            let definition = TriggerDefinition(
                id: triggerID,
                name: "Review cases",
                enabled: false,
                activeRevisionID: nil,
                draftRevisionID: revisionID,
                createdAt: now,
                updatedAt: now
            )
            let revision = TriggerRevision(
                id: revisionID,
                triggerID: triggerID,
                sequence: 1,
                sourceInstallationID: sourceID,
                eventKind: "case.review-required",
                conditions: condition.map { [$0] } ?? [],
                projectID: ProjectID(),
                instructions: "Assess the event.",
                agentKind: .codex,
                accountHandleName: nil,
                model: nil,
                reasoningEffort: nil,
                executionMode: .assessThenFix,
                checkoutPolicy: .projectCheckout,
                limits: .conservative,
                quietHours: quietHours,
                notifications: .standard,
                allowSourceResources: false,
                proposedBySessionID: nil,
                createdAt: now
            )
            try await store.saveDraft(definition, revision: revision)
            try await store.activate(triggerID: triggerID, revisionID: revisionID, at: now)
            return (definition, revision)
        }

        func event(
            sourceID: TriggerSourceInstallationID,
            status: String = "needs_review",
            externalID: String = "case-1"
        ) -> TriggerEvent {
            TriggerEvent(
                sourceInstallationID: sourceID,
                externalID: externalID,
                revision: "1",
                kind: "case.review-required",
                occurredAt: now,
                receivedAt: now,
                title: "Case 1",
                attributes: ["status": .string(status)],
                deepLink: nil,
                resources: []
            )
        }
    }
}
