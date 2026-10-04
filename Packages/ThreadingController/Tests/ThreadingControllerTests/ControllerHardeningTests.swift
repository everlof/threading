import Foundation
import Testing
@testable import ThreadingController

struct ControllerHardeningTests {
    let fixture = ControllerStoreTests()
    let usage = ControllerUsageTests()

    @Test func budgetReservesCapacityUntilUsageIsKnown() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        _ = try await store.enqueue(workerID: work.workerID, key: "next", instruction: "Next")
        let policy = try await store.configureWorker(work.workerID, expectedRevision: 0, maximumConcurrent: 2, spec: usage.spec())
        _ = try await store.setWorkerEnabled(work.workerID, expectedRevision: policy.revision, enabled: true)
        _ = try await store.setWorkerBudget(work.workerID, expectedRevision: 0, tokensPerDay: 100)
        let launch = try #require(await store.prepareSupervisedLaunch(work.workerID))
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        await #expect(throws: ControllerError.conflict) {
            try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "ops", cells: [], coverage: .unavailable, reason: "early")
        }
        _ = try await store.confirmLaunchStopped(launch.executionID, exitStatus: 0)
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
        _ = try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "ops", cells: [], coverage: .unavailable, reason: "missing")
        #expect(try await store.prepareSupervisedLaunch(work.workerID) == nil)
    }

    @Test func lateCollectionUsesThePersistedStopDay() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        var launch = try await usage.stoppedLaunch(store, worker: work.workerID, spec: usage.spec())
        launch.stoppedAt = "2026-01-02T23:59:59Z"
        try await store.saveLaunch(launch)
        let receipt = try await store.recordUsageReceipt(launch.executionID, runtime: "claude", account: "ops",
            cells: [usage.cell("m", input: 10, output: 5)], coverage: .complete, reason: nil)
        #expect(receipt.endedAt == launch.stoppedAt)
        #expect(try await store.usageSummary(from: "2026-01-02", through: "2026-01-02").items.first?.uncachedInput == 10)
    }

    @Test func revokedRetainedMailCannotStartNewWork() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = try await fixture.seed(store)
        let recipient = WorkerID()
        _ = try await store.addWorker(id: recipient, name: "Recipient")
        let address = try await store.mailAddress(worker: recipient)
        _ = try await store.setMailGrant(recipient: address, sender: "*", expectedRevision: 0, mode: .wake, allowsInterrupt: false)
        _ = try await store.sendMail(from: try await store.mailAddress(worker: sender.workerID), to: address,
            id: UUID(), text: "Wake up", replyTo: nil, priority: .normal)
        _ = try await store.setMailGrant(recipient: address, sender: "*", expectedRevision: 1, mode: nil, allowsInterrupt: false)
        #expect(try await store.admitMailWakes(after: 0).admitted.isEmpty)
        #expect(try await store.inbox(address).items.count == 1)
    }

    @Test func processTimeoutBoundsIgnoredSignalsAndHeldPipes() async throws {
        let started = Date()
        let result = await BoundedCommand.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            environment: ["PATH": "/usr/bin:/bin"], directory: "/tmp", input: Data(repeating: 65, count: 262_144), timeout: 0.2, outputLimit: 1024)
        #expect(result.failure == "timed_out")
        #expect(Date().timeIntervalSince(started) < 3)
        let next = await BoundedCommand.run(executable: "/bin/sh", arguments: ["-c", "printf ok"],
            environment: [:], directory: "/tmp", input: Data(), timeout: 1, outputLimit: 1024)
        #expect(next.exitCode == 0 && next.output == Data("ok".utf8))
    }

    @Test func transcriptBindingIsAuthenticatedImmutableAndFencedAtStop() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await fixture.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: usage.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let transcript = ProviderTranscript(sessionID: "session", path: "/tmp/claude-home/projects/session.jsonl")
        await #expect(throws: ControllerError.forbidden) {
            try await store.bindProviderTranscript(launch.executionID, credential: "wrong", transcript: transcript)
        }
        try await store.bindProviderTranscript(launch.executionID, credential: credential, transcript: transcript)
        #expect(try await store.launch(launch.executionID).providerTranscriptChanged != true)
        try await store.bindProviderTranscript(launch.executionID, credential: credential, transcript: transcript)
        await #expect(throws: ControllerError.conflict) {
            try await store.bindProviderTranscript(launch.executionID, credential: credential,
                transcript: ProviderTranscript(sessionID: "other", path: transcript.path))
        }
        #expect(try await store.launch(launch.executionID).providerTranscriptChanged == true)
        _ = try await store.confirmLaunchStopped(launch.executionID, exitStatus: 0)
        await #expect(throws: ControllerError.forbidden) {
            try await store.bindProviderTranscript(launch.executionID, credential: credential, transcript: transcript)
        }
    }
    @Test func pausedTriggerHistoryDoesNotConsumeTheActiveLimit() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Events")
        let executable = try ControllerSourcesTests().script(directory, "probe.sh", "exit 0")
        let source = try await store.configureSource(SourceID(), expectedRevision: 0,
            spec: ControllerSourceSpec(name: "Events", executable: executable, intervalSeconds: 60))
        let approved = try await store.approveSource(source.id, expectedRevision: source.revision, hash: source.hash)
        let enabled = try await store.setSourceEnabled(source.id, expectedRevision: approved.revision, enabled: true)
        let spec = ControllerTriggerSpec(name: "Rule", sourceID: source.id, workerID: worker, match: [], instruction: "Inspect")
        for _ in 0..<100 { _ = try await store.configureTrigger(TriggerRuleID(), expectedRevision: 0, spec: spec) }
        let active = try await store.configureTrigger(TriggerRuleID(), expectedRevision: 0, spec: spec)
        _ = try await store.setTriggerEnabled(active.id, expectedRevision: active.revision, enabled: true)
        let event = try JSONDecoder().decode(ProbeEvent.self, from: Data(#"{"id":"one"}"#.utf8))
        let recorded = try await store.recordPoll(source.id, revision: enabled.revision, observedHash: source.hash,
            run: ProbeRun(outcome: .healthy, events: [event], cursor: "one", diagnostics: ""))
        #expect(recorded.first?.receipts.first?.triggerID == active.id)
        #expect(try await store.works(workerID: worker).items.count == 1)
        for _ in 0..<99 {
            let rule = try await store.configureTrigger(TriggerRuleID(), expectedRevision: 0, spec: spec)
            _ = try await store.setTriggerEnabled(rule.id, expectedRevision: rule.revision, enabled: true)
        }
        let excess = try await store.configureTrigger(TriggerRuleID(), expectedRevision: 0, spec: spec)
        await #expect(throws: ControllerError.invalidInput("active_trigger_limit")) {
            try await store.setTriggerEnabled(excess.id, expectedRevision: excess.revision, enabled: true)
        }
    }

    @Test func freshExecutionsDiscoverOnlyTheirStableAgentsMemory() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await fixture.seed(store)
        let second = try await fixture.seed(store, worker: WorkerID(), key: "other")
        for index in 0..<25 {
            _ = try await store.putMemory(workerID: first.workerID, key: "note-\(index)", expectedRevision: 0, content: "Synthetic preference")
        }
        let identity = try await store.agentIdentity(first.workerID)
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.agentIdentity(first.workerID) == identity)
        let launch = try #require(await reopened.prepareLaunch(workerID: first.workerID, spec: usage.spec()))
        _ = try await reopened.beginLaunch(launch.executionID)
        let credential = try await reopened.launchCredential(launch.executionID)
        let context = try await reopened.agentRequest(executionID: launch.executionID, credential: credential, request: .context)
        #expect(context.agent == identity && context.memoryKeys?.items.count == 20)
        let next = try await reopened.agentRequest(executionID: launch.executionID, credential: credential,
            request: .memoryList(after: context.memoryKeys?.next ?? 0))
        #expect(next.memoryKeys?.items.count == 5)
    }

    /// The agent routes derive the worker from the authenticated execution, so a running agent that
    /// knows another worker's memory key — or holds that worker's execution id — still cannot read,
    /// list or overwrite that worker's note. Both workers share one store, as on a host.
    @Test func runningAgentCannotReachAnotherWorkersMemory() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await fixture.seed(store)
        let second = try await fixture.seed(store, worker: WorkerID(), key: "other")
        let key = "deploy-credentials-location"
        let secret = "Second worker's private note"
        _ = try await store.putMemory(workerID: second.workerID, key: key, expectedRevision: 0, content: secret)

        let launch = try #require(await store.prepareLaunch(workerID: first.workerID, spec: usage.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let otherLaunch = try #require(await store.prepareLaunch(workerID: second.workerID, spec: usage.spec()))
        _ = try await store.beginLaunch(otherLaunch.executionID)

        let read = try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .memoryGet(key: key))
        #expect(read.memory == nil)
        let context = try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .context)
        #expect(context.memoryKeys?.items.isEmpty == true)
        let listed = try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .memoryList(after: 0))
        #expect(listed.memoryKeys?.items.isEmpty == true)
        // Presenting this execution's credential for the other worker's running execution is refused.
        await #expect(throws: ControllerError.forbidden) {
            try await store.agentRequest(executionID: otherLaunch.executionID, credential: credential, request: .memoryGet(key: key))
        }
        // A write under the same key lands in the caller's own namespace and leaves the other note intact.
        let written = try await store.agentRequest(executionID: launch.executionID, credential: credential,
            request: .memoryPut(key: key, expectedRevision: 0, content: "First worker's note"))
        #expect(written.memory?.workerID == first.workerID)
        let untouched = try #require(await store.memory(workerID: second.workerID, key: key))
        #expect(untouched.revision == 1 && untouched.content == secret)
    }

}
