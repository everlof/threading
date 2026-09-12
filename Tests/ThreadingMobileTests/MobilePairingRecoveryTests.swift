import Foundation
import Security
import XCTest
@testable import ThreadingMobile
import ThreadingRemoteKit

@MainActor
final class MobilePairingRecoveryTests: XCTestCase {
    func testLockedLaunchPreservesSelectionAndRestoresWithoutRelaunch() async throws {
        let host = try makeHost()
        let data = try JSONEncoder().encode([host])
        let store = RemoteHostStore(reader: { .success(data) })
        let suite = "MobilePairingRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        continuity.setActiveHostID(host.id)
        var unlocked = false
        let model = RemoteAppModel(
            continuity: continuity,
            newSessionDefaults: MobileNewSessionDefaultsStore(defaults: defaults),
            themeCache: MobileThemeCacheStore(defaults: defaults),
            dashboardCache: MobileDashboardCacheStore(suiteName: suite),
            hostStore: store,
            protectedDataAvailable: { unlocked }
        )
        XCTAssertTrue(model.needsHostStorageRecovery)
        XCTAssertFalse(store.writesAllowed)
        XCTAssertEqual(continuity.activeHostID, host.id)
        let lockedResult = await model.restorePairedHostsIfNeeded()
        XCTAssertFalse(lockedResult)
        XCTAssertThrowsError(try store.save([]))

        unlocked = true
        let recovered = await model.restorePairedHostsIfNeeded()
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.hosts, [host])
        XCTAssertEqual(model.activeHostID, host.id)
        XCTAssertEqual(continuity.activeHostID, host.id)
        XCTAssertFalse(model.needsHostStorageRecovery)
        XCTAssertNil(model.storageIssue)
        XCTAssertTrue(store.writesAllowed)
    }

    func testTransientKeychainFailureDoesNotPermanentlyDisableWrites() async throws {
        let bytes = try JSONEncoder().encode([makeHost()])
        let source = ReadSequence([.failure(.keychain(errSecInteractionNotAllowed)), .success(bytes)])
        let store = RemoteHostStore(reader: { source.read() })
        guard case .failure = await store.reload() else { return XCTFail("Expected locked Keychain") }
        XCTAssertThrowsError(try store.save([]))
        let result = await store.reload()
        XCTAssertEqual(try result.get().count, 1)
        XCTAssertTrue(store.writesAllowed)
    }

    func testCorruptAndUnavailableStoresNeverAuthorizeReplacement() async throws {
        for response: Result<Data?, RemoteHostStore.StoreError> in [
            .success(Data("future or corrupt credentials".utf8)),
            .failure(.keychain(errSecNotAvailable)),
        ] {
            let store = RemoteHostStore(reader: { response })
            for _ in 0..<2 {
                let result = await store.reload()
                guard case .failure = result else { return XCTFail("Failure became an empty pairing set") }
                XCTAssertFalse(store.writesAllowed)
                XCTAssertThrowsError(try store.save([]))
            }
        }
    }

    func testOnlyVerifiedMissingItemMeansNoPairings() async throws {
        let store = RemoteHostStore(reader: { .success(nil) })
        XCTAssertFalse(store.writesAllowed)
        let result = await store.reload()
        XCTAssertEqual(try result.get(), [])
        XCTAssertTrue(store.writesAllowed)
    }

    func testFailedReadThenOverlappingUnlockRetriesRestoreOnce() async throws {
        let host = try makeHost()
        let bytes = try JSONEncoder().encode([host])
        let source = ReadSequence([.failure(.keychain(errSecInteractionNotAllowed)), .success(bytes)])
        let store = RemoteHostStore(reader: { source.read() })
        let suite = "MobilePairingRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        continuity.setActiveHostID(host.id)
        let model = RemoteAppModel(
            continuity: continuity,
            newSessionDefaults: MobileNewSessionDefaultsStore(defaults: defaults),
            themeCache: MobileThemeCacheStore(defaults: defaults),
            dashboardCache: MobileDashboardCacheStore(suiteName: suite),
            hostStore: store,
            protectedDataAvailable: { true }
        )
        let initialRead = await model.restorePairedHostsIfNeeded()
        XCTAssertFalse(initialRead)
        XCTAssertTrue(model.needsHostStorageRecovery)
        XCTAssertEqual(continuity.activeHostID, host.id)
        async let unlock = model.restorePairedHostsIfNeeded()
        async let foreground = model.restorePairedHostsIfNeeded()
        let results = await (unlock, foreground)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(source.count, 2, "One failed startup read and one shared recovery read")
        XCTAssertEqual(model.hosts, [host])
        let alreadyRecovered = await model.restorePairedHostsIfNeeded()
        XCTAssertTrue(alreadyRecovered)
        XCTAssertEqual(source.count, 2, "Healthy foregrounds must not keep reloading credentials")
    }

    func testRelockDuringRecoveryKeepsWritesClosedAndSelectionIntact() async throws {
        let host = try makeHost()
        let bytes = try JSONEncoder().encode([host])
        let store = RemoteHostStore(reader: { .success(bytes) })
        let suite = "MobilePairingRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        continuity.setActiveHostID(host.id)
        var checks = 0
        var remainUnlocked = false
        let model = RemoteAppModel(
            continuity: continuity,
            newSessionDefaults: MobileNewSessionDefaultsStore(defaults: defaults),
            themeCache: MobileThemeCacheStore(defaults: defaults),
            dashboardCache: MobileDashboardCacheStore(suiteName: suite),
            hostStore: store,
            protectedDataAvailable: { checks += 1; return remainUnlocked || checks == 1 }
        )
        let interrupted = await model.restorePairedHostsIfNeeded()
        XCTAssertFalse(interrupted)
        XCTAssertTrue(model.needsHostStorageRecovery)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(store.writesAllowed)
        XCTAssertEqual(continuity.activeHostID, host.id)
        remainUnlocked = true
        let restored = await model.restorePairedHostsIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(model.hosts, [host])
    }

    func testWidgetTapWaitsForPairingRestoration() async throws {
        let host = try makeHost()
        let bytes = try JSONEncoder().encode([host])
        let suite = "MobilePairingRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unlocked = false
        let model = RemoteAppModel(
            continuity: MobileSessionContinuityStore(defaults: defaults),
            newSessionDefaults: MobileNewSessionDefaultsStore(defaults: defaults),
            themeCache: MobileThemeCacheStore(defaults: defaults),
            dashboardCache: MobileDashboardCacheStore(suiteName: suite),
            hostStore: RemoteHostStore(reader: { .success(bytes) }),
            protectedDataAvailable: { unlocked }
        )
        let url = try XCTUnwrap(URL(string: "threading://usage?host=saved-mac"))
        XCTAssertTrue(model.open(url))
        XCTAssertNil(model.widgetUsageRoute)
        unlocked = true
        let restored = await model.restorePairedHostsIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(model.widgetUsageRoute?.pairingID, host.id)
    }

    func testNotificationTapSurvivesLockedStartupAndKeepsDeduplication() async throws {
        let host = try makeHost()
        let bytes = try JSONEncoder().encode([host])
        let suite = "MobilePairingRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unlocked = false
        let model = RemoteAppModel(
            continuity: MobileSessionContinuityStore(defaults: defaults),
            newSessionDefaults: MobileNewSessionDefaultsStore(defaults: defaults),
            themeCache: MobileThemeCacheStore(defaults: defaults),
            dashboardCache: MobileDashboardCacheStore(suiteName: suite),
            hostStore: RemoteHostStore(reader: { .success(bytes) }),
            protectedDataAvailable: { unlocked }
        )
        let event = RemoteNotificationEventDTO(
            id: "locked-tap", kind: .agentMessage, hostID: host.id, sessionID: "session",
            title: "Done", body: "Inspect", destination: .session, createdAt: 123
        )
        XCTAssertTrue(model.openSessionFromNotification(event, origin: .notificationCenter))
        XCTAssertFalse(model.openSessionFromNotification(event, origin: .connectingScene))
        unlocked = true
        let restored = await model.restorePairedHostsIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(model.activeHostID, host.id)
        XCTAssertFalse(model.openSessionFromNotification(event, origin: .notificationCenter))
    }

    private func makeHost() throws -> PairedRemoteHost {
        PairedRemoteHost(
            id: "saved-mac", name: "Saved Mac",
            link: try XCTUnwrap(RemoteConnectionLink(string: "https://saved.invalid:8443/#\(String(repeating: "a", count: 43))")),
            lastConnectedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

/// The injected Security result sequence crosses the reload worker; all state is lock-owned.
private final class ReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    private var results: [Result<Data?, RemoteHostStore.StoreError>]
    init(_ results: [Result<Data?, RemoteHostStore.StoreError>]) { self.results = results }
    func read() -> Result<Data?, RemoteHostStore.StoreError> {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}
