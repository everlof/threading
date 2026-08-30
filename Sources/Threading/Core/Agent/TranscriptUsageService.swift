import Foundation

// MARK: - Usage Report

/// Persisted, provider-neutral input for every range the Usage page can present.
struct TranscriptUsageReport: Codable, Equatable, Sendable {
    struct Checkout: Codable, Equatable, Sendable {
        let path: String
        let label: String
        var billedTokens: Int64
        var turns: Int
        var costUSD: Double = 0
        /// See `Slice.runtimeID`. A checkout usually is worked in by more than one runtime, so
        /// this is nil more often than it is set — which is the honest answer, not a gap.
        var runtimeID: String?
    }

    struct Slice: Codable, Equatable, Sendable {
        let name: String
        var billedTokens: Int64
        var tokens: UsageTokenCounts = .init()
        var costUSD: Double = 0
        var records: Int = 0
        /// The one runtime every cell folded into this slice came through, or nil when more than
        /// one did.
        ///
        /// Attribution rather than a second axis: it exists so a breakdown row can wear the mark
        /// of the agent that produced it, and a slice that cannot name one runtime wears none.
        /// `nil` is absorbing — see `accumulate` — because "several" and "not known" are the same
        /// answer to the only question asked of it.
        var runtimeID: String?
    }

    struct Bucket: Codable, Equatable, Sendable {
        let at: Date
        var billedTokens: Int64
        var turns: Int
    }

    struct Cell: Codable, Equatable, Sendable {
        let day: Date
        let origin: UsageOrigin
        /// Provider transcript identity retained so a manager can ask for one session's exact
        /// ledger slice instead of receiving every conversation in the same checkout.
        var sessionID: String? = nil
        let accountID: String
        let accountName: String
        let model: String
        let checkoutPath: String
        let checkoutLabel: String
        var tokens: UsageTokenCounts
        var providerReportedCostUSD: Double
        var catalogCostUSD: Double
        var unpricedTokens: Int64
        var cacheSavingsUSD: Double
        var records: Int

        var costUSD: Double { providerReportedCostUSD + catalogCostUSD }
    }

    /// One session's lifetime ledger at the smallest grain the session surfaces need.
    ///
    /// The Usage page keeps ninety daily cells because its charts have a fixed range. A session
    /// can be older than that, though, and "this session" must not silently mean "the last
    /// ninety days of this session." These cells are therefore aggregated before the date
    /// window is applied. They retain model, account, and billing origin for an honest detailed
    /// breakdown without retaining one value per response.
    struct SessionCell: Codable, Equatable, Sendable {
        let sessionID: String
        let origin: UsageOrigin
        let accountID: String
        let accountName: String
        let model: String
        var tokens: UsageTokenCounts
        var providerReportedCostUSD: Double
        var catalogCostUSD: Double
        var unpricedTokens: Int64
        var cacheSavingsUSD: Double
        var records: Int
        /// Optional for reports built before transcript role provenance was retained.
        var sessionKind: UsageSessionKind? = nil
        /// The durable provider parent, when the transcript names one exactly.
        var parentSessionID: String? = nil

        var costUSD: Double { providerReportedCostUSD + catalogCostUSD }
    }

    struct ScanStatistics: Codable, Equatable, Sendable {
        var sourceFiles: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
        var rawRecords: Int = 0
        var distinctRecords: Int = 0
        var duration: TimeInterval = 0
    }

    var cells: [Cell] = []
    /// Optional for decoding reports built before lifetime session attribution was retained.
    /// Consumers fall back to the ninety-day cells and say so until the next scan replaces it.
    var sessionCells: [SessionCell]? = nil
    var buckets: [Bucket] = []
    var coverage: [UsageSourceCoverage] = []
    var scan = ScanStatistics()
    var builtAt = Date()
    var pricingCatalogVersion = UsagePricingCatalog.version

    /// Compatibility views used by window-spend presentation and the old report while the new
    /// retained page is assembled.
    var billedTokens: Int64 { cells.reduce(0) { $0 + $1.tokens.legacyBilled } }
    var cachedTokens: Int64 { cells.reduce(0) { $0 + $1.tokens.cachedInput } }
    var turns: Int { cells.reduce(0) { $0 + $1.records } }
    var checkouts: [Checkout] { selection(days: UsageReportDefaults.maximumDayRange).checkouts }
    var accounts: [Slice] { selection(days: UsageReportDefaults.maximumDayRange).accounts }
    var days: [Slice] { selection(days: UsageReportDefaults.maximumDayRange).days }
    var models: [Slice] { selection(days: UsageReportDefaults.maximumDayRange).models }
    var recentDays: [Slice] { Array(days.suffix(UsageReportDefaults.legacyDayWindow)) }

