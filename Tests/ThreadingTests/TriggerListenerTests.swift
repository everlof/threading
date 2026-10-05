import Foundation
import Security
import ThreadingController
import XCTest
@testable import Threading

/// `threading-triggerd` has to launch, read the secrets the app stored, and say so when it
/// cannot. From 2026-09-12 to 2026-10-05 it did none of that: a profile-backed
/// `keychain-access-groups` entitlement on a bare helper made launchd's every spawn end in
/// OS_REASON_CODESIGNING, while ServiceManagement reported it enabled and every source read
/// "Checking". These tests pin the replacement: login-Keychain items the listener reads without an
/// entitlement, and a listener state built from its heartbeat and launchd's own answer.
///
/// No test here touches the developer's Keychain: the stores run against `FakeKeychain`.
@MainActor
final class TriggerListenerTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    // MARK: - Fixtures

    /// An in-memory login Keychain that answers the query shapes the stores send and records
    /// each one. `unreadable` accounts refuse their data the way an item whose access list does
    /// not name the reader does.
    private final class FakeKeychain: TriggerSecretKeychainAccessing, @unchecked Sendable {
        struct Item {
            var data: Data
            var marker: Data?
            var hasAccessList: Bool
        }

        var items: [String: [String: Item]] = [:]
        var unreadable: Set<String> = []
        /// Refuses the next add only, as a Keychain that rejects one write would.
        var failNextAdd = false
        private(set) var queries: [[String: Any]] = []
        private(set) var deletes: [[String: Any]] = []
        /// For each value requested, whether a real keychain could have prompted for it.
        private(set) var dataReadsAllowingInteraction: [Bool] = []

        func store(_ value: String, service: TriggerSecretService, account: String, marked: Bool) {
            items[service.service, default: [:]][account] = Item(
                data: Data(value.utf8), marker: marked ? TriggerSecretKeychain.formatMarker : nil,
                hasAccessList: marked)
        }

        func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
            queries.append(query)
            guard let service = query[kSecAttrService as String] as? String else { return (errSecParam, nil) }
            let matching = (items[service] ?? [:]).filter { account, _ in
                (query[kSecAttrAccount as String] as? String).map { $0 == account } ?? true
            }
            guard !matching.isEmpty else { return (errSecItemNotFound, nil) }
            if query[kSecReturnData as String] as? Bool == true {
                dataReadsAllowingInteraction.append(KeychainInteractionGate.interactionAllowed)
                guard let (account, item) = matching.first else { return (errSecItemNotFound, nil) }
                if unreadable.contains(account) { return (errSecAuthFailed, nil) }
                return (errSecSuccess, item.data as NSData)
            }
            let attributes: [[String: Any]] = matching.map { account, item in
                var row: [String: Any] = [kSecAttrAccount as String: account]
                if let marker = item.marker { row[kSecAttrGeneric as String] = marker }
                return row
            }
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                return (errSecSuccess, attributes as NSArray)
            }
            return (errSecSuccess, attributes.first.map { $0 as NSDictionary })
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            queries.append(attributes)
            if failNextAdd {
                failNextAdd = false
                return errSecIO
            }
            guard let service = attributes[kSecAttrService as String] as? String,
                  let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            guard items[service]?[account] == nil else { return errSecDuplicateItem }
            items[service, default: [:]][account] = Item(
                data: data, marker: attributes[kSecAttrGeneric as String] as? Data,
                hasAccessList: attributes[kSecAttrAccess as String] != nil)
            return errSecSuccess
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            deletes.append(query)
            guard let service = query[kSecAttrService as String] as? String, items[service] != nil else {
                return errSecItemNotFound
            }
            if let account = query[kSecAttrAccount as String] as? String {
                return items[service]?.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
            }
            items.removeValue(forKey: service)
            return errSecSuccess
        }
    }

    /// A real access list, built without touching any keychain: this test host and an
    /// Apple-signed tool stand in for the app and its listener.
    nonisolated private static func accessList() throws -> SecAccess {
        try TriggerSecretAccessList.make(listener: URL(fileURLWithPath: "/bin/ls"))
    }

    private func store(_ keychain: FakeKeychain) -> TriggerSecretStore {
        TriggerSecretStore(keychain: keychain, accessList: { try Self.accessList() })
    }

    private static func probe(approved: Bool = true, enabled: Bool = true, health: TriggerSourceHealth = .checking) -> TriggerSourceInstallation {
        let spec = ControllerSourceSpec(name: "Ordus issues", executable: "/opt/homebrew/bin/python3",
                                        script: "/tmp/watch.py", arguments: ["/tmp/watch.py"],
                                        environment: [:], secrets: [:], intervalSeconds: 300,
                                        timeoutSeconds: 120, limit: 20)
        return TriggerSourceInstallation(
            id: TriggerSourceInstallationID(), sourceType: TriggerProbeDefaults.sourceType, displayName: "Ordus issues",
            configuration: [:], credentialReference: nil, enabled: enabled, health: health,
            lastCheckedAt: nil, lastEventAt: nil, boundedDiagnostic: nil, createdAt: now, updatedAt: now,
            probe: TriggerProbeSourceSettings(spec: spec, revision: 2, hash: "12af", approvedHash: approved ? "12af" : nil))
    }

    private static func status(_ source: TriggerSourceInstallation, _ health: TriggerSourceHealth,
                               diagnostic: String? = nil) -> TriggerDaemonSourceStatus {
        TriggerDaemonSourceStatus(sourceInstallationID: source.id, health: health,
                                  lastCheckedAt: now.addingTimeInterval(60), lastEventAt: nil,
                                  boundedDiagnostic: diagnostic)
    }

    private static func heartbeat(age: TimeInterval) -> TriggerListenerHeartbeat {
        TriggerListenerHeartbeat(processIdentifier: 4242, startedAt: now.addingTimeInterval(-3_600),
                                 heartbeatAt: now.addingTimeInterval(-age))
    }

    /// What launchd printed for the listener on 2026-10-05, nested blocks and all.
    private static let refusedJob = """
        gui/501/codes.threading.triggerd = {
        \tactive count = 0
        \tpath = (submitted by smd.324)
        \ttype = Submitted
        \tstate = spawn scheduled

        \tprogram identifier = Contents/Helpers/threading-triggerd (mode: 2)
        \targuments = {
        \t\tContents/Helpers/threading-triggerd
        \t}

        \truns = 153
        \tlast exit reason = OS_REASON_CODESIGNING

        \tresource coalition = {
        \t\tID = 45460
        \t\tstate = active
        \t}
        \tjob state = spawn failed
        }
        """

    // MARK: - The entitlement that stopped every launch

    func testTheListenerDeclaresNoEntitlementThatNeedsAProfile() throws {
        let declaration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Targets/TriggerDaemon/threading-triggerd.entitlements")
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: declaration), format: nil) as? [String: Any])
        // A bare executable in Contents/Helpers cannot embed the profile these keys need, so AMFI
        // kills it at launch while its signature still verifies.
        let restricted = entitlements.keys.filter {
            $0.hasPrefix("com.apple.developer.") || $0 == "keychain-access-groups"
                || $0 == "com.apple.security.application-groups"
        }
        XCTAssertEqual(restricted, [])
    }

    // MARK: - Secrets

    func testTheListenerReadsTheLoginKeychainAndNamesNoAccessGroup() throws {
        let keychain = FakeKeychain()
        keychain.store("bearer", service: .sourceCredential, account: "ref-1", marked: true)
        keychain.store("hunter2", service: .probeSecret, account: "imap-support", marked: true)

        XCTAssertEqual(try TriggerSecretKeychain.read(.sourceCredential, account: "ref-1", keychain: keychain), "bearer")
        XCTAssertEqual(try KeychainTriggerProbeSecrets(keychain: keychain).value(forSecret: "imap-support"), "hunter2")

        XCTAssertEqual(keychain.queries.count, 2)
        for query in keychain.queries {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
            XCTAssertNil(query[kSecAttrAccessGroup as String], "an access group needs an entitlement the listener cannot carry")
        }
        XCTAssertEqual(keychain.queries.map { $0[kSecAttrService as String] as? String },
                       ["codes.threading.trigger-source", "codes.threading.trigger-probe-secret"])
    }

    func testAnUnreadableSecretFailsThePollAsAuthenticationRequiredAndNamesOnlyTheSecret() async throws {
        let keychain = FakeKeychain()
        keychain.store("hunter2", service: .probeSecret, account: "imap-support", marked: false)
        keychain.unreadable = ["imap-support"]

        XCTAssertThrowsError(try TriggerSecretKeychain.read(.probeSecret, account: "imap-support", keychain: keychain)) {
            XCTAssertEqual($0 as? TriggerSecretReadFailure,
                           TriggerSecretReadFailure(service: .probeSecret, name: "imap-support", reason: .refused))
        }
        XCTAssertEqual(TriggerSecretReadFailure(service: .probeSecret, name: "x", status: errSecItemNotFound).reason, .missing)
        XCTAssertEqual(TriggerSecretReadFailure(service: .probeSecret, name: "x", status: errSecInteractionNotAllowed).reason, .refused)
        XCTAssertEqual(TriggerSecretReadFailure(service: .probeSecret, name: "x", status: errSecParam).reason, .keychain(errSecParam))

        let spec = TriggerProbeRunSpec(executable: "/bin/sh", script: nil, arguments: [], environment: [:],
                                       secrets: ["IMAP_PASSWORD": "imap-support"], intervalSeconds: 300,
                                       schedule: nil, timeoutSeconds: 5, limit: 5)
        let source = TriggerProbeDaemonSource(id: UUID(), revision: 1, spec: spec, approvedHash: "h", enabled: true)
        let outcome = await Self.pollWithUnreadableSecret(source, keychain: keychain)
        XCTAssertEqual(outcome.health, .authenticationRequired)
        let diagnostic = try XCTUnwrap(outcome.diagnostic)
        XCTAssertTrue(diagnostic.contains("imap-support"))
        XCTAssertFalse(diagnostic.contains("hunter2"))
    }

    /// The listener polls on its worker; its callbacks are not main-actor test closures.
    nonisolated private static func pollWithUnreadableSecret(
        _ source: TriggerProbeDaemonSource,
        keychain: FakeKeychain
    ) async -> TriggerProbePollOutcome {
        await TriggerProbeSourceRunner.poll(
            source, cursor: nil, directory: NSTemporaryDirectory(),
            secrets: KeychainTriggerProbeSecrets(keychain: keychain), observedHash: "h",
            run: { _ in
                XCTFail("a probe never runs without the secrets it was configured with")
                return ProbeRun(outcome: .healthy, events: [], cursor: "c", diagnostics: "")
            },
            write: { _, _ in }, commit: { _ in })
    }

    func testSavingReplacesTheItemWithOneTheListenerMayRead() throws {
        let keychain = FakeKeychain()
        keychain.store("old", service: .probeSecret, account: "imap-support", marked: false)

        try store(keychain).save("new", service: .probeSecret, account: "imap-support")

        // An update would keep the earlier item's access list, which names only the app.
        XCTAssertEqual(keychain.deletes.count, 1)
        let added = try XCTUnwrap(keychain.queries.last)
        XCTAssertNotNil(added[kSecAttrAccess as String])
        XCTAssertNil(added[kSecAttrAccessGroup as String])
        XCTAssertEqual(added[kSecUseDataProtectionKeychain as String] as? Bool, false)
        XCTAssertEqual(added[kSecAttrGeneric as String] as? Data, TriggerSecretKeychain.formatMarker)
        let item = try XCTUnwrap(keychain.items["codes.threading.trigger-probe-secret"]?["imap-support"])
        XCTAssertEqual(String(decoding: item.data, as: UTF8.self), "new")
        XCTAssertTrue(item.hasAccessList)
        XCTAssertTrue(store(keychain).exists(service: .probeSecret, account: "imap-support"))
    }

    func testABuildWithNoListenerToNameKeepsTheStoredItem() {
        let keychain = FakeKeychain()
        keychain.store("old", service: .sourceCredential, account: "ref-1", marked: true)
        let store = TriggerSecretStore(keychain: keychain, accessList: { throw TriggerSecretStoreError.accessList(errSecParam) })

        XCTAssertThrowsError(try store.save("new", service: .sourceCredential, account: "ref-1"))
        XCTAssertTrue(keychain.deletes.isEmpty)
        XCTAssertEqual(keychain.items["codes.threading.trigger-source"]?["ref-1"]?.data, Data("old".utf8))
    }

    func testMigrationRewritesEarlierItemsAndKeepsWhatItCannotReadWithoutAPrompt() throws {
        let keychain = FakeKeychain()
        // Stored by an earlier build: its access group was ignored outside the data-protection
        // Keychain, so the item names only the app.
        keychain.store("bearer", service: .sourceCredential, account: "ref-1", marked: false)
        keychain.store("current", service: .probeSecret, account: "already", marked: true)
        keychain.store("foreign", service: .probeSecret, account: "debug-build", marked: false)
        keychain.unreadable = ["debug-build"]
        let interactionBefore = KeychainInteractionGate.interactionAllowed

        let result = store(keychain).migrateEarlierItems()

        XCTAssertEqual(result, .init(rewritten: 1, unreadable: 1))
        let migrated = try XCTUnwrap(keychain.items["codes.threading.trigger-source"]?["ref-1"])
        XCTAssertEqual(migrated.marker, TriggerSecretKeychain.formatMarker)
        XCTAssertTrue(migrated.hasAccessList)
        XCTAssertEqual(String(decoding: migrated.data, as: UTF8.self), "bearer")
        XCTAssertNotNil(keychain.items["codes.threading.trigger-probe-secret"]?["debug-build"], "unread, so untouched")
        XCTAssertFalse(keychain.deletes.contains { $0[kSecAttrAccount as String] as? String == "already" })
        // A launch-time pass must never put a keychain dialog in front of the person: every
        // value it asked for was asked for with interaction switched off, and the switch is
        // back where it was afterwards.
        XCTAssertEqual(keychain.dataReadsAllowingInteraction, [false, false])
        XCTAssertEqual(KeychainInteractionGate.interactionAllowed, interactionBefore)

        XCTAssertNil(store(keychain).migrateEarlierItemsAtLaunch(automatedRun: true),
                     "an automated run never rewrites the developer's real items")
        XCTAssertEqual(store(keychain).migrateEarlierItemsAtLaunch(automatedRun: false),
                       .init(rewritten: 0, unreadable: 1),
                       "a repeat touches only the item still without the marker, and silently")
    }

    func testAFailedRewritePutsTheValueBack() throws {
        let keychain = FakeKeychain()
        keychain.store("bearer", service: .sourceCredential, account: "ref-1", marked: false)
        // The rewrite removes the old item and then fails to add its replacement.
        keychain.failNextAdd = true

        XCTAssertEqual(store(keychain).migrateEarlierItems(), .init(rewritten: 0, unreadable: 1))

        let restored = try XCTUnwrap(keychain.items["codes.threading.trigger-source"]?["ref-1"])
        XCTAssertEqual(restored.data, Data("bearer".utf8))
        XCTAssertNil(restored.marker, "left as it was, for the person to set again")
    }

    // MARK: - Listener state

    func testLaunchdsAnswerIsReadFromTheJobsOwnLines() throws {
        let job = try XCTUnwrap(TriggerListenerLaunchJob.parse(Self.refusedJob))
        XCTAssertEqual(job.state, "spawn scheduled", "not the coalition's nested `state = active`")
        XCTAssertEqual(job.jobState, "spawn failed")
        XCTAssertEqual(job.runs, 153)
        XCTAssertEqual(job.lastExitReason, "OS_REASON_CODESIGNING")
        XCTAssertNil(job.processIdentifier)
        XCTAssertTrue(job.spawnFailed)
        XCTAssertNil(TriggerListenerLaunchJob.parse("Bad request.\nCould not find service \"codes.threading.triggerd\" in domain for user gui: 501\n"))
    }

    func testAnEnabledRegistrationIsNotARunningListener() throws {
        func state(_ registration: TriggerDaemonRegistrationStatus = .enabled,
                   heartbeat: TriggerListenerHeartbeat? = nil,
                   job: TriggerListenerLaunchJob? = nil) -> TriggerListenerState {
            TriggerListenerState.classify(.init(registration: registration, heartbeat: heartbeat, launchJob: job),
                                          now: Self.now)
        }
        let refused = try XCTUnwrap(TriggerListenerLaunchJob.parse(Self.refusedJob))

        XCTAssertEqual(state(job: refused), .refused(reason: "OS_REASON_CODESIGNING", attempts: 153))
        XCTAssertFalse(state(job: refused).isListening)
        XCTAssertTrue(state(job: refused).diagnostic.contains("OS_REASON_CODESIGNING"))
        XCTAssertNil(state(job: refused).action, "registering again does not change what macOS accepts")

        XCTAssertEqual(state(heartbeat: Self.heartbeat(age: 20), job: refused), .running, "a fresh beat is proof")
        XCTAssertEqual(state(heartbeat: Self.heartbeat(age: 600)),
                       .stopped(lastReport: Self.now.addingTimeInterval(-600), exitCode: nil))
        XCTAssertEqual(state(heartbeat: Self.heartbeat(age: -3_600)),
                       .stopped(lastReport: Self.now.addingTimeInterval(3_600), exitCode: nil),
                       "a beat from the future is not fresh")
        XCTAssertEqual(state(job: .init(state: "running", processIdentifier: 99)), .running,
                       "a listener from before heartbeats")
        XCTAssertEqual(state(heartbeat: Self.heartbeat(age: 600), job: .init(state: "running", processIdentifier: 99)),
                       .stopped(lastReport: Self.now.addingTimeInterval(-600), exitCode: nil), "running but silent")
        XCTAssertEqual(state(job: .init(state: "spawn scheduled", runs: 0)), .starting)
        XCTAssertEqual(state(job: .init(state: "not running", lastExitCode: "1")),
                       .stopped(lastReport: nil, exitCode: "1"))
        XCTAssertEqual(state(.requiresApproval, job: refused), .requiresApproval)
        XCTAssertEqual(state(.notRegistered), .notRegistered)
        XCTAssertEqual(state(.missingHelper), .missingHelper)
        XCTAssertEqual(state(.requiresApproval).action, .openLoginItems)
        XCTAssertEqual(state(.notRegistered).action, .restartListener)
    }

    func testAnUnregisteredListenerWithNothingToDoIsIdleNotBroken() throws {
        // The app unregisters the listener when nothing needs it, so on a Mac with no source
        // and no schedule "not registered" is the healthy state and offers no repair.
        let empty = try TriggerDaemonConfigurationStore.configuration(for: [])
        XCTAssertFalse(empty.needsListener)
        XCTAssertTrue(try TriggerDaemonConfigurationStore.configuration(for: [], nextScheduleAt: Self.now).needsListener)
        XCTAssertTrue(try TriggerDaemonConfigurationStore.configuration(for: [Self.probe()]).needsListener,
                      "an approved, enabled probe")
        XCTAssertFalse(try TriggerDaemonConfigurationStore.configuration(for: [Self.probe(enabled: false)]).needsListener,
                       "an approved probe that is paused")

        func state(_ registration: TriggerDaemonRegistrationStatus, needed: Bool) -> TriggerListenerState {
            TriggerListenerState.classify(.init(registration: registration, needed: needed), now: Self.now)
        }
        let idle = state(.notRegistered, needed: false)
        XCTAssertEqual(idle, .idle)
        XCTAssertNil(idle.action)
        XCTAssertEqual(idle.wireValue, "idle")
        XCTAssertEqual(state(.notFound, needed: false), .idle)
        XCTAssertEqual(state(.notRegistered, needed: true), .notRegistered, "needed and missing is a failure")
        XCTAssertEqual(state(.notRegistered, needed: true).action, .restartListener)
        XCTAssertEqual(state(.requiresApproval, needed: false), .requiresApproval)
        XCTAssertEqual(TriggerListenerReading(registration: .notRegistered).needed, true,
                       "an unreadable configuration is never explained away as idle")
    }

    func testTheHeartbeatRoundTripsInTheDaemonsSpelling() throws {
        let beat = Self.heartbeat(age: 0)
        let json = try XCTUnwrap(String(data: try beat.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"heartbeatAt\":\"2026-"), json)
        XCTAssertEqual(try TriggerListenerHeartbeat.decode(beat.encoded()), beat)
    }

    // MARK: - What the person and an agent are told

    func testSourcesTheListenerWouldPollAreReportedNotCheckedWhileItIsDown() {
        let approved = Self.probe()
        let draft = Self.probe(approved: false, enabled: false)
        let down = TriggerSourceReceipts(statuses: [:], listener: .refused(reason: "OS_REASON_CODESIGNING", attempts: 3))
        let up = TriggerSourceReceipts(
            statuses: [approved.id: Self.status(approved, .authenticationRequired, diagnostic: "Secret “x” is not set.")],
            listener: .running)

        XCTAssertEqual(down.report(for: approved).health, "not_checked")
        XCTAssertTrue(down.report(for: approved).diagnostic?.contains("OS_REASON_CODESIGNING") == true)
        XCTAssertEqual(down.report(for: draft).health, "checking", "a draft is not polled either way")
        XCTAssertEqual(up.report(for: approved).health, "authenticationRequired")
        XCTAssertEqual(up.report(for: approved).diagnostic, "Secret “x” is not set.")
    }

    func testAProbeRowSaysItIsNotCheckedInsteadOfCheckingForever() {
        let source = Self.probe()
        let refused = TriggerListenerState.refused(reason: "OS_REASON_CODESIGNING", attempts: 87)

        let down = TriggerProbePresentation.row(source, daemonStatus: nil, listener: refused)
        XCTAssertTrue(down.detail.contains(L10n.string("Not checked")), down.detail)
        XCTAssertFalse(down.detail.contains(L10n.string("Checking")), down.detail)
        XCTAssertTrue(down.detail.contains(refused.sourceConsequence))

        let up = TriggerProbePresentation.row(source, daemonStatus: nil, listener: .running)
        XCTAssertTrue(up.detail.contains(L10n.string("Checking")), up.detail)
    }

    func testEachSourceProblemNamesTheHostFlowThatFixesIt() throws {
        func attention(_ source: TriggerSourceInstallation, _ status: TriggerDaemonSourceStatus? = nil,
                       listener: TriggerListenerState = .running) -> TriggerSourceAttention? {
            TriggerSourceAttention.evaluate(source, daemonStatus: status, listener: listener)
        }
        let unapproved = Self.probe(approved: false, enabled: false)
        XCTAssertEqual(attention(unapproved)?.problem, .needsApproval)
        XCTAssertEqual(attention(unapproved)?.action, .review, "approval goes through the host's sheet")
        XCTAssertEqual(attention(unapproved, listener: .missingHelper)?.problem, .needsApproval,
                       "the first thing to fix is the one the person can")

        let approved = Self.probe()
        XCTAssertEqual(attention(approved, Self.status(approved, .changed))?.problem, .changed)
        XCTAssertEqual(attention(approved, Self.status(approved, .changed))?.action, .review)
        XCTAssertEqual(attention(Self.probe(enabled: false))?.action, .resume)
        XCTAssertNil(attention(approved), "approved, enabled and waiting for its first poll")
        XCTAssertNil(attention(approved, Self.status(approved, .healthy)))

        let failing = try XCTUnwrap(attention(approved, Self.status(approved, .failed, diagnostic: "exit 1")))
        XCTAssertEqual(failing.problem, .unhealthy(.failed))
        XCTAssertEqual(failing.consequence, "exit 1")
        XCTAssertNil(failing.action)

        let refused = TriggerListenerState.refused(reason: "OS_REASON_CODESIGNING", attempts: 87)
        let notPolled = try XCTUnwrap(attention(approved, listener: refused))
        XCTAssertEqual(notPolled.problem, .notPolling(refused))
        XCTAssertEqual(notPolled.consequence, L10n.string("Not checked: macOS refuses to start the background listener."))
        XCTAssertEqual(attention(approved, listener: .requiresApproval)?.action, .openLoginItems)

        var sonda = Self.probe()
        sonda.sourceType = "sonda"
        sonda.probe = nil
        XCTAssertEqual(attention(sonda)?.problem, .disconnected)
        XCTAssertEqual(attention(sonda)?.action, .reconnect)
        sonda.credentialReference = "ref-1"
        sonda.enabled = false
        XCTAssertEqual(attention(sonda)?.action, .resume)
    }
}
