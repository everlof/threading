import Foundation

// MARK: - Usage Report

/// What the Usage page draws: totals sliced the three ways worth asking about.
struct TranscriptUsageReport: Codable, Equatable {

    /// One checkout's spend, which is the unit that answers "where did the week go" — a
    /// repository's worktrees are separate places doing separate work.
    struct Checkout: Codable, Equatable {
        let path: String
        /// `<project> · <worktree or branch>`, resolved when the report is built rather than
        /// when it is drawn, since it costs a git read per checkout.
        let label: String
        var billedTokens: Int64
        var turns: Int
    }

    struct Slice: Codable, Equatable {
        let name: String
        var billedTokens: Int64
    }

    /// Spend at quarter-hour resolution, oldest first.
    ///
    /// This is what lets the page answer the question the account is actually metered on. A
    /// five-hour window starts at an arbitrary moment, so a per-day series cannot say what it
    /// has consumed; quarter-hours can, and 8 days of them is under 800 numbers.
    struct Bucket: Codable, Equatable {
        let at: Date
        var billedTokens: Int64
        var turns: Int
    }

    var checkouts: [Checkout] = []
    var buckets: [Bucket] = []

    /// Which login spent it, for the accounts that have more than one.
    var accounts: [Slice] = []

    /// Newest last, so a chart can read it left to right.
    var days: [Slice] = []
    var models: [Slice] = []

    var billedTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var turns: Int = 0
    var builtAt = Date()

    /// Tokens spent since `start`, from the quarter-hour series — the answer to "what has this
    /// 5h window cost", which no rate-limit API reports and no daily total can reconstruct.
    func spend(since start: Date) -> (billedTokens: Int64, turns: Int) {
        buckets
            .filter { $0.at >= start }
            .reduce(into: (Int64(0), 0)) { total, bucket in
                total.0 += bucket.billedTokens
                total.1 += bucket.turns
            }
    }

    /// Days are kept for a bounded window: what a report is *for* is the current billing
    /// period and the days around it, and a year of history makes the file grow without ever
    /// being read.
    var recentDays: [Slice] { Array(days.suffix(UsageReportDefaults.dayWindow)) }
}

// MARK: - Transcript Usage Service

/// Builds and keeps the usage report.
///
/// Same shape as `ArtifactScanService`, for the same reason: the work is a full walk of a large
/// corpus — 2,501 transcripts and 46 seconds here — so the page reads a cached answer and the
/// walk happens on a `.background` queue where the system throttles its I/O.
///
/// The scan is **whole rather than incremental**, deliberately. Deduplication is global — the
/// same turn appears in several files, and which file "owns" it depends on the order they are
/// read in — so a per-file cache would have to store every turn's identity to stay correct,
/// and re-reading one changed file could not be done without the rest. A whole scan an hour, in
/// the background, is the cheaper mistake.
@MainActor
final class TranscriptUsageService {

    // MARK: - Singleton

    static let shared = TranscriptUsageService()

    // MARK: - Properties

    private(set) var report: TranscriptUsageReport?
    private(set) var isBuilding = false

    private let persistence: RecoverableFileStore<TranscriptUsageReport?>
    /// `.utility`, not `.background`: the artifact scan is a chore nobody waits on, but this
    /// one is kicked off by opening the page, and `.background` is throttled hard enough to
    /// turn a minute of work into several.
    private let queue = DispatchQueue(label: "codes.threading.usage-index", qos: .utility)

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(UsageReportDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.report = persistence.load(defaultValue: nil).value
    }

    // MARK: - Building

    /// Rebuilds when the last report has aged out, or on demand.
    func refresh(force: Bool = false) {
        guard !isBuilding else { return }

        if !force, let builtAt = report?.builtAt,
           Date().timeIntervalSince(builtAt) < UsageReportDefaults.staleAfter { return }

        isBuilding = true
        notifyChanged()

        // Resolved on the main queue, because both stores are main-actor bound; the walk that
        // follows touches neither.
        let accounts = AgentKind.allCases
            .filter { $0.supports(.transcriptUsageIndex) }
            .flatMap { AgentAccountDiscovery.accounts(for: $0) }
            .map { (path: $0.configPath, name: AccountName.display(for: $0)) }

        let projects = ProjectStore.shared.projects.map {
            (path: $0.folderPath, name: $0.name)
        }

        queue.async { [weak self] in
            let report = Self.build(accountPaths: accounts, projects: projects)

            Task { @MainActor in
                guard let self else { return }
                self.isBuilding = false
                self.report = report
                self.save()
                self.notifyChanged()
            }
        }
    }

    // MARK: - Private Methods

