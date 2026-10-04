import Foundation
import Testing
import ThreadingUsage
@testable import ThreadingController

struct ControllerUsageTests {
    let fixture = ControllerStoreTests()

    func spec(usage: ControllerUsageSource? = ControllerUsageSource(runtime: .claude, home: "/tmp/claude-home", account: "ops")) -> ControllerLaunchSpec {
        ControllerLaunchSpec(socketPath: "/tmp/fixture.sock", executable: "/bin/true", arguments: [], environment: [:],
                             directory: "/tmp", recipients: ["person:owner"], destination: "draft", usage: usage)
    }
    func cell(_ model: String, input: Int64, output: Int64, cached: Int64 = 0, cost: Double = 0.5) -> UsageCell {
        UsageCell(model: model, tokens: UsageTokenCounts(uncachedInput: input, cachedInput: cached, output: output), requests: 1, costUSD: cost)
    }
    /// Claim, prepare, dispatch and confirm a stop, as the runtime does around a real process.
    func stoppedLaunch(_ store: ControllerStore, worker: WorkerID, spec: ControllerLaunchSpec) async throws -> ControllerLaunch {
        let launch = try #require(await store.prepareLaunch(workerID: worker, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        _ = try await store.recordSpawn(launch.executionID, pid: 42, seconds: 1, microseconds: 0)
        return try await store.confirmLaunchStopped(launch.executionID, exitStatus: 0)
    }