    func spend(since start: Date) -> (billedTokens: Int64, turns: Int) {
        buckets
            .filter { $0.at >= start }
            .reduce(into: (Int64(0), 0)) { total, bucket in
                total.0 += bucket.billedTokens
                total.1 += bucket.turns
            }
    }

    func selection(
        days range: Int,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageReportSelection {
        UsageReportSelection(
            cells: cells,
            range: min(max(1, range), UsageReportDefaults.maximumDayRange),
            now: now,
            calendar: calendar
        )
    }
}

// MARK: - Range Selection

struct UsageReportSelection: Equatable, Sendable {
    struct Provider: Equatable, Sendable {
        let origin: UsageOrigin
        var tokens: UsageTokenCounts
        var costUSD: Double
        var records: Int
    }

    struct Daily: Equatable, Sendable {
        let day: Date
        let origin: UsageOrigin
        var tokens: UsageTokenCounts
        var costUSD: Double
    }

    struct CostQuality: Equatable, Sendable {
        var providerReportedUSD: Double = 0
        var catalogPricedUSD: Double = 0
        var unpricedTokens: Int64 = 0
        var cacheSavingsUSD: Double = 0

        var totalUSD: Double { providerReportedUSD + catalogPricedUSD }
    }

    let range: Int
    let start: Date
    let end: Date
    let tokens: UsageTokenCounts
    let records: Int
    let cost: CostQuality
    let providers: [Provider]
    let daily: [Daily]
    let models: [TranscriptUsageReport.Slice]
    let days: [TranscriptUsageReport.Slice]
    let accounts: [TranscriptUsageReport.Slice]
    let checkouts: [TranscriptUsageReport.Checkout]

    init(cells: [TranscriptUsageReport.Cell], range: Int, now: Date, calendar: Calendar) {
        self.range = range
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(range - 1), to: today) ?? today
        self.start = start
        self.end = calendar.date(byAdding: .day, value: 1, to: today) ?? now

        let selected = cells.filter { $0.day >= start && $0.day <= today }
        var total = UsageTokenCounts()
        var recordCount = 0
        var quality = CostQuality()
        var byProvider: [UsageOrigin: Provider] = [:]
        var byDaily: [DailyKey: Daily] = [:]
        var byModel: [String: TranscriptUsageReport.Slice] = [:]
        var byDay: [Date: TranscriptUsageReport.Slice] = [:]
        var byAccount: [String: TranscriptUsageReport.Slice] = [:]
        var byCheckout: [String: TranscriptUsageReport.Checkout] = [:]

        for cell in selected {
            total += cell.tokens
            recordCount += cell.records
            quality.providerReportedUSD += cell.providerReportedCostUSD
            quality.catalogPricedUSD += cell.catalogCostUSD
            quality.unpricedTokens += cell.unpricedTokens
            quality.cacheSavingsUSD += cell.cacheSavingsUSD

            var provider = byProvider[cell.origin] ?? Provider(
                origin: cell.origin,
                tokens: .init(),
                costUSD: 0,
                records: 0
            )
            provider.tokens += cell.tokens
            provider.costUSD += cell.costUSD
            provider.records += cell.records
            byProvider[cell.origin] = provider

            let dailyKey = DailyKey(day: cell.day, origin: cell.origin)
            var daily = byDaily[dailyKey] ?? Daily(
                day: cell.day,
                origin: cell.origin,
                tokens: .init(),
                costUSD: 0
            )
            daily.tokens += cell.tokens
            daily.costUSD += cell.costUSD
            byDaily[dailyKey] = daily

            Self.accumulate(
                &byModel,
                key: cell.model,
                name: cell.model,
                cell: cell
            )
            Self.accumulate(
                &byAccount,
                key: cell.accountID,
                name: cell.accountName,
                cell: cell
            )
            Self.accumulate(
                &byDay,
                key: cell.day,
                name: Self.dayLabel(cell.day, calendar: calendar),
                cell: cell
            )

            var checkout = byCheckout[cell.checkoutPath] ?? .init(
                path: cell.checkoutPath,
                label: cell.checkoutLabel,
                billedTokens: 0,
                turns: 0,
                costUSD: 0,
                runtimeID: cell.origin.runtimeID
            )
            checkout.billedTokens += cell.tokens.legacyBilled
            checkout.turns += cell.records
            checkout.costUSD += cell.costUSD
            if checkout.runtimeID != cell.origin.runtimeID { checkout.runtimeID = nil }
            byCheckout[cell.checkoutPath] = checkout
        }

