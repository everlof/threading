import Foundation
import UIKit

@MainActor
protocol MobileParkableSessionConnection: AnyObject {
    var supportsSessionConnectionParking: Bool { get }
    var isReadyForConnectionPool: Bool { get }
    var onPooledConnectionInvalidated: (() -> Void)? { get set }
    @discardableResult func parkForReuse() -> Bool
    @discardableResult func resumeFromPool() -> Bool
    func disconnect(markEnded: Bool)
}

extension RemoteSessionConnection: MobileParkableSessionConnection {}

struct MobileConnectionPoolKey: Hashable {
    let hostID: String
    let sessionID: String
}

struct MobileConnectionPoolAgeBuckets: Codable, Equatable {
    var under5Seconds = 0
    var under15Seconds = 0
    var under30Seconds = 0
    var under60Seconds = 0
    var under120Seconds = 0
    var atLeast120Seconds = 0

    mutating func record(_ duration: TimeInterval) {
        switch duration {
        case ..<5: under5Seconds += 1
        case ..<15: under15Seconds += 1
        case ..<30: under30Seconds += 1
        case ..<60: under60Seconds += 1
        case ..<120: under120Seconds += 1
        default: atLeast120Seconds += 1
        }
    }
}

/// Fixed-size, privacy-safe evidence about whether warm session sockets are earning their keep.
/// No host, session, title, prompt, or event history is persisted.
struct MobileConnectionPoolMetrics: Codable, Equatable {
    var resetAt = Date()
    var misses = 0
    var reused = 0
    var parked = 0
    var unsupported = 0
    var failedToPark = 0
    var expiredWithoutReuse = 0
    var capacityEvictions = 0
    var configurationEvictions = 0
    var backgroundEvictions = 0
    var memoryPressureEvictions = 0
    var hostChangeEvictions = 0
    var invalidatedWhileHeld = 0
    var peakOccupancy = 0
    var totalReusedHoldMilliseconds: Int64 = 0
    var totalUnusedHoldMilliseconds: Int64 = 0
    var longestHoldMilliseconds: Int64 = 0
    var reusedByAge = MobileConnectionPoolAgeBuckets()
    var unusedByAge = MobileConnectionPoolAgeBuckets()

    var requests: Int { misses + reused }
    var hitRate: Double { requests == 0 ? 0 : Double(reused) / Double(requests) }

    /// The counters as one closed `key.value` token list for a diagnostics capture, so an
    /// audit reads the pool's hit rate from the copy on the Mac without asking the phone — the
    /// 4–5 Sep 2026 audit could not, because the phone disconnected during that final read.
    var summaryToken: String {
        [
            "reused.\(reused)",
            "misses.\(misses)",
            "parked.\(parked)",
            "peak.\(peakOccupancy)",
            "hitpct.\(Int((hitRate * 100).rounded()))",
            "expired.\(expiredWithoutReuse)",
            "capacity.\(capacityEvictions)",
            "background.\(backgroundEvictions)",
            "memory.\(memoryPressureEvictions)",
            "hostchange.\(hostChangeEvictions)",
            "invalidated.\(invalidatedWhileHeld)",
            "unsupported.\(unsupported)",
            "failedtopark.\(failedToPark)",
        ].joined(separator: ":")
    }
    var heldWithoutReuse: Int {
        expiredWithoutReuse + capacityEvictions + configurationEvictions
            + backgroundEvictions + memoryPressureEvictions + hostChangeEvictions
            + invalidatedWhileHeld
    }
    var averageReusedHold: TimeInterval {
        reused == 0 ? 0 : Double(totalReusedHoldMilliseconds) / 1_000 / Double(reused)
    }
    var averageUnusedHold: TimeInterval {
        heldWithoutReuse == 0
            ? 0
            : Double(totalUnusedHoldMilliseconds) / 1_000 / Double(heldWithoutReuse)
    }

    mutating func recordReuse(after duration: TimeInterval) {
        reused += 1
        record(duration, reused: true)
    }

