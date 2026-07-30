import Foundation

// MARK: - Usage History Store

/// Keeps rate-limit readings over time, so a level can become a rate.
///
/// Nothing kept history before this: `AccountUsageService` held one snapshot per account, and
/// every reading before the current one was discarded. That is enough to say "85% spent" and
/// can never say "and you will run out at 19:40" — which is the question that actually changes
/// what someone does next.
///
/// Samples are cheap and the window that matters is short: one reading is a date, a fraction
/// and a reset, and anything older than the longest window it could belong to has nothing left
/// to say. The file is pruned on every write rather than growing forever.
@MainActor
final class UsageHistoryStore {

    // MARK: - Singleton

    static let shared = UsageHistoryStore()

    // MARK: - Properties

    /// Samples per `accountID|windowID`, oldest first.
    private var samples: [String: [UsageSample]] = [:]

    private let storeURL: URL
    private let fileManager: FileManager

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.storeURL = root.appendingPathComponent(UsageHistoryDefaults.fileName)
        load()
    }

    // MARK: - Public Methods

    /// Records every window of a reading, ignoring what has not moved.
    ///
    /// A reading arrives every 30 seconds from a local cache, and most say exactly what the last
    /// one did. Storing those would fill the file with duplicates and teach the forecast
    /// nothing, so a sample is kept only when the fraction actually changed or enough time has
    /// passed to prove the *absence* of change.
    func record(_ usage: AccountUsage, for account: AgentAccount) {
        for window in usage.windows {
            guard let fraction = window.fraction, !window.isExpired() else { continue }

            let key = "\(account.id)|\(window.id)"
            var series = samples[key] ?? []

            if let last = series.last {
                let moved = abs(fraction - last.fraction) >= UsageHistoryDefaults.minimumChange
                let waited = usage.observedAt.timeIntervalSince(last.at)
                    >= UsageHistoryDefaults.forcedInterval
                guard moved || waited else { continue }
            }

            series.append(UsageSample(
                at: usage.observedAt,
                fraction: fraction,
                resetsAt: window.resetsAt
            ))

            samples[key] = prune(series)
        }

        save()
    }

    /// Every sample kept for one window of one account, oldest first.
    func samples(for account: AgentAccount, windowID: String) -> [UsageSample] {
        samples["\(account.id)|\(windowID)"] ?? []
    }

    /// The projection for one window, or `.unknown` while the history is too thin to claim one.
    func forecast(for account: AgentAccount, window: AccountUsage.Window) -> UsageForecast.Outcome {
        UsageForecast.project(
            samples: samples(for: account, windowID: window.id),
            resetsAt: window.resetsAt
        )
    }

    /// Seeds a window's history from readings recovered elsewhere — Codex writes rate limits
    /// into its own rollouts, so a fresh install can know the week's shape before it has watched
    /// any of it.
    func seed(_ recovered: [UsageSample], for account: AgentAccount, windowID: String) {
        let key = "\(account.id)|\(windowID)"
        let existing = samples[key] ?? []

        // Anything already observed wins: a live reading is first-hand, and a recovered one is
        // whatever a rollout happened to record.
        let earliest = existing.first?.at ?? .distantFuture
        let merged = recovered.filter { $0.at < earliest } + existing

        samples[key] = prune(merged.sorted { $0.at < $1.at })
        save()
    }

    // MARK: - Private Methods

    /// Drops what is too old to belong to any window still in progress, and caps the series so
    /// a busy day cannot grow it without bound.
    private func prune(_ series: [UsageSample]) -> [UsageSample] {
        let cutoff = Date().addingTimeInterval(-UsageHistoryDefaults.retention)
        let recent = series.filter { $0.at > cutoff }
        return Array(recent.suffix(UsageHistoryDefaults.maximumSamples))
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        samples = (try? decoder.decode([String: [UsageSample]].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(samples).write(to: storeURL, options: .atomic)
        } catch {
            ThreadingLogger.agent.error(
                "Could not save usage history: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - Usage History Defaults

enum UsageHistoryDefaults {
    static let fileName = "usage-history.json"

    /// Longer than the longest window anyone meters on, so a weekly window always has its whole
    /// span available, and nothing older is kept.
    static let retention: TimeInterval = 9 * 24 * 3600

    /// Enough for a reading every few minutes across a week.
    static let maximumSamples = 4000

    /// Movement below this is the same reading again — Claude reports whole percentages, so one
    /// point is the smallest real change there is.
    static let minimumChange = 0.005

    /// Below this many samples, a window has no shape worth projecting from and is worth
    /// recovering from disk where that is possible.
    static let thinHistory = 8

    /// Recorded even without movement at this spacing, because a window that is *not* moving is
    /// itself a fact the forecast needs.
    static let forcedInterval: TimeInterval = 15 * 60
}