        self.tokens = total
        self.records = recordCount
        self.cost = quality
        self.providers = byProvider.values.sorted { lhs, rhs in
            if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
            return lhs.tokens.processed > rhs.tokens.processed
        }
        self.daily = byDaily.values.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            return lhs.origin.seriesName < rhs.origin.seriesName
        }
        self.models = byModel.values.sorted(by: Self.sliceOrder)
        self.days = byDay.values.sorted { $0.name < $1.name }
        self.accounts = byAccount.values.sorted(by: Self.sliceOrder)
        self.checkouts = byCheckout.values.sorted { lhs, rhs in
            if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
            return lhs.billedTokens > rhs.billedTokens
        }
    }

    private struct DailyKey: Hashable {
        let day: Date
        let origin: UsageOrigin
    }

    private static func accumulate<Key: Hashable>(
        _ values: inout [Key: TranscriptUsageReport.Slice],
        key: Key,
        name: String,
        cell: TranscriptUsageReport.Cell
    ) {
        var value = values[key] ?? .init(
            name: name,
            billedTokens: 0,
            runtimeID: cell.origin.runtimeID
        )
        value.tokens += cell.tokens
        value.billedTokens += cell.tokens.legacyBilled
        value.costUSD += cell.costUSD
        value.records += cell.records
        // Absorbing on purpose: a slice already reading "several runtimes" (nil) can never be
        // talked back into naming one, and a second runtime always removes the name. One
        // comparison, no mixed-flag to keep in step with it.
        if value.runtimeID != cell.origin.runtimeID { value.runtimeID = nil }
        values[key] = value
    }

    private static func sliceOrder(
        _ lhs: TranscriptUsageReport.Slice,
        _ rhs: TranscriptUsageReport.Slice
    ) -> Bool {
        if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
        return lhs.billedTokens > rhs.billedTokens
    }

    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04lld-%02lld-%02lld",
            Int64(components.year ?? 0),
            Int64(components.month ?? 0),
            Int64(components.day ?? 0)
        )
    }
}

// MARK: - Ledger Builder

enum UsageLedgerBuilder {
    struct ProjectDescriptor: Sendable {
        let path: String
        let name: String
    }

    private struct CellKey: Hashable {
        let day: Date
        let origin: UsageOrigin
        let sessionID: String
        let accountID: String
        let model: String
        let checkoutPath: String
    }

    private struct SessionCellKey: Hashable {
        let sessionID: String
        let origin: UsageOrigin
        let accountID: String
        let model: String
        let sessionKind: UsageSessionKind?
        let parentSessionID: String?
    }