    mutating func recordUnused(after duration: TimeInterval) {
        record(duration, reused: false)
    }

    private mutating func record(_ duration: TimeInterval, reused: Bool) {
        let milliseconds = Int64(max(0, duration) * 1_000)
        longestHoldMilliseconds = max(longestHoldMilliseconds, milliseconds)
        if reused {
            totalReusedHoldMilliseconds += milliseconds
            reusedByAge.record(duration)
        } else {
            totalUnusedHoldMilliseconds += milliseconds
            unusedByAge.record(duration)
        }
    }

    init(resetAt: Date = Date()) {
        self.resetAt = resetAt
    }

    private enum CodingKeys: String, CodingKey {
        case resetAt
        case misses
        case reused
        case parked
        case unsupported
        case failedToPark
        case expiredWithoutReuse
        case capacityEvictions
        case configurationEvictions
        case backgroundEvictions
        case memoryPressureEvictions
        case hostChangeEvictions
        case invalidatedWhileHeld
        case peakOccupancy
        case totalReusedHoldMilliseconds
        case totalUnusedHoldMilliseconds
        case longestHoldMilliseconds
        case reusedByAge
        case unusedByAge
        // A pre-release build stored these three reasons as one aggregate. Preserve it as
        // background evidence when decoding instead of resetting the whole metrics window.
        case lifecycleEvictions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt) ?? Date()
        misses = try values.decodeIfPresent(Int.self, forKey: .misses) ?? 0
        reused = try values.decodeIfPresent(Int.self, forKey: .reused) ?? 0
        parked = try values.decodeIfPresent(Int.self, forKey: .parked) ?? 0
        unsupported = try values.decodeIfPresent(Int.self, forKey: .unsupported) ?? 0
        failedToPark = try values.decodeIfPresent(Int.self, forKey: .failedToPark) ?? 0
        expiredWithoutReuse = try values.decodeIfPresent(Int.self, forKey: .expiredWithoutReuse) ?? 0
        capacityEvictions = try values.decodeIfPresent(Int.self, forKey: .capacityEvictions) ?? 0
        configurationEvictions = try values.decodeIfPresent(
            Int.self,
            forKey: .configurationEvictions
        ) ?? 0
        backgroundEvictions = try values.decodeIfPresent(Int.self, forKey: .backgroundEvictions)
            ?? values.decodeIfPresent(Int.self, forKey: .lifecycleEvictions)
            ?? 0
        memoryPressureEvictions = try values.decodeIfPresent(
            Int.self,
            forKey: .memoryPressureEvictions
        ) ?? 0
        hostChangeEvictions = try values.decodeIfPresent(Int.self, forKey: .hostChangeEvictions) ?? 0
        invalidatedWhileHeld = try values.decodeIfPresent(
            Int.self,
            forKey: .invalidatedWhileHeld
        ) ?? 0
        peakOccupancy = try values.decodeIfPresent(Int.self, forKey: .peakOccupancy) ?? 0
        totalReusedHoldMilliseconds = try values.decodeIfPresent(
            Int64.self,
            forKey: .totalReusedHoldMilliseconds
        ) ?? 0
        totalUnusedHoldMilliseconds = try values.decodeIfPresent(
            Int64.self,
            forKey: .totalUnusedHoldMilliseconds
        ) ?? 0
        longestHoldMilliseconds = try values.decodeIfPresent(
            Int64.self,
            forKey: .longestHoldMilliseconds
        ) ?? 0
        reusedByAge = try values.decodeIfPresent(
            MobileConnectionPoolAgeBuckets.self,
            forKey: .reusedByAge
        ) ?? MobileConnectionPoolAgeBuckets()
        unusedByAge = try values.decodeIfPresent(
            MobileConnectionPoolAgeBuckets.self,
            forKey: .unusedByAge
        ) ?? MobileConnectionPoolAgeBuckets()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(resetAt, forKey: .resetAt)
        try values.encode(misses, forKey: .misses)
        try values.encode(reused, forKey: .reused)
        try values.encode(parked, forKey: .parked)
        try values.encode(unsupported, forKey: .unsupported)
        try values.encode(failedToPark, forKey: .failedToPark)
        try values.encode(expiredWithoutReuse, forKey: .expiredWithoutReuse)
        try values.encode(capacityEvictions, forKey: .capacityEvictions)
        try values.encode(configurationEvictions, forKey: .configurationEvictions)
        try values.encode(backgroundEvictions, forKey: .backgroundEvictions)
        try values.encode(memoryPressureEvictions, forKey: .memoryPressureEvictions)
        try values.encode(hostChangeEvictions, forKey: .hostChangeEvictions)
        try values.encode(invalidatedWhileHeld, forKey: .invalidatedWhileHeld)
        try values.encode(peakOccupancy, forKey: .peakOccupancy)
        try values.encode(totalReusedHoldMilliseconds, forKey: .totalReusedHoldMilliseconds)
        try values.encode(totalUnusedHoldMilliseconds, forKey: .totalUnusedHoldMilliseconds)
        try values.encode(longestHoldMilliseconds, forKey: .longestHoldMilliseconds)
        try values.encode(reusedByAge, forKey: .reusedByAge)
        try values.encode(unusedByAge, forKey: .unusedByAge)
    }
}

