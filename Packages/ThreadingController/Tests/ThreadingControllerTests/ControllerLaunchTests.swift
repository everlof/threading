import Foundation
import Testing
@testable import ThreadingController

struct ControllerLaunchTests {
    let helpers = ControllerStoreTests()
    func spec() -> ControllerLaunchSpec {
        .init(socketPath: "/tmp/fixture.sock", executable: "/bin/sh", arguments: [], environment: [:],
              directory: "/tmp", recipients: ["group:ops"], destination: "draft")
    }

    @Test func answerCannotOverlapLiveProcessAndOtherWorkContinues() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: spec()))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let question = try #require(await store.agentRequest(executionID: launch.executionID, credential: credential,
            request: .ask(id: QuestionID(), text: "Audience?", checkpoint: "Ready")).question)
        _ = try await store.answer(questionID: question.id, principal: AnswerPrincipal(person: "person:a", groups: ["group:ops"]), text: "Team")
        #expect(try await store.claim(workerID: work.workerID) == nil)
        let other = try await store.enqueue(workerID: work.workerID, key: "other", instruction: "Unrelated")
        #expect(try await store.claim(workerID: work.workerID)?.work.id == other.id)
        _ = try await store.confirmLaunchStopped(launch.executionID, exitStatus: 0)
        let continuation = try #require(await store.claim(workerID: work.workerID))
        #expect(continuation.work.id == work.id)
        #expect(continuation.work.checkpoint == "Ready")
        await #expect(throws: ControllerError.forbidden) {
            try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .memoryGet(key: "x"))
        }
    }

    @Test func scopeAndTerminalWritesAreFencedAtomically() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: spec()))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        await #expect(throws: ControllerError.forbidden) {
            try await store.agentRequest(executionID: launch.executionID, credential: "wrong", request: .context)
        }
        let memory = try await store.agentRequest(executionID: launch.executionID, credential: credential,
            request: .memoryPut(key: "notes", expectedRevision: 0, content: "Learned"))
        #expect(memory.memory?.workerID == work.workerID)
        let delivery = try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .finish(payload: "Result"))
        #expect(delivery.delivery?.destination == "draft")
        #expect(try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .finish(payload: "Result")).delivery == delivery.delivery)
        await #expect(throws: ControllerError.conflict) {
            try await store.agentRequest(executionID: launch.executionID, credential: credential,
                request: .memoryPut(key: "notes", expectedRevision: 1, content: "Stale"))
        }
        #expect(try await store.memory(workerID: work.workerID, key: "notes")?.content == "Learned")
    }

    @Test func onlyOneDispatcherAcrossConnectionsAndNoExpiryRetry() async throws {
        let (directory, first) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(first)
        let launch = try #require(await first.prepareLaunch(workerID: work.workerID, spec: spec()))
        let second = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        async let a = try? first.beginLaunch(launch.executionID)
        async let b = try? second.beginLaunch(launch.executionID)
        #expect(await [a, b].compactMap { $0 }.count == 1)
        #expect(try await second.claim(workerID: work.workerID) == nil)
        _ = try await second.confirmLaunchStopped(launch.executionID, exitStatus: 0)
        #expect(try await first.work(work.id).state == .interrupted)
        #expect(try await first.claim(workerID: work.workerID) == nil)
        _ = try await first.retry(workID: work.id)
        #expect(try await second.claim(workerID: work.workerID)?.work.id == work.id)
    }

    @Test func failedLaunchPreparationRollsBackClaimAndMigrationKeepsWork() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let path = directory.appendingPathComponent("controller.db").path
        let connection = try ControllerDatabase(path: path)
        try connection.run("CREATE TRIGGER refuse_launch BEFORE INSERT ON event WHEN NEW.kind='launch.prepared' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        await #expect(throws: (any Error).self) { try await store.prepareLaunch(workerID: work.workerID, spec: spec()) }
        #expect(try await store.work(work.id).state == .queued)
        #expect(try await store.launches(workID: work.id).items.isEmpty)
        try connection.run("DROP INDEX record_scope_state")
        try connection.run("DROP INDEX unresolved_launch")
        try connection.run("DROP INDEX unresolved_delivery")
        try connection.run("ALTER TABLE record DROP COLUMN scope")
        try connection.run("DROP TABLE automation_due")
        try connection.run("PRAGMA user_version=1")
        let migrated = try ControllerStore(path: path)
        #expect(try await migrated.work(work.id) == work)
        #expect(try connection.rows("PRAGMA user_version").first?.integers[0] == 9)
    }
}