    static func build(
        records: [UsageLedgerRecord],
        coverage: [UsageSourceCoverage],
        projects: [ProjectDescriptor],
        scan: TranscriptUsageReport.ScanStatistics,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> TranscriptUsageReport {
        // The array entry point remains for adapters and focused tests. The shipping scan uses
        // the streaming overload below so total history never becomes one resident array.
        build(
            forEachRecord: { body in records.forEach(body) },
            coverage: coverage,
            projects: projects,
            scan: scan,
            now: now,
            calendar: calendar
        )
    }

    static func build(
        forEachRecord: (_ body: (UsageLedgerRecord) -> Void) throws -> Void,
        recordsAreDistinct: Bool = false,
        coverage: [UsageSourceCoverage],
        projects: [ProjectDescriptor],
        scan: TranscriptUsageReport.ScanStatistics,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) rethrows -> TranscriptUsageReport {
        if !recordsAreDistinct {
            var recordsByIdentity: [String: UsageLedgerRecord] = [:]
            try forEachRecord { record in
                if let previous = recordsByIdentity[record.identity] {
                    recordsByIdentity[record.identity] = previous.mergingUsageMaximums(
                        with: record
                    )
                } else {
                    recordsByIdentity[record.identity] = record
                }
            }
            return build(
                forEachRecord: { body in recordsByIdentity.values.forEach(body) },
                recordsAreDistinct: true,
                coverage: coverage,
                projects: projects,
                scan: scan,
                now: now,
                calendar: calendar
            )
        }

        let oldest = calendar.date(
            byAdding: .day,
            value: -(UsageReportDefaults.maximumDayRange - 1),
            to: calendar.startOfDay(for: now)
        ) ?? .distantPast
        var rootsByDirectory: [String: String] = [:]
        var labelsByRoot: [String: String] = [:]
        var byCell: [CellKey: TranscriptUsageReport.Cell] = [:]
        var bySessionCell: [SessionCellKey: TranscriptUsageReport.SessionCell] = [:]
        var byBucket: [Date: TranscriptUsageReport.Bucket] = [:]
        var distinct = 0

        try forEachRecord { raw in
            distinct += 1
            let priced = UsagePricingCatalog.price(raw)

            let sessionKey = SessionCellKey(
                sessionID: priced.sessionID,
                origin: priced.origin,
                accountID: priced.accountID,
                model: priced.model,
                sessionKind: priced.sessionKind,
                parentSessionID: priced.parentSessionID
            )
            var sessionCell = bySessionCell[sessionKey] ?? .init(
                sessionID: priced.sessionID,
                origin: priced.origin,
                accountID: priced.accountID,
                accountName: priced.accountName,
                model: priced.model,
                tokens: .init(),
                providerReportedCostUSD: 0,
                catalogCostUSD: 0,
                unpricedTokens: 0,
                cacheSavingsUSD: 0,
                records: 0,
                sessionKind: priced.sessionKind,
                parentSessionID: priced.parentSessionID
            )
            sessionCell.tokens += priced.tokens
            sessionCell.records += 1
            sessionCell.cacheSavingsUSD += priced.cacheSavingsUSD
            switch priced.costSource {
            case .providerReported:
                sessionCell.providerReportedCostUSD += priced.costUSD ?? 0
            case .catalogPriced:
                sessionCell.catalogCostUSD += priced.costUSD ?? 0
            case .unpriced:
                sessionCell.unpricedTokens += priced.tokens.processed
            }
            bySessionCell[sessionKey] = sessionCell

            // Missing provider timestamps still contribute to the lifetime session receipt, but
            // cannot honestly be placed on a day chart or in a quarter-hour spend bucket.
            guard let at = raw.at else { return }
            let day = calendar.startOfDay(for: at)

            let root: String
            if let known = rootsByDirectory[raw.workingDirectory] {
                root = known
            } else {
                root = checkoutRoot(of: raw.workingDirectory)
                rootsByDirectory[raw.workingDirectory] = root
            }
            let checkoutLabel: String
            if let known = labelsByRoot[root] {
                checkoutLabel = known
            } else {
                checkoutLabel = label(for: root, projects: projects)
                labelsByRoot[root] = checkoutLabel
            }

            if day >= oldest {
                let key = CellKey(
                    day: day,
                    origin: priced.origin,
                    sessionID: priced.sessionID,
                    accountID: priced.accountID,
                    model: priced.model,
                    checkoutPath: root
                )
                var cell = byCell[key] ?? .init(
                    day: day,
                    origin: priced.origin,
                    sessionID: priced.sessionID,
                    accountID: priced.accountID,
                    accountName: priced.accountName,
                    model: priced.model,
                    checkoutPath: root,
                    checkoutLabel: checkoutLabel,
                    tokens: .init(),
                    providerReportedCostUSD: 0,
                    catalogCostUSD: 0,
                    unpricedTokens: 0,
                    cacheSavingsUSD: 0,
                    records: 0
                )
                cell.tokens += priced.tokens
                cell.records += 1
                cell.cacheSavingsUSD += priced.cacheSavingsUSD
                switch priced.costSource {
                case .providerReported:
                    cell.providerReportedCostUSD += priced.costUSD ?? 0
                case .catalogPriced:
                    cell.catalogCostUSD += priced.costUSD ?? 0
                case .unpriced:
                    cell.unpricedTokens += priced.tokens.processed
                }
                byCell[key] = cell
            }

            if at >= now.addingTimeInterval(-UsageReportDefaults.bucketRetention) {
                let bucketDate = UsageLedgerDate.quarterHour(at)
                var bucket = byBucket[bucketDate] ?? .init(
                    at: bucketDate,
                    billedTokens: 0,
                    turns: 0
                )
                bucket.billedTokens += priced.tokens.legacyBilled
                bucket.turns += 1
                byBucket[bucketDate] = bucket
            }
        }

        var finalScan = scan
        finalScan.distinctRecords = distinct
        return TranscriptUsageReport(
            cells: byCell.values.sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                if lhs.origin.seriesID != rhs.origin.seriesID {
                    return lhs.origin.seriesID < rhs.origin.seriesID
                }
                return lhs.model < rhs.model
            },
            sessionCells: bySessionCell.values.sorted { lhs, rhs in
                if lhs.sessionID != rhs.sessionID { return lhs.sessionID < rhs.sessionID }
                if lhs.origin.seriesID != rhs.origin.seriesID {
                    return lhs.origin.seriesID < rhs.origin.seriesID
                }
                return lhs.model < rhs.model
            },
            buckets: byBucket.values.sorted { $0.at < $1.at },
            coverage: coverage.sorted { $0.runtimeName < $1.runtimeName },
            scan: finalScan,
            builtAt: now,
            pricingCatalogVersion: UsagePricingCatalog.version
        )
    }

