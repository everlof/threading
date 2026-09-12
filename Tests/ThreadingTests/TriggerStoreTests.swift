import XCTest
@testable import Threading

final class TriggerStoreTests: XCTestCase {
    func testDraftActivationAndIdempotentEventAndRunCreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let now = Date(timeIntervalSince1970: 1_000)
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
            sourceInstallationID: source.id,
            eventKind: "case.review-required",
            conditions: [],
            projectID: ProjectID(),
            instructions: "Assess this event.",
            agentKind: .codex,
            accountHandleName: nil,
            model: nil,
            reasoningEffort: nil,
            executionMode: .assessThenFix,
            checkoutPolicy: .projectCheckout,
            limits: .conservative,
            quietHours: nil,
            notifications: .standard,
            allowSourceResources: false,
            proposedBySessionID: nil,
            createdAt: now
        )
        try await store.saveDraft(definition, revision: revision)
        try await store.activate(triggerID: triggerID, revisionID: revisionID, at: now)

        let saved = try await store.trigger(id: triggerID)
        XCTAssertEqual(saved?.definition.activeRevisionID, revisionID)
        XCTAssertTrue(saved?.definition.enabled == true)

        let event = TriggerEvent(
            sourceInstallationID: source.id,
            externalID: "case-1",
            revision: "1",
            kind: revision.eventKind,
            occurredAt: now,
            receivedAt: now,
            title: "Case 1",
            attributes: [:],
            deepLink: nil,
            resources: []
        )
        let firstAcceptance = try await store.accept(event)
        let repeatedAcceptance = try await store.accept(event)
        XCTAssertTrue(firstAcceptance)
        XCTAssertFalse(repeatedAcceptance)

        let sessionID = SessionID()
        let run = TriggerRun(
            id: TriggerRunID(),
            triggerID: triggerID,
            triggerRevisionID: revisionID,
            eventKey: event.storageKey,
            state: .queued,
            queuedAt: now,
            startedAt: nil,
            settledAt: nil,
            sessionID: sessionID,
            managedWorkspaceID: nil,
            holdReason: nil,
            result: nil,
            boundedDiagnostic: nil
        )
        let firstRunCreation = try await store.createRun(run)
        let repeatedRunCreation = try await store.createRun(run)
        let savedRunIDs = try await store.runs().map(\.id)
        XCTAssertTrue(firstRunCreation)
        XCTAssertFalse(repeatedRunCreation)
        XCTAssertEqual(savedRunIDs, [run.id])
        let runForSession = try await store.run(sessionID: sessionID)
        XCTAssertEqual(runForSession?.id, run.id)
        let activeRunCount = try await store.activeRunCount(triggerID: triggerID)
        let fixStageRunIDs = try await store.fixStageDispatches().map(\.run.id)
        XCTAssertEqual(activeRunCount, 1)
        XCTAssertEqual(fixStageRunIDs, [run.id])

        var interrupted = run
        interrupted.state = .assessing
        interrupted.startedAt = now
        try await store.updateRun(interrupted)
        let interruptedRunIDs = try await store.interruptedRuns().map(\.id)
        XCTAssertEqual(interruptedRunIDs, [run.id])
    }

    func testRevisionPayloadCannotBeChangedInPlace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let triggerID = TriggerID()
        let revisionID = TriggerRevisionID()
        let definition = TriggerDefinition(
            id: triggerID,
            name: "Immutable approval",
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
            sourceInstallationID: TriggerSourceInstallationID(),
            eventKind: "example.created",
            conditions: [],
            projectID: ProjectID(),
            instructions: "Original instructions",
            agentKind: .codex,
            accountHandleName: nil,
            model: nil,
            reasoningEffort: nil,
            executionMode: .assessOnly,
            checkoutPolicy: .projectCheckout,
            limits: .conservative,
            quietHours: nil,
            notifications: .standard,
            allowSourceResources: false,
            proposedBySessionID: nil,
            createdAt: now
        )
        try await store.saveDraft(definition, revision: revision)
        var changed = revision
        changed.instructions = "Changed without a new approval"

        do {
            try await store.saveDraft(definition, revision: changed)
            XCTFail("Expected an immutable revision conflict")
        } catch {
            let savedInstructions = try await store.revision(id: revisionID)?.instructions
            XCTAssertEqual(savedInstructions, "Original instructions")
        }
    }
}
