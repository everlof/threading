import Foundation
import XCTest
@testable import ThreadingMobile

final class MobileSessionConnectionPoolTests: XCTestCase {
    @MainActor
    func testDefaultsAreTwoMinutesAndFiveConnections() {
        let fixture = makePool()
        defer { fixture.cleanUp() }

        XCTAssertEqual(fixture.pool.retentionSeconds, 120)
        XCTAssertEqual(fixture.pool.capacity, 5)
        XCTAssertEqual(fixture.pool.occupancy, 0)
    }

    /// The counters travel in a diagnostics capture as one closed token list, so an audit reads
    /// the hit rate from the Mac's copy. Only token characters, and the counters it says.
    @MainActor
    func testTheMetricsSummaryIsOneClosedTokenList() throws {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let key = MobileConnectionPoolKey(hostID: "mac", sessionID: "chat")
        fixture.pool.park(PoolConnectionDouble(), for: key)
        _ = try XCTUnwrap(fixture.pool.take(key))
        XCTAssertNil(fixture.pool.take(MobileConnectionPoolKey(hostID: "mac", sessionID: "other")))

        let summary = fixture.pool.metrics.summaryToken
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:_-"))
        XCTAssertTrue(summary.unicodeScalars.allSatisfy { allowed.contains($0) }, summary)
        XCTAssertTrue(summary.contains("reused.1:misses.1:"), summary)
        XCTAssertTrue(summary.contains(":hitpct.50:"), summary)
    }

    @MainActor
    func testAReusedConnectionRecordsItsActualHoldAndAvoidsAFreshConnection() throws {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        let key = MobileConnectionPoolKey(hostID: "mac", sessionID: "chat")

        fixture.pool.park(connection, for: key)
        fixture.clock.date.addTimeInterval(18)
        let taken = try XCTUnwrap(fixture.pool.take(key))

        XCTAssertTrue(taken === connection)
        XCTAssertEqual(connection.parkCalls, 1)
        XCTAssertEqual(connection.resumeCalls, 1)
        XCTAssertEqual(fixture.pool.metrics.reused, 1)
        XCTAssertEqual(fixture.pool.metrics.misses, 0)
        XCTAssertEqual(fixture.pool.metrics.averageReusedHold, 18, accuracy: 0.001)
        XCTAssertEqual(fixture.pool.metrics.reusedByAge.under30Seconds, 1)
        XCTAssertEqual(fixture.pool.occupancy, 0)
    }

    @MainActor
    func testCapacityEvictsTheOldestConnectionAndRecordsUnusedHold() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        fixture.pool.setCapacity(2)
        let first = PoolConnectionDouble()
        let second = PoolConnectionDouble()
        let third = PoolConnectionDouble()

        fixture.pool.park(first, for: key(1))
        fixture.clock.date.addTimeInterval(4)
        fixture.pool.park(second, for: key(2))
        fixture.clock.date.addTimeInterval(7)
        fixture.pool.park(third, for: key(3))

