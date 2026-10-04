import Foundation
import Testing
@testable import ThreadingController

/// Admission bounds, dependency ordering, archive fencing, memory lifecycle and retention.
@Suite(.serialized) struct ControllerSchedulingMemoryTests {
    let fixture = ControllerStoreTests()

    /// An approved, enabled source with `triggers` enabled rules that all admit for `worker`.
    func source(_ store: ControllerStore, directory: URL, worker: WorkerID, triggers: Int) async throws -> (ControllerSource, [TriggerRuleID]) {
        let probe = directory.appendingPathComponent("probe.sh")
        try "#!/bin/sh\necho ok\n".write(to: probe, atomically: true, encoding: .utf8)
        let id = SourceID()
        let configured = try await store.configureSource(id, expectedRevision: 0, spec: ControllerSourceSpec(name: "Burst", executable: probe.path, intervalSeconds: 60, limit: ProbeLimits.maximumEvents))
        let approved = try await store.approveSource(id, expectedRevision: configured.revision, hash: configured.hash)
        let enabled = try await store.setSourceEnabled(id, expectedRevision: approved.revision, enabled: true)
        var ids: [TriggerRuleID] = []
        for index in 0..<triggers {
            let trigger = TriggerRuleID()
            let paused = try await store.configureTrigger(trigger, expectedRevision: 0, spec: ControllerTriggerSpec(
                name: "Rule \(index)", sourceID: id, workerID: worker, match: [TriggerClause(field: "kind", op: .equals, value: "ticket")],
                instruction: "Handle the ticket."))
            _ = try await store.setTriggerEnabled(trigger, expectedRevision: paused.revision, enabled: true)
            ids.append(trigger)
        }
        return (enabled, ids)
    }
    func event(_ id: Int, evidence: String = "body") throws -> ProbeEvent {
        try JSONDecoder().decode(ProbeEvent.self, from: Data(#"{"id":"e\#(id)","fields":{"kind":"ticket"},"evidence":"\#(evidence)"}"#.utf8))
    }

    // MARK: - Trigger admission

    @Test func aBurstCommitsInBoundedChunksAndStopsAtEachTriggersBacklog() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Support")
        let triggerCount = 20, eventCount = 500
        let (source, triggers) = try await source(store, directory: directory, worker: worker, triggers: triggerCount)
        let run = ProbeRun(outcome: .healthy, events: try (0..<eventCount).map { try event($0) }, cursor: "end", diagnostics: "")
        // A probe re-reports from its unmoved cursor until a poll takes everything.
        var stored: [SourceEvent] = []
        var polls = 0
        var longest: UInt64 = 0
        var commits = 0
        _ = await store.takeTransactionStatistics()
        while try await store.source(source.id).cursor != "end" {
            polls += 1
            #expect(polls <= 20, "admission made no progress")
            if polls > 20 { break }
            let recorded = try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash, run: run)
            let admitted = recorded.flatMap(\.receipts).filter { $0.admission == .queued }.count
            #expect(admitted <= TriggerAdmissionLimits.admissionsPerPoll)
            stored += recorded
            let statistics = await store.takeTransactionStatistics()
            longest = max(longest, statistics.longestNanoseconds)
            commits += statistics.commits
        }
        #expect(stored.count == eventCount)
        let receipts = stored.flatMap(\.receipts)
        #expect(receipts.count == eventCount * triggerCount)
        let queued = receipts.filter { $0.admission == .queued }
        #expect(queued.count == triggerCount * TriggerAdmissionLimits.backlogPerTrigger)
        for trigger in triggers {
            #expect(queued.filter { $0.triggerID == trigger }.count == TriggerAdmissionLimits.backlogPerTrigger)
        }
        let refused = receipts.filter { $0.admission == .refused }
        #expect(refused.count == receipts.count - queued.count)
        #expect(refused.allSatisfy { $0.reason == TriggerAdmissionLimits.backlogReason })
        // Bounded transactions: chunks, not one lock held for the whole burst. The pre-fix
        // single transaction measured 4-7 s for this shape.
        #expect(commits >= eventCount / TriggerAdmissionLimits.eventsPerCommit)
        let longestSeconds = Double(longest) / 1_000_000_000
        #expect(longestSeconds < 1.0, "longest write transaction \(longestSeconds) s")
        // A deferral polls again soon rather than after a full interval.
        let health = try await store.source(source.id).health
        #expect(health.state == .healthy)

        // Claiming frees backlog: a later event is admitted again.
        _ = try #require(await store.claim(workerID: worker))
        let later = ProbeRun(outcome: .healthy, events: [try event(eventCount)], cursor: "later", diagnostics: "")
        let next = try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash, run: later)
        #expect(next.first?.receipts.filter { $0.admission == .queued }.count == 1)
    }

    @Test func archivingAWorkerPausesItsTriggersAndMailWake() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Retired")
        let (source, triggers) = try await source(store, directory: directory, worker: worker, triggers: 2)
        let sender = try await fixture.seed(store, key: "sender")
        let senderClaim = try #require(await store.claim(workerID: sender.workerID))
        let address = try await store.mailAddress(worker: worker)
        _ = try await store.setMailGrant(recipient: address, sender: "*", expectedRevision: 0, mode: .wake, allowsInterrupt: false)
        _ = try await store.sendMail(executionID: senderClaim.execution.id, to: address, id: UUID(), text: "Wake up", replyTo: nil, priority: .normal)

        let before = try await store.trigger(triggers[0])
        _ = try await store.archiveWorker(worker)
        for id in triggers {
            let trigger = try await store.trigger(id)
            #expect(!trigger.enabled && !trigger.deleted && trigger.revision == before.revision + 1)
        }
        let recorded = try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash,
                                                  run: ProbeRun(outcome: .healthy, events: [try event(1)], cursor: "c", diagnostics: ""))
        #expect(recorded.first?.receipts.isEmpty == true)
        #expect(try await store.works(workerID: worker).items.isEmpty)
        #expect(try await store.inbox(address).items.count == 1)   // still readable
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
        #expect(try await store.mailWakeCandidate(address) == nil)
        // Re-enabling a trigger for an archived worker stays refused at admission.
        let paused = try await store.trigger(triggers[0])
        _ = try await store.setTriggerEnabled(triggers[0], expectedRevision: paused.revision, enabled: true)
        let refused = try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash,
                                                 run: ProbeRun(outcome: .healthy, events: [try event(2)], cursor: "d", diagnostics: ""))
        #expect(refused.first?.receipts.map(\.admission) == [.refused])
    }

    // MARK: - Automation admission

    @Test func aScheduledOccurrenceThatCannotBeAdmittedIsRecordedRefusedNotMissed() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Reports")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)), now: now)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: now)
        // The owner later restricts the worker to requests: scheduled admission is forbidden.
        _ = try await store.setWorkerSources(worker, expectedRevision: 0, sources: [.request])
        let due = now.addingTimeInterval(60)
        let first = try await store.tickAutomations(now: due)
        #expect(first.map(\.admission) == ["refused"])
        #expect(first.first?.reason == "forbidden" && first.first?.workID == nil && first.first?.scheduledAt == due)
        // The rule moved on to its next occurrence instead of retrying this one late.
        #expect(try await store.automation(id).nextRunAt == now.addingTimeInterval(120))
        _ = try await store.tickAutomations(now: now.addingTimeInterval(120))
        _ = try await store.tickAutomations(now: now.addingTimeInterval(60 + ControllerStore.failedAdmissionRetry + 1))
        let runs = try await store.automationRuns(id).items.map(\.run)
        let original = runs.filter { $0.scheduledAt == due }
        #expect(original.map(\.admission) == ["refused"])
        #expect(!runs.contains { $0.admission == "missed" && $0.scheduledAt <= now.addingTimeInterval(120) })
        #expect(try await store.works(workerID: worker).items.isEmpty)
    }

    // MARK: - Dependencies

    @Test func dependenciesOrderClaimsAndACancelledDependencyCascades() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await fixture.seed(store, key: "a")
        let worker = a.workerID
        let b = try await store.enqueue(workerID: worker, key: "b", instruction: "After a", after: [a.id])
        let c = try await store.enqueue(workerID: worker, key: "c", instruction: "Independent")
        #expect(b.dependsOn == [a.id])
        #expect(try await store.enqueue(workerID: worker, key: "b", instruction: "After a", after: [a.id]) == b)
        await #expect(throws: ControllerError.conflict) { try await store.enqueue(workerID: worker, key: "b", instruction: "After a") }
        await #expect(throws: ControllerError.notFound) { try await store.enqueue(workerID: worker, key: "x", instruction: "Unknown", after: [WorkID()]) }

        let first = try #require(await store.claim(workerID: worker))
        #expect(first.work.id == a.id)
        let second = try #require(await store.claim(workerID: worker))
        #expect(second.work.id == c.id)   // b waits for a
        #expect(try await store.claim(workerID: worker) == nil)
        _ = try await store.finish(executionID: first.execution.id, destination: "draft", payload: "A done")
        let third = try #require(await store.claim(workerID: worker))
        #expect(third.work.id == b.id)

        // A cancelled dependency cancels its queued dependents, transitively, with a reason.
        let d = try await store.enqueue(workerID: worker, key: "d", instruction: "Root")
        let e = try await store.enqueue(workerID: worker, key: "e", instruction: "After d", after: [d.id])
        let f = try await store.enqueue(workerID: worker, key: "f", instruction: "After e", after: [e.id])
        let g = try await store.enqueue(workerID: worker, key: "g", instruction: "After d and a", after: [d.id, a.id])
        _ = try await store.cancel(workID: d.id)
        let cancelledE = try await store.work(e.id), cancelledF = try await store.work(f.id), cancelledG = try await store.work(g.id)
        #expect(cancelledE.state == .cancelled && cancelledE.cancelReason == "dependency_cancelled: \(d.id)")
        #expect(cancelledF.state == .cancelled && cancelledF.cancelReason == "dependency_cancelled: \(e.id)")
        #expect(cancelledG.state == .cancelled && cancelledG.cancelReason == "dependency_cancelled: \(d.id)")
        #expect(try await store.activities(workID: f.id).items.last?.text == "dependency_cancelled: \(e.id)")
        await #expect(throws: ControllerError.invalidInput("dependency_cancelled")) {
            try await store.enqueue(workerID: worker, key: "h", instruction: "After d", after: [d.id])
        }
        await #expect(throws: ControllerError.invalidInput("dependencies")) {
            try await store.enqueue(workerID: worker, key: "i", instruction: "Duplicate", after: [a.id, a.id])
        }
    }

    // MARK: - Memory

    func agent(_ store: ControllerStore, worker: WorkerID) async throws -> (ExecutionID, String) {
        _ = try await store.enqueue(workerID: worker, key: "memory:\(UUID())", instruction: "Remember things")
        let spec = ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: [], environment: [:],
                                        directory: "/tmp", recipients: ["person:owner"], destination: "draft")
        let launch = try #require(await store.prepareLaunch(workerID: worker, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        return (launch.executionID, try await store.launchCredential(launch.executionID))
    }

    @Test func memoryDeleteIsATombstoneAndForgetErasesEveryBody() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Notes")
        let (execution, credential) = try await agent(store, worker: worker)
        func request(_ value: ControllerAgentRequest) async throws -> ControllerAgentResponse {
            try await store.agentRequest(executionID: execution, credential: credential, request: value)
        }
        let first = try #require(try await request(.memoryPut(key: "note", expectedRevision: 0, content: "SECRET-NOTE-ONE")).memory)
        #expect(first.provenance?.actor == .agent && first.provenance?.executionID == execution && first.state == .active)
        _ = try await request(.memoryPut(key: "note", expectedRevision: 1, content: "SECRET-NOTE-TWO"))
        let owner = try await store.putMemory(workerID: worker, key: "kept", expectedRevision: 0, content: "Owner fact")
        #expect(owner.provenance?.actor == .owner && owner.provenance?.executionID == nil)

        await #expect(throws: ControllerError.conflict) { try await request(.memoryDelete(key: "note", expectedRevision: 1)) }
        let tombstone = try #require(try await request(.memoryDelete(key: "note", expectedRevision: 2)).memory)
        #expect(tombstone.state == .deleted && tombstone.content.isEmpty && tombstone.revision == 3)
        #expect(try await request(.memoryDelete(key: "note", expectedRevision: 3)).memory == tombstone)
        #expect(try await store.memoryKeys(workerID: worker).items.map(\.key) == ["kept"])
        #expect(try await store.memory(workerID: worker, key: "note") == tombstone)
        // A delayed write at zero cannot recreate the entry; only the tombstone's revision can.
        await #expect(throws: ControllerError.conflict) { try await request(.memoryPut(key: "note", expectedRevision: 0, content: "Stale")) }
        let deletedHistory = try await store.memoryHistory(workerID: worker, key: "note").items
        #expect(deletedHistory.map(\.content) == ["SECRET-NOTE-ONE", "SECRET-NOTE-TWO", ""])
        #expect(deletedHistory.compactMap(\.provenance?.actor) == [.agent, .agent, .agent])

        let forgotten = try await store.forgetMemory(workerID: worker, key: "note")
        #expect(forgotten.state == .forgotten && forgotten.revision == 4 && forgotten.provenance?.actor == .owner)
        let history = try await store.memoryHistory(workerID: worker, key: "note").items
        #expect(history.count == 4 && history.allSatisfy { $0.content.isEmpty && $0.state == .forgotten })
        #expect(history.map(\.revision) == [1, 2, 3, 4])
        #expect(try await store.forgetMemory(workerID: worker, key: "note") == forgotten)
        // Gone from the live database files too, not only from the API's projection.
        for suffix in ["", "-wal"] {
            let path = directory.appendingPathComponent("controller.db" + suffix).path
            guard let bytes = FileManager.default.contents(atPath: path) else { continue }
            #expect(bytes.range(of: Data("SECRET-NOTE".utf8)) == nil, "body survives in controller.db\(suffix)")
        }
        // Relearning is a new authorized write at the tombstone's revision.
        let relearned = try await store.putMemory(workerID: worker, key: "note", expectedRevision: 4, content: "New fact")
        #expect(relearned.state == .active && relearned.revision == 5)
    }

    @Test func memoryQuotasBoundKeysAndBytesButNeverShrinkingWrites() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Quota")
        let body = String(repeating: "x", count: 32_768)
        let fullBodies = ContentQuota.memoryBytesPerWorker / body.utf8.count
        for index in 0..<fullBodies {
            _ = try await store.putMemory(workerID: worker, key: "big\(index)", expectedRevision: 0, content: body)
        }
        await #expect(throws: ControllerError.invalidInput("memory_byte_quota")) {
            try await store.putMemory(workerID: worker, key: "overflow", expectedRevision: 0, content: "y")
        }
        // Shrinking an entry is always accepted and frees room.
        _ = try await store.putMemory(workerID: worker, key: "big0", expectedRevision: 1, content: "small")
        _ = try await store.putMemory(workerID: worker, key: "overflow", expectedRevision: 0, content: "y")
        // Deleting frees bytes and a key.
        _ = try await store.deleteMemory(workerID: worker, key: "big1", expectedRevision: 1)
        _ = try await store.putMemory(workerID: worker, key: "fits", expectedRevision: 0, content: String(repeating: "z", count: 30_000))

        let other = WorkerID()
        _ = try await store.addWorker(id: other, name: "Keys")
        for index in 0..<ContentQuota.memoryKeysPerWorker {
            _ = try await store.putMemory(workerID: other, key: "k\(index)", expectedRevision: 0, content: "v")
        }
        await #expect(throws: ControllerError.invalidInput("memory_key_quota")) {
            try await store.putMemory(workerID: other, key: "one-more", expectedRevision: 0, content: "v")
        }
        _ = try await store.putMemory(workerID: other, key: "k0", expectedRevision: 1, content: "updated")   // no new key
        _ = try await store.forgetMemory(workerID: other, key: "k1")
        _ = try await store.putMemory(workerID: other, key: "one-more", expectedRevision: 0, content: "v")
    }

    @Test func knowledgeRevisionsCarryProvenanceAndForgetErasesHistory() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Shared")
        let space = KnowledgeSpaceID()
        _ = try await store.grantKnowledge(spaceID: space, workerID: worker, expectedRevision: 0, access: .write)
        let owned = try await store.putKnowledge(spaceID: space, key: "runbook", expectedRevision: 0, content: "PRIVATE-RUNBOOK")
        #expect(owned.provenance?.actor == .owner)
        let (execution, credential) = try await agent(store, worker: worker)
        let edited = try #require(try await store.agentRequest(executionID: execution, credential: credential,
            request: .knowledgePut(spaceID: space, key: "runbook", expectedRevision: 1, content: "PRIVATE-RUNBOOK v2")).knowledge)
        #expect(edited.provenance?.actor == .agent && edited.provenance?.executionID == execution)
        let forgotten = try await store.forgetKnowledge(spaceID: space, key: "runbook")
        #expect(forgotten.state == .forgotten && forgotten.content.isEmpty)
        let history = try await store.knowledgeHistory(spaceID: space, key: "runbook").items
        #expect(history.count == 3 && history.allSatisfy { $0.content.isEmpty })
    }

    // MARK: - Retention

    @Test func pruneRemovesFinishedHistoryAndKeepsUnresolvedStateAndDedupe() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = try await fixture.seed(store, key: "finished")
        let worker = finished.workerID
        let claim = try #require(await store.claim(workerID: worker))
        _ = try await store.checkpoint(executionID: claim.execution.id, text: "Halfway")
        _ = try await store.finish(executionID: claim.execution.id, destination: "draft", payload: "Done")
        let open = try await store.enqueue(workerID: worker, key: "open", instruction: "Still to do")
        let (source, _) = try await source(store, directory: directory, worker: worker, triggers: 1)
        let run = ProbeRun(outcome: .healthy, events: [try event(1, evidence: "PRIVATE-EVIDENCE")], cursor: "c1", diagnostics: "")
        _ = try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash, run: run)
        #expect(try await store.events().items.count > 0)

        await #expect(throws: ControllerError.invalidInput("prune_too_recent")) { try await store.prune(before: Date()) }
        let now = Date().addingTimeInterval(3 * 86_400)
        let result = try await store.prune(before: Date().addingTimeInterval(86_400), now: now)
        #expect(!result.more && result.events > 0 && result.activities > 0 && result.sourceEvents == 1)
        #expect(try await store.events().items.map(\.kind) == ["controller.pruned"])
        #expect(try await store.activities(workID: finished.id).items.isEmpty)
        #expect(!(try await store.activities(workID: open.id).items.isEmpty))
        #expect(try await store.work(finished.id).state == .completed)
        #expect(try await store.workDeliveries(workID: finished.id).items.count == 1)
        let compacted = try await store.sourceEvents(source.id).items
        #expect(compacted.count == 1 && compacted[0].event.evidence == nil && compacted[0].event.fields.isEmpty)
        #expect(compacted[0].receipts.map(\.admission) == [.queued])
        // The dedupe key survived: redelivery admits nothing twice.
        #expect(try await store.recordPoll(source.id, revision: source.revision, observedHash: source.hash, run: run).isEmpty)
        #expect(try await store.works(workerID: worker).items.count == 3)
        // Repeating finds nothing more.
        let again = try await store.prune(before: Date().addingTimeInterval(86_400), now: now)
        #expect(again.activities == 0 && again.sourceEvents == 0 && !again.more)
    }
}
