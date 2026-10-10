import Foundation
import Testing
@testable import ThreadingController

struct LinkedWorkroomTests {
    private func fixture() throws -> (URL, ControllerStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try ControllerStore(path: directory.appendingPathComponent("controller.db").path))
    }

    @Test func unlinkedRoomCanGainLinksAndKeepQuestionAcrossRestart() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roomID = WorkroomID()
        let workerID = WorkerID()
        let room = try await store.createWorkroom(id: roomID, scope: "sonda", title: "Classification decision",
                                                  purpose: "Agree on the domain rule")
        #expect(try await store.createWorkroom(id: roomID, scope: "sonda", title: room.title,
                                               purpose: room.purpose) == room)
        #expect(try await store.workroomLinks(roomID: roomID).items.isEmpty)

        let linkID = WorkroomLinkID()
        let link = try await store.addWorkroomLink(id: linkID, roomID: roomID, kind: .issue,
                                                   provider: "jira", target: "SONDA-123", label: "SONDA-123",
                                                   relationship: .affected, url: "https://example.test/browse/SONDA-123")
        #expect(try await store.addWorkroomLink(id: linkID, roomID: roomID, kind: .issue,
                                                 provider: "jira", target: "SONDA-123", label: "SONDA-123",
                                                 relationship: .affected, url: link.url) == link)
        #expect(try await store.workroomLinks(roomID: roomID).items == [link])

        _ = try await store.addWorker(id: workerID, name: "Technical agent")
        let work = try await store.enqueueInWorkroom(roomID: roomID, workerID: workerID, key: "decision-1",
                                                      instruction: "Ask the domain expert")
        #expect(work.workroomID == roomID)
        #expect(try await store.enqueueInWorkroom(roomID: roomID, workerID: workerID, key: "decision-1",
                                                  instruction: "Ask the domain expert") == work)
        #expect(try await store.workroomWorks(roomID: roomID).items.map(\.id) == [work.id])

        let claim = try #require(await store.claim(workerID: workerID))
        let presentation = WorkQuestionPresentation(context: "The current rule has two plausible readings.",
                                                    choices: ["Keep the existing behavior", "Apply the new classification"],
                                                    sources: ["SONDA-123 description; verify its latest revision"])
        let question = try await store.ask(executionID: claim.execution.id, id: QuestionID(),
                                           recipients: ["person:expert"], text: "Which rule applies?",
                                           checkpoint: "Analysis prepared", presentation: presentation)
        #expect(question.presentation == presentation)
        #expect(try await store.ask(executionID: claim.execution.id, id: question.id,
                                    recipients: ["person:expert"], text: "Which rule applies?",
                                    checkpoint: "Analysis prepared", presentation: presentation) == question)
        await #expect(throws: ControllerError.conflict) {
            try await store.ask(executionID: claim.execution.id, id: question.id,
                                recipients: ["person:expert"], text: "Which rule applies?",
                                checkpoint: "Analysis prepared",
                                presentation: WorkQuestionPresentation(context: "Changed explanation"))
        }
        #expect(try await store.workroomQuestions(roomID: roomID, openOnly: true).items.map(\.id) == [question.id])
        #expect(try await store.workroomQuestionsFor(roomID: roomID, recipient: "person:expert").items.map(\.id) == [question.id])
        #expect(try await store.workroomQuestionsFor(roomID: roomID, recipient: "person:owner").items.isEmpty)

        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.workroom(roomID) == room)
        #expect(try await reopened.workroomQuestions(roomID: roomID, openOnly: true).items.count == 1)
        #expect(try await reopened.workroomQuestion(roomID: roomID, questionID: question.id).presentation == presentation)
        let principal = try AnswerPrincipal(person: "person:expert")
        let answered = try await reopened.answer(questionID: question.id, principal: principal,
                                                  text: "Use the existing rule")
        #expect(answered.answer == "Use the existing rule")
        #expect(try await reopened.workroomQuestions(roomID: roomID, openOnly: true).items.isEmpty)
        #expect(try await reopened.workroomQuestions(roomID: roomID).items.first?.answer == "Use the existing rule")
        #expect(try await reopened.claim(workerID: workerID)?.work.id == work.id)
    }

    @Test func roomsAndWorkCannotCrossTheirBoundaries() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkroomID()
        let second = WorkroomID()
        let worker = WorkerID()
        _ = try await store.createWorkroom(id: first, scope: "sonda", title: "First", purpose: "")
        _ = try await store.createWorkroom(id: second, scope: "other", title: "Second", purpose: "")
        _ = try await store.addWorker(id: worker, name: "Agent")
        _ = try await store.enqueueInWorkroom(roomID: first, workerID: worker, key: "same-key",
                                              instruction: "Do one thing")
        await #expect(throws: ControllerError.conflict) {
            try await store.enqueueInWorkroom(roomID: second, workerID: worker, key: "same-key",
                                              instruction: "Do one thing")
        }
        #expect(try await store.workrooms(scope: "sonda").items.map(\.id) == [first])
        #expect(try await store.workrooms(scope: "other").items.map(\.id) == [second])
        #expect(try await store.workroomWorks(roomID: second).items.isEmpty)
        await #expect(throws: ControllerError.invalidInput("url")) {
            try await store.addWorkroomLink(id: WorkroomLinkID(), roomID: first, kind: .url,
                                            provider: "web", target: "bad", label: "Bad",
                                            relationship: .context, url: "javascript:alert(1)")
        }
    }

    @Test func agentToolsDeriveTheRoomFromTheirExecution() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkroomID()
        let second = WorkroomID()
        let worker = WorkerID()
        _ = try await store.createWorkroom(id: first, scope: "sonda", title: "Allowed", purpose: "")
        _ = try await store.createWorkroom(id: second, scope: "sonda", title: "Other", purpose: "")
        _ = try await store.addWorkroomLink(id: WorkroomLinkID(), roomID: first, kind: .issue,
                                            provider: "jira", target: "SONDA-1", label: "Allowed issue",
                                            relationship: .context)
        _ = try await store.addWorkroomLink(id: WorkroomLinkID(), roomID: second, kind: .issue,
                                            provider: "jira", target: "SONDA-2", label: "Other issue",
                                            relationship: .context)
        _ = try await store.addWorker(id: worker, name: "Agent")
        _ = try await store.enqueueInWorkroom(roomID: first, workerID: worker, key: "one", instruction: "Inspect")
        let spec = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true",
                                        arguments: [], environment: [:], directory: "/tmp",
                                        recipients: ["person:expert"], destination: "draft")
        let launch = try #require(await store.prepareLaunch(workerID: worker, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let context = try await store.agentRequest(executionID: launch.executionID, credential: credential,
                                                    request: .workroomContext)
        #expect(context.workroom?.id == first)
        #expect(context.workroomLinks?.items.map(\.label) == ["Allowed issue"])
        let links = try await store.agentRequest(executionID: launch.executionID, credential: credential,
                                                  request: .workroomLinks(after: 0))
        #expect(links.workroomLinks?.items.map(\.target) == ["SONDA-1"])
    }
}
