import Foundation
import ThreadingController
import ThreadingUsage

/// Folds the Agents breakdown and a worker's usage page from values already in hand: the Mac's
/// range selection and each host's cached daily cells, or one worker's cells and receipts.
///
/// Attribution rules (usage-dashboard.md, "Remote hosts are sources of their own"):
/// - **Billed to the host.** Mirrored remote sessions are rows of that host, never this Mac's;
///   workers' rows always name the host whose controller ran them.
/// - **Nothing counted twice.** Session rows come only from the transcript ledger and worker rows
///   only from controller cells. Workers' transcripts are never mirrored, so the two cannot
///   overlap; within a host, cells are keyed (day, worker, account, model) and a repeat replaces.
/// - **Coverage is data.** A host never read is an unmeasured row, a stale one keeps its last
///   numbers with their age, and a page-budget cut is marked partial.
///
/// Work is O(days × cells) per host; nothing here is proportional to executions.
enum AgentUsageProjector {
    nonisolated static func agents(
        selection: UsageReportSelection,
        hosts: [RemoteAgentUsageHostState],
        now: Date
    ) -> UsageDashboardBreakdownProjection {
        var rows: [UsageDashboardBreakdownRowProjection] = selection.locations.map {
            .init(
                title: L10n.string("Sessions"),
                tokens: $0.tokens.processed,
                costUSD: $0.costUSD,
                records: $0.records,
                runtimeID: nil,
                location: $0.hostName ?? L10n.string("This Mac")
            )
        }
        var unmeasured: [UsageDashboardBreakdownRowProjection] = []
        let from = RemoteAgentUsageDay.string(daysBefore: selection.range - 1, now)
        for host in hosts {
            guard let snapshot = host.snapshot else {
                unmeasured.append(.init(title: L10n.string("Workers"), tokens: 0, costUSD: 0, records: 0,
                                        runtimeID: nil, location: host.hostName, isUnmeasured: true))
                continue
            }
            let staleSince: Date? = {
                if case .stale(let since) = host.freshness(now: now) { return since }
                return nil
            }()
            let partial = snapshot.completeFrom > from
            let workers = workerTotals(snapshot.cells, from: from)
            if workers.isEmpty {
                rows.append(.init(title: L10n.string("Workers"), tokens: 0, costUSD: 0, records: 0, runtimeID: nil,
                                  location: host.hostName, staleSince: staleSince, isPartial: partial))
            }
            for (worker, total) in workers {
                rows.append(.init(
                    title: snapshot.workerNames[worker] ?? L10n.format("Worker %@", String(worker.prefix(8))),
                    tokens: total.tokens.processed,
                    costUSD: total.costUSD,
                    records: Int(clamping: total.requests),
                    runtimeID: nil,
                    location: host.hostName,
                    staleSince: staleSince,
                    isPartial: partial
                ))
            }
        }
        rows.sort { lhs, rhs in
            if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return (lhs.location ?? "", lhs.title) < (rhs.location ?? "", rhs.title)
        }
        return UsageDashboardProjector.cappedBreakdown(rows + unmeasured)
    }

    struct Total: Equatable, Sendable {
        var tokens = UsageTokenCounts()
        var costUSD: Double = 0
        var requests: Int64 = 0
        var executions: Int64 = 0

        mutating func add(_ cell: UsageDailyCell) {
            tokens += Self.tokens(cell)
            costUSD += cell.costUSD
            requests += cell.requests
            executions += cell.executions
        }

        static func tokens(_ cell: UsageDailyCell) -> UsageTokenCounts {
            UsageTokenCounts(uncachedInput: cell.uncachedInput, cachedInput: cell.cachedInput,
                             cacheWrite: cell.cacheWrite, output: cell.output, reasoning: cell.reasoning)
        }

        /// What a worker's daily budget counts: everything but cached reads.
        var budgetTokens: Int64 { tokens.uncachedInput + tokens.cacheWrite + tokens.output }
    }

    /// Cells keyed (day, worker, account, model), so a cell read twice — a page boundary moving
    /// under a live host — counts once, as its latest value.
    nonisolated static func distinct(_ cells: [UsageDailyCell]) -> [UsageDailyCell] {
        struct Key: Hashable { let day: String; let worker: String; let account: String; let model: String }
        var index: [Key: Int] = [:]
        var result: [UsageDailyCell] = []
        result.reserveCapacity(cells.count)
        for cell in cells {
            let key = Key(day: cell.day, worker: cell.workerID.description, account: cell.account, model: cell.model)
            if let existing = index[key] { result[existing] = cell } else { index[key] = result.count; result.append(cell) }
        }
        return result
    }

