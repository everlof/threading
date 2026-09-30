import Foundation
import Testing
@testable import ThreadingController

struct ControllerStoreTests {
    func fixture() throws -> (URL, ControllerStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try ControllerStore(path: directory.appendingPathComponent("controller.db").path))
    }
    func seed(_ store: ControllerStore, worker: WorkerID = WorkerID(), key: String = "source:1") async throws -> WorkItem {
        _ = try await store.addWorker(id: worker, name: "Research")
        return try await store.enqueue(workerID: worker, key: key, instruction: "Produce a report")
    }

    @Test func questionSurvivesRestartAndUnrelatedWorkContinues() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let question = try await store.ask(executionID: claim.execution.id, id: QuestionID(),
            recipients: ["group:operations", "person:owner"], text: "Which destination?", checkpoint: "Analysis finished")
        let other = try await store.enqueue(workerID: work.workerID, key: "source:2", instruction: "Independent task")
        #expect(try await store.claim(workerID: work.workerID)?.work.id == other.id)
        #expect(try await store.claim(workerID: work.workerID) == nil)

        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.work(work.id).state == .waiting)
        let principal = try AnswerPrincipal(person: "person:alice", groups: ["group:operations"])
        _ = try await reopened.answer(questionID: question.id, principal: principal, text: "Drafts")
        let resumed = try #require(await reopened.claim(workerID: work.workerID))
        #expect(resumed.work.id == work.id)
        #expect(resumed.execution.id != claim.execution.id)
        #expect(resumed.work.checkpoint == "Analysis finished")
        #expect(try await reopened.questions(workID: work.id).items.first?.answer == "Drafts")
        await #expect(throws: ControllerError.conflict) {
            try await reopened.checkpoint(executionID: claim.execution.id, text: "Stale writer")
        }
    }

    @Test func firstAuthorizedAnswerWinsAndRetryIsIdempotent() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let q = try await store.ask(executionID: claim.execution.id, id: QuestionID(), recipients: ["group:ops"],
                                    text: "Who?", checkpoint: "Prepared")
        await #expect(throws: ControllerError.forbidden) {
            try await store.answer(questionID: q.id, principal: AnswerPrincipal(person: "person:outsider"), text: "Me")
        }
        let alice = try AnswerPrincipal(person: "person:alice", groups: ["group:ops"])
        let answer = try await store.answer(questionID: q.id, principal: alice, text: "Alice")
        #expect(try await store.answer(questionID: q.id, principal: alice, text: "Alice") == answer)
        await #expect(throws: ControllerError.conflict) {
            try await store.answer(questionID: q.id,
                principal: AnswerPrincipal(person: "person:bob", groups: ["group:ops"]), text: "Bob")
        }
        let resumed = try #require(await store.claim(workerID: work.workerID))
        _ = try await store.checkpoint(executionID: resumed.execution.id, text: "Advanced")
        #expect(try await store.ask(executionID: claim.execution.id, id: q.id, recipients: ["group:ops"],
                                    text: "Who?", checkpoint: "Prepared") == answer)
    }

    @Test func questionAndYieldRollbackTogether() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let connection = try ControllerDatabase(path: directory.appendingPathComponent("controller.db").path)
        try connection.run("CREATE TRIGGER refuse_event BEFORE INSERT ON event WHEN NEW.kind='question.opened' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        await #expect(throws: (any Error).self) {
            try await store.ask(executionID: claim.execution.id, id: QuestionID(), recipients: ["person:owner"],
                                text: "Question", checkpoint: "Checkpoint")
        }
        #expect(try await store.questions(workID: work.id).items.isEmpty)
        #expect(try await store.work(work.id).state == .running)
        #expect(try await store.work(work.id).checkpoint == "")
        _ = try await store.checkpoint(executionID: claim.execution.id, text: "Still valid")
    }

    @Test func twoIndependentConnectionsCannotClaimSameWork() async throws {
        let (directory, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(first)
        let second = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        async let a = first.claim(workerID: work.workerID)
        async let b = second.claim(workerID: work.workerID)
        let claims = try await [a, b].compactMap { $0 }
        #expect(claims.count == 1)
    }

    @Test func duplicateSourceDoesNotEnqueueAgain() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        #expect(try await store.enqueue(workerID: work.workerID, key: work.key, instruction: work.instruction) == work)
        await #expect(throws: ControllerError.conflict) {
            try await store.enqueue(workerID: work.workerID, key: work.key, instruction: "Different input")
        }
        #expect(try await store.works(workerID: work.workerID).items.count == 1)
    }

    @Test func deliveryAmbiguityNeverSilentlyRetriesAndFencesOldAttempt() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let outbox = try await store.finish(executionID: claim.execution.id, destination: "drafts", payload: "Report")
        #expect(try await store.finish(executionID: claim.execution.id, destination: "drafts", payload: "Report") == outbox)
        #expect(try await store.work(work.id).state == .completed)
        #expect(outbox.state == .pending)
        let first = try await store.beginDelivery(outbox.id)
        let firstAttempt = try #require(first.attemptID)
        await #expect(throws: ControllerError.conflict) { try await store.beginDelivery(outbox.id) }
        _ = try await store.markDeliveryUncertain(outbox.id, attemptID: firstAttempt)
        await #expect(throws: ControllerError.conflict) { try await store.beginDelivery(outbox.id) }
        _ = try await store.confirmDeliveryAbsent(outbox.id, attemptID: firstAttempt)
        let second = try await store.beginDelivery(outbox.id)
        let secondAttempt = try #require(second.attemptID)
        await #expect(throws: ControllerError.conflict) {
            try await store.acknowledgeDelivery(outbox.id, attemptID: firstAttempt, receipt: "late")
        }
        _ = try await store.markDeliveryUncertain(outbox.id, attemptID: secondAttempt)
        let settled = try await store.acknowledgeDelivery(outbox.id, attemptID: secondAttempt, receipt: "remote:123")
        #expect(settled.state == .delivered)
        #expect(try await store.acknowledgeDelivery(outbox.id, attemptID: secondAttempt, receipt: "remote:123") == settled)
    }

    @Test func restartDoesNotRequeueClaimedWorkOrSendingDelivery() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        let claim = try #require(await store.claim(workerID: work.workerID))
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.claim(workerID: work.workerID) == nil)
        _ = try await reopened.interrupt(executionID: claim.execution.id)
        _ = try await reopened.retry(workID: work.id)
        let resumed = try #require(await reopened.claim(workerID: work.workerID))
        await #expect(throws: ControllerError.conflict) {
            try await store.finish(executionID: claim.execution.id, destination: "drafts", payload: "Old")
        }
        let delivery = try await reopened.finish(executionID: resumed.execution.id, destination: "drafts", payload: "New")
        _ = try await reopened.beginDelivery(delivery.id)
        let third = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await third.delivery(delivery.id).state == .sending)
        await #expect(throws: ControllerError.conflict) { try await third.beginDelivery(delivery.id) }
    }

    @Test func memoryIsWorkerScopedVersionedAndCompareAndSwap() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        _ = try await store.putMemory(workerID: work.workerID, key: "brief", expectedRevision: 0, content: "First")
        _ = try await store.putMemory(workerID: work.workerID, key: "brief", expectedRevision: 1, content: "Second")
        await #expect(throws: ControllerError.conflict) {
            try await store.putMemory(workerID: work.workerID, key: "brief", expectedRevision: 1, content: "Lost update")
        }
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.memory(workerID: work.workerID, key: "brief")?.content == "Second")
        #expect(try await reopened.memory(workerID: WorkerID(), key: "brief") == nil)
        #expect(try await reopened.memoryHistory(workerID: work.workerID, key: "brief").items.map(\.content) == ["First", "Second"])
    }

    @Test func paginationIsBoundedAndEventsOnlyFollowCommittedMutations() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        for index in 2...8 { _ = try await store.enqueue(workerID: work.workerID, key: "\(index)", instruction: "Work") }
        var cursor: Int64 = 0
        var ids = Set<WorkID>()
        while true {
            let page = try await store.works(workerID: work.workerID, after: cursor, limit: 3)
            #expect(page.items.count <= 3)
            if page.items.isEmpty { break }
            ids.formUnion(page.items.map(\.id))
            #expect(page.next > cursor)
            cursor = page.next
        }
        #expect(ids.count == 8)
        let events = try await store.events()
        #expect(events.items.count == 9)
        #expect(events.items.map(\.sequence) == Array(1...9).map(Int64.init))
        await #expect(throws: ControllerError.invalidInput("page")) { try await store.events(limit: 101) }
    }

    @Test func pagesAlsoBoundAggregateBytesWithoutDroppingRows() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Large records")
        // JSON escaping expands this bounded input by six; a row cap alone is insufficient.
        let text = String(repeating: "\u{1}", count: 32_768)
        for index in 0..<8 { _ = try await store.enqueue(workerID: worker, key: "\(index)", instruction: text) }
        let first = try await store.works(workerID: worker, limit: 100)
        #expect(first.items.count > 0 && first.items.count < 8)
        let second = try await store.works(workerID: worker, after: first.next, limit: 100)
        #expect(Set((first.items + second.items).map(\.id)).count == 8)
        #expect(try JSONEncoder().encode(first).count < 1_048_576)
    }

    @Test func malformedIdentityAndOversizedInputsRefuse() async throws {
        #expect(throws: ControllerError.invalidInput("recipient")) { try AnswerPrincipal(person: "person:") }
        #expect(throws: ControllerError.invalidInput("recipient")) { try AnswerPrincipal(person: "group:ops") }
        #expect(throws: ControllerError.invalidInput("identifier")) { try WorkID("not-an-id") }
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await seed(store)
        await #expect(throws: ControllerError.invalidInput("instruction")) {
            try await store.enqueue(workerID: work.workerID, key: "huge", instruction: String(repeating: "x", count: 32_769))
        }
        #expect(try await store.works(workerID: work.workerID).items.count == 1)
    }

    @Test func futureSchemaAndCorruptStoreAreNeverRecreated() throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("future.db").path
        let connection = try ControllerDatabase(path: path)
        try connection.run("PRAGMA user_version=99")
        #expect(throws: ControllerError.unsupportedSchema) { try ControllerStore(path: path) }
        let bad = directory.appendingPathComponent("corrupt.db")
        let bytes = Data("not a database".utf8)
        try bytes.write(to: bad)
        #expect(throws: (any Error).self) { try ControllerStore(path: bad.path) }
        #expect(try Data(contentsOf: bad) == bytes)
    }
}