@MainActor
final class MobileSessionConnectionPool: ObservableObject {
    static let shared = MobileSessionConnectionPool()

    /// Two minutes and five connections. The audit of 4–5 Sep 2026 saw 33 warm resumptions at a
    /// 31 ms median against 222 fresh hellos, across 44 sessions several of which were reopened
    /// again and again: a person moving between a handful of chats spends longer than a minute
    /// away from each, and comes back to more than three. Both stay within the settings' bounds.
    static let defaultRetentionSeconds = 120
    static let defaultCapacity = 5
    static let minimumRetentionSeconds = 5
    static let maximumRetentionSeconds = 300
    static let maximumCapacity = 8

    @Published private(set) var retentionSeconds: Int
    @Published private(set) var capacity: Int
    @Published private(set) var metrics: MobileConnectionPoolMetrics
    @Published private(set) var occupancy = 0
    @Published private(set) var oldestHeldSince: Date?

    private struct Entry {
        let key: MobileConnectionPoolKey
        let connection: any MobileParkableSessionConnection
        let parkedAt: Date
    }

    private enum UnusedReason {
        case expired
        case capacity
        case configuration
        case background
        case memoryPressure
        case hostChanged
        case invalidated
    }

    private static let retentionKey = "mobile.sessionConnectionPool.retentionSeconds"
    private static let capacityKey = "mobile.sessionConnectionPool.capacity"
    private static let metricsKey = "mobile.sessionConnectionPool.metrics.v1"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let schedulesExpiry: Bool
    private var entries: [Entry] = []
    private var expiryTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        schedulesExpiry: Bool = true,
        observesApplicationLifecycle: Bool = true
    ) {
        self.defaults = defaults
        self.now = now
        self.schedulesExpiry = schedulesExpiry
        if defaults.object(forKey: Self.retentionKey) == nil {
            retentionSeconds = Self.defaultRetentionSeconds
        } else {
            retentionSeconds = Self.clampedRetention(
                defaults.integer(forKey: Self.retentionKey)
            )
        }
        if defaults.object(forKey: Self.capacityKey) == nil {
            capacity = Self.defaultCapacity
        } else {
            capacity = Self.clampedCapacity(defaults.integer(forKey: Self.capacityKey))
        }
        if let data = defaults.data(forKey: Self.metricsKey),
           let saved = try? JSONDecoder().decode(MobileConnectionPoolMetrics.self, from: data) {
            metrics = saved
        } else {
            metrics = MobileConnectionPoolMetrics()
        }

        guard observesApplicationLifecycle else { return }
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.discardAll(reason: .background) }
            },
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.discardAll(reason: .memoryPressure) }
            },
        ]
    }

    func setRetentionSeconds(_ value: Int) {
        let value = Self.clampedRetention(value)
        guard value != retentionSeconds else { return }
        retentionSeconds = value
        defaults.set(value, forKey: Self.retentionKey)
        expireStaleEntries()
        scheduleExpiry()
    }

    func setCapacity(_ value: Int) {
        let value = Self.clampedCapacity(value)
        guard value != capacity else { return }
        capacity = value
        defaults.set(value, forKey: Self.capacityKey)
        while entries.count > value {
            removeEntry(at: 0, reason: .configuration)
        }
        publishOccupancy()
        scheduleExpiry()
    }

    /// Counts every attempted warm lookup. A miss is therefore the actual number of fresh
    /// handshakes the pool could not avoid, rather than only expiry events.
    func take(_ key: MobileConnectionPoolKey) -> (any MobileParkableSessionConnection)? {
        expireStaleEntries()
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            metrics.misses += 1
            saveMetrics()
            return nil
        }
        let entry = entries.remove(at: index)
        entry.connection.onPooledConnectionInvalidated = nil
        let held = max(0, now().timeIntervalSince(entry.parkedAt))
        guard entry.connection.resumeFromPool() else {
            entry.connection.disconnect(markEnded: false)
            metrics.misses += 1
            metrics.invalidatedWhileHeld += 1
            metrics.recordUnused(after: held)
            publishOccupancy()
            saveMetrics()
            scheduleExpiry()
            return nil
        }
        metrics.recordReuse(after: held)
        publishOccupancy()
        saveMetrics()
        scheduleExpiry()
        return entry.connection
    }

    func park(_ connection: any MobileParkableSessionConnection, for key: MobileConnectionPoolKey) {
        expireStaleEntries()
        guard capacity > 0 else {
            connection.disconnect(markEnded: false)
            return
        }
        guard connection.isReadyForConnectionPool else {
            metrics.failedToPark += 1
            connection.disconnect(markEnded: false)
            saveMetrics()
            return
        }
        guard connection.supportsSessionConnectionParking else {
            metrics.unsupported += 1
            connection.disconnect(markEnded: false)
            saveMetrics()
            return
        }
        guard connection.parkForReuse() else {
            metrics.failedToPark += 1
            connection.disconnect(markEnded: false)
            saveMetrics()
            return
        }

        if let duplicate = entries.firstIndex(where: { $0.key == key }) {
            removeEntry(at: duplicate, reason: .capacity)
        }
        while entries.count >= capacity {
            removeEntry(at: 0, reason: .capacity)
        }
        let entry = Entry(key: key, connection: connection, parkedAt: now())
        entries.append(entry)
        metrics.parked += 1
        metrics.peakOccupancy = max(metrics.peakOccupancy, entries.count)
        connection.onPooledConnectionInvalidated = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.removeInvalidated(connection)
        }
        publishOccupancy()
        saveMetrics()
        scheduleExpiry()
    }

    func discardEntries(exceptHostID hostID: String) {
        for index in entries.indices.reversed() where entries[index].key.hostID != hostID {
            removeEntry(at: index, reason: .hostChanged)
        }
        publishOccupancy()
        scheduleExpiry()
    }

    func expireStaleEntries() {
        let cutoff = now().addingTimeInterval(-TimeInterval(retentionSeconds))
        while let first = entries.first, first.parkedAt <= cutoff {
            removeEntry(at: 0, reason: .expired)
        }
        publishOccupancy()
    }

    func resetMetrics() {
        metrics = MobileConnectionPoolMetrics(resetAt: now())
        metrics.peakOccupancy = entries.count
        saveMetrics()
    }

    var oldestHeldDuration: TimeInterval? {
        oldestHeldSince.map { max(0, now().timeIntervalSince($0)) }
    }

    private func discardAll(reason: UnusedReason) {
        while !entries.isEmpty {
            removeEntry(at: 0, reason: reason)
        }
        publishOccupancy()
        scheduleExpiry()
    }

    private func removeInvalidated(_ connection: any MobileParkableSessionConnection) {
        guard let index = entries.firstIndex(where: { $0.connection === connection }) else {
            return
        }
        removeEntry(at: index, reason: .invalidated, disconnect: false)
        publishOccupancy()
        scheduleExpiry()
    }

    private func removeEntry(
        at index: Int,
        reason: UnusedReason,
        disconnect: Bool = true
    ) {
        let entry = entries.remove(at: index)
        entry.connection.onPooledConnectionInvalidated = nil
        if disconnect { entry.connection.disconnect(markEnded: false) }
        let held = max(0, now().timeIntervalSince(entry.parkedAt))
        switch reason {
        case .expired: metrics.expiredWithoutReuse += 1
        case .capacity: metrics.capacityEvictions += 1
        case .configuration: metrics.configurationEvictions += 1
        case .background: metrics.backgroundEvictions += 1
        case .memoryPressure: metrics.memoryPressureEvictions += 1
        case .hostChanged: metrics.hostChangeEvictions += 1
        case .invalidated: metrics.invalidatedWhileHeld += 1
        }
        metrics.recordUnused(after: held)
        saveMetrics()
    }

    private func publishOccupancy() {
        occupancy = entries.count
        oldestHeldSince = entries.first?.parkedAt
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard schedulesExpiry, let first = entries.first else { return }
        let deadline = first.parkedAt.addingTimeInterval(TimeInterval(retentionSeconds))
        let delay = max(0, deadline.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expireStaleEntries()
            self?.scheduleExpiry()
        }
    }

    private func saveMetrics() {
        if let data = try? JSONEncoder().encode(metrics) {
            defaults.set(data, forKey: Self.metricsKey)
        }
    }

    private static func clampedRetention(_ value: Int) -> Int {
        min(maximumRetentionSeconds, max(minimumRetentionSeconds, value))
    }

    private static func clampedCapacity(_ value: Int) -> Int {
        min(maximumCapacity, max(0, value))
    }