    private static func checkoutRoot(of directory: String) -> String {
        guard !directory.isEmpty else { return UsageReportDefaults.unknownCheckout }
        return GitInfo.repositoryRoot(for: directory)?.path ?? directory
    }

    private static func label(for root: String, projects: [ProjectDescriptor]) -> String {
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
}

// MARK: - Scan progress

/// How far a usage scan has got, while the report it will produce does not exist yet.
///
/// The dashboard used to have one bit for this: building or not. That is enough to choose a
/// sentence and nothing else, so a scan of a well-used machine — thousands of transcripts across
/// several accounts, seconds of filesystem work on a cold cache — looked exactly like a scan that
/// had stalled. The counts are what make the difference visible.
struct UsageScanProgress: Sendable, Equatable {

    /// What is being read right now, named the way the coverage list names it.
    let sourceName: String?
    let completedSources: Int
    /// Zero while the sources are still being enumerated, which is the one phase with no
    /// denominator to report.
    let totalSources: Int

    /// `nil` while the total is unknown, so a caller shows an indeterminate state rather than a
    /// bar pinned at zero.
    var fraction: Double? {
        guard totalSources > 0 else { return nil }
        return min(max(Double(completedSources) / Double(totalSources), 0), 1)
    }
}

/// Turns a per-file scan into a bounded stream of progress reports.
///
/// A warm scan answers nearly every file from `UsageScanCache` and gets through thousands of them
/// a second. Reporting each one would post more main-actor work than the scan itself does, and the
/// dashboard cannot show a number that changes 5,000 times either. So a report leaves here when
/// the interval has elapsed, or when the source being read changes — the second condition is what
/// keeps "Claude Code" from sitting on screen through the whole of the Codex half.
///
/// Created and used on the scan queue; the closure it is given is what crosses to the main actor.
final class UsageScanProgressReporter {

    private let interval: CFTimeInterval
    private let clock: () -> CFTimeInterval
    private let publish: (UsageScanProgress) -> Void

    private var total = 0
    private var completed = 0
    private var sourceName: String?
    private var lastPublishedAt: CFTimeInterval?

    init(
        interval: CFTimeInterval = UsageScanDefaults.progressInterval,
        clock: @escaping () -> CFTimeInterval = { CFAbsoluteTimeGetCurrent() },
        publish: @escaping (UsageScanProgress) -> Void
    ) {
        self.interval = interval
        self.clock = clock
        self.publish = publish
    }

    /// The sources have been counted. Always reported: it is the moment an indeterminate wait
    /// becomes a determinate one.
    func begin(totalSources: Int) {
        total = totalSources
        emit()
    }

    /// One source has been read. Reported only if this tick is due.
    func advance(sourceName: String) {
        completed += 1
        let changedSource = sourceName != self.sourceName
        self.sourceName = sourceName
        guard changedSource || isDue else { return }
        emit()
    }

    private var isDue: Bool {
        guard let lastPublishedAt else { return true }
        return clock() - lastPublishedAt >= interval
    }

    private func emit() {
        lastPublishedAt = clock()
        publish(UsageScanProgress(
            sourceName: sourceName,
            completedSources: completed,
            totalSources: total
        ))
    }
}

// MARK: - Transcript Usage Service

@MainActor
final class TranscriptUsageService {
    static let shared = TranscriptUsageService()

    private struct AccountSource: Sendable {
        let runtimeID: String
        let path: String
        let accountID: String
        let accountName: String
    }

    private struct ExportSource: Sendable {
        let runtimeID: String
        let transcriptID: String
        let projectPath: String
        let lastActiveAt: Date
    }

    /// One transcript or rollout waiting to be parsed, resolved during enumeration so the scan
    /// knows how much work it has before it starts doing any of it.
    private struct PendingSource {
        let runtime: AgentKind
        let account: AccountSource
        let file: URL
        let parserID: String
    }

    private(set) var report: TranscriptUsageReport?
    private(set) var isBuilding = false
    /// Non-nil only while `isBuilding`. Read by the dashboard's placeholder.
    private(set) var scanProgress: UsageScanProgress?