        XCTAssertEqual(first.disconnectCalls, 1)
        XCTAssertEqual(second.disconnectCalls, 0)
        XCTAssertEqual(third.disconnectCalls, 0)
        XCTAssertEqual(fixture.pool.occupancy, 2)
        XCTAssertEqual(fixture.pool.metrics.capacityEvictions, 1)
        XCTAssertEqual(fixture.pool.metrics.heldWithoutReuse, 1)
        XCTAssertEqual(fixture.pool.metrics.averageUnusedHold, 11, accuracy: 0.001)
    }

    @MainActor
    func testExpiryCountsAConnectionHeldWithoutReuse() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        fixture.pool.park(connection, for: key(1))

        // One second past the default hold, whatever that default is.
        fixture.clock.date.addTimeInterval(
            TimeInterval(MobileSessionConnectionPool.defaultRetentionSeconds + 1)
        )
        fixture.pool.expireStaleEntries()

        XCTAssertEqual(connection.disconnectCalls, 1)
        XCTAssertEqual(fixture.pool.occupancy, 0)
        XCTAssertEqual(fixture.pool.metrics.expiredWithoutReuse, 1)
        XCTAssertEqual(fixture.pool.metrics.unusedByAge.atLeast120Seconds, 1)
    }

    @MainActor
    func testReducingCapacityAppliesImmediatelyAndPersists() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let first = PoolConnectionDouble()
        let second = PoolConnectionDouble()
        fixture.pool.park(first, for: key(1))
        fixture.pool.park(second, for: key(2))

        fixture.pool.setRetentionSeconds(95)
        fixture.pool.setCapacity(1)
        let restored = MobileSessionConnectionPool(
            defaults: fixture.defaults,
            now: { fixture.clock.date },
            schedulesExpiry: false,
            observesApplicationLifecycle: false
        )

        XCTAssertEqual(first.disconnectCalls, 1)
        XCTAssertEqual(fixture.pool.occupancy, 1)
        XCTAssertEqual(fixture.pool.metrics.configurationEvictions, 1)
        XCTAssertEqual(restored.retentionSeconds, 95)
        XCTAssertEqual(restored.capacity, 1)
        XCTAssertEqual(restored.metrics.configurationEvictions, 1)
    }

    @MainActor
    func testOlderHostNeverEntersPoolAndIsVisibleInMetrics() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        connection.supportsSessionConnectionParking = false

        fixture.pool.park(connection, for: key(1))

        XCTAssertEqual(connection.parkCalls, 0)
        XCTAssertEqual(connection.disconnectCalls, 1)
        XCTAssertEqual(fixture.pool.metrics.unsupported, 1)
        XCTAssertEqual(fixture.pool.occupancy, 0)
    }

    @MainActor
    func testAParkFailureIsNotReportedAsTimeHeldWithoutReuse() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        connection.parkResult = false

        fixture.pool.park(connection, for: key(1))

        XCTAssertEqual(connection.disconnectCalls, 1)
        XCTAssertEqual(fixture.pool.metrics.failedToPark, 1)
        XCTAssertEqual(fixture.pool.metrics.heldWithoutReuse, 0)
    }

    @MainActor
    func testAConnectionThatIsNotReadyIsReportedAsUnableToEnterThePool() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        connection.isReadyForConnectionPool = false

        fixture.pool.park(connection, for: key(1))

        XCTAssertEqual(connection.parkCalls, 0)
        XCTAssertEqual(connection.disconnectCalls, 1)
        XCTAssertEqual(fixture.pool.metrics.failedToPark, 1)
        XCTAssertEqual(fixture.pool.metrics.heldWithoutReuse, 0)
    }

    @MainActor
    func testSwitchingHostsHasItsOwnUnusedReason() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let first = PoolConnectionDouble()
        let second = PoolConnectionDouble()
        fixture.pool.park(
            first,
            for: MobileConnectionPoolKey(hostID: "first-mac", sessionID: "chat")
        )
        fixture.pool.park(
            second,
            for: MobileConnectionPoolKey(hostID: "second-mac", sessionID: "chat")
        )

        fixture.pool.discardEntries(exceptHostID: "second-mac")

        XCTAssertEqual(first.disconnectCalls, 1)
        XCTAssertEqual(second.disconnectCalls, 0)
        XCTAssertEqual(fixture.pool.occupancy, 1)
        XCTAssertEqual(fixture.pool.metrics.hostChangeEvictions, 1)
        XCTAssertEqual(fixture.pool.metrics.heldWithoutReuse, 1)
    }

    func testAddingMetricsFieldsDoesNotEraseAnOlderMetricsWindow() throws {
        let legacy = try JSONEncoder().encode(["lifecycleEvictions": 2])

        let decoded = try JSONDecoder().decode(MobileConnectionPoolMetrics.self, from: legacy)

        XCTAssertEqual(decoded.backgroundEvictions, 2)
        XCTAssertEqual(decoded.memoryPressureEvictions, 0)
        XCTAssertEqual(decoded.hostChangeEvictions, 0)
        XCTAssertEqual(decoded.heldWithoutReuse, 2)
    }

    @MainActor
    func testTransportFailureRemovesHeldConnectionWithoutReconnectOwnership() {
        let fixture = makePool()
        defer { fixture.cleanUp() }
        let connection = PoolConnectionDouble()
        fixture.pool.park(connection, for: key(1))

        fixture.clock.date.addTimeInterval(9)
        connection.onPooledConnectionInvalidated?()

        XCTAssertEqual(fixture.pool.occupancy, 0)
        XCTAssertEqual(fixture.pool.metrics.invalidatedWhileHeld, 1)
        XCTAssertEqual(fixture.pool.metrics.averageUnusedHold, 9, accuracy: 0.001)
        XCTAssertEqual(connection.disconnectCalls, 0)
    }

    @MainActor
    private func makePool() -> PoolFixture {
        let name = "MobileSessionConnectionPoolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let clock = PoolClock()
        let pool = MobileSessionConnectionPool(
            defaults: defaults,
            now: { clock.date },
            schedulesExpiry: false,
            observesApplicationLifecycle: false
        )
        return PoolFixture(pool: pool, defaults: defaults, suiteName: name, clock: clock)
    }

    private func key(_ number: Int) -> MobileConnectionPoolKey {
        MobileConnectionPoolKey(hostID: "mac", sessionID: "chat-\(number)")
    }
}

private final class PoolClock {
    var date = Date(timeIntervalSince1970: 10_000)
}

@MainActor
private final class PoolConnectionDouble: MobileParkableSessionConnection {
    var supportsSessionConnectionParking = true
    var isReadyForConnectionPool = true
    var onPooledConnectionInvalidated: (() -> Void)?
    var parkCalls = 0
    var resumeCalls = 0
    var disconnectCalls = 0
    var parkResult = true

    func parkForReuse() -> Bool {
        parkCalls += 1
        return parkResult
    }

    func resumeFromPool() -> Bool {
        resumeCalls += 1
        return true
    }

    func disconnect(markEnded: Bool) {
        disconnectCalls += 1
    }

    func leave() {
        disconnect(markEnded: false)
    }
}

@MainActor
private struct PoolFixture {
    let pool: MobileSessionConnectionPool
    let defaults: UserDefaults
    let suiteName: String
    let clock: PoolClock

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
