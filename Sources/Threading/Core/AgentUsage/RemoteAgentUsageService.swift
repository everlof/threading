import Foundation
import ThreadingController

/// A host's last usage summary changed, or a read of it failed.
struct RemoteAgentUsageDidChange: AppEvent {
    static let name = Notification.Name("ThreadingRemoteAgentUsageDidChange")
}

/// A host whose controller connection is saved: the only hosts the Usage page reads.
struct RemoteAgentUsageHost: Sendable, Equatable {
    let id: RemoteHostID
    let name: String
    let endpoint: RemoteAutomationEndpoint
    let destination: RemoteHostDestination

    /// A host record names a connected controller once the Remote automations page has saved
    /// both of its paths.
    @MainActor
    static func connected(in records: [RemoteHostRecord]) -> [RemoteAgentUsageHost] {
        records.compactMap { record in
            guard let executable = record.controllerExecutable, let database = record.controllerDatabase else { return nil }
            let endpoint = RemoteAutomationEndpoint(hostID: record.id, executable: executable, database: database)
            guard (try? endpoint.validate()) != nil else { return nil }
            return RemoteAgentUsageHost(id: record.id, name: record.displayName, endpoint: endpoint,
                                        destination: record.sshDestination)
        }
    }
}

/// What one host's ledger said, when it said it.
struct RemoteAgentUsageSnapshot: Codable, Equatable, Sendable {
    let fetchedAt: Date
    /// The UTC days asked for.
    let from: String
    let through: String
    /// The oldest UTC day read completely; later than `from` when the page budget cut the read.
    let completeFrom: String
    let cells: [UsageDailyCell]
    /// Worker id (lowercased UUID) to the name its owner gave it.
    let workerNames: [String: String]

    var isTruncated: Bool { completeFrom > from }
}

/// One host's place on the Usage page: its last good summary, kept across failures, and what
/// happened on the latest attempt.
struct RemoteAgentUsageHostState: Codable, Equatable, Sendable {
    enum Freshness: Equatable, Sendable {
        /// Read recently and the latest attempt succeeded.
        case current
        /// A summary exists but is old or the latest read failed. Shown with its age, never as zero.
        case stale(since: Date)
        /// Never read successfully: nothing is known, which is not the same as nothing spent.
        case unread
    }

    let hostID: RemoteHostID
    var hostName: String
    var snapshot: RemoteAgentUsageSnapshot?
    var lastAttemptAt: Date?
    /// The latest attempt's failure, cleared by the next success.
    var lastFailure: String?

    func freshness(now: Date, staleAfter: TimeInterval = RemoteAgentUsageDefaults.staleAfter) -> Freshness {
        guard let snapshot else { return .unread }
        if lastFailure != nil || now.timeIntervalSince(snapshot.fetchedAt) > staleAfter {
            return .stale(since: snapshot.fetchedAt)
        }
        return .current
    }
}

