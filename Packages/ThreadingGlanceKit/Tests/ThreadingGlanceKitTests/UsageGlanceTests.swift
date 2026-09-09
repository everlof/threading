import Foundation
import XCTest
import ThreadingRemoteKit
@testable import ThreadingGlanceKit

final class UsageGlanceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    func account(age: Double = 0, reset: Double? = nil,
                 state: RemoteUsageCapacityReadingState = .current) -> RemoteUsageCapacityAccountDTO {
        .init(runtimeID: "codex", runtimeName: "Codex", accountID: "personal", accountName: "Personal",
              observedAt: now.timeIntervalSince1970 - age, state: state,
              windows: [.init(id: "week", name: "Week", fraction: 0.3, resetsAt: reset)])
    }

    func snapshot() -> UsageGlanceSnapshot {
        .init(pairingID: "mac-1", hostName: "Work Mac",
              capacity: .init(epoch: UUID().uuidString, revision: 1, accounts: [account()]), receivedAt: now)
    }

    func testResetRemovesReadingInsteadOfInventingFullCapacity() {
        let value = account(reset: now.timeIntervalSince1970)
        XCTAssertEqual(UsageGlanceFreshness.resolve(account: value, window: value.windows[0], now: now), .expired)
    }

    func testFreshnessUsesProviderObservationNotPhoneReceipt() {
        for (age, expected): (Double, UsageGlanceFreshness) in [
            (0, .recent), (900, .dated), (21600, .cached), (86400, .expired), (-120, .expired)
        ] {
            let value = account(age: age)
            XCTAssertEqual(UsageGlanceFreshness.resolve(account: value, window: value.windows[0], now: now), expected)
        }
        let stale = account(state: .stale)
        XCTAssertEqual(UsageGlanceFreshness.resolve(account: stale, window: stale.windows[0], now: now), .cached)
    }

    func testConfiguredMissingAccountDoesNotSelectAnotherLogin() {
        XCTAssertNil(snapshot().account(id: "deleted"))
        XCTAssertNotNil(snapshot().account(id: nil))
    }

    func testTimelineIncludesExactResetAndAgeBoundaries() {
        let value = account(reset: now.addingTimeInterval(1200).timeIntervalSince1970)
        XCTAssertEqual(UsageGlanceFreshness.transitions(account: value, now: now),
                       [0, 900, 1200, 21600, 86400].map { now.addingTimeInterval($0) })
    }

    func testClearFencesAnOlderPublicationAndReaderNeverRepairs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageGlanceStore(directory: directory)
        try await store.publish(snapshot(), sequence: 1)
        try await store.clear(sequence: 3)
        do {
            try await store.publish(snapshot(), sequence: 2)
            XCTFail("Old fetch restored cleared data")
        } catch UsageGlanceStoreError.superseded { }
        let empty = try await store.read()
        XCTAssertNil(empty)
        let file = directory.appendingPathComponent("usage-v1.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        do { _ = try await store.read(); XCTFail("Accepted corrupt data") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try await store.clear(sequence: 4)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("unreadable")), corrupt)
        try await store.publish(snapshot(), sequence: 5)
    }

    func testNewerFormatIsPreservedOnPublishAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-v1.json")
        let bytes = Data(#"{"version":2,"newData":"keep me"}"#.utf8)
        try bytes.write(to: file)
        let store = UsageGlanceStore(directory: directory)
        do { try await store.publish(snapshot(), sequence: 1); XCTFail() }
        catch UsageGlanceStoreError.unsupportedVersion { }
        do { try await store.clear(sequence: 2); XCTFail() }
        catch UsageGlanceStoreError.unsupportedVersion { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRouteRoundTripsReservedCharactersAndRejectsAmbiguousTargets() {
        let route = UsageGlanceRoute(pairingID: "mac & +?", accountID: "5:codexfoo|bar")
        XCTAssertEqual(UsageGlanceRoute(url: route.url), route)
        for raw in ["threading://usage?host=a&host=b", "threading://usage?host=a&token=secret",
                    "threading://usage/path?host=a", "https://usage?host=a"] {
            XCTAssertNil(UsageGlanceRoute(url: URL(string: raw)!))
        }
    }
}