    @Test func aConfirmedStopOwesOneReceiptAndDailyCellsAddUp() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let launch = try await stoppedLaunch(store, worker: work.workerID, spec: spec())
        #expect(try await store.pendingUsage() == [launch.executionID])
        let receipt = try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "ops",
            cells: [cell("claude-a", input: 100, output: 50, cached: 1_000), cell("claude-b", input: 10, output: 5)], coverage: .complete, reason: nil)
        #expect(receipt.workerID == work.workerID && receipt.workID == work.id && receipt.budgetTokens == 165)
        #expect(try await store.pendingUsage().isEmpty)
        // Recording again returns the first receipt and adds nothing.
        let again = try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "ops", cells: [cell("claude-a", input: 9_999, output: 9_999)], coverage: .complete, reason: nil)
        #expect(again == receipt)
        let day = String(receipt.endedAt.prefix(10))
        let summary = try await store.usageSummary(from: day, through: day).items
        #expect(summary.count == 2)
        #expect(summary.first(where: { $0.model == "claude-a" })?.cachedInput == 1_000)
        #expect(summary.reduce(0) { $0 + $1.executions } == 1)
        #expect(try await store.usageReceipts(worker: work.workerID).items == [receipt])
        // A recipe that names no transcript owes nothing.
        let other = try await fixture.seed(store, worker: WorkerID(), key: "x")
        _ = try await stoppedLaunch(store, worker: other.workerID, spec: spec(usage: nil))
        #expect(try await store.pendingUsage().isEmpty)
    }

    @Test func aWorkerOverItsDailyBudgetStartsNothingNew() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = try await store.enqueue(workerID: work.workerID, key: "second", instruction: "More")
        let policy = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 2, spec: spec())
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 0, tokensPerDay: 100)
        let first = try #require(await store.prepareSupervisedLaunch(work.workerID))
        _ = try await store.beginLaunch(first.executionID)
        _ = try await store.recordSpawn(first.executionID, pid: 42, seconds: 1, microseconds: 0)
        _ = try await store.confirmLaunchStopped(first.executionID, exitStatus: 0)
        _ = try await store.recordUsageReceipt(first.executionID, runtime: "claude", account: "ops",
                                               cells: [cell("m", input: 80, output: 30)], coverage: .complete, reason: nil)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 1, tokensPerDay: nil)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) != nil)
    }

    @Test func aChainPastItsGrantBudgetStillDeliversButNoLongerWakes() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = try await fixture.seed(store, key: "a")
        let senderClaim = try #require(await store.claim(workerID: sender.workerID))
        let idle = WorkerID()
        _ = try await store.addWorker(id: idle, name: "Reviewer")
        let idleAddress = try await store.mailAddress(worker: idle)
        _ = try await store.setMailGrant(recipient: idleAddress, sender: "*", expectedRevision: 0, mode: .wake, allowsInterrupt: false, chainTokenBudget: 500)
        // The recipient wakes, acts on the mail and spends past the chain's budget.
        let first = try await store.sendMail(executionID: senderClaim.execution.id, to: idleAddress, id: UUID(), text: "Review", replyTo: nil, priority: .normal)
        #expect(try await store.admitMailWakes(after: 0).admitted.count == 1)
        let woken = try #require(await store.prepareLaunch(workerID: idle, spec: spec()))
        _ = try await store.acknowledgeMail(executionID: woken.executionID, ids: [first.envelope.id])
        let answer = try await store.sendMail(executionID: woken.executionID, to: try await store.mailAddress(worker: sender.workerID),
                                              id: UUID(), text: "Looks good", replyTo: first.envelope.id, priority: .normal)
        _ = try await store.beginLaunch(woken.executionID)
        _ = try await store.recordSpawn(woken.executionID, pid: 7, seconds: 1, microseconds: 0)
        _ = try await store.finish(executionID: woken.executionID, destination: "draft", payload: "Reviewed")
        _ = try await store.confirmLaunchStopped(woken.executionID, exitStatus: 0)
        let receipt = try await store.recordUsageReceipt(woken.executionID, runtime: "claude", account: "ops",
                                                         cells: [cell("m", input: 400, output: 200)], coverage: .complete, reason: nil)
        #expect(receipt.chainID == first.envelope.chainID)
        #expect(try await store.chainUsage(first.envelope.chainID) == 600)
        // The same conversation continues — A acts on B's answer and writes again: the mail
        // arrives, but starts no more work.
        _ = try await store.acknowledgeMail(executionID: senderClaim.execution.id, ids: [answer.envelope.id])
        let reply = try await store.sendMail(executionID: senderClaim.execution.id, to: idleAddress, id: UUID(), text: "One more thing",
                                             replyTo: nil, priority: .normal)
        #expect(reply.state == .inbox && reply.envelope.chainID == first.envelope.chainID)
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
    }

    /// A run whose usage can never be settled from a transcript (a deleted home, a provider
    /// that wrote nothing readable) must not hold a budgeted worker until midnight. The owner
    /// releases it explicitly, with a reason, and the release is audited and idempotent.
    @Test func usageWaiveReleasesAnUnsettledExecution() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = try await store.enqueue(workerID: work.workerID, key: "second", instruction: "More")
        let policy = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 2, spec: spec())
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 0, tokensPerDay: 10_000)
        let first = try #require(await store.prepareSupervisedLaunch(work.workerID))
        _ = try await store.beginLaunch(first.executionID)
        _ = try await store.recordSpawn(first.executionID, pid: 42, seconds: 1, microseconds: 0)
        await #expect(throws: ControllerError.conflict) { try await store.waiveUsage(first.executionID, reason: "still running") }
        _ = try await store.confirmLaunchStopped(first.executionID, exitStatus: 0)
        _ = try await store.recordUsageReceipt(first.executionID, runtime: "claude", account: "ops",
                                               cells: [cell("m", input: 10, output: 5)], coverage: .partial, reason: "transcript_unterminated")
        #expect(try await store.workerCapacity(work.workerID).reason == .usageUnsettled)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        await #expect(throws: ControllerError.invalidInput("waive_reason")) { try await store.waiveUsage(first.executionID, reason: " ") }

        let waiver = try await store.waiveUsage(first.executionID, reason: "home deleted by operator")
        #expect(waiver.priorCoverage == .partial && waiver.workerID == work.workerID)
        #expect(try await store.waiveUsage(first.executionID, reason: "again") == waiver)
        #expect(try await store.workerCapacity(work.workerID).reason == .ready)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) != nil)
        let events = try await store.events(after: 0, limit: 100).items
        #expect(events.contains { $0.kind == "launch.usage_waived" && $0.subject == first.executionID.description })
        // A complete receipt leaves nothing to waive.
        let other = try await fixture.seed(store, worker: WorkerID(), key: "x")
        let settled = try await stoppedLaunch(store, worker: other.workerID, spec: spec())
        _ = try await store.recordUsageReceipt(settled.executionID, runtime: "claude", account: "ops", cells: [], coverage: .complete, reason: nil)
        await #expect(throws: ControllerError.conflict) { try await store.waiveUsage(settled.executionID, reason: "nothing owed") }
    }

    /// An owner's manual launch is admitted on the same budget as supervised work, judged on
    /// the recipe it will run; an explicit override is recorded.
    @Test func aManualLaunchRespectsTheWorkerBudget() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = try await store.enqueue(workerID: work.workerID, key: "second", instruction: "More")
        _ = try await store.enqueue(workerID: work.workerID, key: "third", instruction: "More")
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 0, tokensPerDay: 100)
        await #expect(throws: ControllerError.invalidInput("worker_capacity_usageNotConfigured")) {
            try await store.prepareLaunch(workerID: work.workerID, spec: spec(usage: nil))
        }
        let first = try await stoppedLaunch(store, worker: work.workerID, spec: spec())
        await #expect(throws: ControllerError.invalidInput("worker_capacity_usageUnsettled")) {
            try await store.prepareLaunch(workerID: work.workerID, spec: spec())
        }
        _ = try await store.recordUsageReceipt(first.executionID, runtime: "claude", account: "ops",
                                               cells: [cell("m", input: 80, output: 30)], coverage: .complete, reason: nil)
        await #expect(throws: ControllerError.invalidInput("worker_capacity_dailyBudget")) {
            try await store.prepareLaunch(workerID: work.workerID, spec: spec())
        }
        let overridden = try #require(await store.prepareLaunch(workerID: work.workerID, spec: spec(), overrideBudget: true))
        let events = try await store.events(after: 0, limit: 100).items
        #expect(events.contains { $0.kind == "launch.budget_overridden" && $0.subject == overridden.executionID.description })
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 1, tokensPerDay: nil)
        #expect(try await store.prepareLaunch(workerID: work.workerID, spec: spec()) != nil)
    }

    /// A capacity hold defers supervised admission only while every account the recipe may use
    /// is held; an expired or cleared hold admits again.
    @Test func capacityHoldsDeferAdmissionWhenEveryDeclaredAccountIsHeld() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let usage = ControllerUsageSource(runtime: .claude, accounts: [.init(account: "work", home: "/tmp/claude-work"),
                                                                         .init(account: "spare", home: "/tmp/claude-spare")])
        let policy = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 1, spec: spec(usage: usage))
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        await #expect(throws: ControllerError.invalidInput("hold_until")) {
            try await store.setCapacityHold(account: "work", until: "tomorrow", reason: "cooldown")
        }
        _ = try await store.setCapacityHold(account: "work", until: later, reason: "provider cooldown")
        #expect(try await store.workerCapacity(work.workerID).reason == .ready, "one free account is enough")
        _ = try await store.setCapacityHold(account: "spare", until: past, reason: "expired")
        #expect(try await store.workerCapacity(work.workerID).reason == .ready, "an expired hold holds nothing")
        _ = try await store.setCapacityHold(account: "spare", until: soon, reason: "weekly limit")
        let held = try await store.workerCapacity(work.workerID)
        #expect(held.reason == .capacityHeld && held.heldUntil == soon)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        #expect(try await store.capacityHolds().items.map(\.account).sorted() == ["spare", "work"])
        #expect(try await store.clearCapacityHold(account: "spare")?.reason == "weekly limit")
        #expect(try await store.prepareSupervisedLaunch(work.workerID) != nil)
    }

    /// The multi-account usage shape and its backward compatibility with stored policies.
    @Test func usageSourcesDeclareAccountsInAttemptOrder() throws {
        let legacy = try JSONDecoder().decode(ControllerUsageSource.self,
            from: Data(#"{"runtime":"claude","home":"/h/one","account":"ops"}"#.utf8))
        try legacy.validate()
        #expect(legacy.attempts == [.init(account: "ops", home: "/h/one")])
        let unnamed = try JSONDecoder().decode(ControllerUsageSource.self, from: Data(#"{"runtime":"codex","home":"/h/one"}"#.utf8))
        #expect(unnamed.attempts == [.init(account: "/h/one", home: "/h/one")])
        let declared = try JSONDecoder().decode(ControllerUsageSource.self, from: Data(#"""
            {"runtime":"claude","accounts":[{"account":"work","home":"/h/work"},{"account":"spare","home":"/h/spare"}]}
            """#.utf8))
        try declared.validate()
        #expect(declared.attempts.map(\.account) == ["work", "spare"])
        // Both shapes at once, for older controllers that read only `home`, while they agree.
        let both = try JSONDecoder().decode(ControllerUsageSource.self, from: Data(#"""
            {"runtime":"claude","home":"/h/work","account":"work","accounts":[{"account":"work","home":"/h/work"},{"account":"spare","home":"/h/spare"}]}
            """#.utf8))
        try both.validate()
        let refusals: [(String, String)] = [
            (#"{"runtime":"claude","home":"/h/other","accounts":[{"account":"work","home":"/h/work"}]}"#, "usage_accounts_conflict"),
            (#"{"runtime":"claude","accounts":[]}"#, "usage_accounts"),
            (#"{"runtime":"claude","accounts":[{"account":"a","home":"/h/x"},{"account":"a","home":"/h/y"}]}"#, "usage_accounts_duplicate"),
            (#"{"runtime":"claude","accounts":[{"account":"a","home":"/h/x"},{"account":"b","home":"/h/x/nested"}]}"#, "usage_homes_overlap"),
            (#"{"runtime":"claude","accounts":[{"account":"a","home":"relative"}]}"#, "usage_home"),
            (#"{"runtime":"claude"}"#, "usage_home")
        ]
        for (json, field) in refusals {
            let source = try JSONDecoder().decode(ControllerUsageSource.self, from: Data(json.utf8))
            #expect(throws: ControllerError.invalidInput(field)) { try source.validate() }
        }
        // A legacy recipe encodes exactly as before: no `accounts` key appears.
        let encoded = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        #expect(!encoded.contains("accounts"))
    }

    /// Hooks may report a transcript in each declared home once; anything else marks the
    /// launch changed and is refused.
    @Test func transcriptBindingAcceptsOneAttemptPerDeclaredHome() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let usage = ControllerUsageSource(runtime: .codex, accounts: [.init(account: "work", home: "/h/work"),
                                                                        .init(account: "spare", home: "/h/spare")])
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: spec(usage: usage)))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let first = ProviderTranscript(sessionID: "s1", path: "/h/work/sessions/a.jsonl")
        try await store.bindProviderTranscript(launch.executionID, credential: credential, transcript: first)
        try await store.bindProviderTranscript(launch.executionID, credential: credential, transcript: first)
        try await store.bindProviderTranscript(launch.executionID, credential: credential,
                                               transcript: ProviderTranscript(sessionID: "s2", path: "/h/spare/sessions/b.jsonl"))
        var value = try await store.launch(launch.executionID)
        #expect(value.transcriptBindings == [.init(account: "work", sessionID: "s1", path: first.path),
                                             .init(account: "spare", sessionID: "s2", path: "/h/spare/sessions/b.jsonl")])
        #expect(value.providerTranscript == first && value.providerTranscriptChanged == nil)
        await #expect(throws: ControllerError.conflict) {
            try await store.bindProviderTranscript(launch.executionID, credential: credential,
                                                   transcript: ProviderTranscript(sessionID: "s3", path: "/h/work/sessions/c.jsonl"))
        }
        await #expect(throws: ControllerError.forbidden) {
            try await store.bindProviderTranscript(launch.executionID, credential: credential,
                                                   transcript: ProviderTranscript(sessionID: "s4", path: "/h/workshop/x.jsonl"))
        }
        value = try await store.launch(launch.executionID)
        #expect(value.providerTranscriptChanged == true && value.transcriptBindings.count == 2)
    }

    /// Per-account receipt cells reach daily cells under their own account, with labels that
    /// say what is an estimate and how complete the receipts behind each cell were.
    @Test func receiptsSplitDailyCellsPerAccountWithCostLabels() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let usage = ControllerUsageSource(runtime: .claude, accounts: [.init(account: "work", home: "/h/work"),
                                                                         .init(account: "spare", home: "/h/spare")])
        let launch = try await stoppedLaunch(store, worker: work.workerID, spec: spec(usage: usage))
        let receipt = try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "work", cells: [
            UsageCell(model: "m", account: "work", tokens: UsageTokenCounts(uncachedInput: 10, output: 5), requests: 1, costUSD: 0.2, catalogCostUSD: 0.2),
            UsageCell(model: "m", account: "spare", tokens: UsageTokenCounts(uncachedInput: 100, output: 50), requests: 2,
                      costUSD: 1, unpricedTokens: 0, catalogCostUSD: 0),
            UsageCell(model: "mystery", account: "spare", tokens: UsageTokenCounts(output: 7), requests: 1, unpricedTokens: 7, catalogCostUSD: 0)
        ], coverage: .complete, reason: nil, pricingVersion: "2026-08-28")
        #expect(receipt.accounts?.map(\.account) == ["work", "spare"])
        #expect(receipt.accounts?.map(\.budgetTokens) == [15, 157])
        #expect(receipt.pricingVersion == "2026-08-28")
        let day = String(receipt.endedAt.prefix(10))
        let cells = try await store.usageSummary(from: day, through: day).items
        let byKey = Dictionary(uniqueKeysWithValues: cells.map { ("\($0.account)/\($0.model)", $0) })
        #expect(byKey["work/m"]?.output == 5 && byKey["spare/m"]?.output == 50)
        #expect(byKey["work/m"]?.costIsEstimate == true && byKey["spare/m"]?.costIsEstimate == false)
        #expect(byKey["spare/mystery"]?.unpricedTokens == 7 && byKey["spare/mystery"]?.costIsEstimate == true)
        #expect(cells.allSatisfy { $0.coverage?.complete == 1 && $0.pricingVersion == "2026-08-28" })
        #expect(cells.reduce(0) { $0 + $1.executions } == 1)
    }
}
