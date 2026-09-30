import Foundation
import Testing
@testable import ThreadingController

struct ControllerOperationsTests {
    @Test func openInboxAndOutboxExcludeClosedHistoryAcrossMigration() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let execution = try #require(await store.claim(workerID: work.workerID))
        let question = try await store.ask(executionID: execution.execution.id, id: QuestionID(), recipients: ["group:ops"], text: "Question", checkpoint: "Saved")
        let connection = try ControllerDatabase(path: directory.appendingPathComponent("controller.db").path)
        try connection.run("UPDATE record SET scope=NULL WHERE kind='question'")
        try connection.run("DROP INDEX unresolved_delivery")
        try connection.run("DROP TABLE automation_due")
        try connection.run("PRAGMA user_version=3")
        let migrated = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await migrated.openQuestions(workerID: work.workerID).items == [question])
        #expect(try await migrated.openQuestions(workerID: WorkerID()).items.isEmpty)
        _ = try await migrated.answer(questionID: question.id, principal: AnswerPrincipal(person: "person:owner", groups: ["group:ops"]), text: "Yes")
        #expect(try await migrated.openQuestions(workerID: work.workerID).items.isEmpty)
        let continued = try #require(await migrated.claim(workerID: work.workerID))
        let delivery = try await migrated.finish(executionID: continued.execution.id, destination: "draft", payload: "Result")
        #expect(try await migrated.pendingDeliveries().items == [delivery])
        let sending = try await migrated.beginDelivery(delivery.id)
        let attempt = try #require(sending.attemptID)
        _ = try await migrated.markDeliveryUncertain(delivery.id, attemptID: attempt)
        #expect(try await migrated.pendingDeliveries().items.first?.state == .uncertain)
        _ = try await migrated.acknowledgeDelivery(delivery.id, attemptID: attempt, receipt: "confirmed")
        #expect(try await migrated.pendingDeliveries().items.isEmpty)
        #expect(try await migrated.workDeliveries(workID: work.id).items.count == 1)
    }

    @Test func sharedKnowledgeRequiresCurrentGrantAndPreservesExecutionProvenance() async throws {
        let fixture = ControllerStoreTests()
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try await fixture.seed(store)
        let reader = try await fixture.seed(store)
        let space = KnowledgeSpaceID()
        let spec = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: [], environment: [:], directory: "/tmp", recipients: ["person:owner"], destination: "draft")
        let launch = try #require(await store.prepareLaunch(workerID: writer.workerID, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        let token = try await store.launchCredential(launch.executionID)
        let readLaunch = try #require(await store.prepareLaunch(workerID: reader.workerID, spec: spec))
        _ = try await store.beginLaunch(readLaunch.executionID)
        let readToken = try await store.launchCredential(readLaunch.executionID)
        let put = ControllerAgentRequest.knowledgePut(spaceID: space, key: "facts", expectedRevision: 0, content: "Evidence")
        await #expect(throws: ControllerError.forbidden) { try await store.agentRequest(executionID: launch.executionID, credential: token, request: put) }
        _ = try await store.grantKnowledge(spaceID: space, workerID: writer.workerID, expectedRevision: 0, access: .write)
        _ = try await store.grantKnowledge(spaceID: space, workerID: reader.workerID, expectedRevision: 0, access: .read)
        let saved = try await store.agentRequest(executionID: launch.executionID, credential: token, request: put)
        #expect(saved.knowledge?.executionID == launch.executionID)
        #expect(try await store.agentRequest(executionID: readLaunch.executionID, credential: readToken, request: .knowledgeGet(spaceID: space, key: "facts")).knowledge == saved.knowledge)
        await #expect(throws: ControllerError.forbidden) { try await store.agentRequest(executionID: readLaunch.executionID, credential: readToken, request: put) }
        await #expect(throws: ControllerError.conflict) { try await store.agentRequest(executionID: launch.executionID, credential: token, request: put) }
        _ = try await store.grantKnowledge(spaceID: space, workerID: writer.workerID, expectedRevision: 1, access: .none)
        await #expect(throws: ControllerError.forbidden) { try await store.agentRequest(executionID: launch.executionID, credential: token, request: .knowledgeGet(spaceID: space, key: "facts")) }
        #expect(try await store.knowledgeHistory(spaceID: space, key: "facts").items.count == 1)
    }
}
