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

    var checkouts: [Checkout] = []

    /// Newest last, so a chart can read it left to right.
    var days: [Slice] = []
    var models: [Slice] = []

    var billedTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var turns: Int = 0
    var builtAt = Date()

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

    private let storeURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.skalman.usage-index", qos: .background)

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.storeURL = root.appendingPathComponent(UsageReportDefaults.fileName)
        load()
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
            .filter { $0 == .claude }
            .flatMap { AgentAccountDiscovery.accounts(for: $0) }
            .map(\.configPath)

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
        accountPaths: [String],
        projects: [(path: String, name: String)]
    ) -> TranscriptUsageReport {
        var seen: Set<String> = []
        var report = TranscriptUsageReport()

        var byCheckout: [String: TranscriptUsageReport.Checkout] = [:]
        var byDay: [String: Int64] = [:]
        var byModel: [String: Int64] = [:]

        for path in accountPaths {
            for url in TranscriptUsageIndex.transcripts(inAccountAt: path) {
                for entry in TranscriptUsageIndex.entries(inTranscriptAt: url, seen: &seen) {
                    report.billedTokens += entry.usage.billedTokens
                    report.cachedTokens += entry.usage.cachedTokens
                    report.turns += entry.usage.turns

                    if !entry.day.isEmpty {
                        byDay[entry.day, default: 0] += entry.usage.billedTokens
                    }
                    byModel[entry.model, default: 0] += entry.usage.billedTokens

                    let root = checkoutRoot(of: entry.workingDirectory)
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

        return report
    }

    /// The checkout a conversation ran in, which is what its spend belongs to. A subdirectory
    /// of a checkout is the same checkout; a worktree is its own.
    private nonisolated static func checkoutRoot(of directory: String) -> String {
        guard !directory.isEmpty else { return UsageReportDefaults.unknownCheckout }
        return GitInfo.repositoryRoot(for: directory)?.path ?? directory
    }

    /// `<project> · <worktree>` where the checkout belongs to a project Skalman knows, else the
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

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        report = try? decoder.decode(TranscriptUsageReport.self, from: data)
    }

    private func save() {
        guard let report else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(report).write(to: storeURL, options: .atomic)
        } catch {
            SkalmanLogger.agent.error(
                "Could not save the usage report: \(error.localizedDescription, privacy: .public)"
            )
        }
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
}
