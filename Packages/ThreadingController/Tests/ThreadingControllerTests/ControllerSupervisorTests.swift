import Foundation
import Testing
@testable import ThreadingController

struct ControllerSupervisorTests {
    let helpers = ControllerStoreTests()
    let launches = ControllerLaunchTests()

    @Test func globalCapacityIncludesOtherWorkersAndManualIntents() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let busyWorker = WorkerID()
        var oldest: ExecutionID?
        for index in 0..<ControllerSupervisorLimits.maximumActiveLaunches {
            _ = try await helpers.seed(store, worker: busyWorker, key: "busy:\(index)")
            let launch = try #require(await store.prepareLaunch(workerID: busyWorker, spec: launches.spec()))
            if oldest == nil { oldest = launch.executionID }
        }
        let other = try await helpers.seed(store)
        _ = try await store.configureWorker(other.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        _ = try await store.setWorkerEnabled(other.workerID, expectedRevision: 1, enabled: true)
        #expect(try await store.prepareSupervisedLaunch(other.workerID) == nil)
        _ = try await store.confirmLaunchStopped(#require(oldest), exitStatus: nil)
        #expect(try await store.prepareSupervisedLaunch(other.workerID)?.workID == other.id)
    }

    @Test func concurrentSupervisorsRespectSlotsAndUncertaintyOccupiesOne() async throws {
        let (directory, first) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(first)
        _ = try await first.enqueue(workerID: work.workerID, key: "second", instruction: "Independent")
        let policy = try await first.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        #expect(!policy.enabled)
        #expect(try await first.prepareSupervisedLaunch(work.workerID) == nil)
        _ = try await first.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        let second = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        async let a = first.prepareSupervisedLaunch(work.workerID)
        async let b = second.prepareSupervisedLaunch(work.workerID)
        let prepared = try await [a, b].compactMap { $0 }
        #expect(prepared.count == 1)
        let launch = try #require(prepared.first)
        _ = try await first.beginLaunch(launch.executionID)
        #expect(try await second.prepareSupervisedLaunch(work.workerID) == nil)
        _ = try await first.confirmLaunchStopped(launch.executionID, exitStatus: 1)
        let next = try #require(await second.prepareSupervisedLaunch(work.workerID))
        #expect(next.workID != work.id) // Failed work is never silently retried.
    }

    @Test func pauseFencesPreparedLaunchButKeepsRunningAuthority() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        _ = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        let enabled = try await store.setWorkerEnabled(work.workerID, expectedRevision: 1, enabled: true)
        let prepared = try #require(await store.prepareSupervisedLaunch(work.workerID))
        let paused = try await store.setWorkerEnabled(work.workerID, expectedRevision: enabled.revision, enabled: false)
        await #expect(throws: ControllerError.conflict) { try await store.beginLaunch(prepared.executionID) }
        #expect(try await store.cancelObsoletePreparation(prepared.executionID))
        #expect(try await store.work(work.id).state == .queued)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        let resumed = try await store.setWorkerEnabled(work.workerID, expectedRevision: paused.revision, enabled: true)
        let live = try #require(await store.prepareSupervisedLaunch(work.workerID))
        _ = try await store.beginLaunch(live.executionID)
        let credential = try await store.launchCredential(live.executionID)
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: resumed.revision, enabled: false)
        #expect(try await store.cancelObsoletePreparation(live.executionID) == false)
        let result = try await store.agentRequest(executionID: live.executionID, credential: credential, request: .finish(payload: "Result"))
        #expect(result.delivery?.destination == "draft")
    }

    @Test func recipeReplacementPausesAndDoesNotChangePreparedAuthority() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        _ = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        let policy = try await store.setWorkerEnabled(work.workerID, expectedRevision: 1, enabled: true)
        let prepared = try #require(await store.prepareSupervisedLaunch(work.workerID))
        let updated = try await store.configureWorker(work.workerID, expectedRevision: policy.revision, maximumConcurrent: 2, spec: launches.spec())
        #expect(!updated.enabled)
        await #expect(throws: ControllerError.conflict) {
            try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        }
        #expect(try await store.cancelObsoletePreparation(prepared.executionID))
        #expect(try await store.unresolvedLaunches().items.isEmpty)
    }

    @Test func migrationBackfillsLaunchOwnershipAndManualIntentStaysManual() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        let connection = try ControllerDatabase(path: directory.appendingPathComponent("controller.db").path)
        try connection.run("DROP INDEX usage_receipt_coverage")
        try connection.run("DROP INDEX record_scope_state")
        try connection.run("DROP INDEX unresolved_launch")
        try connection.run("DROP INDEX unresolved_delivery")
        try connection.run("ALTER TABLE record DROP COLUMN scope")
        try connection.run("DROP TABLE automation_due")
        try connection.run("PRAGMA user_version=2")
        let migrated = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try connection.rows("SELECT scope FROM record WHERE kind='launch' LIMIT 1").first?.text(0) == work.workerID.description)
        _ = try await migrated.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        _ = try await migrated.setWorkerEnabled(work.workerID, expectedRevision: 1, enabled: true)
        #expect(try await migrated.prepareSupervisedLaunch(work.workerID) == nil)
        #expect(try await migrated.cancelObsoletePreparation(launch.executionID) == false)
        #expect(try await migrated.unresolvedLaunches().items.first?.supervisorRevision == nil)
    }
}
