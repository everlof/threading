import XCTest
@testable import Threading

/// The held-run queue: one trigger's backlog never delays another's run, and a held run whose
/// authority is gone settles with a visible reason instead of waiting forever.
final class TriggerQueueFairnessTests: XCTestCase {
    private static let quietUntilTwoAM = TriggerQuietHours(
        startMinute: 0,
        endMinute: 120,
        timeZoneIdentifier: "UTC"
    )

    func testBurstHeldBehindOneTriggersLimitDoesNotDelayAnotherTrigger() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let busySource = try await fixture.source()
        let quietSource = try await fixture.source()
        let busy = try await fixture.trigger(sourceID: busySource.id)
        let quiet = try await fixture.trigger(sourceID: quietSource.id, quietHours: Self.quietUntilTwoAM)

        // Trigger A: one running run, then a 150-run burst held at maximumConcurrentRuns = 1.
        let burstEngine = TriggerEngine(store: fixture.store, now: { Date(timeIntervalSince1970: 3_600) })
        let first = try await burstEngine.ingest(fixture.event(sourceID: busySource.id, externalID: "case-0"))
        XCTAssertEqual(first.createdRuns.map(\.state), [.received])
        for index in 1 ... 150 {
            let held = try await burstEngine.ingest(
                fixture.event(sourceID: busySource.id, externalID: "case-\(index)")
            )
            XCTAssertEqual(held.createdRuns.first?.holdReason, .concurrencyLimit)
        }

        // Trigger B: one run, accepted after the burst and held only by quiet hours.
        let laterEngine = TriggerEngine(store: fixture.store, now: { Date(timeIntervalSince1970: 3_700) })
        let waiting = try await laterEngine.ingest(fixture.event(sourceID: quietSource.id, externalID: "other"))
        XCTAssertEqual(waiting.createdRuns.first?.holdReason, .quietHours)

        let released = try await TriggerEngine(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 10_800) }
        ).releaseEligibleQueuedRuns()

        XCTAssertEqual(released.map(\.run.id), waiting.createdRuns.map(\.id))
        XCTAssertEqual(released.first?.run.state, .received)
        let busyRuns = try await fixture.store.runs(triggerID: busy.definition.id)
        XCTAssertEqual(busyRuns.filter { $0.state == .queued }.count, 150)
        let busyActive = try await fixture.store.activeRunCount(triggerID: busy.definition.id)
        let quietActive = try await fixture.store.activeRunCount(triggerID: quiet.definition.id)
        XCTAssertEqual(busyActive, 1)
        XCTAssertEqual(quietActive, 1)
    }

    func testReleaseTakesOnlyTheFreeSlotsOfEachTrigger() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let trigger = try await fixture.trigger(sourceID: source.id, maximumConcurrentRuns: 2)
        let engine = TriggerEngine(store: fixture.store, now: { fixture.now })
        var created: [TriggerRun] = []
        for index in 0 ..< 5 {
            created += try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-\(index)")).createdRuns
        }
        XCTAssertEqual(created.map(\.state), [.received, .received, .queued, .queued, .queued])

        var done = created[0]
        done.state = .completed
        done.settledAt = fixture.now
        try await fixture.store.updateRun(done)

        let released = try await engine.releaseEligibleQueuedRuns()
        XCTAssertEqual(released.map(\.run.id), [created[2].id], "oldest held run, one free slot")
        let active = try await fixture.store.activeRunCount(triggerID: trigger.definition.id)
        XCTAssertEqual(active, 2)
        let again = try await engine.releaseEligibleQueuedRuns()
        XCTAssertTrue(again.isEmpty)
    }

    func testEditingAnAutomationSettlesItsHeldRunsWithAReason() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let trigger = try await fixture.trigger(sourceID: source.id)
        let engine = TriggerEngine(store: fixture.store, now: { fixture.now })
        let running = try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-0"))
        var held: [TriggerRun] = []
        for index in 1 ... 3 {
            held += try await engine.ingest(fixture.event(sourceID: source.id, externalID: "case-\(index)")).createdRuns
        }

        let edit = try await fixture.saveRevision(of: trigger, sequence: 2)

        for run in held {
            let settled = try await fixture.store.run(id: run.id)
            XCTAssertEqual(settled?.state, .suppressed)
            XCTAssertNotNil(settled?.settledAt)
            XCTAssertNil(settled?.holdReason)
            XCTAssertEqual(settled?.boundedDiagnostic, QueuedRunSettlement.revisionSuperseded.diagnostic)
        }
        let stillRunning = try await fixture.store.run(id: try XCTUnwrap(running.createdRuns.first).id)
        XCTAssertEqual(stillRunning?.state, .received, "a started run is not the queue's to settle")

        // Activating the edit does not resurrect them, and nothing stale is left for the sweep.
        try await fixture.store.activate(triggerID: trigger.definition.id, revisionID: edit.id, at: fixture.now)
        let stale = try await fixture.store.settleStaleQueuedRuns()
        XCTAssertEqual(stale, 0)
        let released = try await engine.releaseEligibleQueuedRuns()
        XCTAssertTrue(released.isEmpty)
    }

    func testDeletingAnAutomationSettlesItsHeldRunsWithAReason() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let trigger = try await fixture.trigger(sourceID: source.id, quietHours: Self.quietUntilTwoAM)
        let engine = TriggerEngine(store: fixture.store, now: { Date(timeIntervalSince1970: 3_600) })
        let held = try await engine.ingest(fixture.event(sourceID: source.id)).createdRuns
        XCTAssertEqual(held.map(\.state), [.queued])

        try await fixture.store.removeAutomation(
            trigger.definition.id,
            expectedRevision: trigger.revision.id,
            at: fixture.now
        )

        let settled = try await fixture.store.run(id: try XCTUnwrap(held.first).id)
        XCTAssertEqual(settled?.state, .suppressed)
        XCTAssertEqual(settled?.boundedDiagnostic, QueuedRunSettlement.automationRemoved.diagnostic)
    }

    func testPausedTriggerKeepsItsHeldRunsForResume() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let trigger = try await fixture.trigger(sourceID: source.id, quietHours: Self.quietUntilTwoAM)
        let held = try await TriggerEngine(store: fixture.store, now: { Date(timeIntervalSince1970: 3_600) })
            .ingest(fixture.event(sourceID: source.id)).createdRuns
        let later = TriggerEngine(store: fixture.store, now: { Date(timeIntervalSince1970: 10_800) })

        try await fixture.store.setEnabled(false, triggerID: trigger.definition.id)
        let whilePaused = try await later.releaseEligibleQueuedRuns()
        XCTAssertTrue(whilePaused.isEmpty)
        let stale = try await fixture.store.settleStaleQueuedRuns()
        XCTAssertEqual(stale, 0)

        try await fixture.store.setEnabled(true, triggerID: trigger.definition.id)
        let resumed = try await later.releaseEligibleQueuedRuns()
        XCTAssertEqual(resumed.map(\.run.id), held.map(\.id))
    }
}

