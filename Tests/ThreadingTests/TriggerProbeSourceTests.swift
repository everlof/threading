import AppKit
import ThreadingController
import XCTest
@testable import Threading

/// Probe sources on the Mac: the configuration the app projects for `threading-triggerd`, the
/// poll pipeline the daemon runs (shared source, so tested here), and the approval gate.
final class TriggerProbeSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerProbeSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private struct FakeSecrets: TriggerProbeSecretResolving {
        let values: [String: String]
        func value(forSecret name: String) throws -> String {
            guard let value = values[name] else { throw TriggerProbeSecretFailure.unavailable(name) }
            return value
        }
    }

    private func spec(executable: String = "/bin/sh", script: String? = nil,
                      secrets: [String: String] = [:], limit: Int = 50) -> ControllerSourceSpec {
        ControllerSourceSpec(name: "Mailbox", executable: executable, script: script,
                             arguments: script.map { [$0] } ?? [], environment: ["FOLDER": "INBOX"],
                             secrets: secrets, intervalSeconds: 600, timeoutSeconds: 10, limit: limit)
    }

    private func daemonSource(secrets: [String: String] = [:], limit: Int = 50) -> TriggerProbeDaemonSource {
        TriggerProbeDaemonSource(id: UUID(), revision: 3, spec: TriggerProbeRunSpec(spec(secrets: secrets, limit: limit)),
                                 approvedHash: "approved", enabled: true)
    }

    private func installation(approved: Bool, enabled: Bool, type: String = "probe") -> TriggerSourceInstallation {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return TriggerSourceInstallation(
            id: TriggerSourceInstallationID(), sourceType: type, displayName: "Mailbox", configuration: [:],
            credentialReference: nil, enabled: enabled, health: .disconnected, lastCheckedAt: nil, lastEventAt: nil,
            boundedDiagnostic: nil, createdAt: now, updatedAt: now,
            probe: TriggerProbeSourceSettings(spec: spec(), revision: 2, hash: "abc",
                                              approvedHash: approved ? "abc" : nil))
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    private static func event(_ id: String, fields: [String: Any] = [:]) throws -> ProbeEvent {
        let line = try JSONSerialization.data(withJSONObject: ["event": ["id": id, "fields": fields]])
        return try TriggerProbe.parse(line + Data("\n{\"cursor\":\"c\"}\n".utf8), limit: 10).events[0]
    }

    // MARK: - Configuration projection

    func testOnlyApprovedProbesReachTheDaemonAndPausedOnesStayForManualPolls() throws {
        let unapproved = installation(approved: false, enabled: false)
        let paused = installation(approved: true, enabled: false)
        let enabled = installation(approved: true, enabled: true)
        let configuration = try TriggerDaemonConfigurationStore.configuration(for: [unapproved, paused, enabled])

        let probes = try XCTUnwrap(configuration.probes)
        XCTAssertEqual(Set(probes.map(\.id)), [paused.id.rawValue, enabled.id.rawValue])
        XCTAssertEqual(probes.first { $0.id == paused.id.rawValue }?.enabled, false)
        XCTAssertEqual(probes.first { $0.id == enabled.id.rawValue }?.approvedHash, "abc")
        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertTrue(configuration.sources.isEmpty, "a probe is never projected as an HTTP adapter")

        // The daemon decodes the same declaration the app encoded.
        let decoded = try JSONDecoder().decode(TriggerDaemonConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.probes, probes)
    }

    func testAProbeWhoseFilesChangedAfterConfigureIsNotProjected() throws {
        var source = installation(approved: true, enabled: true)
        source.probe?.hash = "new-content"
        XCTAssertNil(try TriggerDaemonConfigurationStore.configuration(for: [source]).probes)
    }

    // MARK: - Poll pipeline

    func testAChangedHashRefusesToRunAndCommitsNothing() async {
        var ran = false, wrote = false, committed = false
        let outcome = await TriggerProbeSourceRunner.poll(
            daemonSource(), cursor: nil, directory: directory.path, secrets: FakeSecrets(values: [:]),
            observedHash: "edited",
            run: { _ in ran = true; return ProbeRun(outcome: .healthy, events: [], cursor: "x", diagnostics: "") },
            write: { _, _ in wrote = true }, commit: { _ in committed = true })
        XCTAssertEqual(outcome.health, .changed)
        XCTAssertFalse(ran || wrote || committed)
    }

    func testTheCursorIsCommittedOnlyAfterEveryEventIsInTheInbox() async throws {
        let events = [try Self.event("a"), try Self.event("b"), try Self.event("c")]
        var log: [String] = []
        let outcome = await TriggerProbeSourceRunner.poll(
            daemonSource(), cursor: "old", directory: directory.path, secrets: FakeSecrets(values: [:]),
            observedHash: "approved",
            run: { invocation in
                XCTAssertEqual(invocation.cursor, "old")
                return ProbeRun(outcome: .healthy, events: events, cursor: "new", diagnostics: "")
            },
            write: { event, index in log.append("write \(event.externalID) \(index)") },
            commit: { log.append("commit \($0)") })
        XCTAssertEqual(log, ["write a 0", "write b 1", "write c 2", "commit new"])
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertEqual(outcome.committedCursor, "new")

        // An inbox failure part-way leaves the cursor where it was, so the poll redelivers.
        var committed = false
        let failed = await TriggerProbeSourceRunner.poll(
            daemonSource(), cursor: "old", directory: directory.path, secrets: FakeSecrets(values: [:]),
            observedHash: "approved",
            run: { _ in ProbeRun(outcome: .healthy, events: events, cursor: "new", diagnostics: "") },
            write: { _, index in if index == 1 { throw CocoaError(.fileWriteNoPermission) } },
            commit: { _ in committed = true })
        XCTAssertFalse(committed)
        XCTAssertEqual(failed.health, .failed)
        XCTAssertEqual(failed.writtenEvents, 1)
        XCTAssertNil(failed.committedCursor)
    }

    func testExitCodesMapToTheExistingHealthReceipts() async {
        for (outcome, health) in [(ProbeOutcome.backoff, TriggerProbeHealth.backingOff),
                                  (.authenticationNeeded, .authenticationRequired), (.failed, .failed)] {
            var committed = false
            let result = await TriggerProbeSourceRunner.poll(
                daemonSource(), cursor: nil, directory: directory.path, secrets: FakeSecrets(values: [:]),
                observedHash: "approved",
                run: { _ in ProbeRun(outcome: outcome, events: [], cursor: nil, diagnostics: "stderr") },
                write: { _, _ in }, commit: { _ in committed = true })
            XCTAssertEqual(result.health, health)
            XCTAssertEqual(result.diagnostic, "stderr")
            XCTAssertFalse(committed)
        }
    }

    func testSecretsResolveByNameIntoTheEnvironmentOnlyAndAreNeverEchoed() async {
        let source = daemonSource(secrets: ["IMAP_PASSWORD": "imap-support"])
        var environment: [String: String] = [:]
        let outcome = await TriggerProbeSourceRunner.poll(
            source, cursor: nil, directory: directory.path,
            secrets: FakeSecrets(values: ["imap-support": "hunter2"]), observedHash: "approved",
            run: { invocation in
                environment = invocation.environment
                return ProbeRun(outcome: .authenticationNeeded, events: [], cursor: nil, diagnostics: "login hunter2 refused")
            },
            write: { _, _ in }, commit: { _ in })
        XCTAssertEqual(environment, [
            "FOLDER": "INBOX", "IMAP_PASSWORD": "hunter2",
            "THREADING_SOURCE_ID": source.id.uuidString.lowercased(), "THREADING_SOURCE_REVISION": "3",
        ], "exactly the configured environment, the secret and the reserved identities; nothing inherited")
        XCTAssertEqual(outcome.diagnostic, "login [secret] refused")

        var ran = false
        let missing = await TriggerProbeSourceRunner.poll(
            source, cursor: nil, directory: directory.path, secrets: FakeSecrets(values: [:]),
            observedHash: "approved",
            run: { _ in ran = true; return ProbeRun(outcome: .healthy, events: [], cursor: "x", diagnostics: "") },
            write: { _, _ in }, commit: { _ in })
        XCTAssertFalse(ran)
        XCTAssertEqual(missing.health, .authenticationRequired)
        XCTAssertTrue(missing.diagnostic?.contains("imap-support") == true)
    }

    func testAProbeEventBecomesATypedTriggerEventTheEngineCanMatch() throws {
        let line = """
            {"event":{"id":"imap:INBOX:48213","revision":"2","occurredAt":"2026-10-03T09:12:00Z",\
            "fields":{"from":"kund@example.com","subject":"Faktura 1123","uid":48213,"score":0.5,"seen":false},\
            "evidence":"first lines of the body"}}
            {"cursor":"uidnext=48214"}

            """
        let event = try TriggerProbe.parse(Data(line.utf8), limit: 5).events[0]
        let sourceID = UUID()
        let envelope = TriggerProbeSourceRunner.inboxEvent(event, sourceID: sourceID, receivedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TriggerEvent.self, from: encoder.encode(envelope))

        XCTAssertEqual(decoded.sourceInstallationID.rawValue, sourceID)
        XCTAssertEqual(decoded.kind, TriggerProbeDefaults.eventKind)
        XCTAssertEqual(decoded.externalID, "imap:INBOX:48213")
        XCTAssertEqual(decoded.revision, "2")
        XCTAssertEqual(decoded.title, "Faktura 1123")
        XCTAssertEqual(decoded.occurredAt, ISO8601DateFormatter().date(from: "2026-10-03T09:12:00Z"))
        XCTAssertEqual(decoded.attributes["uid"], .integer(48213))
        XCTAssertEqual(decoded.attributes["score"], .decimal(0.5))
        XCTAssertEqual(decoded.attributes["seen"], .boolean(false))
        XCTAssertEqual(decoded.evidence, "first lines of the body")
        XCTAssertNil(decoded.attributes["evidence"], "evidence is never a matchable attribute")
        XCTAssertTrue(TriggerMatcher.matches(decoded, conditions: [
            TriggerCondition(attribute: "from", comparison: .equals, value: .string("kund@example.com")),
            TriggerCondition(attribute: "uid", comparison: .greaterThan, value: .integer(48000)),
        ]))
        XCTAssertFalse(TriggerMatcher.matches(decoded, conditions: [
            TriggerCondition(attribute: "body", comparison: .exists, value: nil),
        ]))
    }

    func testARealProbeProcessRunsThroughThePipeline() async throws {
        let path = try script("probe.sh", """
            read request
            echo "{\\"event\\":{\\"id\\":\\"one\\",\\"fields\\":{\\"folder\\":\\"$FOLDER\\",\\"home\\":\\"${HOME:-unset}\\"}}}"
            echo '{"cursor":"after-one"}'
            """)
        let hash = try TriggerProbe.contentHash(of: ["/bin/sh", path])
        let source = TriggerProbeDaemonSource(id: UUID(), revision: 1, spec: TriggerProbeRunSpec(spec(script: path)),
                                              approvedHash: hash, enabled: true)
        var written: [TriggerProbeInboxEvent] = []
        var cursor: String?
        let outcome = await TriggerProbeSourceRunner.poll(
            source, cursor: nil, directory: directory.path, secrets: FakeSecrets(values: [:]),
            observedHash: try TriggerProbe.contentHash(of: source.spec.hashedPaths),
            write: { event, _ in written.append(event) }, commit: { cursor = $0 })
        XCTAssertEqual(outcome.health, .healthy, outcome.diagnostic ?? "")
        XCTAssertEqual(cursor, "after-one")
        XCTAssertEqual(written.map(\.externalID), ["one"])
        XCTAssertEqual(written.first?.attributes["folder"], .string("INBOX"))
        XCTAssertEqual(written.first?.attributes["home"], .string("unset"), "the daemon's environment is not inherited")
    }

    func testABackoffKeepsGrowingToTheCeiling() {
        let start = Date(timeIntervalSince1970: 0)
        let probe = TriggerProbeRunSpec(spec())
        XCTAssertEqual(TriggerProbeSourceRunner.nextPoll(probe, after: start, failures: 0), start.addingTimeInterval(600))
        XCTAssertEqual(TriggerProbeSourceRunner.nextPoll(probe, after: start, failures: 1), start.addingTimeInterval(1_200))
        XCTAssertEqual(TriggerProbeSourceRunner.nextPoll(probe, after: start, failures: 9), start.addingTimeInterval(3_600))
    }

    // MARK: - Approval gating

    func testConfiguringPausesAndOnlyAnApprovalOfTheCurrentHashEnables() async throws {
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let path = try script("gate.sh", "echo '{\"cursor\":\"x\"}'\n")
        let configured = try await TriggerProbeSourceCommands.configure(
            id: nil, expectedRevision: 0, spec: spec(script: path), store: store)
        let probe = try XCTUnwrap(configured.probe)
        XCTAssertFalse(configured.enabled)
        XCTAssertNil(probe.approvedHash)
        XCTAssertEqual(probe.hash, try TriggerProbe.contentHash(of: [ "/bin/sh", path ]))

        do {
            _ = try await TriggerProbeSourceCommands.setEnabled(true, id: configured.id, expectedRevision: probe.revision, store: store)
            XCTFail("an unapproved probe was enabled")
        } catch { XCTAssertEqual(error as? TriggerProbeSourceCommands.Failure, .notApproved) }
        do {
            try await TriggerProbeSourceCommands.runNow(configured.id, store: store, request: { _ in XCTFail("polled") })
            XCTFail("an unapproved probe was polled")
        } catch { XCTAssertEqual(error as? TriggerProbeSourceCommands.Failure, .notApproved) }

        // The store is the last gate, whatever path writes.
        var forced = configured
        forced.enabled = true
        do { try await store.saveSource(forced); XCTFail("store saved an enabled unapproved probe") } catch {}

        do {
            _ = try await TriggerProbeSourceCommands.approve(configured.id, expectedRevision: probe.revision,
                                                             reviewedHash: "something else", enable: true, store: store)
            XCTFail("approved a hash nobody reviewed")
        } catch { XCTAssertEqual(error as? TriggerProbeSourceCommands.Failure, .hashChanged) }

        let approved = try await TriggerProbeSourceCommands.approve(
            configured.id, expectedRevision: probe.revision, reviewedHash: probe.hash, enable: true, store: store)
        XCTAssertTrue(approved.enabled)
        XCTAssertEqual(approved.probe?.isApproved, true)
        var polled: [TriggerSourceInstallationID] = []
        let recorder = PollRecorder()
        try await TriggerProbeSourceCommands.runNow(configured.id, store: store, request: { recorder.record($0) })
        polled = recorder.ids
        XCTAssertEqual(polled, [configured.id])

        // Any edit clears the approval and pauses it again.
        let edited = try await TriggerProbeSourceCommands.configure(
            id: configured.id, expectedRevision: approved.probe!.revision, spec: spec(script: path), store: store)
        XCTAssertFalse(edited.enabled)
        XCTAssertNil(edited.probe?.approvedHash)

        // A file changed on disk is re-hashed for review rather than approved by its old hash.
        try ("#!/bin/sh\necho changed\n").write(toFile: path, atomically: true, encoding: .utf8)
        let review = try await TriggerProbeSourceCommands.prepareReview(configured.id, store: store)
        XCTAssertNotEqual(review.probe?.hash, edited.probe?.hash)
        XCTAssertEqual(review.probe?.revision, edited.probe!.revision + 1)
    }

    func testAnAgentDraftIsPausedAndUnapprovedAndNoOperationApprovesIt() async throws {
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let path = try script("agent.sh", "echo '{\"cursor\":\"x\"}'\n")
        var arguments = AutomationToolArguments(operation: "draftSource")
        arguments.sourceSpec = spec(script: path, secrets: ["TOKEN": "feed-token"])
        let output = try await AutomationCommands.execute(arguments, store: store, approve: { _ in true })
        let snapshot = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(snapshot?["approved"] as? Bool, false)
        XCTAssertEqual(snapshot?["enabled"] as? Bool, false)
        let id = try XCTUnwrap(TriggerSourceInstallationID(uuidString: snapshot?["id"] as? String ?? ""))
        let stored = try await store.source(id: id)
        XCTAssertEqual(stored?.enabled, false)
        XCTAssertNil(stored?.probe?.approvedHash)

        // The automation operations act on automations, never on a source id.
        var enable = AutomationToolArguments(operation: "enable")
        enable.id = id.uuidString
        enable.expectedRevision = UUID().uuidString
        do { _ = try await AutomationCommands.execute(enable, store: store, approve: { _ in true }); XCTFail() } catch {}
        let after = try await store.source(id: id)
        XCTAssertEqual(after?.enabled, false)

        // A stale revision is refused.
        arguments.id = id.uuidString
        arguments.expectedRevision = "0"
        do { _ = try await AutomationCommands.execute(arguments, store: store); XCTFail("stale draft saved") } catch {}
    }

    func testTheEditorPutsTheScriptFirstSoTheHashedFileIsTheOneThatRuns() throws {
        let parsed = try TriggerProbeEditorForm.spec(
            name: " Mailbox ", executable: "/usr/bin/python3", script: "/Users/me/probe.py",
            arguments: "--folder\nINBOX\n", environment: "FOLDER=INBOX", secrets: "IMAP_PASSWORD=imap-support",
            timing: AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 15),
            timeoutSeconds: "", limit: "")
        XCTAssertEqual(parsed.arguments, ["/Users/me/probe.py", "--folder", "INBOX"])
        XCTAssertEqual(parsed.secrets, ["IMAP_PASSWORD": "imap-support"])
        XCTAssertEqual(parsed.intervalSeconds, 900)
        XCTAssertEqual(parsed.name, "Mailbox")
        XCTAssertThrowsError(try TriggerProbeSourceCommands.validate(ControllerSourceSpec(
            name: "x", executable: "/usr/bin/python3", script: "/a.py", arguments: ["/b.py"])))
    }

    func testTheEditorStatesACalendarScheduleWithTheAutomationEditorsPieces() throws {
        let weekly = AutomationSchedule(kind: .weekdays, timeZone: "Europe/Stockholm", hour: 7, minute: 30, days: [2, 3, 4, 5, 6])
        let parsed = try TriggerProbeEditorForm.spec(
            name: "Mailbox", executable: "/bin/sh", script: "", arguments: "", environment: "", secrets: "",
            timing: weekly, timeoutSeconds: "30", limit: "50")
        XCTAssertNil(parsed.intervalSeconds)
        XCTAssertEqual(parsed.schedule, weekly)

        let form = MainActor.assumeIsolated { TriggerProbeEditorForm(spec: parsed) }
        let roundTrip = try MainActor.assumeIsolated { try form.spec() }
        XCTAssertEqual(roundTrip.schedule?.kind, .weekdays)
        XCTAssertEqual(roundTrip.schedule?.hour, 7)
        XCTAssertEqual(roundTrip.schedule?.days, [2, 3, 4, 5, 6])
        MainActor.assumeIsolated {
            XCTAssertTrue(form.timing.time.isEnabled)
            XCTAssertFalse(form.timing.interval.isEnabled)
        }
    }

    // MARK: - Delete

    func testDeletingTombstonesAProbeStopsItsPollingAndKeepsItsEvents() async throws {
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let path = try script("del.sh", "echo '{\"cursor\":\"x\"}'\n")
        let configured = try await TriggerProbeSourceCommands.configure(id: nil, expectedRevision: 0, spec: spec(script: path), store: store)
        let approved = try await TriggerProbeSourceCommands.approve(
            configured.id, expectedRevision: configured.probe!.revision, reviewedHash: configured.probe!.hash, enable: true, store: store)
        let event = TriggerEvent(sourceInstallationID: configured.id, externalID: "kept", revision: "1",
                                 kind: TriggerProbeDefaults.eventKind, occurredAt: Date(), receivedAt: Date(), title: "kept",
                                 attributes: [:], deepLink: nil, resources: [])
        let first = try await store.accept(event)
        XCTAssertTrue(first)

        do {
            _ = try await TriggerProbeSourceCommands.delete(configured.id, expectedRevision: configured.probe!.revision, store: store)
            XCTFail("a stale revision deleted the probe")
        } catch { XCTAssertEqual(error as? TriggerProbeSourceCommands.Failure, .revisionChanged) }

        let deleted = try await TriggerProbeSourceCommands.delete(configured.id, expectedRevision: approved.probe!.revision, store: store)
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertFalse(deleted.enabled)
        XCTAssertNil(try TriggerDaemonConfigurationStore.configuration(for: [deleted]).probes, "polling stops")
        let again = try await store.accept(event)
        XCTAssertFalse(again, "the accepted event is still there")
        let stored = try await store.source(id: configured.id)
        XCTAssertEqual(stored?.isDeleted, true, "the record is a tombstone, not removed")

        for operation in [
            { _ = try await TriggerProbeSourceCommands.configure(id: configured.id, expectedRevision: deleted.probe!.revision, spec: self.spec(script: path), store: store) },
            { _ = try await TriggerProbeSourceCommands.setEnabled(true, id: configured.id, expectedRevision: deleted.probe!.revision, store: store) },
            { try await TriggerProbeSourceCommands.runNow(configured.id, store: store, request: { _ in }) },
        ] as [() async throws -> Void] {
            do { try await operation(); XCTFail("a deleted probe was revived") } catch {}
        }

        // An agent's draft cannot name it either, and no tool operation deletes.
        var draft = AutomationToolArguments(operation: "draftSource")
        draft.id = configured.id.uuidString
        draft.expectedRevision = String(deleted.probe!.revision)
        draft.sourceSpec = spec(script: path)
        do { _ = try await AutomationCommands.execute(draft, store: store); XCTFail("draft revived a deleted probe") } catch {}
        var remove = AutomationToolArguments(operation: "deleteSource")
        remove.id = configured.id.uuidString
        do { _ = try await AutomationCommands.execute(remove, store: store); XCTFail("an agent deleted a source") } catch {}
    }

    // MARK: - Sonda on the shared contract

    private static let sondaPage = """
        {"schemaVersion":1,"nextCursor":12,"events":[
          {"cursor":11,"caseID":"case-1042","reviewCycle":2,"occurredAt":"2026-10-03T09:12:00.250Z","title":"Report upload needs review",
           "portalURL":"https://demo.example.com/admin/case-1042","projectID":"p1","reportID":null,"uploadID":"u9"},
          {"cursor":12,"caseID":"case-1043","reviewCycle":1,"occurredAt":"2026-10-03T09:13:00Z","title":"Second"}]}
        """

    func testSondaKeepsItsIdentityRevisionKindAttributesAndLink() throws {
        let feed = try SondaFeedAdapter.decode(Data(Self.sondaPage.utf8), after: 10)
        let id = UUID()
        let report = SondaFeedAdapter.report(feed, sourceID: id, receivedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(report.outcome, .healthy)
        XCTAssertEqual(report.cursor, "12")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(TriggerEvent.self, from: encoder.encode(report.events[0]))
        XCTAssertEqual(first.externalID, "case-1042")
        XCTAssertEqual(first.revision, "2")
        XCTAssertEqual(first.kind, "case.review-required")
        XCTAssertEqual(first.title, "Report upload needs review")
        XCTAssertEqual(first.deepLink?.absoluteString, "https://demo.example.com/admin/case-1042")
        XCTAssertEqual(first.attributes, [
            "status": .string("needs_review"), "cursor": .integer(11), "review_cycle": .integer(2),
            "project_id": .string("p1"), "upload_id": .string("u9"),
        ])
        XCTAssertNil(first.evidence)
        // The envelope's JSON is the shape the compiled-in adapter wrote: no evidence key, and no
        // deepLink key when there is no link.
        let second = String(decoding: try encoder.encode(report.events[1]), as: UTF8.self)
        XCTAssertFalse(second.contains("evidence"))
        XCTAssertFalse(second.contains("deepLink"))
        XCTAssertTrue(second.contains("\"resources\":[]"))
    }

    func testSondaRefusesAPageWhoseCursorsDoNotAdvance() {
        let stale = Self.sondaPage.replacingOccurrences(of: "\"cursor\":11", with: "\"cursor\":9")
        XCTAssertThrowsError(try SondaFeedAdapter.decode(Data(stale.utf8), after: 10)) {
            XCTAssertEqual($0 as? SondaFeedAdapter.Failure, .invalidResponse)
        }
        let past = Self.sondaPage.replacingOccurrences(of: "\"nextCursor\":12", with: "\"nextCursor\":11")
        XCTAssertThrowsError(try SondaFeedAdapter.decode(Data(past.utf8), after: 10))
    }

    func testSondaCommitsItsCursorOnlyAfterTheInboxAndBacksOffOnAnInboxFailure() throws {
        let feed = try SondaFeedAdapter.decode(Data(Self.sondaPage.utf8), after: 10)
        let report = SondaFeedAdapter.report(feed, sourceID: UUID(), receivedAt: Date())
        var log: [String] = []
        let outcome = TriggerProbeSourceRunner.deliver(report, inboxFailure: .backingOff,
            write: { event, index in log.append("write \(event.externalID) \(feed.events[index].cursor)") },
            commit: { log.append("commit \($0)") })
        XCTAssertEqual(log, ["write case-1042 11", "write case-1043 12", "commit 12"])
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertNil(outcome.diagnostic)
        XCTAssertEqual(outcome.lastEventAt, feed.events.last?.occurredAt)

        var committed = false
        let failed = TriggerProbeSourceRunner.deliver(report, inboxFailure: .backingOff,
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, commit: { _ in committed = true })
        XCTAssertFalse(committed)
        XCTAssertEqual(failed.health, .backingOff)
    }
}

private final class PollRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TriggerSourceInstallationID] = []
    func record(_ id: TriggerSourceInstallationID) { lock.lock(); values.append(id); lock.unlock() }
    var ids: [TriggerSourceInstallationID] { lock.lock(); defer { lock.unlock() }; return values }
}
