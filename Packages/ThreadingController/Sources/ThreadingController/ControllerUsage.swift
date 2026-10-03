import Foundation
import ThreadingUsage

// What each agent spent, kept on the host that ran it. A receipt per execution is written once
// its process is confirmed stopped, from that execution's transcript read through the same
// adapters the Mac's Usage page uses (ThreadingUsage). Attribution — worker, task, chain,
// trigger — comes from the controller's own records, never from the transcript or the model.
// See docs/feature-drafts/agent-usage-ledger.md.

/// Where a recipe's runtime writes its transcript. Owner-authored with the recipe.
public struct ControllerUsageSource: Codable, Equatable, Sendable {
    public enum Runtime: String, Codable, Sendable { case claude, codex }
    public let runtime: Runtime
    /// The runtime's configuration home: `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
    public let home: String
    /// The login this home belongs to, as a person would name it.
    public let account: String?
    public init(runtime: Runtime, home: String, account: String? = nil) { self.runtime = runtime; self.home = home; self.account = account }
    func validate() throws {
        try Limits.text(home, field: "usage_home", maximum: 4096)
        guard home.hasPrefix("/") else { throw ControllerError.invalidInput("usage_home") }
        if let account { try Limits.text(account, field: "usage_account", maximum: 256) }
    }
}

public enum UsageCoverage: String, Codable, Sendable { case complete, partial, failed, unavailable }

/// Tokens for one model within one execution. Categories stay separate, as on the Mac.
public struct UsageCell: Codable, Equatable, Sendable {
    public let model: String
    public var tokens: UsageTokenCounts
    public var requests: Int
    public var costUSD: Double
    public var unpricedTokens: Int64
    public init(model: String, tokens: UsageTokenCounts = UsageTokenCounts(), requests: Int = 0, costUSD: Double = 0, unpricedTokens: Int64 = 0) {
        self.model = model; self.tokens = tokens; self.requests = requests; self.costUSD = costUSD; self.unpricedTokens = unpricedTokens
    }
}

public struct UsageReceipt: Codable, Equatable, Sendable {
    public let executionID: ExecutionID
    public let workID: WorkID
    public let workerID: WorkerID
    public let source: WorkSource?
    /// The mail chain this execution acted on, if any.
    public let chainID: UUID?
    /// The trigger whose event admitted this work, if any.
    public let triggerID: String?
    public let runtime: String
    public let account: String
    public let cells: [UsageCell]
    public let coverage: UsageCoverage
    public let reason: String?
    public let endedAt: String
    /// The measure budgets use: everything but cached input reads, which providers bill at a
    /// fraction and which a long conversation rereads every turn.
    public var budgetTokens: Int64 { cells.reduce(0) { $0 + UsageReceipt.budgetTokens($1.tokens) } }
    static func budgetTokens(_ tokens: UsageTokenCounts) -> Int64 { tokens.uncachedInput + tokens.cacheWrite + tokens.output }
}

/// A day's spend for one worker, account and model — what a dashboard range reads.
public struct UsageDailyCell: Codable, Equatable, Sendable {
    public let day: String
    public let workerID: WorkerID
    public let account: String
    public let model: String
    public let uncachedInput: Int64
    public let cachedInput: Int64
    public let cacheWrite: Int64
    public let output: Int64
    public let reasoning: Int64
    public let costUSD: Double
    public let requests: Int64
    public let executions: Int64
}

/// Owner-set ceiling on what one worker may spend in a UTC day, in budget tokens. Admission
/// stops starting new executions past it; running ones are never stopped.
public struct WorkerBudget: Codable, Equatable, Sendable {
    public let workerID: WorkerID
    public let revision: Int
    public let tokensPerDay: Int64?
}

struct UsageChainTotal: Codable { var tokens: Int64; var executions: Int }

extension ControllerStore {
    /// Stopped executions whose receipt has not been written yet, oldest first.
    public func pendingUsage(limit: Int = 8) throws -> [ExecutionID] {
        let rows = try db.rows("SELECT execution FROM usage_pending ORDER BY rowid LIMIT ?", [.integer(Int64(min(limit, 100)))])
        return try rows.map { try ExecutionID($0.text(0)) }
    }

