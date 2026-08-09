import Foundation

// MARK: - Usage Report

/// Persisted, provider-neutral input for every range the Usage page can present.
struct TranscriptUsageReport: Codable, Equatable {
    struct Checkout: Codable, Equatable {
        let path: String
        let label: String
        var billedTokens: Int64
        var turns: Int
        var costUSD: Double = 0
    }

    struct Slice: Codable, Equatable {
        let name: String
        var billedTokens: Int64
        var tokens: UsageTokenCounts = .init()
        var costUSD: Double = 0
        var records: Int = 0
    }

    struct Bucket: Codable, Equatable {
        let at: Date
        var billedTokens: Int64
        var turns: Int
    }

    struct Cell: Codable, Equatable {
        let day: Date
        let origin: UsageOrigin
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

    struct ScanStatistics: Codable, Equatable {
        var sourceFiles: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
        var rawRecords: Int = 0
        var distinctRecords: Int = 0
        var duration: TimeInterval = 0
    }

    var cells: [Cell] = []
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

struct UsageReportSelection: Equatable {
    struct Provider: Equatable {
        let origin: UsageOrigin
        var tokens: UsageTokenCounts
        var costUSD: Double
        var records: Int
    }

    struct Daily: Equatable {
        let day: Date
        let origin: UsageOrigin
        var tokens: UsageTokenCounts
        var costUSD: Double
    }

    struct CostQuality: Equatable {
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
                costUSD: 0
            )
            checkout.billedTokens += cell.tokens.legacyBilled
            checkout.turns += cell.records
            checkout.costUSD += cell.costUSD
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
        var value = values[key] ?? .init(name: name, billedTokens: 0)
        value.tokens += cell.tokens
        value.billedTokens += cell.tokens.legacyBilled
        value.costUSD += cell.costUSD
        value.records += cell.records
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
        let accountID: String
        let model: String
        let checkoutPath: String
    }

    static func build(
        records rawRecords: [UsageLedgerRecord],
        coverage: [UsageSourceCoverage],
        projects: [ProjectDescriptor],
        scan: TranscriptUsageReport.ScanStatistics,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> TranscriptUsageReport {
        let oldest = calendar.date(
            byAdding: .day,
            value: -(UsageReportDefaults.maximumDayRange - 1),
            to: calendar.startOfDay(for: now)
        ) ?? .distantPast
        var seen = Set<String>()
        var rootsByDirectory: [String: String] = [:]
        var labelsByRoot: [String: String] = [:]
        var byCell: [CellKey: TranscriptUsageReport.Cell] = [:]
        var byBucket: [Date: TranscriptUsageReport.Bucket] = [:]
        var distinct = 0

        for raw in rawRecords {
            guard seen.insert(raw.identity).inserted else { continue }
            distinct += 1
            guard let at = raw.at else { continue }
            let priced = UsagePricingCatalog.price(raw)
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
                    accountID: priced.accountID,
                    model: priced.model,
                    checkoutPath: root
                )
                var cell = byCell[key] ?? .init(
                    day: day,
                    origin: priced.origin,
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

    private(set) var report: TranscriptUsageReport?
    private(set) var isBuilding = false

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
                case .claude, .codex, .grok:
                    return nil
                }
            }
        }
        let loginShellPath = AgentLauncher.loginShellPath
        let cacheDirectory = cacheDirectory

        queue.async { [weak self] in
            let report = Self.build(
                accountSources: accountSources,
                exportSources: exports,
                projects: projectDescriptors,
                loginShellPath: loginShellPath,
                cacheDirectory: cacheDirectory
            )

            Task { @MainActor in
                guard let self else { return }
                self.isBuilding = false
                self.report = report
                _ = self.persistence.save(report)
                self.notifyChanged()
            }
        }
    }

    private nonisolated static func build(
        accountSources: [AccountSource],
        exportSources: [ExportSource],
        projects: [UsageLedgerBuilder.ProjectDescriptor],
        loginShellPath: String,
        cacheDirectory: URL
    ) -> TranscriptUsageReport {
        let started = CFAbsoluteTimeGetCurrent()
        let cache = UsageScanCache(directory: cacheDirectory)
        cache.beginScan()
        defer { cache.finishScan() }

        var records: [UsageLedgerRecord] = []
        var scan = TranscriptUsageReport.ScanStatistics()
        var coverage = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { runtime in
            let detail: String?
            switch runtime {
            case .grok: detail = GrokUsageAdapter.coverageDetail
            case .openCode: detail = "No resumable OpenCode sessions are known to Threading yet."
            case .claude, .codex: detail = "No transcript source was found."
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
            case .grok, .openCode:
                files = []
                parserID = "unused"
            }

            for file in files {
                let result = cache.records(for: file, parserID: parserID) {
                    switch runtime {
                    case .claude:
                        return ClaudeUsageAdapter.records(
                            inTranscriptAt: file,
                            accountID: source.accountID,
                            accountName: source.accountName
                        )
                    case .codex:
                        return CodexUsageAdapter.records(
                            inRolloutAt: file,
                            accountID: source.accountID,
                            accountName: source.accountName
                        )
                    case .grok, .openCode:
                        return []
                    }
                }
                scan.sourceFiles += 1
                if result.wasCacheHit { scan.cacheHits += 1 } else { scan.cacheMisses += 1 }
                records.append(contentsOf: result.records)
                var item = coverage[runtime.rawValue]!
                item.sourceCount += 1
                item.recordCount += result.records.count
                item.state = .complete
                item.detail = nil
                coverage[runtime.rawValue] = item
            }
        }

        for source in exportSources {
            guard let runtime = AgentKind(rawValue: source.runtimeID) else { continue }
            switch runtime {
            case .openCode: break
            case .claude, .codex, .grok: continue
            }
            var item = coverage[runtime.rawValue]!
            item.sourceCount += 1
            do {
                let result = try cache.records(
                    forKey: "opencode|\(source.transcriptID)",
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
                scan.sourceFiles += 1
                if result.wasCacheHit { scan.cacheHits += 1 } else { scan.cacheMisses += 1 }
                records.append(contentsOf: result.records)
                item.recordCount += result.records.count
                item.state = .complete
                item.detail = nil

                let routed = result.records.filter {
                    $0.origin.billingProviderID == UsageReportDefaults.openRouterCoverageID
                }
                if !routed.isEmpty {
                    var route = coverage[UsageReportDefaults.openRouterCoverageID]!
                    route.sourceCount += 1
                    route.recordCount += routed.count
                    route.state = .complete
                    route.detail = nil
                    coverage[UsageReportDefaults.openRouterCoverageID] = route
                }
            } catch {
                item.state = item.recordCount > 0 ? .partial : .failed
                item.detail = "One or more OpenCode exports could not be read."
            }
            coverage[runtime.rawValue] = item
        }

        scan.rawRecords = records.count
        scan.duration = CFAbsoluteTimeGetCurrent() - started
        return UsageLedgerBuilder.build(
            records: records,
            coverage: Array(coverage.values),
            projects: projects,
            scan: scan
        )
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
