import Foundation
import Testing
@testable import ThreadingController

struct ControllerSourcesTests {
    let fixture = ControllerStoreTests()

    func script(_ directory: URL, _ name: String, _ body: String) throws -> String {
        let path = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }
    func invocation(_ executable: String, _ directory: URL, environment: [String: String] = [:], timeout: TimeInterval = 5) -> ProbeInvocation {
        ProbeInvocation(executable: executable, arguments: [], environment: environment, directory: directory.path,
                        cursor: "c0", limit: 3, timeout: timeout)
    }

    @Test func sha256MatchesTheStandardVectors() {
        var empty = SHA256()
        #expect(empty.finalize() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var abc = SHA256()
        abc.update(Array("abc".utf8))
        #expect(abc.finalize() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var long = SHA256()
        long.update(Array(String(repeating: "a", count: 1_000).utf8))
        #expect(long.finalize() == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func parsingAcceptsOnlyEventsThenOneFinalCursor() throws {
        let good = Data(#"{"event":{"id":"a","fields":{"n":3,"ok":true,"s":"x"}}}"#.utf8) + Data([10]) + Data(#"{"cursor":"7"}"#.utf8)
        let parsed = try TriggerProbe.parse(good, limit: 5)
        #expect(parsed.events.map(\.id) == ["a"] && parsed.cursor == "7" && parsed.events[0].fields["n"]?.text == "3")
        #expect(throws: ProbeFailure.invalidOutput("missing_cursor")) { try TriggerProbe.parse(Data(#"{"event":{"id":"a"}}"#.utf8), limit: 5) }
        #expect(throws: ProbeFailure.invalidOutput("line_after_cursor")) {
            try TriggerProbe.parse(Data((#"{"cursor":"1"}"# + "\n" + #"{"event":{"id":"a"}}"#).utf8), limit: 5)
        }
        #expect(throws: ProbeFailure.invalidOutput("too_many_events")) {
            try TriggerProbe.parse(Data((#"{"event":{"id":"a"}}"# + "\n" + #"{"event":{"id":"b"}}"# + "\n" + #"{"cursor":"1"}"#).utf8), limit: 1)
        }
        #expect(throws: ProbeFailure.invalidOutput("field_name")) {
            try TriggerProbe.parse(Data((#"{"event":{"id":"a","fields":{"bad key":1}}}"# + "\n" + #"{"cursor":"1"}"#).utf8), limit: 5)
        }
    }

    @Test func aProbeSeesOnlyItsEnvironmentAndItsRequest() async throws {
        let (directory, _) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try script(directory, "env.sh", """
            read request
            printf '{"event":{"id":"e","fields":{"home":"%s","given":"%s","pwd":"%s"},"evidence":%s}}\\n' "${HOME:-none}" "$GIVEN" "$(pwd)" "$(printf '%s' "$request" | sed 's/"/\\\\"/g; s/^/"/; s/$/"/')"
            echo '{"cursor":"c1"}'
            """)
        let run = await TriggerProbe.run(invocation(probe, directory, environment: ["GIVEN": "yes", "PATH": "/usr/bin:/bin"]))
        #expect(run.outcome == .healthy, "\(run.diagnostics)")
        #expect(run.events.first?.fields["home"]?.text == "none")   // nothing inherited
        #expect(run.events.first?.fields["given"]?.text == "yes")
        #expect(run.events.first?.evidence?.contains("\"cursor\":\"c0\"") == true)
        #expect(run.cursor == "c1")
    }

    @Test func exitCodesTimeoutsAndFloodsAreFailuresWithoutACursor() async throws {
        let (directory, _) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await TriggerProbe.run(invocation(try script(directory, "b.sh", "exit 75\n"), directory)).outcome == .backoff)
        #expect(await TriggerProbe.run(invocation(try script(directory, "a.sh", "exit 77\n"), directory)).outcome == .authenticationNeeded)
        let failed = await TriggerProbe.run(invocation(try script(directory, "f.sh", "echo broken >&2\nexit 3\n"), directory))
        #expect(failed.outcome == .failed && failed.diagnostics.contains("broken") && failed.cursor == nil)
        // The timeout kills the probe's whole group, including a child it left running.
        let marker = directory.appendingPathComponent("child-alive").path
        let slow = try script(directory, "slow.sh", "(sleep 3; touch \(marker)) &\nsleep 30\n")
        let started = Date()
        let timedOut = await TriggerProbe.run(invocation(slow, directory, environment: ["PATH": "/usr/bin:/bin"], timeout: 1))
        #expect(timedOut.outcome == .failed && timedOut.diagnostics == "timed_out")
        #expect(Date().timeIntervalSince(started) < 10)
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: marker))
        let flood = try script(directory, "flood.sh", "yes '{\"event\":{\"id\":\"x\"}}'\n")
        let flooded = await TriggerProbe.run(invocation(flood, directory, environment: ["PATH": "/usr/bin:/bin"]))
        #expect(flooded.outcome == .failed && flooded.diagnostics == "output_too_large")
    }

    @Test func approvalPinsTheHashAndMatchedEventsAdmitWorkOnce() async throws {
        let (directory, store) = try fixture.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Support")
        let probe = try script(directory, "probe.sh", "echo ok\n")
        let id = SourceID()
        let configured = try await store.configureSource(id, expectedRevision: 0, spec: ControllerSourceSpec(name: "Inbox", executable: probe, intervalSeconds: 60))
        #expect(!configured.enabled && configured.approvedHash == nil)
        await #expect(throws: ControllerError.forbidden) { try await store.setSourceEnabled(id, expectedRevision: 1, enabled: true) }
        await #expect(throws: ControllerError.conflict) { try await store.approveSource(id, expectedRevision: 1, hash: String(repeating: "0", count: 64)) }
        let approved = try await store.approveSource(id, expectedRevision: 1, hash: configured.hash)
        let enabled = try await store.setSourceEnabled(id, expectedRevision: approved.revision, enabled: true)
        #expect(try await store.dueSources().map(\.id) == [id])

        let trigger = TriggerRuleID()
        let rule = ControllerTriggerSpec(name: "New tickets", sourceID: id, workerID: worker,
                                         match: [TriggerClause(field: "subject", op: .notPrefix, value: "Re:"), TriggerClause(field: "to", op: .equals, value: "support@x")],
                                         instruction: "Triage the ticket in the request.")
        let paused = try await store.configureTrigger(trigger, expectedRevision: 0, spec: rule)
        _ = try await store.setWorkerSources(worker, expectedRevision: 0, sources: [.request])
        await #expect(throws: ControllerError.forbidden) { try await store.setTriggerEnabled(trigger, expectedRevision: paused.revision, enabled: true) }
        _ = try await store.setWorkerSources(worker, expectedRevision: 1, sources: [.request, .event])
        _ = try await store.setTriggerEnabled(trigger, expectedRevision: paused.revision, enabled: true)

        func event(_ id: String, _ subject: String) throws -> ProbeEvent {
            try JSONDecoder().decode(ProbeEvent.self, from: Data(#"{"id":"\#(id)","fields":{"subject":"\#(subject)","to":"support@x"},"evidence":"body"}"#.utf8))
        }
        let run = ProbeRun(outcome: .healthy, events: [try event("1", "Help"), try event("2", "Re: Help")], cursor: "c2", diagnostics: "")
        let recorded = try await store.recordPoll(id, revision: enabled.revision, observedHash: configured.hash, run: run)
        #expect(recorded.map { $0.receipts.first?.admission } == [.queued, .notMatched])
        let works = try await store.works(workerID: worker).items
        #expect(works.count == 1 && works[0].source == .event && works[0].instruction == "Triage the ticket in the request.")
        #expect(works[0].request?.contains("\"evidence\":\"body\"") == true)
        // Redelivering the same events records nothing new and admits nothing twice.
        #expect(try await store.recordPoll(id, revision: enabled.revision, observedHash: configured.hash, run: run).isEmpty)
        #expect(try await store.works(workerID: worker).items.count == 1)
        #expect(try await store.source(id).cursor == "c2")

        // A failure backs off without moving the cursor; an edited probe stops the source.
        _ = try await store.recordPoll(id, revision: enabled.revision, observedHash: configured.hash,
                                       run: ProbeRun(outcome: .backoff, events: [], cursor: nil, diagnostics: "rate limited"))
        let backedOff = try await store.source(id)
        #expect(backedOff.health.state == .backoff && backedOff.health.failures == 1 && backedOff.cursor == "c2")
        _ = try await store.recordPoll(id, revision: enabled.revision, observedHash: "edited", run: run)
        #expect(try await store.source(id).health.state == .changed)
        #expect(try await store.dueSources(now: Date().addingTimeInterval(86_400)).isEmpty)
    }

    @Test func aMissingFieldOnlyMatchesAbsent() {
        let fields: [String: ProbeValue] = ["a": .string("x")]
        #expect(!TriggerClause(field: "b", op: .notEquals, value: "y").matches(fields))
        #expect(!TriggerClause(field: "b", op: .notPrefix, value: "y").matches(fields))
        #expect(TriggerClause(field: "b", op: .absent).matches(fields))
        #expect(TriggerClause(field: "a", op: .exists).matches(fields))
        #expect(TriggerClause(field: "a", op: .contains, value: "x").matches(fields))
    }
}