    /// Commits the receipt, its daily cells and chain total together, and clears the pending
    /// entry. Idempotent: a second write for the same execution returns the first.
    public func recordUsageReceipt(_ executionID: ExecutionID, runtime: String, account: String,
                                   cells: [UsageCell], coverage: UsageCoverage, reason: String?) throws -> UsageReceipt {
        try db.transaction {
            if let existing: UsageReceipt = try optional("usageReceipt", executionID.description) {
                try db.run("DELETE FROM usage_pending WHERE execution=?", [.text(executionID.description)])
                return existing
            }
            let launch = try launch(executionID)
            let work = try work(launch.workID)
            let context: MailContext? = try optional("mailContext", executionID.description)
            let trigger = work.key.hasPrefix("trigger:") ? work.key.split(separator: ":").dropFirst().first.map(String.init) : nil
            var bounded = cells.sorted { UsageReceipt.budgetTokens($0.tokens) > UsageReceipt.budgetTokens($1.tokens) }
            if bounded.count > 16 {
                // Overflow folds into one cell so totals stay exact and the record stays bounded.
                let rest = bounded[15...].reduce(UsageCell(model: "other models")) { sum, cell in
                    var sum = sum
                    sum.tokens += cell.tokens; sum.requests += cell.requests
                    sum.costUSD += cell.costUSD; sum.unpricedTokens += cell.unpricedTokens
                    return sum
                }
                bounded = Array(bounded[..<15]) + [rest]
            }
            let receipt = UsageReceipt(executionID: executionID, workID: work.id, workerID: work.workerID, source: work.source,
                                       chainID: context?.chainID, triggerID: trigger, runtime: runtime,
                                       account: String(account.prefix(256)), cells: bounded, coverage: coverage,
                                       reason: reason.map { String($0.prefix(512)) }, endedAt: Self.now())
            try insert("usageReceipt", executionID.description, parent: work.id.description, state: coverage.rawValue,
                       scope: work.workerID.description, value: receipt)
            let day = String(receipt.endedAt.prefix(10))
            for (index, cell) in bounded.enumerated() {
                try db.run("""
                    INSERT INTO usage_daily(day,worker,account,model,uncached,cached,cache_write,output,reasoning,cost,requests,executions)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(day,worker,account,model) DO UPDATE SET uncached=uncached+excluded.uncached,
                    cached=cached+excluded.cached, cache_write=cache_write+excluded.cache_write, output=output+excluded.output,
                    reasoning=reasoning+excluded.reasoning, cost=cost+excluded.cost, requests=requests+excluded.requests,
                    executions=executions+excluded.executions
                    """, [.text(day), .text(work.workerID.description), .text(receipt.account), .text(cell.model),
                          .integer(cell.tokens.uncachedInput), .integer(cell.tokens.cachedInput), .integer(cell.tokens.cacheWrite),
                          .integer(cell.tokens.output), .integer(cell.tokens.reasoning), .text(String(cell.costUSD)),
                          .integer(Int64(cell.requests)), .integer(index == 0 ? 1 : 0)])
            }
            if let chain = context?.chainID {
                let id = chain.uuidString.lowercased()
                var total: UsageChainTotal = try optional("usageChain", id) ?? UsageChainTotal(tokens: 0, executions: 0)
                let isNew = (try optional("usageChain", id) as UsageChainTotal?) == nil
                total.tokens += receipt.budgetTokens; total.executions += 1
                if isNew { try insert("usageChain", id, value: total) } else { try update("usageChain", id, value: total) }
            }
            try db.run("DELETE FROM usage_pending WHERE execution=?", [.text(executionID.description)])
            try event("usage.recorded", executionID.description)
            return receipt
        }
    }

    public func usageReceipt(_ executionID: ExecutionID) throws -> UsageReceipt? { try optional("usageReceipt", executionID.description) }
    public func usageReceipts(worker: WorkerID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<UsageReceipt> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record WHERE kind='usageReceipt' AND scope=? AND sequence>? ORDER BY sequence LIMIT ?
            """, [.text(worker.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }
    /// Daily cells for a UTC date range, a page at a time: O(days × cells), never O(executions).
    public func usageSummary(from: String, through: String, after: Int64 = 0, limit: Int = 100) throws -> ControllerPage<UsageDailyCell> {
        try Limits.page(after, limit)
        guard from.count == 10, through.count == 10 else { throw ControllerError.invalidInput("day") }
        let rows = try db.rows("""
            SELECT rowid,day,worker,account,model,uncached,cached,cache_write,output,reasoning,cost,requests,executions
            FROM usage_daily WHERE day>=? AND day<=? AND rowid>? ORDER BY rowid LIMIT ?
            """, [.text(from), .text(through), .integer(after), .integer(Int64(limit))])
        let cells = try rows.map { row in
            UsageDailyCell(day: try row.text(1), workerID: try WorkerID(row.text(2)), account: try row.text(3), model: try row.text(4),
                           uncachedInput: row.integers[5], cachedInput: row.integers[6], cacheWrite: row.integers[7],
                           output: row.integers[8], reasoning: row.integers[9], costUSD: Double(try row.text(10)) ?? 0,
                           requests: row.integers[11], executions: row.integers[12])
        }
        return ControllerPage(items: cells, next: rows.last?.integers[0] ?? after)
    }
    public func chainUsage(_ chainID: UUID) throws -> Int64 {
        (try optional("usageChain", chainID.uuidString.lowercased()) as UsageChainTotal?)?.tokens ?? 0
    }

    public func setWorkerBudget(_ worker: WorkerID, expectedRevision: Int, tokensPerDay: Int64?) throws -> WorkerBudget {
        if let tokensPerDay { guard tokensPerDay > 0 else { throw ControllerError.invalidInput("budget") } }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", worker.description)
            let prior: WorkerBudget? = try optional("workerBudget", worker.description)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let value = WorkerBudget(workerID: worker, revision: expectedRevision + 1, tokensPerDay: tokensPerDay)
            if prior == nil { try insert("workerBudget", worker.description, value: value) } else { try update("workerBudget", worker.description, value: value) }
            try event("worker.budget_changed", worker.description)
            return value
        }
    }
    public func workerBudget(_ worker: WorkerID) throws -> WorkerBudget? { try optional("workerBudget", worker.description) }

    /// Today's budget tokens for a worker, read from its daily cells (a handful of rows).
    func workerSpendToday(_ worker: WorkerID) throws -> Int64 {
        let day = String(Self.now().prefix(10))
        let rows = try db.rows("SELECT COALESCE(SUM(uncached+cache_write+output),0) FROM usage_daily WHERE day=? AND worker=?",
                               [.text(day), .text(worker.description)])
        return rows.first?.integers[0] ?? 0
    }
    func workerWithinBudget(_ worker: WorkerID) throws -> Bool {
        guard let limit = try workerBudget(worker)?.tokensPerDay else { return true }
        return try workerSpendToday(worker) < limit
    }
}
