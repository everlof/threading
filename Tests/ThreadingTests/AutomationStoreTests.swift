import XCTest
@testable import Threading

final class AutomationStoreTests: XCTestCase {
    func testScheduleClaimsOnceAndPersistsNextDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("db")
        let store = TriggerStore(url: url)
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize changes"
        config.options.schedule = .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil, now: now)
        try await store.activate(triggerID: id, revisionID: revision.id, at: now)
        let initial = try await store.nextAutomationDate(id)
        XCTAssertEqual(initial, now.addingTimeInterval(60))
        let dispatches = try await store.scheduledDispatches(now: now.addingTimeInterval(60))
        XCTAssertEqual(dispatches.count, 1)
        let runID = try XCTUnwrap(dispatches.first?.run.id)
        let firstClaim = try await store.claimDispatch(runID)
        XCTAssertNotNil(firstClaim?.sessionID)
        let secondClaim = try await store.claimDispatch(runID)
        XCTAssertNil(secondClaim)
        let repeated = try await store.scheduledDispatches(now: now.addingTimeInterval(60))
        XCTAssertTrue(repeated.isEmpty)
        let restarted = TriggerStore(url: url)
        let next = try await restarted.nextAutomationDate(id)
        XCTAssertEqual(next, now.addingTimeInterval(120))
        let overlap = try await restarted.scheduledDispatches(now: now.addingTimeInterval(120))
        XCTAssertTrue(overlap.isEmpty)
        let runs = try await restarted.runs(triggerID: id)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.contains { $0.state == .suppressed && $0.holdReason == .concurrencyLimit })
        let interrupted = try await restarted.interruptedRuns()
        XCTAssertEqual(interrupted.map(\.id), [runID])
        await restarted.close()
    }

    func testMissedRunPauseEditAndDeleteRetainHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        config.options.schedule = .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil, now: now)
        try await store.activate(triggerID: id, revisionID: revision.id, at: now)
        let missed = try await store.scheduledDispatches(now: now.addingTimeInterval(600))
        XCTAssertTrue(missed.isEmpty)
        let history = try await store.runs(triggerID: id)
        XCTAssertEqual(history.first?.state, .suppressed)
        let edit = try await store.configureAutomation(config, id: id, expectedRevision: revision.id, proposedBy: nil, now: now)
        let paused = try await store.nextAutomationDate(id)
        XCTAssertNil(paused)
        do {
            _ = try await store.configureAutomation(config, id: id, expectedRevision: revision.id, proposedBy: nil)
            XCTFail("stale editor overwrote current revision")
        } catch { }
        try await store.removeAutomation(id, expectedRevision: edit.id)
        let deleted = try await store.trigger(id: id)
        XCTAssertNil(deleted)
        let retained = try await store.runs(triggerID: id)
        XCTAssertEqual(retained.map(\.id), history.map(\.id))
        let oldRevision = try await store.revision(id: revision.id)
        XCTAssertNotNil(oldRevision)
    }

    func testPauseBeforeDispatchSuppressesTheReservedRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        config.options.schedule = .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil, now: now)
        try await store.activate(triggerID: id, revisionID: revision.id, at: now)
        let dispatches = try await store.scheduledDispatches(now: now.addingTimeInterval(60))
        let runID = try XCTUnwrap(dispatches.first?.run.id)
        try await store.setEnabled(false, triggerID: id)
        let claim = try await store.claimDispatch(runID)
        XCTAssertNil(claim)
        let remaining = try await store.activeRunCount(triggerID: id)
        XCTAssertEqual(remaining, 0)
        let page = try await store.runPage(triggerID: id)
        XCTAssertEqual(page.items.first?.state, .suppressed)
        try await store.removeAutomation(id, expectedRevision: revision.id)
        do {
            _ = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
            XCTFail("a deleted identity cannot be repurposed")
        } catch { }
    }

    func testExplicitRunOfDraftDoesNotEnableItsSchedule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        let first = try await store.runAutomationNow(id, expectedRevision: revision.id, requestKey: "explicit-run")
        let duplicate = try await store.runAutomationNow(id, expectedRevision: revision.id, requestKey: "explicit-run")
        XCTAssertEqual(first.run.id, duplicate.run.id)
        let claim = try await store.claimDispatch(first.run.id)
        XCTAssertNotNil(claim?.sessionID)
        let pair = try await store.trigger(id: id)
        XCTAssertEqual(pair?.definition.enabled, false)
        let next = try await store.nextAutomationDate(id)
        XCTAssertNil(next)
    }

    func testLegacyRevisionDecodesAndPreservesEventPolicies() async throws {
        var revision = TriggerRevision(id: TriggerRevisionID(), triggerID: TriggerID(), sequence: 1,
            sourceInstallationID: TriggerSourceInstallationID(), eventKind: "test", conditions: [],
            projectID: ProjectID(), instructions: "Assess", agentKind: .codex, accountHandleName: nil,
            model: nil, reasoningEffort: nil, executionMode: .assessOnly, checkoutPolicy: .projectCheckout,
            limits: .conservative, quietHours: nil, notifications: .standard, allowSourceResources: false,
            proposedBySessionID: nil, createdAt: Date())
        let data = try JSONEncoder().encode(revision)
        let decoded = try JSONDecoder().decode(TriggerRevision.self, from: data)
        XCTAssertNil(decoded.automation)
        revision.quietHours = .init(startMinute: 1_200, endMinute: 480, timeZoneIdentifier: "UTC")
        revision.notifications = .init(onCompletion: false, onNeedsAttention: true, onFailure: true)
        revision.allowSourceResources = true
        revision.limits.maximumConcurrentRuns = 2
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        try await store.saveSource(.init(id: revision.sourceInstallationID, sourceType: "test", displayName: "Events",
            configuration: [:], credentialReference: nil, enabled: true, health: .healthy,
            lastCheckedAt: nil, lastEventAt: nil, boundedDiagnostic: nil, createdAt: Date(), updatedAt: Date()))
        let definition = TriggerDefinition(id: revision.triggerID, name: "Event review", enabled: false,
            activeRevisionID: nil, draftRevisionID: revision.id, createdAt: Date(), updatedAt: Date())
        try await store.saveDraft(definition, revision: revision)
        var config = AutomationConfiguration(definition: definition, revision: revision)
        config.instructions = "Review the event and summarize it."
        let edited = try await store.configureAutomation(config, id: definition.id, expectedRevision: revision.id, proposedBy: nil)
        XCTAssertEqual(edited.quietHours, revision.quietHours)
        XCTAssertEqual(edited.notifications, revision.notifications)
        XCTAssertTrue(edited.allowSourceResources)
        XCTAssertEqual(edited.limits.maximumConcurrentRuns, 2)
    }

    private func scratchStore() throws -> TriggerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        return store
    }

    private func activeSchedule(_ schedule: AutomationSchedule, policy: AutomationOptions.MissedRunPolicy = .skip,
                                in store: TriggerStore, at now: Date) async throws -> (TriggerID, TriggerRevision) {
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        config.options.schedule = schedule
        config.options.missedRunPolicy = policy
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil, now: now)
        try await store.activate(triggerID: id, revisionID: revision.id, at: now)
        return (id, revision)
    }

    /// The sweep runs a few seconds after the first 02:30 of the fall-back night. Recomputing
    /// from that moment once landed on the second 02:30, an hour later, and ran the task twice.
    func testRepeatedHourSweepRunsOnce() async throws {
        let store = try scratchStore()
        let iso = ISO8601DateFormatter()
        let (id, _) = try await activeSchedule(.init(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30),
                                              in: store, at: iso.date(from: "2026-10-24T12:00:00Z")!)
        let fired = try await store.scheduledDispatches(now: iso.date(from: "2026-10-25T00:30:10Z")!)
        XCTAssertEqual(fired.count, 1)
        let next = try await store.nextAutomationDate(id)
        XCTAssertEqual(next, iso.date(from: "2026-10-26T01:30:00Z"))
    }

    func testLateCatchUpNamesTheMostRecentOccurrence() async throws {
        let store = try scratchStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await activeSchedule(.init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now),
                                     policy: .latest, in: store, at: now)
        let caughtUp = try await store.scheduledDispatches(now: now.addingTimeInterval(630))
        XCTAssertEqual(caughtUp.count, 1)
        XCTAssertEqual(caughtUp.first?.event.occurredAt, now.addingTimeInterval(600))
    }

    /// One rule whose admission fails is deferred on its own; every other due rule still runs.
    func testOneRuleThatCannotBeAdmittedDoesNotHoldTheOthers() async throws {
        let store = try scratchStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)
        let (broken, brokenRevision) = try await activeSchedule(schedule, in: store, at: now)
        let (healthy, _) = try await activeSchedule(schedule, in: store, at: now)
        // An event already holding the broken rule's occurrence key makes its reservation fail.
        let moment = now.addingTimeInterval(60)
        let key = "scheduled:\(brokenRevision.id.uuidString):\(Int64(moment.timeIntervalSince1970))"
        try await store.accept(TriggerEvent(sourceInstallationID: TriggerSourceInstallationID(broken.rawValue),
            externalID: broken.uuidString + ":" + key, revision: brokenRevision.id.uuidString, kind: "schedule.due",
            occurredAt: moment, receivedAt: now, title: "Report", attributes: [:], deepLink: nil, resources: []))
        let dispatches = try await store.scheduledDispatches(now: moment)
        XCTAssertEqual(dispatches.map(\.run.triggerID), [healthy])
        let deferred = try await store.nextAutomationDate(broken)
        XCTAssertEqual(deferred, moment.addingTimeInterval(TriggerStore.failedAdmissionRetry))
        let brokenRuns = try await store.runs(triggerID: broken)
        XCTAssertTrue(brokenRuns.isEmpty)
    }

    func testDeleteIsOneStepAndStopsScheduling() async throws {
        let store = try scratchStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (id, revision) = try await activeSchedule(.init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now),
                                                      in: store, at: now)
        try await store.removeAutomation(id, expectedRevision: revision.id, at: now)
        let next = try await store.nextAutomationDate(id)
        XCTAssertNil(next)
        let remaining = try await store.scheduledDispatches(now: now.addingTimeInterval(60))
        XCTAssertTrue(remaining.isEmpty)
        let current = try await store.trigger(id: id)
        XCTAssertNil(current)
    }
}