/// A private trigger store with sources and activated triggers, for the queue tests.
struct QueueFixture: Sendable {
    let directory: URL
    let store: TriggerStore
    let now = Date(timeIntervalSince1970: 1_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerQueue-\(UUID().uuidString)", isDirectory: true)
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
        quietHours: TriggerQuietHours? = nil,
        maximumConcurrentRuns: Int = 1
    ) async throws -> (definition: TriggerDefinition, revision: TriggerRevision) {
        let triggerID = TriggerID()
        let revision = self.revision(
            triggerID: triggerID,
            sequence: 1,
            sourceID: sourceID,
            quietHours: quietHours,
            maximumConcurrentRuns: maximumConcurrentRuns
        )
        let definition = TriggerDefinition(
            id: triggerID,
            name: "Review cases",
            enabled: false,
            activeRevisionID: nil,
            draftRevisionID: revision.id,
            createdAt: now,
            updatedAt: now
        )
        try await store.saveDraft(definition, revision: revision)
        try await store.activate(triggerID: triggerID, revisionID: revision.id, at: now)
        return (definition, revision)
    }

    /// Saves an edited draft of `trigger`, as the editor does.
    func saveRevision(
        of trigger: (definition: TriggerDefinition, revision: TriggerRevision),
        sequence: Int
    ) async throws -> TriggerRevision {
        let revision = self.revision(
            triggerID: trigger.definition.id,
            sequence: sequence,
            sourceID: trigger.revision.sourceInstallationID,
            quietHours: trigger.revision.quietHours,
            maximumConcurrentRuns: trigger.revision.limits.maximumConcurrentRuns
        )
        var definition = trigger.definition
        definition.enabled = true
        definition.activeRevisionID = trigger.revision.id
        definition.draftRevisionID = revision.id
        definition.updatedAt = now
        try await store.saveDraft(definition, revision: revision)
        return revision
    }

    func event(
        sourceID: TriggerSourceInstallationID,
        externalID: String = "case-1",
        title: String = "Case"
    ) -> TriggerEvent {
        TriggerEvent(
            sourceInstallationID: sourceID,
            externalID: externalID,
            revision: "1",
            kind: "case.review-required",
            occurredAt: now,
            receivedAt: now,
            title: title,
            attributes: ["status": .string("needs_review")],
            deepLink: nil,
            resources: []
        )
    }

    private func revision(
        triggerID: TriggerID,
        sequence: Int,
        sourceID: TriggerSourceInstallationID,
        quietHours: TriggerQuietHours?,
        maximumConcurrentRuns: Int
    ) -> TriggerRevision {
        TriggerRevision(
            id: TriggerRevisionID(),
            triggerID: triggerID,
            sequence: sequence,
            sourceInstallationID: sourceID,
            eventKind: "case.review-required",
            conditions: [],
            projectID: ProjectID(),
            instructions: "Assess the event.",
            agentKind: .codex,
            accountHandleName: nil,
            model: nil,
            reasoningEffort: nil,
            executionMode: .assessThenFix,
            checkoutPolicy: .projectCheckout,
            limits: TriggerLimits(maximumConcurrentRuns: maximumConcurrentRuns, maximumRuntimeMinutes: 60),
            quietHours: quietHours,
            notifications: .standard,
            allowSourceResources: false,
            proposedBySessionID: nil,
            createdAt: now
        )
    }
}
