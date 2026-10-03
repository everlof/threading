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
}