    nonisolated static func workerTotals(_ cells: [UsageDailyCell], from: String) -> [(String, Total)] {
        var totals: [String: Total] = [:]
        for cell in distinct(cells) where cell.day >= from {
            totals[cell.workerID.description, default: Total()].add(cell)
        }
        return totals.sorted { $0.key < $1.key }
    }
}

// MARK: - A worker's page

/// One worker's spend, from its host's daily cells (exact, by day) and the receipts read so far
/// (by task, trigger and mail chain, each with its coverage).
struct RemoteWorkerUsageProjection: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let day: String
        let total: AgentUsageProjector.Total
    }

    /// One execution's receipt, as the page lists it.
    struct Execution: Equatable, Sendable {
        let executionID: String
        let workID: String
        let endedAt: String
        let trigger: String?
        let chain: String?
        let coverage: UsageCoverage
        let reason: String?
        let tokens: Int64
        let budgetTokens: Int64
        let costUSD: Double
    }

    struct Group: Equatable, Sendable {
        let key: String
        var executions: Int
        var tokens: Int64
        var costUSD: Double
        /// Executions whose receipt is not `complete`: their spend is missing or short.
        var incomplete: Int
    }

    let days: [Day]
    let total: AgentUsageProjector.Total
    let today: AgentUsageProjector.Total
    /// Newest first, at most `maximumExecutions`.
    let executions: [Execution]
    let byTask: [Group]
    let byTrigger: [Group]
    let byChain: [Group]
    let receiptsRead: Int
    let incompleteReceipts: Int

    static let maximumExecutions = 500
    static let maximumGroups = 200

    nonisolated static func make(worker: WorkerID, cells: [UsageDailyCell], receipts: [UsageReceipt],
                                 days: Int, now: Date) -> RemoteWorkerUsageProjection {
        let from = RemoteAgentUsageDay.string(daysBefore: days - 1, now)
        let todayKey = RemoteAgentUsageDay.string(now)
        var byDay: [String: AgentUsageProjector.Total] = [:]
        var total = AgentUsageProjector.Total()
        var today = AgentUsageProjector.Total()
        for cell in AgentUsageProjector.distinct(cells) where cell.workerID == worker {
            if cell.day == todayKey { today.add(cell) }
            guard cell.day >= from else { continue }
            byDay[cell.day, default: .init()].add(cell)
            total.add(cell)
        }
        var seen: Set<String> = []
        var executions: [Execution] = []
        var task: [String: Group] = [:]
        var trigger: [String: Group] = [:]
        var chain: [String: Group] = [:]
        var incomplete = 0
        for receipt in receipts where receipt.workerID == worker && String(receipt.endedAt.prefix(10)) >= from {
            guard seen.insert(receipt.executionID.description).inserted else { continue }
            let tokens = receipt.cells.reduce(Int64(0)) { $0 + $1.tokens.processed }
            let cost = receipt.cells.reduce(0.0) { $0 + $1.costUSD }
            let isIncomplete = receipt.coverage != .complete
            if isIncomplete { incomplete += 1 }
            let execution = Execution(
                executionID: receipt.executionID.description, workID: receipt.workID.description,
                endedAt: receipt.endedAt, trigger: receipt.triggerID,
                chain: receipt.chainID?.uuidString.lowercased(), coverage: receipt.coverage, reason: receipt.reason,
                tokens: tokens, budgetTokens: receipt.budgetTokens, costUSD: cost
            )
            executions.append(execution)
            func add(_ groups: inout [String: Group], _ key: String) {
                var group = groups[key] ?? Group(key: key, executions: 0, tokens: 0, costUSD: 0, incomplete: 0)
                group.executions += 1; group.tokens += tokens; group.costUSD += cost
                if isIncomplete { group.incomplete += 1 }
                groups[key] = group
            }
            add(&task, execution.workID)
            add(&trigger, execution.trigger ?? "")
            if let chainKey = execution.chain { add(&chain, chainKey) }
        }
        executions.sort { $0.endedAt > $1.endedAt }
        let ranked: ([String: Group]) -> [Group] = { groups in
            Array(groups.values.sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.key < rhs.key
            }.prefix(maximumGroups))
        }
        return RemoteWorkerUsageProjection(
            days: byDay.map { Day(day: $0.key, total: $0.value) }.sorted { $0.day > $1.day },
            total: total, today: today,
            executions: Array(executions.prefix(maximumExecutions)),
            byTask: ranked(task), byTrigger: ranked(trigger), byChain: ranked(chain),
            receiptsRead: seen.count, incompleteReceipts: incomplete
        )
    }
}
