import Foundation
import XCTest
import ThreadingDomain
@testable import ThreadingController

final class ControllerAutomationTests: XCTestCase {
    func testScheduleDSTAndIntervalDoNotDrift() throws {
        let iso = ISO8601DateFormatter()
        let daily = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm")
        XCTAssertEqual(try daily.next(after: iso.date(from: "2026-03-28T08:00:00Z")!), iso.date(from: "2026-03-29T07:00:00Z"))
        XCTAssertEqual(try daily.next(after: iso.date(from: "2026-10-24T07:00:00Z")!), iso.date(from: "2026-10-25T08:00:00Z"))
        let repeated = AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30)
        XCTAssertEqual(try repeated.next(after: iso.date(from: "2026-10-25T00:30:00Z")!), iso.date(from: "2026-10-26T01:30:00Z"))
        let interval = AutomationSchedule(kind: .interval, timeZone: "UTC", intervalMinutes: 60, anchor: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try interval.next(after: Date(timeIntervalSince1970: 3_650)).timeIntervalSince1970, 7_200)
    }
    func testDueAdmissionRestartOverlapPauseAndStaleEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("controller.db").path
        let store = try ControllerStore(path: path)
        let worker = WorkerID()
        _ = try await store.addWorker(id: worker, name: "Reports")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = AutomationID()
        let spec = ControllerAutomationSpec(name: "Hourly", workerID: worker, instruction: "Prepare a report",
            schedule: .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now), missedPolicy: .latest)
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: spec, now: now)
        let enabled = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: now)
        XCTAssertEqual(enabled.nextRunAt, now.addingTimeInterval(60))
        let due = try await store.tickAutomations(now: now.addingTimeInterval(60))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.admission, "enqueued")
        let restarted = try ControllerStore(path: path)
        let duplicate = try await restarted.tickAutomations(now: now.addingTimeInterval(60))
        XCTAssertTrue(duplicate.isEmpty)
        let overlap = try await restarted.tickAutomations(now: now.addingTimeInterval(600))
        XCTAssertEqual(overlap.first?.admission, "overlap")
        let works = try await store.works(workerID: worker)
        XCTAssertEqual(works.items.count, 1)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 2, enabled: false)
        do { _ = try await store.configureAutomation(id, expectedRevision: 2, spec: spec); XCTFail("stale edit accepted") }
        catch { XCTAssertEqual(error as? ControllerError, .conflict) }
        let paused = try await store.tickAutomations(now: now.addingTimeInterval(1_000))
        XCTAssertTrue(paused.isEmpty)
        let runs = try await store.automationRuns(id)
        XCTAssertEqual(runs.items.count, 2)
        XCTAssertFalse(runs.items.contains { $0.archived })
    }
    func testMissedSkipAndRunNowRetryAndArchiveRequiresDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControllerStore(path: directory.appendingPathComponent("db").path)
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)), now: now)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: now)
        let missed = try await store.tickAutomations(now: now.addingTimeInterval(600))
        XCTAssertEqual(missed.first?.admission, "missed")
        let first = try await store.runAutomation(id, expectedRevision: 2, key: "request-1", now: now)
        let retry = try await store.runAutomation(id, expectedRevision: 2, key: "request-1", now: now)
        XCTAssertEqual(first, retry)
        let claim = try await store.claim(workerID: worker)
        let execution = try XCTUnwrap(claim?.execution.id)
        let delivery = try await store.finish(executionID: execution, destination: "inbox", payload: "Done")
        let pending = try await store.automationRuns(id)
        XCTAssertFalse(try XCTUnwrap(pending.items.last).archived)
        let sending = try await store.beginDelivery(delivery.id)
        _ = try await store.acknowledgeDelivery(delivery.id, attemptID: XCTUnwrap(sending.attemptID), receipt: "stored")
        let completed = try await store.automationRuns(id)
        XCTAssertTrue(try XCTUnwrap(completed.items.last).archived)
        _ = try await store.deleteAutomation(id, expectedRevision: 2)
        let retained = try await store.automationRuns(id)
        XCTAssertEqual(retained.items.count, 2)
    }
    private func scratchStore() throws -> (URL, ControllerStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try ControllerStore(path: directory.appendingPathComponent("controller.db").path))
    }
    func testRepeatedHourDoesNotRunTwice() async throws {
        let (directory, store) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let iso = ISO8601DateFormatter()
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let id = AutomationID()
        let before = iso.date(from: "2026-10-24T12:00:00Z")!
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Night", workerID: worker,
            instruction: "Report", schedule: .init(kind: .daily, timeZone: "Europe/Stockholm", hour: 2, minute: 30)), now: before)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: before)
        // The supervisor wakes a moment after the first 02:30; the second 02:30 is an hour later.
        let fired = try await store.tickAutomations(now: iso.date(from: "2026-10-25T00:30:02Z")!)
        XCTAssertEqual(fired.count, 1)
        let next = try await store.automation(id).nextRunAt
        XCTAssertEqual(next, iso.date(from: "2026-10-26T01:30:00Z"))
    }
    func testLateCatchUpNamesTheMostRecentOccurrence() async throws {
        let (directory, store) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now),
            missedPolicy: .latest), now: now)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: now)
        let caughtUp = try await store.tickAutomations(now: now.addingTimeInterval(630))
        XCTAssertEqual(caughtUp.first?.admission, "enqueued")
        XCTAssertEqual(caughtUp.first?.scheduledAt, now.addingTimeInterval(600))
    }
    func testOneRuleThatCannotBeAdmittedDoesNotHoldTheOthers() async throws {
        let (directory, store) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: .init(kind: .interval, timeZone: "UTC", intervalMinutes: 1, anchor: now)), now: now)
        _ = try await store.setAutomationEnabled(id, expectedRevision: 1, enabled: true, now: now)
        // A due row naming no automation fails its own admission, and sorts first.
        let connection = try ControllerDatabase(path: directory.appendingPathComponent("controller.db").path)
        try connection.run("INSERT INTO automation_due(id,due) VALUES(?,?)",
            [.text(AutomationID().description), .integer(Int64(now.timeIntervalSince1970 * 1_000))])
        let first = try await store.tickAutomations(now: now.addingTimeInterval(60))
        XCTAssertEqual(first.map(\.automationID), [id])
        let deferred = try connection.rows("SELECT due FROM automation_due WHERE id!=?", [.text(id.description)])
        XCTAssertEqual(deferred.first?.integers[0],
            Int64((now.addingTimeInterval(60 + ControllerStore.failedAdmissionRetry).timeIntervalSince1970) * 1_000))
    }
    func testRunPagesStayWithinTheOwnerTransport() async throws {
        let (directory, store) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: nil))
        // Quotes and newlines double under JSON escaping, as a real report's would.
        let report = String(repeating: "\"\n", count: 16_000)
        for index in 0..<40 {
            _ = try await store.runAutomation(id, expectedRevision: 1, key: "request-\(index)")
            let claim = try await XCTUnwrapAsync(await store.claim(workerID: worker))
            _ = try await store.finish(executionID: claim.execution.id, destination: "inbox", payload: report)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var cursor: Int64 = 0
        var seen: [UUID] = []
        while true {
            let page = try await store.automationRuns(id, after: cursor)
            guard !page.items.isEmpty else { break }
            XCTAssertLessThan(try encoder.encode(page).count, 2_097_152)
            seen += page.items.map(\.run.id)
            cursor = page.next
        }
        XCTAssertEqual(seen.count, 40)
        XCTAssertEqual(Set(seen).count, 40)
    }
    func testRetryCannotRunBesideANewerOccurrence() async throws {
        let (directory, store) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = WorkerID(); _ = try await store.addWorker(id: worker, name: "Worker")
        let id = AutomationID()
        _ = try await store.configureAutomation(id, expectedRevision: 0, spec: .init(name: "Report", workerID: worker,
            instruction: "Report", schedule: nil))
        let first = try await store.runAutomation(id, expectedRevision: 1, key: "first")
        let interrupted = try XCTUnwrap(first.workID)
        let claim = try await XCTUnwrapAsync(await store.claim(workerID: worker))
        _ = try await store.interrupt(executionID: claim.execution.id)
        let second = try await store.runAutomation(id, expectedRevision: 1, key: "second")
        XCTAssertEqual(second.admission, "enqueued")
        do { _ = try await store.retry(workID: interrupted); XCTFail("retry ran beside a newer occurrence") }
        catch { XCTAssertEqual(error as? ControllerError, .conflict) }
        let newer = try await XCTUnwrapAsync(await store.claim(workerID: worker))
        _ = try await store.finish(executionID: newer.execution.id, destination: "inbox", payload: "Done")
        _ = try await store.retry(workID: interrupted)
        let third = try await store.runAutomation(id, expectedRevision: 1, key: "third")
        XCTAssertEqual(third.admission, "overlap")
    }
    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
