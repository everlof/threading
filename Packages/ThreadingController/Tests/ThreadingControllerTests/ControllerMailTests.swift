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
        // A session continues the conversation by replying to it.
        _ = try await store.acknowledgeMail(mailbox: b, ids: [admitted.envelope.id])
        let reply = try await store.sendMail(from: b, to: a, id: UUID(), text: "next", replyTo: admitted.envelope.id, priority: .normal, ownerAdmitted: true)
        #expect(reply.envelope.chainID == admitted.envelope.chainID && reply.envelope.depth == 1)
    }

    @Test func aSessionContinuesAChainOnlyByReplyingAndOtherwiseStartsFresh() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let a = MailAddress(host: host.id, kind: .session, id: UUID())
        let b = MailAddress(host: host.id, kind: .session, id: UUID())
        let c = MailAddress(host: host.id, kind: .session, id: UUID())
        for (address, name) in [(a, "A"), (b, "B"), (c, "C")] { _ = try await store.registerMailbox(address, name: name) }
        // A reply chain is bounded however deep it goes.
        var message = try await store.sendMail(from: a, to: b, id: UUID(), text: "ping", replyTo: nil, priority: .normal, ownerAdmitted: true)
        var from = b, to = a
        while message.envelope.depth < MailLimits.maximumDepth {
            _ = try await store.acknowledgeMail(mailbox: from, ids: [message.envelope.id])
            message = try await store.sendMail(from: from, to: to, id: UUID(), text: "pong", replyTo: message.envelope.id, priority: .normal, ownerAdmitted: true)
            swap(&from, &to)
        }
        await #expect(throws: ControllerError.invalidInput("chain_depth")) {
            try await store.sendMail(from: from, to: to, id: UUID(), text: "too deep", replyTo: message.envelope.id, priority: .normal, ownerAdmitted: true)
        }
        // Having read the deepest mail, and even after acknowledging it again, the session's
        // unrelated messages start fresh: nothing it read can refuse what it says next.
        _ = try await store.acknowledgeMail(mailbox: from, ids: [message.envelope.id])
        _ = try await store.acknowledgeMail(mailbox: from, ids: [message.envelope.id])
        let fresh = try await store.sendMail(from: from, to: c, id: UUID(), text: "new topic", replyTo: nil, priority: .normal, ownerAdmitted: true)
        #expect(fresh.envelope.depth == 0 && fresh.envelope.chainID != message.envelope.chainID)
    }

    @Test func theWakeBudgetIsJudgedOnTheMailThatMayWakeNotOnWhicheverArrivedLast() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let idle = WorkerID()
        _ = try await store.addWorker(id: idle, name: "Reviewer")
        _ = try await store.setWorkerSources(idle, expectedRevision: 0, sources: [.request, .event])
        let idleAddress = try await store.mailAddress(worker: idle)
        let lead = MailAddress(host: host.id, kind: .session, id: UUID())
        let chatter = MailAddress(host: host.id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(lead, name: "Lead"); _ = try await store.registerMailbox(chatter, name: "Chatter")
        _ = try await store.setMailGrant(recipient: idleAddress, sender: lead.description, expectedRevision: 0, mode: .wake,
                                         allowsInterrupt: false, chainTokenBudget: 500)
        _ = try await store.setMailGrant(recipient: idleAddress, sender: chatter.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        // The lead's conversation has already spent past its budget.
        let spent = try await store.sendMail(from: lead, to: idleAddress, id: UUID(), text: "Again", replyTo: nil, priority: .normal)
        try await store.insert("usageChain", spent.envelope.chainID.uuidString.lowercased(), value: UsageChainTotal(tokens: 1_000, executions: 2))
        // Newer notify-only mail, from a sender with no budget, must not wake it in its place.
        _ = try await store.sendMail(from: chatter, to: idleAddress, id: UUID(), text: "fyi", replyTo: nil, priority: .normal)
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
        // And a newer over-budget message must not hide an older in-budget one that may wake.
        _ = try await store.setMailGrant(recipient: idleAddress, sender: chatter.description, expectedRevision: 1, mode: .wake, allowsInterrupt: false)
        _ = try await store.sendMail(from: chatter, to: idleAddress, id: UUID(), text: "please look", replyTo: nil, priority: .normal)
        let newest = try await store.sendMail(from: lead, to: idleAddress, id: UUID(), text: "Again!", replyTo: nil, priority: .normal)
        try await store.insert("usageChain", newest.envelope.chainID.uuidString.lowercased(), value: UsageChainTotal(tokens: 900, executions: 1))
        #expect(try await store.admitMailWakes(after: 0).admitted.count == 1)
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

    // MARK: - Moving a mailbox

    @Test func movingASessionMovesOpenMailOnceAndForwardsLateMailWithoutRelaying() async throws {
        let (d1, d2, mac, vps, macID, vpsID) = try await twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let session = UUID()
        let old = MailAddress(host: macID, kind: .session, id: session)
        let new = MailAddress(host: vpsID, kind: .session, id: session)
        let sibling = MailAddress(host: macID, kind: .session, id: UUID())
        _ = try await mac.registerMailbox(old, name: "Deploy")
        _ = try await mac.registerMailbox(sibling, name: "Review")
        _ = try await vps.registerMailbox(new, name: "Deploy")
        let open = try await mac.sendMail(from: sibling, to: old, id: UUID(), text: "before the move", replyTo: nil, priority: .normal, ownerAdmitted: true)
        let read = try await mac.sendMail(from: sibling, to: old, id: UUID(), text: "already read", replyTo: nil, priority: .normal, ownerAdmitted: true)
        _ = try await mac.acknowledgeMail(mailbox: old, ids: [read.envelope.id])

        // The new store's forward is the owner's consent; without it a forwarded copy is refused.
        #expect(try await mac.moveMail(from: old, to: new) == 1)
        #expect(try await mac.mail(open.envelope.id).state == .moved)
        #expect(try await mac.mail(read.envelope.id).state == .acked, "acknowledged mail stays")
        #expect(try await mac.inbox(old).items.isEmpty)
        #expect(try await mac.moveMail(from: old, to: new) == 0, "a second move finds nothing open")
        let batch = try await mac.outboundBatch(for: vpsID)
        #expect(batch.envelopes.map(\.forwardedFrom) == [old])
        let unexpected = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        #expect(unexpected.results?.first?.outcome == .refused, "no grant and no forward written here")
        _ = try await vps.setMailForward(from: old, to: new, expectedRevision: 0)
        let expected = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        #expect(expected.results?.first?.outcome == .accepted)
        #expect(try await vps.inbox(new).items.map(\.message.envelope.id) == [open.envelope.id])
        // Pushing the same ids again is a duplicate, not a second copy.
        let again = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        #expect(again.results?.map(\.outcome) == [.duplicate])
        try await mac.applyPushResults(again.results ?? [], peer: vpsID)
        #expect(try await mac.mail(open.envelope.id).state == .moved)

        // Mail still addressed to the old address is forwarded once, as the same message.
        let late = try await mac.sendMail(from: sibling, to: old, id: UUID(), text: "after the move", replyTo: nil, priority: .normal, ownerAdmitted: true)
        #expect(late.state == .moved && late.envelope.recipient == new && late.envelope.forwardedFrom == old)

        // Back again: the host forwards to the Mac; the Mac accepts only because it wrote the forward.
        let worker = try await fixture.seed(vps, key: "w")
        let workerAddress = try await vps.mailAddress(worker: worker.workerID)
        _ = try await vps.setMailGrant(recipient: new, sender: workerAddress.description, expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let claim = try #require(await vps.claim(workerID: worker.workerID))
        let fromWorker = try await vps.sendMail(executionID: claim.execution.id, to: new, id: UUID(), text: "from a worker", replyTo: nil, priority: .normal)
        // Moving back: the Mac's own forward for the old address is cleared first.
        try await mac.clearMailForward(old, expectedRevision: try await mac.mailForwardRevision(old))
        #expect(try await vps.moveMail(from: new, to: old) == 2)
        let back = try await vps.outboundBatch(for: macID).envelopes
        #expect(back.contains { $0.id == fromWorker.envelope.id })
        let refused = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: back.filter { $0.id == fromWorker.envelope.id })), peer: vpsID)
        #expect(refused.results?.first?.outcome == .refused, "a worker on the host is not the host's to vouch for without a forward here")
        _ = try await mac.setMailForward(from: new, to: old, expectedRevision: 0)
        let accepted = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: back.filter { $0.id == fromWorker.envelope.id })), peer: vpsID)
        #expect(accepted.results?.first?.outcome == .accepted)
        #expect(try await mac.inbox(old).items.map(\.message.envelope.text).contains("from a worker"))
        // The message that moved away comes home under its own id, replacing the copy left here.
        let home = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: back.filter { $0.id == open.envelope.id })), peer: vpsID)
        #expect(home.results?.first?.outcome == .accepted)
        #expect(try await mac.mail(open.envelope.id).state == .inbox)

        // Never relayed onward: a forwarded copy for an address that is itself forwarded is refused.
        _ = try await mac.setMailForward(from: old, to: new, expectedRevision: try await mac.mailForwardRevision(old))
        let onward = back.first { $0.id == fromWorker.envelope.id }!
        let replay = MailEnvelope(id: UUID(), sender: onward.sender, senderName: onward.senderName, recipient: old, text: "loop",
                                  priority: .normal, replyTo: nil, questionID: nil, chainID: UUID(), depth: 0, sentAt: "now")
        var looped = replay
        looped.forwardedFrom = new
        let relay = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: [looped])), peer: vpsID)
        #expect(relay.results?.first?.outcome == .refused)
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

    @Test func aMovedMailboxAnswersTheQuestionAskedOfItsOldAddress() async throws {
        let (d1, d2, mac, vps, macID, vpsID) = try await twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        // A worker on the VPS asks a Mac session a question.
        let work = try await fixture.seed(vps, key: "asker")
        let claim = try #require(await vps.claim(workerID: work.workerID))
        let session = UUID()
        let oldAddress = MailAddress(host: macID, kind: .session, id: session)
        let newAddress = MailAddress(host: vpsID, kind: .session, id: session)
        _ = try await mac.registerMailbox(oldAddress, name: "Release notes")
        _ = try await mac.setMailGrant(recipient: oldAddress, sender: "\(vpsID)/*", expectedRevision: 0, mode: .ask, allowsInterrupt: false)
        let question = try await vps.askMail(executionID: claim.execution.id, to: oldAddress, questionID: QuestionID(), text: "Ship it?", checkpoint: "Asked")
        let held = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: macID)
        try await mac.acceptPulled(held.messages ?? [], from: vpsID, next: held.next ?? 0)
        // The session's project moves to the VPS before it answers.
        _ = try await vps.registerMailbox(newAddress, name: "Release notes")
        _ = try await vps.setMailForward(from: oldAddress, to: newAddress, expectedRevision: 0)
        #expect(try await mac.moveMail(from: oldAddress, to: newAddress) == 1)
        let batch = try await mac.outboundBatch(for: vpsID)
        let pushed = try await vps.handleMailRPC(MailRPCRequest(push: MailPush(from: macID, messages: batch.envelopes)), peer: macID)
        try await mac.applyPushResults(pushed.results ?? [], peer: vpsID)
        #expect(pushed.results?.map(\.outcome) == [.accepted])
        let moved = try #require(try await vps.inbox(newAddress).items.first)
        #expect(moved.message.envelope.questionID == question.id)
        // Its reply, from the new address, answers the question and resumes the asker.
        let asker = try await vps.mailAddress(worker: work.workerID)
        _ = try await vps.sendMail(from: newAddress, to: asker, id: UUID(), text: "Yes", replyTo: moved.message.envelope.id, priority: .normal)
        #expect(try await vps.question(question.id).answer == "Yes")
        #expect(try await vps.work(work.id).state == .queued)
        // No other mailbox may claim to answer for that address.
        let impostor = MailAddress(host: vpsID, kind: .session, id: UUID())
        _ = try await vps.registerMailbox(impostor, name: "Impostor")
        await #expect(throws: ControllerError.forbidden) {
            try await vps.sendMail(from: impostor, to: asker, id: UUID(), text: "No", replyTo: moved.message.envelope.id, priority: .normal)
        }
    }
}
