import Foundation
import Testing
import ThreadingController
import ThreadingUsage
@testable import ControllerRuntime

/// A store, a worker with one queued task, and a scratch root, removed when the test ends.
private struct UsageFixture {
    let root: URL
    let store: ControllerStore
    let worker = WorkerID()

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try ControllerStore(path: root.appendingPathComponent("controller.db").path)
        _ = try await store.addWorker(id: worker, name: "Fixture")
        _ = try await store.enqueue(workerID: worker, key: "trial", instruction: "Synthetic")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func spec(_ usage: ControllerUsageSource) -> ControllerLaunchSpec {
        ControllerLaunchSpec(socketPath: "/tmp/unused.sock", executable: "/bin/true", arguments: [], environment: [:],
                             directory: root.path, recipients: ["person:operator"], destination: "fixture", usage: usage)
    }
    /// Prepared and dispatched, with the execution credential a hook would carry.
    func running(_ usage: ControllerUsageSource) async throws -> (ExecutionID, String) {
        let launch = try #require(await store.prepareLaunch(workerID: worker, spec: spec(usage)))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        _ = try await store.recordSpawn(launch.executionID, pid: 42, seconds: 1, microseconds: 0)
        return (launch.executionID, credential)
    }
    func stopAndCollect(_ id: ExecutionID) async throws -> UsageReceipt {
        _ = try await store.confirmLaunchStopped(id, exitStatus: 0)
        return try await ControllerUsageCollector.collect(store: store, executionID: id)
    }
    @discardableResult
    func write(_ lines: [String], to file: URL, terminated: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + (terminated ? "\n" : "")).utf8).write(to: file)
        return file
    }
}

/// One Claude assistant response line.
private func claudeLine(_ id: String, input: Int64 = 100, output: Int64 = 10, model: String = "claude-sonnet-4-5") -> String {
    #"{"requestId":"r-\#(id)","timestamp":"2026-10-03T10:00:00.000Z","cwd":"/work","message":{"id":"m-\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":\#(output)}}}"#
}

