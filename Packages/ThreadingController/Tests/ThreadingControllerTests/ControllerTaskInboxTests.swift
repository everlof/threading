import Foundation
import Testing
import ThreadingDomain
@testable import ThreadingController

struct ControllerTaskInboxTests {
    @Test func reconciliationPreservesPauseAndRetryDoesNotInvalidateLaunch() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let spec = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: [], environment: [:], directory: "/tmp", recipients: ["person:owner"], destination: "draft")
        let initial = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 2, spec: spec)
        let enabled = try await store.setWorkerEnabled(work.workerID, expectedRevision: initial.revision, enabled: true)
        let prepared = try #require(await store.prepareSupervisedLaunch(work.workerID))
        let same = try await store.reconcileWorker(work.workerID, expectedRevision: enabled.revision, spec: spec)
        #expect(same.enabled && same.revision == enabled.revision && same.maximumConcurrent == 2)
        #expect(try await store.cancelObsoletePreparation(prepared.executionID) == false)
        let changed = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: ["changed"], environment: [:], directory: "/tmp", recipients: ["person:owner"], destination: "draft")
        let updated = try await store.reconcileWorker(work.workerID, expectedRevision: same.revision, spec: changed)
        #expect(updated.enabled)
        // Simulate losing that response: retry from the newly observed policy.
        let retry = try await store.reconcileWorker(work.workerID, expectedRevision: updated.revision, spec: changed)
        #expect(retry.revision == updated.revision && retry.enabled)
        let paused = try await store.setWorkerEnabled(work.workerID, expectedRevision: retry.revision, enabled: false)
        let reconciled = try await store.reconcileWorker(work.workerID, expectedRevision: paused.revision, spec: spec)
        #expect(!reconciled.enabled)
    }
    @Test func messagesFenceCompletionAndHistorySurvivesReopen() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let message = try await store.message(workID: work.id, id: UUID(), author: "person:owner", text: "Include costs")
        #expect(try await store.message(workID: work.id, id: message.id, author: "person:owner", text: message.text) == message)
        await #expect(throws: ControllerError.conflict) { try await store.finish(executionID: claim.execution.id, destination: "draft", payload: "Premature") }
        _ = try await store.consumeMessage(executionID: claim.execution.id, id: message.id)
        _ = try await store.checkpoint(executionID: claim.execution.id, text: "First milestone")
        _ = try await store.checkpoint(executionID: claim.execution.id, text: "Second milestone")
        _ = try await store.finish(executionID: claim.execution.id, destination: "draft", payload: "Done")
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.activities(workID: work.id).items.compactMap(\.text) == ["First milestone", "Second milestone"])
        #expect(try await reopened.messages(workID: work.id).items.first?.consumedBy == claim.execution.id)
        await #expect(throws: ControllerError.conflict) { try await reopened.message(workID: work.id, id: UUID(), author: "person:owner", text: "Too late") }
    }
    @Test func requestOnlyPolicyFencesScheduledAndEventAdmission() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = try await store.setWorkerSources(work.workerID, expectedRevision: 0, sources: [.request])
        await #expect(throws: ControllerError.forbidden) { try await store.enqueue(workerID: work.workerID, key: "schedule", instruction: "Denied", source: .schedule) }
        await #expect(throws: ControllerError.forbidden) { try await store.enqueue(workerID: work.workerID, key: "event", instruction: "Denied", source: .event) }
        let accepted = try await store.enqueue(workerID: work.workerID, key: "request", instruction: "Accepted", request: "{\"version\":1}")
        #expect(accepted.source == .request)
        #expect(accepted.request == "{\"version\":1}")
    }
    @Test func cancelledWorkCannotResumeAndArchiveRetainsHistory() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        await #expect(throws: ControllerError.conflict) { try await store.archiveWorker(work.workerID) }
        _ = try await store.cancel(workID: work.id)
        let schedule = AutomationID()
        let spec = ControllerAutomationSpec(name: "Schedule", workerID: work.workerID, instruction: "Run", schedule: .init(kind: .daily, timeZone: "UTC"))
        _ = try await store.configureAutomation(schedule, expectedRevision: 0, spec: spec)
        _ = try await store.setAutomationEnabled(schedule, expectedRevision: 1, enabled: true)
        await #expect(throws: ControllerError.conflict) { try await store.archiveWorker(work.workerID) }
        _ = try await store.setAutomationEnabled(schedule, expectedRevision: 2, enabled: false)
        _ = try await store.archiveWorker(work.workerID)
        await #expect(throws: ControllerError.conflict) { try await store.setAutomationEnabled(schedule, expectedRevision: 3, enabled: true) }
        let launch = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: [], environment: [:], directory: "/tmp", recipients: ["person:owner"], destination: "draft")
        await #expect(throws: ControllerError.conflict) { try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launch) }
        #expect(try await store.work(work.id).state == .cancelled)
        await #expect(throws: ControllerError.conflict) { try await store.enqueue(workerID: work.workerID, key: "new", instruction: "No") }
        await #expect(throws: ControllerError.conflict) { try await store.retry(workID: work.id) }
    }
}
