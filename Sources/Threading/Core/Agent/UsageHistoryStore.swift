import Foundation

/// Main-actor view of rate-limit history. Durable I/O is isolated in
/// `UsageLimitHistoryJournal`; existing forecast callers retain synchronous in-memory reads.
@MainActor
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    struct PreparedJournal: Sendable {
        let samplesBySeries: [String: [UsageSample]]
        let resets: [UsageLimitResetEvent]
        let sampleIdentities: Set<String>
        let loadedAt: Date
    }

    /// Samples per `accountID|windowID`, oldest first.
    private var samples: [String: [UsageSample]]
    private var resetEvents: [UsageLimitResetEvent] = []
    private let legacySamples: [UsageSample]
    private let journal: UsageLimitHistoryJournal
    private var journalLoaded = false
    private var journalLoadTask: Task<PreparedJournal, Never>?

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        let legacy = RecoverableFileStore<[String: [UsageSample]]>(
            url: root.appendingPathComponent(UsageHistoryDefaults.legacyFileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        ).load(defaultValue: [:]).value
        let enriched = Self.enrichedLegacy(legacy)
        self.samples = enriched
        self.legacySamples = enriched.values.flatMap { $0 }
        self.journal = UsageLimitHistoryJournal(
            directory: root.appendingPathComponent(UsageLimitHistoryDefaults.directoryName)
        )

        Task { [weak self] in
            await self?.bootstrapJournal()
        }
    }

    /// Records changed observations and a sparse heartbeat. This keeps 180 days useful without
    /// turning a 30-second refresh loop into millions of identical chart points.
    func record(_ usage: AccountUsage, for account: AgentAccount) {
        var persistedSamples: [UsageSample] = []
        var persistedResets: [UsageLimitResetEvent] = []
        let accountName = AccountName.display(for: account)
        let source = sampleSource(for: account.provider, usageSource: usage.source)

        for window in usage.allWindows {
            guard let fraction = window.fraction, !window.isExpired(at: usage.observedAt) else {
                continue
            }

            let key = Self.key(accountID: account.id.rawValue, windowID: window.id)
            var series = samples[key] ?? []
            let sample = UsageSample(
                at: usage.observedAt,
                fraction: fraction,
                resetsAt: window.resetsAt,
                runtimeID: account.provider.rawValue,
                accountID: account.id.rawValue,
                accountName: accountName,
                windowID: window.id,
                windowLabel: window.label,
                windowDuration: window.windowDuration,
                source: source,
                nextResetCreditExpiresAt: usage.nextExpiringResetCredit?.expiresAt,
                resetCreditCount: usage.resetCredits
            )

            if let last = series.last {
                guard sample.at > last.at else { continue }
                let moved = abs(sample.fraction - last.fraction)
                    >= UsageHistoryDefaults.minimumChange
                let resetMoved = sample.resetsAt != last.resetsAt
                let creditChanged = sample.resetCreditCount != last.resetCreditCount
                    || sample.nextResetCreditExpiresAt != last.nextResetCreditExpiresAt
                let waited = sample.at.timeIntervalSince(last.at)
                    >= UsageHistoryDefaults.forcedInterval
                guard moved || resetMoved || creditChanged || waited else { continue }

                if let event = UsageLimitHistoryAnalysis.reset(between: last, and: sample),
                   !resetEvents.contains(where: { $0.id == event.id }) {
                    resetEvents.append(event)
                    persistedResets.append(event)
                }
            }

            series.append(sample)
            samples[key] = prune(series, now: usage.observedAt)
            persistedSamples.append(sample)
        }

        pruneEvents(now: usage.observedAt)
        persist(samples: persistedSamples, resets: persistedResets)
        if !persistedSamples.isEmpty {
            NotificationCenter.default.post(name: .usageLimitHistoryDidChange, object: self)
        }
    }

    func samples(for account: AgentAccount, windowID: String) -> [UsageSample] {
        samples[Self.key(accountID: account.id.rawValue, windowID: windowID)] ?? []
    }

    func forecast(for account: AgentAccount, window: AccountUsage.Window) -> UsageForecast.Outcome {
        UsageForecast.project(
            samples: samples(for: account, windowID: window.id),
            resetsAt: window.resetsAt
        )
    }

    /// Seeds a Codex window from bounded rollout recovery and also joins it to the long journal.
    func seed(_ recovered: [UsageSample], for account: AgentAccount, windowID: String) {
        let key = Self.key(accountID: account.id.rawValue, windowID: windowID)
        let existing = samples[key] ?? []
        let earliest = existing.first?.at ?? .distantFuture
        let accountName = AccountName.display(for: account)
        let enriched = recovered
            .filter { $0.at < earliest }
            .map {
                UsageSample(
                    at: $0.at,
                    fraction: $0.fraction,
                    resetsAt: $0.resetsAt,
                    runtimeID: account.provider.rawValue,
                    accountID: account.id.rawValue,
                    accountName: accountName,
                    windowID: windowID,
                    windowLabel: windowID,
                    windowDuration: nil,
                    source: .codexRollout
                )
            }

        guard !enriched.isEmpty else { return }
        samples[key] = prune((enriched + existing).sorted { $0.at < $1.at }, now: Date())
        persist(samples: enriched, resets: [])
        NotificationCenter.default.post(name: .usageLimitHistoryDidChange, object: self)
    }

    func snapshot(
        since: Date,
        now: Date = Date()
    ) -> UsageLimitHistorySnapshot {
        UsageLimitHistorySnapshot(
            samples: samples.values.flatMap { $0 }.filter { $0.at >= since && $0.at <= now },
            resets: resetEvents.filter { $0.detectedAt >= since && $0.detectedAt <= now },
            loadedAt: now
        )
    }

    /// Ensures a caller opening the full dashboard sees the journal load, without forcing app
    /// launch or compact pill reads to parse up to 250,000 records on the main actor.
    func loadSnapshot(
        since: Date,
        now: Date = Date()
    ) async -> UsageLimitHistorySnapshot {
        if !journalLoaded { await bootstrapJournal() }
        return snapshot(since: since, now: now)
    }

    func deleteHistory() async {
        await journal.deleteHistory()
        samples = [:]
        resetEvents = []
        journalLoaded = true
        NotificationCenter.default.post(name: .usageLimitHistoryDidChange, object: self)
    }

    private func bootstrapJournal() async {
        guard !journalLoaded else { return }
        let task: Task<PreparedJournal, Never>
        if let journalLoadTask {
            task = journalLoadTask
        } else {
            let journal = journal
            let includeIdentities = !legacySamples.isEmpty
            task = Task.detached(priority: .utility) {
                let snapshot = await journal.load(now: Date())
                return Self.prepareJournalSnapshot(
                    snapshot,
                    includeIdentities: includeIdentities
                )
            }
            journalLoadTask = task
        }
        let prepared = await task.value

        // Initialization and the dashboard's first load can arrive together. Claim the result
        // before the legacy-migration await so only one continuation merges and appends it.
        guard !journalLoaded else { return }
        journalLoaded = true
        journalLoadTask = nil

        merge(prepared)
        if !legacySamples.isEmpty {
            let missing = legacySamples.filter {
                !prepared.sampleIdentities.contains(Self.sampleIdentity($0))
            }
            if !missing.isEmpty {
                try? await journal.append(samples: missing, resets: [], now: Date())
            }
        }
        NotificationCenter.default.post(name: .usageLimitHistoryDidChange, object: self)
    }

    private func merge(_ prepared: PreparedJournal) {
        for (key, durable) in prepared.samplesBySeries {
            let existing = samples[key] ?? []
            guard !existing.isEmpty else {
                samples[key] = durable
                continue
            }

            var seenDates = Set(existing.map(\.at))
            let missing = durable.filter { seenDates.insert($0.at).inserted }
            samples[key] = prune(
                (existing + missing).sorted { $0.at < $1.at },
                now: prepared.loadedAt
            )
        }

        var ids = Set(resetEvents.map(\.id))
        for event in prepared.resets where ids.insert(event.id).inserted {
            resetEvents.append(event)
        }
        resetEvents.sort { $0.detectedAt < $1.detectedAt }
        pruneEvents(now: prepared.loadedAt)
    }

    private func persist(samples: [UsageSample], resets: [UsageLimitResetEvent]) {
        guard !samples.isEmpty || !resets.isEmpty else { return }
        Task { [journal] in
            try? await journal.append(samples: samples, resets: resets, now: Date())
        }
    }

    private func prune(_ series: [UsageSample], now: Date) -> [UsageSample] {
        let cutoff = now.addingTimeInterval(-UsageHistoryDefaults.retention)
        return Array(series.lazy.filter { $0.at >= cutoff }.suffix(UsageHistoryDefaults.maximumSamples))
    }

    private func pruneEvents(now: Date) {
        let cutoff = now.addingTimeInterval(-UsageHistoryDefaults.retention)
        resetEvents.removeAll { $0.detectedAt < cutoff }
    }

    private func sampleSource(
        for provider: AgentKind,
        usageSource: AccountUsage.Source
    ) -> UsageLimitSampleSource {
        switch (provider, usageSource) {
        case (.claude, .api): return .claudeAPI
        case (.claude, .localCache): return .claudeLocalCache
        case (.codex, _): return .codexAPI
        case (.grok, _): return .grokRuntime
        case (.openCode, _): return .openCodeRuntime
        }
    }

    private static func key(accountID: String, windowID: String) -> String {
        "\(accountID)|\(windowID)"
    }

    nonisolated static func prepareJournalSnapshot(
        _ snapshot: UsageLimitHistorySnapshot,
        includeIdentities: Bool
    ) -> PreparedJournal {
        var grouped: [String: [UsageSample]] = [:]
        grouped.reserveCapacity(32)
        for sample in snapshot.samples {
            guard let id = sample.limitSeriesID else { continue }
            grouped[id, default: []].append(sample)
        }
        for (id, raw) in grouped {
            let sorted = raw.sorted { $0.at < $1.at }
            grouped[id] = Array(sorted.suffix(UsageHistoryDefaults.maximumSamples))
        }
        let identities = includeIdentities
            ? Set(snapshot.samples.map(Self.sampleIdentity))
            : []
        return PreparedJournal(
            samplesBySeries: grouped,
            resets: snapshot.resets,
            sampleIdentities: identities,
            loadedAt: snapshot.loadedAt
        )
    }

    private nonisolated static func sampleIdentity(_ sample: UsageSample) -> String {
        [
            sample.limitSeriesID ?? "legacy",
            String(Int64((sample.at.timeIntervalSince1970 * 1_000).rounded())),
            String(sample.fraction.bitPattern)
        ].joined(separator: "|")
    }

    private static func enrichedLegacy(
        _ values: [String: [UsageSample]]
    ) -> [String: [UsageSample]] {
        Dictionary(uniqueKeysWithValues: values.map { key, series in
            guard let separator = key.lastIndex(of: "|") else { return (key, series) }
            let accountID = String(key[..<separator])
            let windowID = String(key[key.index(after: separator)...])
            let runtimeID = accountID.split(separator: ":", maxSplits: 1).first.map(String.init)
            let enriched = series.map {
                UsageSample(
                    at: $0.at,
                    fraction: $0.fraction,
                    resetsAt: $0.resetsAt,
                    runtimeID: runtimeID,
                    accountID: accountID,
                    accountName: accountID,
                    windowID: windowID,
                    windowLabel: windowID,
                    source: runtimeID == AgentKind.codex.rawValue ? .codexRollout : nil
                )
            }
            return (key, enriched)
        })
    }
}

extension Notification.Name {
    static let usageLimitHistoryDidChange = Notification.Name("usageLimitHistoryDidChange")
}

enum UsageHistoryDefaults {
    static let legacyFileName = "usage-history.json"
    static let retention: TimeInterval = TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
    static let maximumSamples = UsageLimitHistoryDefaults.retentionDays * 24 * 4
    static let minimumChange = 0.005
    static let thinHistory = 8
    static let forcedInterval: TimeInterval = 15 * 60
}