    private let persistence: RecoverableFileStore<TranscriptUsageReport?>
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "codes.threading.usage-index", qos: .utility)

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
        self.cacheDirectory = root.appendingPathComponent(UsageScanCacheDefaults.directoryName)
        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(UsageReportDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.report = persistence.load(defaultValue: nil).value
    }

    func refresh(force: Bool = false) {
        guard !isBuilding else { return }
        if !force, let builtAt = report?.builtAt,
           Date().timeIntervalSince(builtAt) < UsageReportDefaults.staleAfter { return }

        isBuilding = true
        scanProgress = nil
        notifyChanged()

        let accountSources = AgentKind.allCases
            .filter { $0.supports(.transcriptUsageIndex) }
            .flatMap { runtime in
                AgentAccountDiscovery.accounts(for: runtime).map { account in
                    AccountSource(
                        runtimeID: runtime.rawValue,
                        path: account.configPath,
                        accountID: account.id.rawValue,
                        accountName: AccountName.display(for: account)
                    )
                }
            }
        let projects = ProjectStore.shared.projects
        let projectDescriptors = projects.map {
            UsageLedgerBuilder.ProjectDescriptor(path: $0.folderPath, name: $0.name)
        }
        let exports: [ExportSource] = projects.flatMap { project in
            project.sessions.compactMap { session in
                guard let transcriptID = session.resumeState.transcriptID else { return nil }
                switch session.kind {
                case .openCode:
                    return ExportSource(
                        runtimeID: session.kind.rawValue,
                        transcriptID: transcriptID.rawValue,
                        projectPath: project.folderPath,
                        lastActiveAt: session.lastActiveAt
                    )
                case .claude, .codex, .grok, .cursor:
                    return nil
                }
            }
        }
        let loginShellPath = AgentLauncher.loginShellPath
        let cacheDirectory = cacheDirectory
        let previousReport = report
        ThreadingLogger.usage.info(
            "Usage scan started accounts=\(accountSources.count, privacy: .public) projects=\(projects.count, privacy: .public) exports=\(exports.count, privacy: .public)"
        )

        queue.async { [weak self] in
            let reporter = UsageScanProgressReporter { progress in
                Task { @MainActor in
                    guard let self, self.isBuilding else { return }
                    self.scanProgress = progress
                    NotificationCenter.default.post(TranscriptUsageScanProgressDidChange())
                }
            }
            let report = Self.build(
                accountSources: accountSources,
                exportSources: exports,
                projects: projectDescriptors,
                loginShellPath: loginShellPath,
                cacheDirectory: cacheDirectory,
                reporter: reporter,
                previousReport: previousReport
            )

            Task { @MainActor in
                guard let self else { return }
                self.isBuilding = false
                self.scanProgress = nil
                self.report = report
                _ = self.persistence.save(report)
                let failedCoverage = report.coverage.filter { $0.state == .failed }.count
                ThreadingLogger.usage.info(
                    "Usage scan completed sources=\(report.scan.sourceFiles, privacy: .public) cache_hits=\(report.scan.cacheHits, privacy: .public) cache_misses=\(report.scan.cacheMisses, privacy: .public) records=\(report.scan.distinctRecords, privacy: .public) failed_sources=\(failedCoverage, privacy: .public) duration_ms=\(Int(report.scan.duration * 1_000), privacy: .public)"
                )
                self.notifyChanged()
            }
        }
    }

