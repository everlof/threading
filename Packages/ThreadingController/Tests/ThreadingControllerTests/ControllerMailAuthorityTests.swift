import Foundation
import Testing
@testable import ThreadingController

/// Mail authority and bounds that a review reproduced as escapes: chains that unacknowledged
/// mail left unbounded, a forward that let the old host vouch for anyone, replies and queued
/// wakes that outlived a revocation, re-wakes for mail already seen, a transient write failure
/// turned into a permanent bounce, and outbound mail with no way to stop.
struct ControllerMailAuthorityTests {
    let fixture = ControllerStoreTests()
    let mail = ControllerMailTests()
    let usage = ControllerUsageTests()

    /// An idle worker that mail from anyone may wake, with event admission enabled.
    func wakeable(_ store: ControllerStore, name: String = "Reviewer", budget: Int64? = nil) async throws -> (WorkerID, MailAddress) {
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: name)
        let address = try await store.mailAddress(worker: worker)
        _ = try await store.setMailGrant(recipient: address, sender: "*", expectedRevision: 0, mode: .wake,
                                         allowsInterrupt: false, chainTokenBudget: budget)
        _ = try await store.setWorkerSources(worker, expectedRevision: 0, sources: [.request, .event])
        return (worker, address)
    }

    // MARK: - H3: chains bind what wakes start, acknowledged or not

    @Test func workersWakingEachOtherWithoutAcknowledgingStayInOneBoundedChain() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, aAddress) = try await wakeable(store, name: "A")
        let (b, bAddress) = try await wakeable(store, name: "B")
        _ = try await store.enqueue(workerID: a, key: "seed", instruction: "start")
        var current = a, rounds = 0, depths: [Int] = [], chains = Set<UUID>()
        var refusedAtDepthLimit = false
        for _ in 0..<12 {
            let claim = try #require(await store.claim(workerID: current))
            _ = try await store.inbox(executionID: claim.execution.id, after: 0) // Read, never acknowledged.
            do {
                let sent = try await store.sendMail(executionID: claim.execution.id, to: current == a ? bAddress : aAddress,
                                                    id: UUID(), text: "ping \(rounds)", replyTo: nil, priority: .normal)
                depths.append(sent.envelope.depth); chains.insert(sent.envelope.chainID)
            } catch ControllerError.invalidInput("chain_depth") {
                refusedAtDepthLimit = true
            }
            _ = try await store.finish(executionID: claim.execution.id, destination: "draft", payload: "ok")
            guard let next = try await store.admitMailWakes(after: 0).admitted.first else { break }
            rounds += 1; current = next.workerID
        }
        #expect(depths == Array(0...MailLimits.maximumDepth))
        #expect(chains.count == 1, "every wake continued the chain of the mail that started it")
        #expect(refusedAtDepthLimit)
        #expect(rounds == MailLimits.maximumDepth + 1)
        _ = b
    }

    @Test func aBudgetedChainHoldsWakesWhileSpendInItIsUnsettledAndReceiptsCarryTheWakesChain() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let starter = try await fixture.seed(store, key: "start")
        let starterClaim = try #require(await store.claim(workerID: starter.workerID))
        let (first, firstAddress) = try await wakeable(store, name: "First", budget: 1_000)
        let (second, secondAddress) = try await wakeable(store, name: "Second", budget: 1_000)
        let (third, thirdAddress) = try await wakeable(store, name: "Third", budget: 1_000)
        let opening = try await store.sendMail(executionID: starterClaim.execution.id, to: firstAddress, id: UUID(),
                                               text: "Review", replyTo: nil, priority: .normal)
        #expect(try await store.admitMailWakes(after: 0).admitted.map(\.workerID) == [first])
        let woken = try #require(await store.prepareLaunch(workerID: first, spec: usage.spec()))
        // It never acknowledges; what it sends still continues the chain that woke it.
        let onward = try await store.sendMail(executionID: woken.executionID, to: secondAddress, id: UUID(),
                                              text: "Second opinion?", replyTo: nil, priority: .normal)
        #expect(onward.envelope.chainID == opening.envelope.chainID && onward.envelope.depth == 1)
        // Its spend is not known yet, so the chain's budget cannot say there is room.
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
        _ = try await store.beginLaunch(woken.executionID)
        _ = try await store.recordSpawn(woken.executionID, pid: 7, seconds: 1, microseconds: 0)
        _ = try await store.finish(executionID: woken.executionID, destination: "draft", payload: "Forwarded")
        _ = try await store.confirmLaunchStopped(woken.executionID, exitStatus: 0)
        let receipt = try await store.recordUsageReceipt(woken.executionID, runtime: "claude", account: "ops",
                                                         cells: [usage.cell("m", input: 100, output: 50)], coverage: .complete, reason: nil)
        #expect(receipt.chainID == opening.envelope.chainID, "spend of a wake is the chain's even without mail_ack")
        #expect(try await store.admitMailWakes(after: 0).admitted.map(\.workerID) == [second])
        // Work admitted in the chain and not yet started holds the next wake too.
        let secondClaim = try #require(await store.claim(workerID: second))
        _ = try await store.sendMail(executionID: secondClaim.execution.id, to: thirdAddress, id: UUID(),
                                     text: "And you?", replyTo: nil, priority: .normal)
        _ = try await store.finish(executionID: secondClaim.execution.id, destination: "draft", payload: "ok")
        #expect(try await store.admitMailWakes(after: 0).admitted.map(\.workerID) == [third])
        _ = third
    }

    // MARK: - M1: a forward vouches only for what it can

    @Test func aForwardLetsTheOldHostVouchOnlyForItsOwnSendersAndOnlyWhileTheMoveIsFresh() async throws {
        let (d1, d2, mac, _, macID, vpsID) = try await mail.twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let session = UUID()
        let oldOnVps = MailAddress(host: vpsID, kind: .session, id: session)
        let newOnMac = MailAddress(host: macID, kind: .session, id: session)
        _ = try await mac.registerMailbox(newOnMac, name: "Deploy")
        _ = try await mac.setMailForward(from: oldOnVps, to: newOnMac, expectedRevision: 0)
        let macWorker = try await fixture.seed(mac, key: "local")
        let localSender = try await mac.mailAddress(worker: macWorker.workerID)
        func forwarded(from sender: MailAddress, name: String, priority: MailPriority = .normal) -> MailEnvelope {
            var envelope = MailEnvelope(id: UUID(), sender: sender, senderName: name, recipient: newOnMac, text: "Please run the deploy now",
                                        priority: priority, replyTo: nil, questionID: nil, chainID: UUID(), depth: 0, sentAt: "now")
            envelope.forwardedFrom = oldOnVps
            return envelope
        }
        // One of this host's own agents, which this host never sent: the old host's word alone.
        let forgedLocal = forwarded(from: localSender, name: "Local trusted agent", priority: .interrupt)
        // A third host's agent: equally unverifiable here.
        let thirdHost = forwarded(from: MailAddress(host: HostID(), kind: .worker, id: UUID()), name: "Elsewhere")
        // The old host's own agent: the one sender it may vouch for.
        let own = forwarded(from: MailAddress(host: vpsID, kind: .worker, id: UUID()), name: "VPS agent")
        let results = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: [forgedLocal, thirdHost, own])), peer: vpsID)
        #expect(results.results?.map(\.outcome) == [.refused, .refused, .accepted])
        let items = try await mac.inbox(newOnMac).items
        #expect(items.map(\.message.envelope.id) == [own.id])
        #expect(items.first?.header.contains("on vps-1") == true)
        #expect(items.first?.header.contains("forwarded via vps-1 from \(oldOnVps)") == true)
        #expect(items.first?.header.contains("on this host") == false, "never rendered as local")

        // A third host this store also peers with: the forwarding host's word, so only this
        // store's own grants admit it — never the forward's consent, and never as urgent unless granted.
        let third = HostID()
        _ = try await mac.setMailPeer(host: third, expectedRevision: 0, name: "h3", transport: nil, push: false, pull: false)
        let thirdSender = MailAddress(host: third, kind: .session, id: UUID())
        let ungranted = forwarded(from: thirdSender, name: "Sibling on h3")
        #expect(try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: [ungranted])), peer: vpsID)
            .results?.map(\.outcome) == [.refused])
        _ = try await mac.setMailGrant(recipient: newOnMac, sender: "\(third)/*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let urgent = forwarded(from: thirdSender, name: "Sibling on h3", priority: .interrupt)
        let granted = forwarded(from: thirdSender, name: "Sibling on h3")
        #expect(try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: [urgent, granted])), peer: vpsID)
            .results?.map(\.outcome) == [.refused, .accepted])
        let viaThird = try #require(try await mac.inbox(newOnMac).items.last)
        #expect(viaThird.message.envelope.id == granted.id && viaThird.header.contains("on h3") && viaThird.header.contains("forwarded via vps-1"))

        // The consent lapses: a move is complete long before `acceptsUntil`.
        let forward = try #require(try await mac.mailForward(oldOnVps))
        #expect(forward.acceptsUntil != nil)
        var lapsed = forward
        lapsed.acceptsUntil = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        try await mac.update("mailForward", oldOnVps.description, state: "active", value: lapsed)
        let late = forwarded(from: MailAddress(host: vpsID, kind: .worker, id: UUID()), name: "VPS agent")
        let refused = try await mac.handleMailRPC(MailRPCRequest(push: MailPush(from: vpsID, messages: [late])), peer: vpsID)
        #expect(refused.results?.map(\.outcome) == [.refused])
    }

    // MARK: - M2: a revocation stands against replies

    @Test func aRevokedSenderCannotReplyAndTheQuestionItOwedIsAnsweredWithTheRevocation() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, aAddress, bAddress) = try await mail.pair(store)
        _ = try await store.setMailGrant(recipient: bAddress, sender: aAddress.description, expectedRevision: 0, mode: .ask, allowsInterrupt: false)
        let question = try await store.askMail(executionID: a.execution.id, to: bAddress, questionID: QuestionID(),
                                               text: "Which region?", checkpoint: "c")
        let asked = try #require(try await store.inbox(bAddress).items.first)
        #expect(try await store.work(a.work.id).state == .waiting)
        // A's owner revokes B on A's mailbox: the reply can never arrive, so the work continues.
        _ = try await store.setMailGrant(recipient: aAddress, sender: bAddress.description, expectedRevision: 0, mode: nil, allowsInterrupt: false)
        let answered = try await store.question(question.id)
        #expect(answered.answer?.hasPrefix("Undeliverable") == true && answered.answeredBy?.hasPrefix("host:") == true)
        #expect(try await store.work(a.work.id).state == .queued)
        await #expect(throws: ControllerError.forbidden) {
            try await store.sendMail(executionID: b.execution.id, to: aAddress, id: UUID(), text: "eu-north-1",
                                     replyTo: asked.message.envelope.id, priority: .normal)
        }
        #expect(try await store.question(question.id).answer == answered.answer, "the revoked sender's words never become the answer")
    }

    // MARK: - M4: a queued wake is admitted again when it starts

    @Test func aWakeQueuedBeforeARevocationIsWithdrawnWhenClaimed() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = try await fixture.seed(store, key: "a")
        let claim = try #require(await store.claim(workerID: sender.workerID))
        let (idle, idleAddress) = try await wakeable(store)
        _ = try await store.sendMail(executionID: claim.execution.id, to: idleAddress, id: UUID(), text: "Do X", replyTo: nil, priority: .normal)
        let admitted = try #require(try await store.admitMailWakes(after: 0).admitted.first)
        _ = try await store.setMailGrant(recipient: idleAddress, sender: "*", expectedRevision: 1, mode: nil, allowsInterrupt: false)
        #expect(try await store.claim(workerID: idle) == nil)
        #expect(try await store.prepareLaunch(workerID: idle, spec: usage.spec()) == nil)
        #expect(try await store.work(admitted.id).state == .cancelled)
        #expect(try await store.inbox(idleAddress).items.count == 1, "the mail is still delivered; it just starts nothing")
        // Ordinary queued work behind it still runs.
        let other = try await store.enqueue(workerID: idle, key: "request", instruction: "Unrelated")
        #expect(try await store.claim(workerID: idle)?.work.id == other.id)
    }

    // MARK: - M8: mail a wake already saw does not wake again

    @Test func acknowledgingOnlyTheNewestDoesNotRewakeForOlderMailButNewMailDoes() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = try await fixture.seed(store, key: "a")
        let claim = try #require(await store.claim(workerID: sender.workerID))
        let (idle, idleAddress) = try await wakeable(store)
        for index in 0..<5 {
            _ = try await store.sendMail(executionID: claim.execution.id, to: idleAddress, id: UUID(), text: "m\(index)", replyTo: nil, priority: .normal)
        }
        func runWakes() async throws -> Int {
            var wakes = 0
            for _ in 0..<10 {
                guard !(try await store.admitMailWakes(after: 0).admitted.isEmpty) else { break }
                wakes += 1
                let woken = try #require(await store.claim(workerID: idle))
                let items = try await store.inbox(executionID: woken.execution.id, after: 0).items
                if let newest = items.last { _ = try await store.acknowledgeMail(executionID: woken.execution.id, ids: [newest.message.envelope.id]) }
                _ = try await store.finish(executionID: woken.execution.id, destination: "draft", payload: "done")
            }
            return wakes
        }
        #expect(try await runWakes() == 1)
        #expect(try await store.inbox(idleAddress).items.count == 4, "older mail stays open, unwoken")
        _ = try await store.sendMail(executionID: claim.execution.id, to: idleAddress, id: UUID(), text: "new", replyTo: nil, priority: .normal)
        #expect(try await runWakes() == 1)
    }

    // MARK: - M7: a pull that could not be stored is pulled again, never bounced

    @Test func aPulledPageThisStoreCouldNotWriteIsPulledAgainNotBounced() async throws {
        let (d1, d2, mac, vps, macID, vpsID) = try await mail.twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let macWorker = try await fixture.seed(mac, key: "a")
        let macAddress = try await mac.mailAddress(worker: macWorker.workerID)
        _ = try await mac.setMailGrant(recipient: macAddress, sender: "\(vpsID)/*", expectedRevision: 0, mode: .ask, allowsInterrupt: false)
        let asker = try await fixture.seed(vps, key: "b")
        let askerClaim = try #require(await vps.claim(workerID: asker.workerID))
        let first = try await vps.sendMail(executionID: askerClaim.execution.id, to: macAddress, id: UUID(), text: "Report ready",
                                           replyTo: nil, priority: .normal)
        // A second, unrelated execution asks: its question must not be answered "Undeliverable".
        let other = try await fixture.seed(vps, worker: WorkerID(), key: "c")
        let otherClaim = try #require(await vps.claim(workerID: other.workerID))
        let question = try await vps.askMail(executionID: otherClaim.execution.id, to: macAddress, questionID: QuestionID(),
                                             text: "Approve the failing write?", checkpoint: "Asked")
        // The Mac's store fails to write the question (a full disk, say).
        let path = d1.appendingPathComponent("controller.db").path
        let injector = try ControllerDatabase(path: path)
        try injector.run("""
            CREATE TRIGGER fail_mail BEFORE INSERT ON record WHEN NEW.kind='mail' AND instr(NEW.payload,'failing write')>0
            BEGIN SELECT RAISE(ABORT,'injected'); END
            """)
        let page = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: macID)
        #expect(page.messages?.count == 2)
        #expect(try await mac.acceptPulled(page.messages ?? [], from: vpsID, next: page.next ?? 0) == false)
        let stalled = try #require(try await mac.mailPeer(vpsID))
        #expect(stalled.pullCursor == 0 && stalled.pendingRefusals == nil, "nothing past the failure is acknowledged")
        #expect(try await mac.inbox(macAddress).items.map(\.message.envelope.id) == [first.envelope.id])
        // The next pull acknowledges nothing and offers the page again; once the store recovers it lands.
        let again = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: stalled.pullCursor, refused: nil)), peer: macID)
        #expect(again.messages?.count == 2)
        try injector.run("DROP TRIGGER fail_mail")
        #expect(try await mac.acceptPulled(again.messages ?? [], from: vpsID, next: again.next ?? 0))
        let caughtUp = try #require(try await mac.mailPeer(vpsID))
        _ = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: caughtUp.pullCursor, refused: caughtUp.pendingRefusals)), peer: macID)
        #expect(try await vps.mail(question.id.rawValue).state == .forwarded)
        #expect(try await vps.question(question.id).answer == nil)
        #expect(try await mac.inbox(macAddress).items.count == 2)
    }

    @Test func anUnavailableRefusalFromAnOlderPullerRequeuesTheMessage() async throws {
        let (d1, d2, mac, vps, macID, _) = try await mail.twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let macWorker = try await fixture.seed(mac, key: "a")
        let macAddress = try await mac.mailAddress(worker: macWorker.workerID)
        let sender = try await fixture.seed(vps, key: "b")
        let claim = try #require(await vps.claim(workerID: sender.workerID))
        let held = try await vps.sendMail(executionID: claim.execution.id, to: macAddress, id: UUID(), text: "Hello", replyTo: nil, priority: .normal)
        let page = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: macID)
        let next = try await vps.handleMailRPC(MailRPCRequest(pull: MailPull(after: page.next ?? 0, refused: [
            MailRefusal(id: held.envelope.id, reason: MailRefusalReason.unavailable)
        ])), peer: macID)
        #expect(next.messages?.map(\.id) == [held.envelope.id])
        #expect(try await vps.mail(held.envelope.id).state == .outbound)
    }

    // MARK: - Mailbox credentials

    @Test func rotatingAMailboxCredentialRevokesTheOldOne() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host()
        let session = MailAddress(host: host.id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(session, name: "Console")
        // Only a digest is stored, so the owner's launch-time read issues a fresh credential and
        // every issue revokes the one before it.
        let old = try await store.mailboxCredential(session)
        let new = try await store.rotateMailboxCredential(session)
        #expect(new != old)
        await #expect(throws: ControllerError.forbidden) {
            try await store.mailboxRequest(address: session, credential: old, request: .mailInbox(after: 0))
        }
        #expect(try await store.mailboxRequest(address: session, credential: new, request: .mailInbox(after: 0)).inbox?.items.isEmpty == true)
        let issued = try await store.mailboxCredential(session)
        #expect(issued != new)
        await #expect(throws: ControllerError.forbidden) {
            try await store.mailboxRequest(address: session, credential: new, request: .mailInbox(after: 0))
        }
        await #expect(throws: ControllerError.notFound) {
            try await store.rotateMailboxCredential(MailAddress(host: host.id, kind: .session, id: UUID()))
        }
    }

    // MARK: - Outbound mail to a peer that never comes back

    @Test func outboundMailCanBeCancelledOrExpiresAndBouncesToItsSender() async throws {
        let (d1, d2, mac, vps, _, vpsID) = try await mail.twoHosts()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let target = try await vps.mailAddress(worker: try await fixture.seed(vps, key: "t").workerID)
        let asking = try await fixture.seed(mac, key: "a")
        let askingClaim = try #require(await mac.claim(workerID: asking.workerID))
        let question = try await mac.askMail(executionID: askingClaim.execution.id, to: target, questionID: QuestionID(),
                                             text: "Approve?", checkpoint: "Waiting")
        let telling = try await fixture.seed(mac, worker: WorkerID(), key: "b")
        let tellingClaim = try #require(await mac.claim(workerID: telling.workerID))
        let note = try await mac.sendMail(executionID: tellingClaim.execution.id, to: target, id: UUID(), text: "FYI",
                                          replyTo: nil, priority: .normal)
        #expect(try await mac.expireOutboundMail().isEmpty, "nothing is old yet")

        // The owner cancels the note: it bounces and leaves the queue.
        let cancelled = try await mac.cancelOutboundMail(note.envelope.id)
        #expect(cancelled.state == .bounced && cancelled.bounce == MailRefusalReason.cancelled)
        await #expect(throws: ControllerError.conflict) { try await mac.cancelOutboundMail(note.envelope.id) }
        #expect(try await mac.outboundBatch(for: vpsID).envelopes.map(\.id) == [question.id.rawValue])

        // The question outlives the peer: it expires, bounces, and the asking work continues.
        let later = Date().addingTimeInterval(MailLimits.outboundLifetime + 60)
        #expect(try await mac.expireOutboundMail(now: later) == [question.id.rawValue])
        let expired = try await mac.mail(question.id.rawValue)
        #expect(expired.state == .bounced && expired.bounce == MailRefusalReason.expired)
        #expect(try await mac.question(question.id).answer?.hasPrefix("Undeliverable: this host stopped trying") == true)
        #expect(try await mac.work(asking.id).state == .queued)
        #expect(try await mac.outboundBatch(for: vpsID).envelopes.isEmpty)
        #expect(try await mac.recentSentMail(try await mac.mailAddress(worker: telling.workerID)).first?.state == .bounced)
    }
}
