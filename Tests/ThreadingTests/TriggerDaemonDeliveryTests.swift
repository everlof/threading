import XCTest
@testable import Threading

/// The file seams between `threading-triggerd` and the app: manual-poll requests survive busy
/// slots, and a bad inbox file is set aside without stopping the files behind it.
final class TriggerDaemonDeliveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerDaemonDelivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Poll requests

    func testPollRequestWhileEverySlotIsBusyIsKeptUntilItIsClaimed() throws {
        let requests = directory.appendingPathComponent("Poll Requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let probe = probe()
        let gone = UUID()
        for id in [probe.id, gone] {
            try Data().write(to: requests.appendingPathComponent(id.uuidString))
        }
        let busy: Set<UUID> = Set((0 ..< TriggerProbeDefaults.concurrentPolls).map { _ in UUID() })

        // Every slot busy: nothing is claimed, the configured probe's request stays, and the
        // request for a probe that is no longer configured is consumed.
        var pending = TriggerProbePollRequests.pending(in: requests)
        var claimed = TriggerProbeClaimPolicy.claim(
            [probe], manual: Set(pending.keys), inFlight: busy, due: { _ in .distantFuture }, now: Date()
        )
        XCTAssertTrue(claimed.isEmpty)
        TriggerProbePollRequests.settle(pending, claimed: [], configured: [probe.id])
        XCTAssertEqual(Set(TriggerProbePollRequests.pending(in: requests).keys), [probe.id])

        // The probe already polling: still kept, since the request may postdate that poll.
        pending = TriggerProbePollRequests.pending(in: requests)
        claimed = TriggerProbeClaimPolicy.claim(
            [probe], manual: Set(pending.keys), inFlight: [probe.id], due: { _ in .distantFuture }, now: Date()
        )
        XCTAssertTrue(claimed.isEmpty)
        TriggerProbePollRequests.settle(pending, claimed: [], configured: [probe.id])
        XCTAssertEqual(Set(TriggerProbePollRequests.pending(in: requests).keys), [probe.id])

        // A free slot: claimed as manual, and only then consumed.
        pending = TriggerProbePollRequests.pending(in: requests)
        claimed = TriggerProbeClaimPolicy.claim(
            [probe], manual: Set(pending.keys), inFlight: [], due: { _ in .distantFuture }, now: Date()
        )
        XCTAssertEqual(claimed.map(\.probe.id), [probe.id])
        XCTAssertEqual(claimed.map(\.manual), [true])
        TriggerProbePollRequests.settle(
            pending, claimed: Set(claimed.filter(\.manual).map(\.probe.id)), configured: [probe.id]
        )
        XCTAssertTrue(TriggerProbePollRequests.pending(in: requests).isEmpty)
    }

    func testPollRequestsLeaveFilesThatAreNotProbeIDs() throws {
        let requests = directory.appendingPathComponent("Poll Requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let partial = requests.appendingPathComponent("write-in-progress")
        try Data().write(to: partial)

        let pending = TriggerProbePollRequests.pending(in: requests)
        TriggerProbePollRequests.settle(pending, claimed: [], configured: [])

        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - Inbox

    func testUndecodableAndInvalidInboxFilesAreQuarantinedWhileGoodOnesIngest() async throws {
        let fixture = try QueueFixture()
        addTeardownBlock { await fixture.remove() }
        let source = try await fixture.source()
        let inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let secret = "do-not-journal-this-content"
        // Sorted first, so before the fix the whole read failed on it and nothing behind it ran.
        try Data("{\"\(secret)\": true".utf8).write(to: inbox.appendingPathComponent("0000-corrupt.json"))
        let good = [
            fixture.event(sourceID: source.id, externalID: "good-1"),
            fixture.event(sourceID: source.id, externalID: "good-2"),
        ]
        let oversized = fixture.event(
            sourceID: source.id,
            externalID: "oversized",
            title: String(repeating: "x", count: 2_048)
        )
        try write(good[0], to: inbox.appendingPathComponent("0001-good.json"))
        try write(oversized, to: inbox.appendingPathComponent("0002-oversized.json"))
        try write(good[1], to: inbox.appendingPathComponent("0003-good.json"))
        let journal = EventLog(directory: directory.appendingPathComponent("Logs", isDirectory: true))

        await TriggerRuntime(store: fixture.store).drainDaemonInbox(directory: inbox, journal: journal)

        for event in good {
            let stored = try await fixture.store.event(key: event.storageKey)
            XCTAssertNotNil(stored)
        }
        let storedOversized = try await fixture.store.event(key: oversized.storageKey)
        XCTAssertNil(storedOversized)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(remaining, [])
        let quarantine = inbox.appendingPathComponent(TriggerDaemonInbox.quarantineDirectoryName)
        let setAside = try FileManager.default.contentsOfDirectory(atPath: quarantine.path).sorted()
        XCTAssertEqual(setAside.count, 2)
        XCTAssertTrue(setAside.contains { $0.hasSuffix("0000-corrupt.json") })
        XCTAssertTrue(setAside.contains { $0.hasSuffix("0002-oversized.json") })

        let log = try String(contentsOf: journal.currentJournalURL, encoding: .utf8)
        XCTAssertTrue(log.contains("Quarantined a trigger inbox file"))
        XCTAssertTrue(log.contains("undecodable"))
        XCTAssertTrue(log.contains("invalid"))
        XCTAssertFalse(log.contains(secret))
        XCTAssertFalse(log.contains("good-1"))
    }

    func testQuarantineKeepsABoundedNumberOfFiles() throws {
        let inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let journal = EventLog(directory: directory.appendingPathComponent("Logs", isDirectory: true))
        let total = TriggerDaemonInbox.quarantineLimit + 3
        for index in 0 ..< total {
            try Data("not json".utf8).write(to: inbox.appendingPathComponent(String(format: "%04d.json", index)))
        }

        var examined = 0
        while true {
            let page = try TriggerDaemonInbox.load(directory: inbox, journal: journal)
            XCTAssertTrue(page.items.isEmpty)
            examined += page.examined
            guard page.examined == TriggerDaemonInbox.pageLimit else { break }
        }

        XCTAssertEqual(examined, total)
        let quarantine = inbox.appendingPathComponent(TriggerDaemonInbox.quarantineDirectoryName)
        let kept = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
        XCTAssertEqual(kept.count, TriggerDaemonInbox.quarantineLimit)
    }

    // MARK: - Fixtures

    private func probe() -> TriggerProbeDaemonSource {
        TriggerProbeDaemonSource(
            id: UUID(),
            revision: 1,
            spec: TriggerProbeRunSpec(
                executable: "/bin/sh", script: nil, arguments: [], environment: [:], secrets: [:],
                intervalSeconds: 600, schedule: nil, timeoutSeconds: 10, limit: 50
            ),
            approvedHash: "approved",
            enabled: true
        )
    }

    private func write(_ event: TriggerEvent, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(event).write(to: file)
    }
}
