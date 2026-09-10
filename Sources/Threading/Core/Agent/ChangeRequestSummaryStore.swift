import Foundation

/// The one bounded read path shared by durable host surfaces.
///
/// Local Git inspection and remote provider work never run on the main actor. Reads deduplicate by
/// checkout, stay fresh briefly across Git Review and native navigator consumers, and admit at
/// most four provider pipelines at once regardless of workspace size.
actor ChangeRequestSummaryStore {
    static let shared = ChangeRequestSummaryStore()
    static let successfulFreshness: TimeInterval = 60
    static let failureFreshness: TimeInterval = 15
    static let maximumConcurrentReads = 4

    struct Reading: Sendable {
        let local: ChangeRequestLocalState?
        let remoteDetection: ChangeRequestRemoteDetection?
        let outcome: ChangeRequestReadOutcome?
        let failureMessage: String?

        var repositoryStatus: ChangeRequestRepositoryStatus? {
            guard case .loaded(let status) = outcome else { return nil }
            return status
        }
    }

    private struct Cached: Sendable {
        let reading: Reading
        let date: Date
    }

    private struct Pending: Sendable {
        let id: UUID
        let task: Task<Reading, Never>
    }

    private let limiter = ChangeRequestReadLimiter(limit: maximumConcurrentReads)
    private var cache: [String: Cached] = [:]
    private var inFlight: [String: Pending] = [:]

    func read(
        root: URL,
        providers: ChangeRequestProviderRegistry,
        force: Bool = false,
        now: Date = Date()
    ) async -> Reading {
        let key = root.standardizedFileURL.path
        if !force, let cached = cache[key] {
            let freshness = cached.reading.failureMessage == nil
                ? Self.successfulFreshness : Self.failureFreshness
            if now.timeIntervalSince(cached.date) < freshness { return cached.reading }
        }
        if let pending = inFlight[key] { return await pending.task.value }

        let limiter = limiter
        let pendingID = UUID()
        let task = Task {
            await limiter.acquire()
            let reading = await Self.load(root: root, providers: providers)
            await limiter.release()
            return reading
        }
        inFlight[key] = Pending(id: pendingID, task: task)
        let reading = await task.value
        if inFlight[key]?.id == pendingID {
            inFlight[key] = nil
            cache[key] = Cached(reading: reading, date: now)
        }
        return reading
    }

    func invalidate(root: URL) {
        let key = root.standardizedFileURL.path
        cache[key] = nil
        inFlight.removeValue(forKey: key)?.task.cancel()
    }

    func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
        let pending = Array(inFlight.values)
        inFlight.removeAll(keepingCapacity: true)
        pending.forEach { $0.task.cancel() }
    }

    private static func load(
        root: URL,
        providers: ChangeRequestProviderRegistry
    ) async -> Reading {
        do {
            let local = try await ChangeRequestGit.state(in: root)
            if Task.isCancelled {
                return Reading(
                    local: local,
                    remoteDetection: nil,
                    outcome: nil,
                    failureMessage: nil
                )
            }
            let detection = await providers.repository(remote: local.remote)
            guard case .supported(let repository) = detection else {
                return Reading(
                    local: local,
                    remoteDetection: detection,
                    outcome: nil,
                    failureMessage: nil
                )
            }
            let outcome = await providers.discover(
                repository: repository,
                branch: local.branch,
                headRevision: local.headRevision
            )
            let failure: String?
            if case .failed(let message) = outcome { failure = message } else { failure = nil }
            return Reading(
                local: local,
                remoteDetection: detection,
                outcome: outcome,
                failureMessage: failure
            )
        } catch {
            return Reading(
                local: nil,
                remoteDetection: nil,
                outcome: nil,
                failureMessage: error.localizedDescription
            )
        }
    }
}

private actor ChangeRequestReadLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