#if DEBUG
    static func evidenceFixture() -> MobileSessionConnectionPool {
        let suite = UserDefaults(suiteName: "MobileConnectionPoolEvidence")!
        suite.removePersistentDomain(forName: "MobileConnectionPoolEvidence")
        let fixedNow = Date(timeIntervalSince1970: 1_787_339_400)
        let fixture = MobileSessionConnectionPool(
            defaults: suite,
            now: { fixedNow },
            schedulesExpiry: false,
            observesApplicationLifecycle: false
        )
        var metrics = MobileConnectionPoolMetrics(
            resetAt: Date(timeIntervalSince1970: 1_786_990_200)
        )
        metrics.misses = 14
        metrics.reused = 31
        metrics.parked = 38
        metrics.unsupported = 2
        metrics.expiredWithoutReuse = 4
        metrics.capacityEvictions = 1
        metrics.configurationEvictions = 0
        metrics.backgroundEvictions = 1
        metrics.memoryPressureEvictions = 1
        metrics.hostChangeEvictions = 1
        metrics.invalidatedWhileHeld = 1
        metrics.peakOccupancy = 3
        metrics.totalReusedHoldMilliseconds = 558_000
        metrics.totalUnusedHoldMilliseconds = 336_000
        metrics.longestHoldMilliseconds = 71_000
        metrics.reusedByAge = MobileConnectionPoolAgeBuckets(
            under5Seconds: 5,
            under15Seconds: 8,
            under30Seconds: 11,
            under60Seconds: 6,
            under120Seconds: 1,
            atLeast120Seconds: 0
        )
        metrics.unusedByAge = MobileConnectionPoolAgeBuckets(
            under5Seconds: 0,
            under15Seconds: 1,
            under30Seconds: 1,
            under60Seconds: 3,
            under120Seconds: 2,
            atLeast120Seconds: 0
        )
        fixture.metrics = metrics
        fixture.occupancy = 2
        fixture.oldestHeldSince = fixedNow.addingTimeInterval(-18)
        return fixture
    }
#endif
}