    private nonisolated static func build(
        accountSources: [AccountSource],
        exportSources: [ExportSource],
        projects: [UsageLedgerBuilder.ProjectDescriptor],
        loginShellPath: String,
        cacheDirectory: URL,
        reporter: UsageScanProgressReporter,
        previousReport: TranscriptUsageReport?
    ) -> TranscriptUsageReport {
        let started = CFAbsoluteTimeGetCurrent()
        let cache = UsageScanCache(directory: cacheDirectory)
        cache.beginScan()
        defer { cache.finishScan() }

        let index: UsageLedgerIndex
        do {
            index = try UsageLedgerIndex(directory: cacheDirectory)
            index.beginScan()
        } catch {
            ThreadingLogger.usage.error(
                "Usage ledger index unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            var fallback = previousReport ?? TranscriptUsageReport()
            fallback.builtAt = Date()
            fallback.scan.duration = CFAbsoluteTimeGetCurrent() - started
            return fallback
        }

        var scan = TranscriptUsageReport.ScanStatistics()
        var coverage = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { runtime in
            let detail: String?
            switch runtime {
            case .grok: detail = GrokUsageAdapter.coverageDetail
            case .openCode: detail = "No resumable OpenCode sessions are known to Threading yet."
            case .claude, .codex: detail = "No transcript source was found."
            case .cursor: detail = "Cursor reports no usage over its protocol."
            }
            return (runtime.rawValue, UsageSourceCoverage(
                runtimeID: runtime.rawValue,
                runtimeName: runtime.displayName,
                state: runtime.supports(.transcriptUsageIndex) ? .unavailable : .partial,
                sourceCount: 0,
                recordCount: 0,
                detail: detail
            ))
        })
        coverage[UsageReportDefaults.openRouterCoverageID] = UsageSourceCoverage(
            runtimeID: UsageReportDefaults.openRouterCoverageID,
            runtimeName: "OpenRouter via OpenCode",
            state: .unavailable,
            sourceCount: 0,
            recordCount: 0,
            detail: "Appears when a supported OpenCode export reports OpenRouter as its billing route."
        )

        // Enumerated before anything is parsed, so the progress a reader sees has a denominator
        // from the first file rather than a total that keeps growing under the bar. Listing a
        // directory is the cheap half of this work; parsing it is the rest.
        var pending: [PendingSource] = []
        for source in accountSources {
            guard let runtime = AgentKind(rawValue: source.runtimeID) else { continue }
            let files: [URL]
            let parserID: String
            switch runtime {
            case .claude:
                files = TranscriptUsageIndex.transcripts(inAccountAt: source.path)
                    .sorted { $0.path < $1.path }
                parserID = UsageScanCacheDefaults.claudeParserID
            case .codex:
                files = CodexUsageAdapter.rollouts(inAccountAt: source.path)
                    .sorted { $0.path < $1.path }
                parserID = UsageScanCacheDefaults.codexParserID
            case .grok, .openCode, .cursor:
                files = []
                parserID = "unused"
            }
            pending.append(contentsOf: files.map {
                PendingSource(runtime: runtime, account: source, file: $0, parserID: parserID)
            })
        }
        // Only runtimes whose usage arrives through an export are counted, so the bar is measured
        // against the work that will actually be done.
        let pendingExports = exportSources.filter { source in
            guard let runtime = AgentKind(rawValue: source.runtimeID) else { return false }
            switch runtime {
            case .openCode: return true
            case .claude, .codex, .grok, .cursor: return false
            }
        }
        reporter.begin(totalSources: pending.count + pendingExports.count)

        for source in pending {
            let runtime = source.runtime
            let account = source.account
            let file = source.file
            guard var item = coverage[runtime.rawValue] else {
                ThreadingLogger.usage.fault(
                    "Usage coverage invariant missing runtime=\(runtime.rawValue, privacy: .public)"
                )
                assertionFailure("Missing usage coverage for \(runtime.rawValue)")
                continue
            }
            item.sourceCount += 1
            scan.sourceFiles += 1
            let result: UsageLedgerIndex.Update
            do {
                result = try index.update(source: file, parserID: source.parserID) {
                    try cache.records(for: file, parserID: source.parserID) {
                        switch runtime {
                        case .claude:
                            return try ClaudeUsageAdapter.records(
                                inTranscriptAt: file,
                                accountID: account.accountID,
                                accountName: account.accountName
                            )
                        case .codex:
                            return try CodexUsageAdapter.records(
                                inRolloutAt: file,
                                accountID: account.accountID,
                                accountName: account.accountName
                            )
                        case .grok, .openCode, .cursor:
                            return []
                        }
                    }
                }
            } catch let error as SQLiteDatabase.Failure {
                ThreadingLogger.usage.error(
                    "Usage ledger index update failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                var fallback = previousReport ?? TranscriptUsageReport()
                fallback.builtAt = Date()
                fallback.scan.duration = CFAbsoluteTimeGetCurrent() - started
                return fallback
            } catch {
                // The source is deliberately absent from `usedSources` after a loader failure,
                // so `finishScan` also removes any stale complete revision from the ledger.
                // Keeping its old rows while saying coverage is partial would still present a
                // mixture of old and new facts as the current transcript.
                item.state = item.recordCount > 0 || item.state == .complete
                    ? .partial
                    : .failed
                item.detail = "One or more \(runtime.displayName) transcripts could not be read completely."
                coverage[runtime.rawValue] = item
                reporter.advance(sourceName: runtime.displayName)
                ThreadingLogger.usage.error(
                    "Usage transcript failed runtime=\(runtime.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                continue
            }
            if result.wasCacheHit { scan.cacheHits += 1 } else { scan.cacheMisses += 1 }
            reporter.advance(sourceName: runtime.displayName)
            item.recordCount += result.recordCount
            switch item.state {
            case .unavailable:
                item.state = .complete
                item.detail = nil
            case .failed:
                // At least one earlier source failed and this one succeeded: some records are
                // known, but the runtime total is still not complete.
                item.state = .partial
            case .complete, .partial:
                break
            }
            coverage[runtime.rawValue] = item
        }

        for source in pendingExports {
            guard let runtime = AgentKind(rawValue: source.runtimeID) else { continue }
            guard var item = coverage[runtime.rawValue] else {
                ThreadingLogger.usage.fault(
                    "Usage coverage invariant missing runtime=\(runtime.rawValue, privacy: .public)"
                )
                assertionFailure("Missing usage coverage for \(runtime.rawValue)")
                continue
            }
            item.sourceCount += 1
            do {
                let key = "opencode|\(source.transcriptID)"
                let result = try index.update(
                    key: key,
                    revision: source.lastActiveAt,
                    parserID: UsageScanCacheDefaults.openCodeParserID
                ) {
                    try cache.records(
                        forKey: key,
                        revision: source.lastActiveAt,
                        parserID: UsageScanCacheDefaults.openCodeParserID
                    ) {
                        let data = try ConversationHandoffCapture.runExport(
                            kind: runtime,
                            transcriptID: TranscriptID(source.transcriptID),
                            projectFolder: source.projectPath,
                            loginShellPath: loginShellPath
                        )
                        return try OpenCodeUsageAdapter.records(fromExport: data)
                    }
                }
                scan.sourceFiles += 1
                if result.wasCacheHit { scan.cacheHits += 1 } else { scan.cacheMisses += 1 }
                item.recordCount += result.recordCount
                item.state = .complete
                item.detail = nil

                if result.routedRecordCount > 0 {
                    let routeID = UsageReportDefaults.openRouterCoverageID
                    if var route = coverage[routeID] {
                        route.sourceCount += 1
                        route.recordCount += result.routedRecordCount
                        route.state = .complete
                        route.detail = nil
                        coverage[routeID] = route
                    } else {
                        ThreadingLogger.usage.fault(
                            "Usage coverage invariant missing route=\(routeID, privacy: .public)"
                        )
                        assertionFailure("Missing usage coverage for \(routeID)")
                    }
                }
            } catch let error as SQLiteDatabase.Failure {
                ThreadingLogger.usage.error(
                    "Usage ledger index update failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                var fallback = previousReport ?? TranscriptUsageReport()
                fallback.builtAt = Date()
                fallback.scan.duration = CFAbsoluteTimeGetCurrent() - started
                return fallback
            } catch {
                item.state = item.recordCount > 0 ? .partial : .failed
                item.detail = "One or more OpenCode exports could not be read."
                ThreadingLogger.usage.error(
                    "Usage export failed runtime=\(runtime.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            // A source that failed is still a source the scan is done with; a bar that only
            // counts successes stops short of its own end whenever an export breaks.
            reporter.advance(sourceName: runtime.displayName)
            coverage[runtime.rawValue] = item
        }

        do {
            scan.rawRecords = try index.finishScan()
        } catch {
            ThreadingLogger.usage.error(
                "Usage ledger index cleanup failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            var fallback = previousReport ?? TranscriptUsageReport()
            fallback.builtAt = Date()
            fallback.scan.duration = CFAbsoluteTimeGetCurrent() - started
            return fallback
        }
        scan.duration = CFAbsoluteTimeGetCurrent() - started
        do {
            return try UsageLedgerBuilder.build(
                forEachRecord: { body in try index.forEachRecord(body) },
                recordsAreDistinct: true,
                coverage: Array(coverage.values),
                projects: projects,
                scan: scan
            )
        } catch {
            ThreadingLogger.usage.error(
                "Usage ledger index read failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            var fallback = previousReport ?? TranscriptUsageReport()
            fallback.builtAt = Date()
            fallback.scan.duration = CFAbsoluteTimeGetCurrent() - started
            return fallback
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(TranscriptUsageDidChange())
    }
}

enum UsageReportDefaults {
    static let fileName = "usage-report-v2.json"
    static let staleAfter: TimeInterval = 60 * 60
    static let maximumDayRange = 90
    static let legacyDayWindow = 14
    static let unknownCheckout = "unknown"
    static let openRouterCoverageID = "openrouter"
    static let bucketRetention: TimeInterval = 9 * 24 * 3600
}