struct UsageCollectorTests {
    @Test func accountFailoverCannotSettleOnlyTheFirstTranscript() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("claude")
        let (id, credential) = try await fixture.running(ControllerUsageSource(runtime: .claude, home: home.path, account: "first"))
        let transcript = try fixture.write([], to: home.appendingPathComponent("projects/fixture/\(id).jsonl"), terminated: false)
        try await fixture.store.bindProviderTranscript(id, credential: credential,
            transcript: ProviderTranscript(sessionID: id.description, path: transcript.path))
        await #expect(throws: ControllerError.forbidden) {
            try await fixture.store.bindProviderTranscript(id, credential: credential,
                transcript: ProviderTranscript(sessionID: id.description, path: fixture.root.appendingPathComponent("second/account.jsonl").path))
        }
        let receipt = try await fixture.stopAndCollect(id)
        #expect(receipt.coverage == .partial && receipt.reason == "provider_transcript_changed")
    }

    /// The contract Rindabox's runner relies on: it fails over from one declared login to the
    /// next and resumes, which copies the conversation into the second home. The copied
    /// responses count once, on the first account; the new ones on the second.
    @Test func failoverAcrossDeclaredHomesCountsCopiedResponsesOnceOnTheFirstAccount() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("claude-work")
        let second = fixture.root.appendingPathComponent("claude-spare")
        let usage = ControllerUsageSource(runtime: .claude, accounts: [.init(account: "work", home: first.path),
                                                                         .init(account: "spare", home: second.path)])
        let (id, credential) = try await fixture.running(usage)
        let original = try fixture.write([claudeLine("1", input: 100, output: 10), claudeLine("2", input: 200, output: 20)],
                                         to: first.appendingPathComponent("projects/-work/\(id).jsonl"))
        try await fixture.store.bindProviderTranscript(id, credential: credential,
            transcript: ProviderTranscript(sessionID: id.description, path: original.path))
        // The resume under the second login: a copy of the history, then its own response.
        let copy = try fixture.write([claudeLine("1", input: 100, output: 10), claudeLine("2", input: 200, output: 20),
                                      claudeLine("3", input: 1_000, output: 100)],
                                     to: second.appendingPathComponent("projects/-work/\(id).jsonl"))
        try await fixture.store.bindProviderTranscript(id, credential: credential,
            transcript: ProviderTranscript(sessionID: id.description, path: copy.path))
        let launch = try await fixture.store.launch(id)
        #expect(launch.transcriptBindings.map(\.account) == ["work", "spare"])

        let receipt = try await fixture.stopAndCollect(id)
        #expect(receipt.coverage == .complete)
        #expect(receipt.account == "work")
        let totals = try #require(receipt.accounts)
        #expect(totals.map(\.account) == ["work", "spare"])
        #expect(totals[0].budgetTokens == 330 && totals[0].requests == 2)
        #expect(totals[1].budgetTokens == 1_100 && totals[1].requests == 1)
        #expect(receipt.budgetTokens == 1_430)
        #expect(Set(receipt.cells.compactMap(\.account)) == ["work", "spare"])
        let day = String(receipt.endedAt.prefix(10))
        let daily = try await fixture.store.usageSummary(from: day, through: day).items
        #expect(Dictionary(grouping: daily, by: \.account).mapValues { $0.reduce(0) { $0 + $1.output } } == ["work": 30, "spare": 100])
        #expect(daily.allSatisfy { $0.costIsEstimate == true && $0.pricingVersion == UsagePricingCatalog.version })
    }

    /// An obsolete preparation or a stop confirmed before dispatch never ran a process. Its
    /// receipt settles at zero and the budgeted worker is admitted again.
    @Test func aLaunchThatNeverSpawnedSettlesAtZero() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let usage = ControllerUsageSource(runtime: .claude, home: fixture.root.appendingPathComponent("claude").path, account: "ops")
        let policy = try await fixture.store.configureWorker(fixture.worker, expectedRevision: 0, maximumConcurrent: 1, spec: fixture.spec(usage))
        _ = try await fixture.store.setWorkerEnabled(fixture.worker, expectedRevision: policy.revision, enabled: true)
        _ = try await fixture.store.setWorkerBudget(fixture.worker, expectedRevision: 0, tokensPerDay: 1_000)
        let launch = try #require(await fixture.store.prepareSupervisedLaunch(fixture.worker))
        #expect(try await fixture.store.workerCapacity(fixture.worker).reason == .usageUnsettled)
        let receipt = try await fixture.stopAndCollect(launch.executionID)
        #expect(receipt.coverage == .complete && receipt.reason == "never_spawned" && receipt.cells.isEmpty)
        #expect(try await fixture.store.workerCapacity(fixture.worker).reason == .ready)
    }

    /// A spawned Claude that never wrote a transcript in any declared home sent no request.
    @Test func aSpawnedRunWithNoProviderSessionSettlesAtZero() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects/other"), withIntermediateDirectories: true)
        let (id, _) = try await fixture.running(ControllerUsageSource(runtime: .claude, home: home.path, account: "ops"))
        let receipt = try await fixture.stopAndCollect(id)
        #expect(receipt.coverage == .complete && receipt.reason == "no_provider_session")

        // A home with no projects directory at all is a misconfiguration, not a zero.
        _ = try await fixture.store.enqueue(workerID: fixture.worker, key: "missing", instruction: "Again")
        let (missing, _) = try await fixture.running(ControllerUsageSource(runtime: .claude,
            home: fixture.root.appendingPathComponent("nowhere").path, account: "ops"))
        let unavailable = try await fixture.stopAndCollect(missing)
        #expect(unavailable.coverage == .unavailable && unavailable.reason == "no_projects_directory")
    }

    /// Claude restates a streaming response with growing counters; the receipt keeps the
    /// component maxima through the same merge the Mac uses, not the first copy.
    @Test func repeatedResponsesMergeToTheirMaximum() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("claude")
        let (id, _) = try await fixture.running(ControllerUsageSource(runtime: .claude, home: home.path, account: "ops"))
        try fixture.write([claudeLine("1", input: 100, output: 5), claudeLine("1", input: 100, output: 90)],
                          to: home.appendingPathComponent("projects/-work/\(id).jsonl"))
        let receipt = try await fixture.stopAndCollect(id)
        let cell = try #require(receipt.cells.first)
        #expect(receipt.coverage == .complete && receipt.cells.count == 1)
        #expect(cell.tokens.output == 90 && cell.tokens.uncachedInput == 100 && cell.requests == 1)
    }

    /// One unreadable line or a final line cut mid-write is a gap beside the records read,
    /// not the loss of the whole transcript.
    @Test func aTruncatedFinalLineKeepsEarlierRecordsAsPartial() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("claude")
        let (id, _) = try await fixture.running(ControllerUsageSource(runtime: .claude, home: home.path, account: "ops"))
        let cut = String(claudeLine("3").prefix(60))
        try fixture.write([claudeLine("1", output: 10), #"{"message":{"id":"x","usage":7}}"#, claudeLine("2", output: 20), cut],
                          to: home.appendingPathComponent("projects/-work/\(id).jsonl"), terminated: false)
        let receipt = try await fixture.stopAndCollect(id)
        #expect(receipt.coverage == .partial)
        #expect(receipt.reason == "unreadable_usage_records; transcript_unterminated")
        #expect(receipt.cells.reduce(0) { $0 + $1.tokens.output } == 30)
        let day = String(receipt.endedAt.prefix(10))
        let cell = try #require(try await fixture.store.usageSummary(from: day, through: day).items.first)
        #expect(cell.coverage?.partial == 1 && cell.coverage?.complete == 0)
    }

    /// A path the hook bound is the transcript: a symlink that resolves outside the home's
    /// `projects`, or a file not named for this execution, is a gap — never a search elsewhere.
    @Test func aBoundClaudePathMustResolveInsideTheHomeAndNameTheExecution() async throws {
        let fixture = try await UsageFixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("claude")
        let (id, credential) = try await fixture.running(ControllerUsageSource(runtime: .claude, home: home.path, account: "ops"))
        let outside = try fixture.write([claudeLine("1", output: 999)], to: fixture.root.appendingPathComponent("outside/\(id).jsonl"))
        let link = home.appendingPathComponent("projects/-work/\(id).jsonl")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        // A real transcript elsewhere in the same home must not be picked up instead.
        try fixture.write([claudeLine("2", output: 1)], to: home.appendingPathComponent("projects/-other/\(id).jsonl"))
        try await fixture.store.bindProviderTranscript(id, credential: credential,
            transcript: ProviderTranscript(sessionID: id.description, path: link.path))
        let receipt = try await fixture.stopAndCollect(id)
        #expect(receipt.coverage == .failed && receipt.reason == "provider_transcript_unreadable" && receipt.cells.isEmpty)

        let boundElsewhere = ControllerUsageCollector.claude(home: home.path, session: id.description,
            bound: home.appendingPathComponent("projects/-other/\(id).jsonl").path, account: "ops")
        #expect(boundElsewhere.found && boundElsewhere.gaps.isEmpty)
        let wrongName = try fixture.write([claudeLine("4")], to: home.appendingPathComponent("projects/-other/elsewhere.jsonl"))
        let refused = ControllerUsageCollector.claude(home: home.path, session: id.description, bound: wrongName.path, account: "ops")
        #expect(!refused.found && refused.gaps == ["provider_transcript_unreadable"])
    }

    @Test func consecutiveCodexRunsUseTheirOwnBoundTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2 {
            let id = UUID().uuidString
            let path = root.appendingPathComponent("rollout-\(index).jsonl")
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/same\"}}\n".utf8).write(to: path)
            let result = ControllerUsageCollector.codex(home: root.path, execution: UUID().uuidString,
                transcript: ProviderTranscript(sessionID: id, path: path.path), account: "fixture")
            #expect(result.found && result.gaps.isEmpty)
            let wrong = ControllerUsageCollector.codex(home: root.path, execution: UUID().uuidString,
                transcript: ProviderTranscript(sessionID: "wrong", path: path.path), account: "fixture")
            #expect(!wrong.found && wrong.gaps == ["provider_transcript_identity"])
        }
    }

    /// Codex's `session_meta` can carry a large instruction block; identity is still read.
    @Test func codexIdentityIsReadPastTheFirst64KB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let instructions = String(repeating: "x", count: 200_000)
        let usage = #"{"type":"event_msg","timestamp":"2026-10-03T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":7,"reasoning_output_tokens":0}}}}"#
        let path = root.appendingPathComponent("rollout.jsonl")
        try Data((#"{"type":"session_meta","payload":{"instructions":"\#(instructions)","id":"\#(id)","cwd":"/w"}}"# + "\n" + usage + "\n").utf8).write(to: path)
        let result = ControllerUsageCollector.codex(home: root.path, execution: UUID().uuidString, transcript: ProviderTranscript(sessionID: id, path: path.path), account: "a")
        #expect(result.found && result.gaps.isEmpty)
        #expect(result.records.map(\.tokens.output) == [7])
    }

    /// A Codex execution's own child runs (the research helper's `codex exec`) are filed under
    /// `<home>/threading-subagents/<execution>/` and counted beside the bound rollout; another
    /// execution's children are not.
    @Test func codexChildRunsFiledUnderTheExecutionAreCounted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func rollout(_ session: String, output: Int, at stamp: String) -> String {
            #"{"type":"session_meta","payload":{"id":"\#(session)","cwd":"/w"}}"# + "\n"
                + #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0}}}}"# + "\n"
        }
        let execution = UUID().uuidString, other = UUID().uuidString, parent = UUID().uuidString
        let main = root.appendingPathComponent("rollout.jsonl")
        try Data(rollout(parent, output: 7, at: "2026-10-03T10:00:00Z").utf8).write(to: main)
        for (owner, output) in [(execution, 11), (other, 999)] {
            let directory = root.appendingPathComponent("\(ControllerUsageCollector.codexSubagentDirectory)/\(owner)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(rollout(UUID().uuidString, output: output, at: "2026-10-03T10:01:00Z").utf8)
                .write(to: directory.appendingPathComponent("research-1.jsonl"))
        }
        let result = ControllerUsageCollector.codex(home: root.path, execution: execution,
            transcript: ProviderTranscript(sessionID: parent, path: main.path), account: "a")
        #expect(result.found && result.gaps.isEmpty)
        #expect(result.records.map(\.tokens.output).sorted() == [7, 11])
    }

    @Test func tooManyClaudeChildrenCannotReportCompleteCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("projects/fixture")
        let children = project.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: project.appendingPathComponent("session.jsonl"))
        for index in 0..<201 { try Data().write(to: children.appendingPathComponent("\(index).jsonl")) }
        let result = ControllerUsageCollector.claude(home: root.path, session: "session", bound: nil, account: "fixture")
        #expect(result.found && result.gaps == ["subagent_transcripts_incomplete"])
        #expect(ControllerUsageCollector.coverage([result], accounts: ["fixture"], transcriptChanged: false).coverage == .partial)
    }

    @Test func mailTransportTimeoutReturnsAndNextExchangeCanRun() async throws {
        let start = Date()
        let failure = await #expect(throws: ControllerRuntimeError.self) {
            try await ControllerMailSync.run(["/bin/sh", "-c", "trap '' TERM; sleep 30 & wait"], input: Data(), limit: 1024, timeout: 0.2)
        }
        guard case .timedOut = failure else { Issue.record("Expected timedOut"); return }
        #expect(Date().timeIntervalSince(start) < 3)
        let result = try await ControllerMailSync.run(["/bin/sh", "-c", "cat"], input: Data("ok".utf8), limit: 1024, timeout: 1)
        #expect(result == Data("ok".utf8))
    }
}
