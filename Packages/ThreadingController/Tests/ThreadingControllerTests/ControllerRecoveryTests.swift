import Foundation
import Testing
@testable import ThreadingController

/// Stop evidence, fenced owner repair, transient refusals, failure diagnostics and the schema
/// fence: the store half of controller execution recovery.
struct ControllerRecoveryTests {
    let helpers = ControllerStoreTests()
    let launches = ControllerLaunchTests()

    @Test func ownerConfirmationIsFencedByTheStateTheOwnerSaw() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        await #expect(throws: ControllerError.conflict) {
            try await store.recordLaunchStopped(launch.executionID, evidence: .ownerConfirmed, expectedState: .running)
        }
        // The lost spawn receipt arrives after the owner looked: their dispatching fence fails.
        _ = try await store.recordSpawn(launch.executionID, pid: 4242, seconds: 1, microseconds: 2)
        await #expect(throws: ControllerError.conflict) {
            try await store.recordLaunchStopped(launch.executionID, evidence: .ownerConfirmed, expectedState: .dispatching)
        }
        let stopped = try await store.recordLaunchStopped(launch.executionID, evidence: .ownerConfirmed, expectedState: .running)
        #expect(stopped.state == .stopped)
        #expect(stopped.failure == ControllerLaunchFailure(stage: "owner", reason: "confirmed_stopped"))
        #expect(try await store.work(work.id).state == .interrupted)
    }

    @Test func ownerInterruptIsRefusedWhileTheLaunchIsUnresolved() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        await #expect(throws: ControllerError.conflict) { try await store.interruptStoppedExecution(launch.executionID) }
        #expect(try await store.work(work.id).state == .running)
        let plain = try await helpers.seed(store, worker: WorkerID(), key: "no-launch")
        let claim = try #require(await store.claim(workerID: plain.workerID))
        #expect(try await store.interruptStoppedExecution(claim.execution.id).state == .interrupted)
    }

    @Test func aTransientRefusalRequeuesWithoutPausingTheWorker() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let policy = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: launches.spec())
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        let launch = try #require(await store.prepareSupervisedLaunch(work.workerID))
        _ = try await store.beginLaunch(launch.executionID)
        let stopped = try await store.recordLaunchStopped(launch.executionID, evidence: .spawnFailed(errorNumber: 35), requeue: true)
        #expect(stopped.failure == ControllerLaunchFailure(stage: "spawn", reason: "spawn_failed", errorNumber: 35))
        #expect(try await store.work(work.id).state == .queued)
        #expect(try await store.workerPolicy(work.workerID)?.enabled == true)
        #expect(try await store.prepareSupervisedLaunch(work.workerID)?.workID == work.id, "the same work is admitted again")
    }

    @Test func aHostLossIsDefiniteStopEvidence() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        _ = try await store.recordSpawn(launch.executionID, pid: 99, seconds: 1, microseconds: 0)
        let incident = UUID()
        let stopped = try await store.recordLaunchStopped(launch.executionID, evidence: .hostLost(incident: incident))
        #expect(stopped.failure?.stage == "host" && stopped.failure?.incident == incident.uuidString.lowercased())
        #expect(try await store.work(work.id).state == .interrupted)
        #expect(try await store.unresolvedLaunches().items.isEmpty, "the slot is released")
    }

    @Test func anEarlyExitKeepsARedactedBoundedTail() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let secret = "sk-fixture-0123456789"
        let spec = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/sh", arguments: ["--token", "argument-secret-value"],
                                        environment: ["API_KEY": secret, "TERM": "xterm"], directory: "/tmp",
                                        recipients: ["group:ops"], destination: "draft")
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let noise = String(repeating: "progress line\r\n", count: 400)
        let output = noise + "\u{1B}[31mfatal:\u{1B}[0m key \(secret) arg argument-secret-value cred \(credential)\u{1B}]0;title\u{07}\r\n"
        let stopped = try await store.recordLaunchStopped(launch.executionID,
            evidence: .exited(status: 2, signalled: false, tail: Data(output.utf8)))
        let tail = try #require(stopped.outputTail)
        #expect(stopped.failure == ControllerLaunchFailure(stage: "exit", reason: "nonzero_exit"))
        #expect(tail.contains("fatal: key [redacted] arg [redacted] cred [redacted]"))
        #expect(!tail.contains(secret) && !tail.contains(credential) && !tail.contains("\u{1B}") && !tail.contains("title"))
        #expect(tail.utf8.count <= ControllerOutputTail.maximumBytes)
        #expect(ControllerLaunchStatus(stopped).outputTail == tail)
    }

    @Test func aCleanFinishRecordsNoFailure() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        _ = try await store.finish(executionID: launch.executionID, destination: "draft", payload: "Done")
        let stopped = try await store.recordLaunchStopped(launch.executionID,
            evidence: .exited(status: 0, signalled: false, tail: Data("bye".utf8)))
        #expect(stopped.failure == nil && stopped.outputTail == nil)
    }

    /// An older process left open while a newer build migrates must stop writing.
    @Test func everyWriteRechecksTheSchema() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let path = directory.appendingPathComponent("controller.db").path
        let newer = try ControllerDatabase(path: path)
        try newer.run("PRAGMA user_version=\(ControllerDatabase.schemaVersion + 1)")
        await #expect(throws: ControllerError.unsupportedSchema) {
            try await store.enqueue(workerID: work.workerID, key: "after-migration", instruction: "Refused")
        }
        #expect(try await store.works(workerID: work.workerID).items.count == 1)
        #expect(throws: ControllerError.unsupportedSchema) { try ControllerStore(path: path) }
    }

    /// Several processes opening an old store at once serialize on the write lock; each step
    /// runs once and the version only moves forward.
    @Test func concurrentOpensMigrateAnOldStoreOnce() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let path = directory.appendingPathComponent("controller.db").path
        do {
            let old = try ControllerDatabase(path: path)
            try old.run("DROP INDEX mail_open"); try old.run("DROP INDEX mail_wake")
            try old.run("DROP TABLE mail_outbound"); try old.run("DROP TABLE usage_unsettled")
            try old.run("PRAGMA user_version=6")
        }
        let failures = OpenFailures()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do { _ = try ControllerStore(path: path) } catch { failures.add(error) }
        }
        #expect(failures.count == 0)
        let reopened = try ControllerDatabase(path: path)
        #expect(try reopened.rows("PRAGMA user_version").first?.integers[0] == ControllerDatabase.schemaVersion)
        #expect(try await ControllerStore(path: path).work(work.id).id == work.id)
    }
}

private final class OpenFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func add(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}