    /// Walks every account's transcripts once, with one shared `seen` set so a turn copied
    /// into a resume or a fork is counted for whichever file reaches it first and never again.
    private nonisolated static func build(
        accountPaths: [(path: String, name: String)],
        projects: [(path: String, name: String)]
    ) -> TranscriptUsageReport {
        var seen: Set<String> = []
        var report = TranscriptUsageReport()

        var byCheckout: [String: TranscriptUsageReport.Checkout] = [:]
        var byDay: [String: Int64] = [:]
        var byModel: [String: Int64] = [:]
        var byAccount: [String: Int64] = [:]
        var byBucket: [String: (tokens: Int64, turns: Int)] = [:]

        // Resolving a working directory to its checkout walks up the filesystem looking for a
        // `.git`, and the same few dozen directories recur across tens of thousands of entries.
        // Unmemoized it dominated the whole build — quarter-hour buckets multiplied the entry
        // count, and with it the number of times this was asked the same question.
        var rootsByDirectory: [String: String] = [:]

        for account in accountPaths {
            let path = account.path
            for url in TranscriptUsageIndex.transcripts(inAccountAt: path) {
                for entry in TranscriptUsageIndex.entries(inTranscriptAt: url, seen: &seen) {
                    report.billedTokens += entry.usage.billedTokens
                    report.cachedTokens += entry.usage.cachedTokens
                    report.turns += entry.usage.turns

                    if !entry.day.isEmpty {
                        byDay[entry.day, default: 0] += entry.usage.billedTokens
                    }
                    byModel[entry.model, default: 0] += entry.usage.billedTokens
                    byAccount[account.name, default: 0] += entry.usage.billedTokens

                    byBucket[entry.bucket, default: (0, 0)].tokens += entry.usage.billedTokens
                    byBucket[entry.bucket, default: (0, 0)].turns += entry.usage.turns

                    let root: String
                    if let known = rootsByDirectory[entry.workingDirectory] {
                        root = known
                    } else {
                        root = checkoutRoot(of: entry.workingDirectory)
                        rootsByDirectory[entry.workingDirectory] = root
                    }
                    var checkout = byCheckout[root] ?? TranscriptUsageReport.Checkout(
                        path: root,
                        label: label(for: root, projects: projects),
                        billedTokens: 0,
                        turns: 0
                    )
                    checkout.billedTokens += entry.usage.billedTokens
                    checkout.turns += entry.usage.turns
                    byCheckout[root] = checkout
                }
            }
        }

        report.checkouts = byCheckout.values.sorted { $0.billedTokens > $1.billedTokens }
        report.days = byDay.keys.sorted().map {
            TranscriptUsageReport.Slice(name: $0, billedTokens: byDay[$0] ?? 0)
        }
        report.models = byModel
            .map { TranscriptUsageReport.Slice(name: $0.key, billedTokens: $0.value) }
            .sorted { $0.billedTokens > $1.billedTokens }
        report.accounts = byAccount
            .map { TranscriptUsageReport.Slice(name: $0.key, billedTokens: $0.value) }
            .sorted { $0.billedTokens > $1.billedTokens }

        // Only the span a window could still be running in: older buckets answer nothing the
        // day slices do not, and there are 96 of them per day.
        let cutoff = Date().addingTimeInterval(-UsageReportDefaults.bucketRetention)
        report.buckets = byBucket
            .compactMap { key, value in
                guard let at = bucketDate(key), at > cutoff else { return nil }
                return TranscriptUsageReport.Bucket(
                    at: at,
                    billedTokens: value.tokens,
                    turns: value.turns
                )
            }
            .sorted { $0.at < $1.at }

        return report
    }

    /// `2026-07-22T14:30` back into a moment. UTC, which is what the transcripts write.
    private nonisolated static func bucketDate(_ key: String) -> Date? {
        bucketFormatter.date(from: key)
    }

    private nonisolated static let bucketFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The checkout a conversation ran in, which is what its spend belongs to. A subdirectory
    /// of a checkout is the same checkout; a worktree is its own.
    private nonisolated static func checkoutRoot(of directory: String) -> String {
        guard !directory.isEmpty else { return UsageReportDefaults.unknownCheckout }
        return GitInfo.repositoryRoot(for: directory)?.path ?? directory
    }

    /// `<project> · <worktree>` where the checkout belongs to a project Threading knows, else the
    /// folder's own name — spend predates the project list, and a conversation from before a
    /// folder was added still happened.
    private nonisolated static func label(
        for root: String,
        projects: [(path: String, name: String)]
    ) -> String {
        let owner = projects
            .filter { root == $0.path || root.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }

        let worktree = GitInfo.worktreeName(for: root)

        switch (owner, worktree) {
        case let (owner?, worktree?): return "\(owner.name) · \(worktree)"
        case let (owner?, nil): return owner.name
        case let (nil, worktree?): return worktree
        case (nil, nil): return URL(fileURLWithPath: root).lastPathComponent
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(TranscriptUsageDidChange())
    }

    // MARK: - Persistence

    private func save() {
        guard let report else { return }
        _ = persistence.save(report)
    }
}

// MARK: - Usage Report Defaults

enum UsageReportDefaults {
    static let fileName = "usage-report.json"

    /// A full walk is expensive and the answer moves slowly; an hour old is a fine answer to
    /// "where did the week go".
    static let staleAfter: TimeInterval = 60 * 60

    /// Days shown. Long enough to cover the weekly window and see the shape around it.
    static let dayWindow = 14

    static let unknownCheckout = "unknown"

    /// How much of the quarter-hour series to keep: a little beyond the longest window anyone
    /// is metered on, since that is the only thing it is read for.
    static let bucketRetention: TimeInterval = 9 * 24 * 3600
}