/// Reads every connected host's usage summary off the main actor, at most
/// `maximumConcurrentHosts` at once, and keeps the last good one per host on disk.
///
/// A failed read never replaces a summary: the host keeps its last cells with their age and is
/// shown stale. Hosts that are no longer connected are dropped.
actor RemoteAgentUsageService {
    static let shared = RemoteAgentUsageService()

    private let client: RemoteAgentUsageClient
    private let persistence: RecoverableFileStore<[RemoteAgentUsageHostState]>?
    private let now: @Sendable () -> Date
    private let postsEvents: Bool
    private var states: [RemoteHostID: RemoteAgentUsageHostState] = [:]
    private var inFlight: Set<RemoteHostID> = []
    private var lastRefreshAt: Date?

    init(client: RemoteAgentUsageClient = RemoteAgentUsageClient(), cacheURL: URL? = RemoteAgentUsageService.defaultCacheURL(),
         postsEvents: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
        self.postsEvents = postsEvents
        let persistence = cacheURL.map {
            RecoverableFileStore<[RemoteAgentUsageHostState]>(
                url: $0, fileManager: .default, criticality: .rebuildableCache, sizePolicy: .derivedCache,
                dateEncodingStrategy: .iso8601, dateDecodingStrategy: .iso8601
            )
        }
        self.persistence = persistence
        let loaded = persistence?.load(defaultValue: []).value ?? []
        states = Dictionary(loaded.prefix(RemoteAgentUsageDefaults.maximumHosts).map { ($0.hostID, $0) },
                            uniquingKeysWith: { first, _ in first })
    }

    /// Application Support, or the hosted-test scratch directory — never the developer's own
    /// cache from inside a test bundle (persistence.md).
    nonisolated static func defaultCacheURL() -> URL? {
        let root = StateManager.isHostedTest ? StateManager.hostedTestDirectory() : AppDataLocations.supportDirectory
        return root.appendingPathComponent(RemoteAgentUsageDefaults.cacheFileName)
    }

    /// The states of the given hosts, in their order, including hosts never read yet.
    func states(for hosts: [RemoteAgentUsageHost]) -> [RemoteAgentUsageHostState] {
        hosts.prefix(RemoteAgentUsageDefaults.maximumHosts).map {
            var state = states[$0.id] ?? RemoteAgentUsageHostState(hostID: $0.id, hostName: $0.name)
            state.hostName = $0.name
            return state
        }
    }

    /// Reads every connected host unless the last refresh is recent. Returns when all reads end.
    func refresh(hosts: [RemoteAgentUsageHost], force: Bool = false) async {
        let hosts = Array(hosts.prefix(RemoteAgentUsageDefaults.maximumHosts))
        let date = now()
        // Forget hosts that are no longer connected, so a removed machine's spend does not linger.
        let connected = Set(hosts.map(\.id))
        if states.keys.contains(where: { !connected.contains($0) }) {
            states = states.filter { connected.contains($0.key) }
            persist()
        }
        if !force, let lastRefreshAt, date.timeIntervalSince(lastRefreshAt) < RemoteAgentUsageDefaults.refreshInterval { return }
        lastRefreshAt = date
        await read(hosts)
    }

    /// Re-reads one host now — the worker page's Refresh — without touching the others.
    func refresh(host: RemoteAgentUsageHost) async {
        await read([host])
    }

    private func read(_ hosts: [RemoteAgentUsageHost]) async {
        let pending = hosts.filter { !inFlight.contains($0.id) }
        guard !pending.isEmpty else { return }
        inFlight.formUnion(pending.map(\.id))
        let client = client
        let now = now
        await withTaskGroup(of: (RemoteAgentUsageHost, Result<RemoteAgentUsageSnapshot, Error>).self) { group in
            var iterator = pending.makeIterator()
            func start(_ host: RemoteAgentUsageHost) {
                group.addTask {
                    do { return (host, .success(try await Self.read(host, client: client, now: now()))) }
                    catch { return (host, .failure(error)) }
                }
            }
            for _ in 0..<RemoteAgentUsageDefaults.maximumConcurrentHosts {
                guard let host = iterator.next() else { break }
                start(host)
            }
            while let (host, result) = await group.next() {
                record(host, result)
                if let next = iterator.next() { start(next) }
            }
        }
    }

    private func record(_ host: RemoteAgentUsageHost, _ result: Result<RemoteAgentUsageSnapshot, Error>) {
        inFlight.remove(host.id)
        var state = states[host.id] ?? RemoteAgentUsageHostState(hostID: host.id, hostName: host.name)
        state.hostName = host.name
        state.lastAttemptAt = now()
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.lastFailure = nil
        case .failure(let error):
            // The summary stays: an unreachable host is stale, not empty.
            state.lastFailure = String(error.localizedDescription.prefix(512))
        }
        states[host.id] = state
        persist()
        if postsEvents { NotificationCenter.default.post(RemoteAgentUsageDidChange()) }
    }

    private func persist() {
        _ = persistence?.save(states.values.sorted { $0.hostName < $1.hostName })
    }

    private static func read(_ host: RemoteAgentUsageHost, client: RemoteAgentUsageClient, now: Date) async throws
        -> RemoteAgentUsageSnapshot {
        let summary = try await client.summary(endpoint: host.endpoint, destination: host.destination, now: now)
        // Names are presentation. A host whose worker list cannot be read still has spend to show.
        let workers = (try? await client.workers(endpoint: host.endpoint, destination: host.destination)) ?? []
        return RemoteAgentUsageSnapshot(
            fetchedAt: now,
            from: RemoteAgentUsageDay.string(daysBefore: RemoteAgentUsageDefaults.summaryDays - 1, now),
            through: RemoteAgentUsageDay.string(now),
            completeFrom: summary.completeFrom,
            cells: summary.cells,
            workerNames: Dictionary(workers.map { ($0.id.description, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
