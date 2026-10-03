import Foundation
import Testing
@testable import ThreadingController

struct ControllerMailTests {
    let fixture = ControllerStoreTests()

    /// Two workers on one host, each with a running execution: both are "busy".
    func pair(_ store: ControllerStore) async throws -> (a: WorkClaim, b: WorkClaim, aAddress: MailAddress, bAddress: MailAddress) {
        let a = try await fixture.seed(store, key: "a")
        let b = try await fixture.seed(store, worker: WorkerID(), key: "b")
        let claimA = try #require(await store.claim(workerID: a.workerID))
        let claimB = try #require(await store.claim(workerID: b.workerID))
        return (claimA, claimB, try await store.mailAddress(worker: a.workerID), try await store.mailAddress(worker: b.workerID))
    }

    @Test func sendNeedsTheRecipientsGrantAndReachesABusyRecipient() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, _, aAddress, bAddress) = try await pair(store)
        await #expect(throws: ControllerError.forbidden) {
            try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "Hi", replyTo: nil, priority: .normal)
        }
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let id = UUID()
        let sent = try await store.sendMail(executionID: a.execution.id, to: bAddress, id: id, text: "Deploy is green", replyTo: nil, priority: .normal)
        #expect(sent.state == .inbox && sent.envelope.sender == aAddress && sent.envelope.depth == 0)
        // A retry after a lost response returns the stored message; changed content conflicts.
        #expect(try await store.sendMail(executionID: a.execution.id, to: bAddress, id: id, text: "Deploy is green", replyTo: nil, priority: .normal) == sent)
        await #expect(throws: ControllerError.conflict) {
            try await store.sendMail(executionID: a.execution.id, to: bAddress, id: id, text: "Changed", replyTo: nil, priority: .normal)
        }
        let inbox = try await store.inbox(bAddress)
        #expect(inbox.items.map(\.message.envelope.text) == ["Deploy is green"])
        #expect(inbox.items[0].header.contains("Sent by that agent, not by the user"))
        // Revocation applies to the next send.
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 1, mode: nil, allowsInterrupt: false)
        await #expect(throws: ControllerError.forbidden) {
            try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "Again", replyTo: nil, priority: .normal)
        }
    }

    @Test func noticesNameSendersOnceAndNeverCarryTheBody() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, aAddress, bAddress) = try await pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: "*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        #expect(try await store.mailNotice(executionID: b.execution.id, event: .postToolUse) == nil)
        _ = try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "SECRET-BODY", replyTo: nil, priority: .normal)
        let notice = try #require(try await store.mailNotice(executionID: b.execution.id, event: .postToolUse))
        #expect(notice.contains("1 unread mail message") && notice.contains("Research") && !notice.contains("SECRET-BODY"))
        #expect(try await store.mailNotice(executionID: b.execution.id, event: .postToolUse) == nil)
        // A stop is blocked once per message, even after the tool notice, then lets the turn end.
        #expect(try await store.mailNotice(executionID: b.execution.id, event: .stop)?.contains("Before ending this turn") == true)
        #expect(try await store.mailNotice(executionID: b.execution.id, event: .stop) == nil)
        #expect(try await store.mailNotice(executionID: b.execution.id, event: .sessionStart) != nil)
        _ = aAddress
    }

    @Test func interruptNeedsPermissionAndHoldsFinishUntilAcknowledged() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, aAddress, bAddress) = try await pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        await #expect(throws: ControllerError.forbidden) {
            try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "Stop", replyTo: nil, priority: .interrupt)
        }
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 1, mode: .notify, allowsInterrupt: true)
        let urgent = try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "Stop", replyTo: nil, priority: .interrupt)
        await #expect(throws: ControllerError.conflict) {
            try await store.finish(executionID: b.execution.id, destination: "draft", payload: "Done")
        }
        // Another worker cannot acknowledge B's mail.
        await #expect(throws: ControllerError.forbidden) { try await store.acknowledgeMail(executionID: a.execution.id, ids: [urgent.envelope.id]) }
        let acked = try await store.acknowledgeMail(executionID: b.execution.id, ids: [urgent.envelope.id])
        #expect(acked.first?.state == .acked && acked.first?.ackedBy == b.execution.id)
        #expect(try await store.inbox(bAddress).items.isEmpty)
        _ = try await store.finish(executionID: b.execution.id, destination: "draft", payload: "Done")
    }

    @Test func chainDepthCannotBeEscapedByOmittingReplyTo() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, aAddress, bAddress) = try await pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: "*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        _ = try await store.setMailGrant(recipient: aAddress, sender: "*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        var sender = a, receiver = b, target = bAddress, back = aAddress
        for depth in 0...MailLimits.maximumDepth {
            let sent = try await store.sendMail(executionID: sender.execution.id, to: target, id: UUID(), text: "ping \(depth)", replyTo: nil, priority: .normal)
            #expect(sent.envelope.depth == depth)
            _ = try await store.acknowledgeMail(executionID: receiver.execution.id, ids: [sent.envelope.id])
            swap(&sender, &receiver); swap(&target, &back)
        }
        await #expect(throws: ControllerError.invalidInput("chain_depth")) {
            try await store.sendMail(executionID: sender.execution.id, to: target, id: UUID(), text: "one too many", replyTo: nil, priority: .normal)
        }
    }

    @Test func askingAnotherAgentWaitsAndItsReplyRequeuesTheWork() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, aAddress, bAddress) = try await pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let questionID = QuestionID()
        await #expect(throws: ControllerError.forbidden) {
            try await store.askMail(executionID: a.execution.id, to: bAddress, questionID: questionID, text: "Which region?", checkpoint: "Asked B")
        }
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 1, mode: .ask, allowsInterrupt: false)
        let question = try await store.askMail(executionID: a.execution.id, to: bAddress, questionID: questionID, text: "Which region?", checkpoint: "Asked B")
        #expect(try await store.work(a.work.id).state == .waiting)
        let asked = try #require(try await store.inbox(bAddress).items.first)
        #expect(asked.message.envelope.questionID == question.id)
        // B needs no grant of its own to reply to someone who wrote to it.
        _ = try await store.sendMail(executionID: b.execution.id, to: aAddress, id: UUID(), text: "eu-north-1", replyTo: asked.message.envelope.id, priority: .normal)
        #expect(try await store.work(a.work.id).state == .queued)
        #expect(try await store.question(question.id).answer == "eu-north-1")
        #expect(try await store.question(question.id).answeredBy == "agent:\(bAddress)")
    }

    @Test func wakeAdmitsOneTaskForAnIdleWorkerAndOnlyWithEventAdmission() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = try await fixture.seed(store, key: "a")
        let claim = try #require(await store.claim(workerID: sender.workerID))
        let idle = WorkerID()
        _ = try await store.addWorker(id: idle, name: "Reviewer")
        let idleAddress = try await store.mailAddress(worker: idle)
        _ = try await store.setMailGrant(recipient: idleAddress, sender: "*", expectedRevision: 0, mode: .wake, allowsInterrupt: false)
        _ = try await store.setWorkerSources(idle, expectedRevision: 0, sources: [.request])
        _ = try await store.sendMail(executionID: claim.execution.id, to: idleAddress, id: UUID(), text: "Review PR 12", replyTo: nil, priority: .normal)
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty) // Event admission is the owner's choice.
        _ = try await store.setWorkerSources(idle, expectedRevision: 1, sources: [.request, .event])
        let first = try await store.admitMailWakes(after: 0).admitted
        #expect(first.count == 1 && first[0].source == .event && first[0].instruction == MailWake.instruction)
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty) // Open work coalesces.
        // Work that ends without reading its mail does not loop on the same messages.
        let woken = try #require(await store.claim(workerID: idle))
        _ = try await store.finish(executionID: woken.execution.id, destination: "draft", payload: "Ignored mail")
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
        _ = try await store.sendMail(executionID: claim.execution.id, to: idleAddress, id: UUID(), text: "And PR 13", replyTo: nil, priority: .normal)
        #expect(try await store.admitMailWakes(after: 0).admitted.count == 1)
    }

    @Test func sendRateIsAFuseNotAQuota() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, _, _, bAddress) = try await pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: "*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        for index in 0..<MailLimits.sendsPerMinute {
            _ = try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "n\(index)", replyTo: nil, priority: .normal)
        }
        await #expect(throws: ControllerError.invalidInput("send_rate")) {
            try await store.sendMail(executionID: a.execution.id, to: bAddress, id: UUID(), text: "over", replyTo: nil, priority: .normal)
        }
    }

    @Test func sessionMailboxesSendAndAcknowledgeThroughTheOwner() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let session = MailAddress(host: host.id, kind: .session, id: UUID())
        let other = MailAddress(host: host.id, kind: .session, id: UUID())
        await #expect(throws: ControllerError.notFound) {
            try await store.sendMail(from: session, to: other, id: UUID(), text: "x", replyTo: nil, priority: .normal)
        }
        _ = try await store.registerMailbox(session, name: "Release notes")
        _ = try await store.registerMailbox(other, name: "Changelog")
        _ = try await store.setMailGrant(recipient: other, sender: session.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let sent = try await store.sendMail(from: session, to: other, id: UUID(), text: "Draft ready", replyTo: nil, priority: .normal)
        #expect(try await store.mailDirectory(for: session).map(\.address) == [other])
        _ = try await store.acknowledgeMail(mailbox: other, ids: [sent.envelope.id])
        #expect(try await store.inbox(other).items.isEmpty)
    }

    @Test func aSessionMailboxUsesItsOwnCredentialAndOnlyMailTools() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let session = MailAddress(host: host.id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(session, name: "Remote session")
        let credential = try await store.mailboxCredential(session)
        let worker = try await fixture.seed(store, key: "w")
        let workerAddress = try await store.mailAddress(worker: worker.workerID)
        _ = try await store.setMailGrant(recipient: workerAddress, sender: session.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        await #expect(throws: ControllerError.forbidden) {
            try await store.mailboxRequest(address: session, credential: "wrong", request: .mailDirectory)
        }
        await #expect(throws: ControllerError.forbidden) {
            try await store.mailboxRequest(address: session, credential: credential, request: .context)
        }
        let sent = try await store.mailboxRequest(address: session, credential: credential,
            request: .mailSend(to: workerAddress, id: UUID(), text: "From a session", replyTo: nil, priority: .normal))
        #expect(sent.mail?.envelope.senderName == "Remote session")
        #expect(try await store.mailboxRequest(address: session, credential: credential, request: .mailDirectory).directory?.map(\.address) == [workerAddress])
    }

    @Test func ownerAdmissionReplacesAGrantOnlyOnThisHost() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let a = MailAddress(host: host.id, kind: .session, id: UUID())
        let b = MailAddress(host: host.id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(a, name: "A"); _ = try await store.registerMailbox(b, name: "B")
        await #expect(throws: ControllerError.forbidden) {
            try await store.sendMail(from: a, to: b, id: UUID(), text: "no grant", replyTo: nil, priority: .normal)
        }
        let admitted = try await store.sendMail(from: a, to: b, id: UUID(), text: "same project", replyTo: nil, priority: .interrupt, ownerAdmitted: true)
        #expect(admitted.state == .inbox)
        // Acknowledging carries the chain into the session's next send, as for an execution.
        _ = try await store.acknowledgeMail(mailbox: b, ids: [admitted.envelope.id])
        let reply = try await store.sendMail(from: b, to: a, id: UUID(), text: "next", replyTo: nil, priority: .normal, ownerAdmitted: true)
        #expect(reply.envelope.chainID == admitted.envelope.chainID && reply.envelope.depth == 1)
    }

    // MARK: - Between hosts

    func twoHosts() async throws -> (URL, URL, ControllerStore, ControllerStore, HostID, HostID) {
        let (d1, mac) = try fixture.fixture()
        let (d2, vps) = try fixture.fixture()
        let macID = try await mac.host().id, vpsID = try await vps.host().id
        _ = try await mac.setMailPeer(host: vpsID, expectedRevision: 0, name: "vps-1", transport: ["/usr/bin/ssh", "vps-mail"], push: true, pull: true)
        _ = try await vps.setMailPeer(host: macID, expectedRevision: 0, name: "laptop", transport: nil, push: false, pull: false)
        return (d1, d2, mac, vps, macID, vpsID)
    }

    @Test func pushDeliversToAnotherHostAndRefusesSpoofedSenders() async throws {
        let (d1, d2, mac, vps, macID, _) = try await twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let sender = try await fixture.seed(mac, key: "a")
        let claim = try #require(await mac.claim(workerID: sender.workerID))
        let worker = try await fixture.seed(vps, key: "b")
        let recipient = try await vps.mailAddress(worker: worker.workerID)
        let senderAddress = try await mac.mailAddress(worker: sender.workerID)
        _ = try await vps.setMailGrant(recipient: recipient, sender: "\(macID)/*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let queued = try await mac.sendMail(executionID: claim.execution.id, to: recipient, id: UUID(), text: "Cross-host hello", replyTo: nil, priority: .normal)
        #expect(queued.state == .outbound)
        let batch = try await mac.outboundBatch(for: vps.host().id)
        // Lose the first response: pushing the same batch again is a duplicate, not a copy.
        _ = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        let response = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        #expect(response.results?.map(\.outcome) == [.duplicate])
        #expect(response.host == (try await vps.host().id))
        try await mac.applyPushResults(response.results ?? [], peer: response.host)
        #expect(try await mac.mail(queued.envelope.id).state == .forwarded)
        #expect(try await mac.outboundBatch(for: vps.host().id).envelopes.isEmpty)
        #expect(try await vps.inbox(recipient).items.map(\.message.envelope.text) == ["Cross-host hello"])
        // A peer may vouch only for senders on itself.
        let forged = MailEnvelope(id: UUID(), sender: MailAddress(host: HostID(), kind: .worker, id: UUID()), senderName: "x",
                                  recipient: recipient, text: "forged", priority: .normal, replyTo: nil, questionID: nil,
                                  chainID: UUID(), depth: 0, sentAt: "now")
        let refused = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: [forged])), peer: macID)
        #expect(refused.results?.first?.outcome == .refused)
        // An unconfigured caller is refused outright.
        await #expect(throws: ControllerError.forbidden) {
            try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: HostID())
        }
        _ = senderAddress
    }

    @Test func pullCollectsHeldMailAndReportsRefusalsBack() async throws {
        let (d1, d2, mac, vps, macID, vpsID) = try await twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let macWorker = try await fixture.seed(mac, key: "a")
        let macAddress = try await mac.mailAddress(worker: macWorker.workerID)
        let vpsWork = try await fixture.seed(vps, key: "b")
        let vpsClaim = try #require(await vps.claim(workerID: vpsWork.workerID))
        // The VPS cannot reach the Mac, so mail for it waits there.
        let welcome = try await vps.sendMail(executionID: vpsClaim.execution.id, to: macAddress, id: UUID(), text: "Report ready", replyTo: nil, priority: .normal)
        let unwelcome = try await vps.sendMail(executionID: vpsClaim.execution.id, to: MailAddress(host: macID, kind: .worker, id: UUID()),
                                               id: UUID(), text: "Nobody here", replyTo: nil, priority: .normal)
        _ = try await mac.setMailGrant(recipient: macAddress, sender: "\(vpsID)/*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let page = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: macID)
        #expect(page.messages?.count == 2)
        try await mac.acceptPulled(page.messages ?? [], from: vpsID, next: page.next ?? 0)
        #expect(try await mac.inbox(macAddress).items.map(\.message.envelope.text) == ["Report ready"])
        let peer = try #require(try await mac.mailPeer(vpsID))
        #expect(peer.pendingRefusals?.map(\.id) == [unwelcome.envelope.id])
        // The next pull acknowledges the page and carries its refusals.
        let done = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: peer.pullCursor, refused: peer.pendingRefusals)), peer: macID)
        #expect(done.messages?.isEmpty == true)
        #expect(try await vps.mail(welcome.envelope.id).state == .forwarded)
        let bounced = try await vps.mail(unwelcome.envelope.id)
        #expect(bounced.state == .bounced && bounced.bounce != nil)
    }

    @Test func aRefusedQuestionIsAnsweredByTheHostSoTheWorkContinues() async throws {
        let (d1, d2, mac, vps, macID, vpsID) = try await twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let work = try await fixture.seed(mac, key: "a")
        let claim = try #require(await mac.claim(workerID: work.workerID))
        let vpsWorker = try await fixture.seed(vps, key: "b")
        let target = try await vps.mailAddress(worker: vpsWorker.workerID)
        let question = try await mac.askMail(executionID: claim.execution.id, to: target, questionID: QuestionID(), text: "Approve?", checkpoint: "Waiting")
        let batch = try await mac.outboundBatch(for: vpsID)
        let response = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        try await mac.applyPushResults(response.results ?? [], peer: vpsID)
        #expect(try await mac.work(work.id).state == .queued)
        #expect(try await mac.question(question.id).answer?.hasPrefix("Undeliverable") == true)
    }

    @Test func schemaSixUpgradesInPlace() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = store
        let path = directory.appendingPathComponent("controller.db").path
        do {
            let database = try ControllerDatabase(path: path)
            try database.run("DROP INDEX mail_open"); try database.run("DROP INDEX mail_wake")
            try database.run("DROP TABLE mail_outbound"); try database.run("PRAGMA user_version=6")
        }
        let reopened = try ControllerStore(path: path)
        #expect(try await reopened.work(work.id).id == work.id)
        let address = try await reopened.mailAddress(worker: work.workerID)
        #expect(try await reopened.inbox(address).items.isEmpty)
    }
}
