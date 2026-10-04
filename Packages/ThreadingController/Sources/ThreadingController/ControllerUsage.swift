import Foundation
import ThreadingUsage

// What each agent spent, kept on the host that ran it. A receipt per execution is written once
// its process is confirmed stopped, from that execution's transcripts read through the same
// adapters the Mac's Usage page uses (ThreadingUsage). Attribution — worker, task, chain,
// trigger, account — comes from the controller's own records, never from the transcript or the
// model. See docs/architecture/autonomous-controller.md#usage-receipts-and-budgets-schema-v9.

/// Where a recipe's runtime writes its transcripts. Owner-authored with the recipe.
///
/// A recipe may run under more than one login: a runner that fails over from an exhausted
/// account resumes the conversation under the next one, which copies the transcript into that
/// account's home. `accounts` declares those logins in attempt order. The legacy one-home shape
/// (`home` with an optional `account`) stays valid and is a single attempt.
public struct ControllerUsageSource: Codable, Equatable, Sendable {
    public enum Runtime: String, Codable, Sendable { case claude, codex }

    /// One login the runtime may use: its configuration home (`CLAUDE_CONFIG_DIR` or
    /// `CODEX_HOME`) and the name spend is attributed to.
    public struct Account: Codable, Equatable, Sendable {
        public let account: String
        public let home: String
        public init(account: String, home: String) { self.account = account; self.home = home }
    }

    public static let maximumAccounts = 8
    static let maximumHomeBytes = 4096
    static let maximumAccountBytes = 256

    public let runtime: Runtime
    /// Legacy single home. With `accounts`, absent or equal to the first entry's home.
    public let home: String?
    /// Legacy single account name. With `accounts`, absent or equal to the first entry's name.
    public let account: String?
    /// Declared logins in attempt order.
    public let accounts: [Account]?

    public init(runtime: Runtime, home: String, account: String? = nil) {
        self.runtime = runtime; self.home = home; self.account = account; self.accounts = nil
    }
    public init(runtime: Runtime, accounts: [Account]) {
        self.runtime = runtime; self.home = nil; self.account = nil; self.accounts = accounts
    }

    /// The declared attempts. A legacy recipe is one attempt, named by its account or its home.
    public var attempts: [Account] {
        if let accounts, !accounts.isEmpty { return accounts }
        let home = home ?? ""
        return [Account(account: account ?? home, home: home)]
    }

    /// The attempt whose home contains `path`, if any. Homes never nest, so at most one does.
    func attempt(containing path: String) -> Account? {
        let resolved = Self.standardized(path)
        return attempts.first { resolved.hasPrefix(Self.standardized($0.home) + "/") }
    }

    func validate() throws {
        if let accounts {
            guard (1...Self.maximumAccounts).contains(accounts.count) else { throw ControllerError.invalidInput("usage_accounts") }
            // Older controllers read only `home`/`account`, so a recipe may state both shapes
            // while they agree; a disagreement would mean different hosts charge different logins.
            if let home, Self.standardized(home) != Self.standardized(accounts[0].home) {
                throw ControllerError.invalidInput("usage_accounts_conflict")
            }
            if let account, account != accounts[0].account { throw ControllerError.invalidInput("usage_accounts_conflict") }
        } else if home == nil {
            throw ControllerError.invalidInput("usage_home")
        }
        if let account { try Limits.text(account, field: "usage_account", maximum: Self.maximumAccountBytes) }
        let attempts = attempts
        for attempt in attempts {
            try Limits.text(attempt.home, field: "usage_home", maximum: Self.maximumHomeBytes)
            guard attempt.home.hasPrefix("/") else { throw ControllerError.invalidInput("usage_home") }
            // A legacy recipe without an account name is named by its home, as before.
            if accounts != nil { try Limits.text(attempt.account, field: "usage_account", maximum: Self.maximumAccountBytes) }
        }
        guard Set(attempts.map(\.account)).count == attempts.count else { throw ControllerError.invalidInput("usage_accounts_duplicate") }
        let homes = attempts.map { Self.standardized($0.home) }
        for (index, home) in homes.enumerated() {
            for other in homes[(index + 1)...] where home == other || home.hasPrefix(other + "/") || other.hasPrefix(home + "/") {
                throw ControllerError.invalidInput("usage_homes_overlap")
            }
        }
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}

public enum UsageCoverage: String, Codable, Sendable { case complete, partial, failed, unavailable }

/// Tokens for one model within one execution, attributed to one declared account. Categories
/// stay separate, as on the Mac.
public struct UsageCell: Codable, Equatable, Sendable {
    public let model: String
    /// The declared account this spend is attributed to. Absent on receipts written before
    /// per-account cells; the receipt's `account` applies then.
    public var account: String?
    public var tokens: UsageTokenCounts
    public var requests: Int
    public var costUSD: Double
    public var unpricedTokens: Int64
    /// The part of `costUSD` that is a catalogue list-price estimate rather than a
    /// provider-reported amount. Absent on older receipts.
    public var catalogCostUSD: Double?
    public init(model: String, account: String? = nil, tokens: UsageTokenCounts = UsageTokenCounts(), requests: Int = 0,
                costUSD: Double = 0, unpricedTokens: Int64 = 0, catalogCostUSD: Double? = nil) {
        self.model = model; self.account = account; self.tokens = tokens; self.requests = requests
        self.costUSD = costUSD; self.unpricedTokens = unpricedTokens; self.catalogCostUSD = catalogCostUSD
    }
    mutating func add(_ other: UsageCell) {
        tokens += other.tokens; requests += other.requests
        costUSD += other.costUSD; unpricedTokens += other.unpricedTokens
        if catalogCostUSD != nil || other.catalogCostUSD != nil { catalogCostUSD = (catalogCostUSD ?? 0) + (other.catalogCostUSD ?? 0) }
    }
}

/// One declared account's share of an execution, in attempt order. Every declared account is
/// listed, including those that spent nothing, so a consumer can tell "not used" from "absent".
public struct UsageAccountTotal: Codable, Equatable, Sendable {
    public let account: String
    public let tokens: UsageTokenCounts
    public let budgetTokens: Int64
    public let requests: Int
    public let costUSD: Double
    public let unpricedTokens: Int64
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
    /// The first declared account (the recipe's primary login). Per-account spend is in
    /// `accounts` and on each cell.
    public let account: String
    public let cells: [UsageCell]
    public let coverage: UsageCoverage
    public let reason: String?
    public let endedAt: String
    public let startedAt: String?
    public let durationSeconds: Double?
    public let providerSessionID: String?
    /// Per declared account totals, attempt order. Absent on receipts written before this field.
    public let accounts: [UsageAccountTotal]?
    /// The ThreadingUsage pricing catalogue version catalogue-priced costs came from.
    public let pricingVersion: String?
    /// The measure budgets use: everything but cached input reads, which providers bill at a
    /// fraction and which a long conversation rereads every turn.
    public var budgetTokens: Int64 { cells.reduce(0) { $0 + UsageReceipt.budgetTokens($1.tokens) } }
    static func budgetTokens(_ tokens: UsageTokenCounts) -> Int64 { tokens.uncachedInput + tokens.cacheWrite + tokens.output }
}

/// How many receipts of each coverage contributed to a daily cell.
public struct UsageCoverageCounts: Codable, Equatable, Sendable {
    public var complete: Int64 = 0
    public var partial: Int64 = 0
    public var failed: Int64 = 0
    public var unavailable: Int64 = 0
    public init() {}
    mutating func add(_ coverage: UsageCoverage) {
        switch coverage {
        case .complete: complete += 1
        case .partial: partial += 1
        case .failed: failed += 1
        case .unavailable: unavailable += 1
        }
    }
}

/// Labels for one daily cell, kept beside `usage_daily` in the record table (no DDL): what part
/// of the cost is an estimate, the tokens no rate priced, and the coverage behind the numbers.
struct UsageDailyLabel: Codable {
    var unpricedTokens: Int64 = 0
    var catalogCostUSD: Double = 0
    var pricingVersion: String?
    var coverage = UsageCoverageCounts()
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
    /// Tokens no catalogue rate priced; they are not in `costUSD`. Absent for cells recorded
    /// before labelling.
    public let unpricedTokens: Int64?
    /// The part of `costUSD` that is a catalogue list-price estimate.
    public let catalogCostUSD: Double?
    public let pricingVersion: String?
    /// True when any of `costUSD` is an estimate or some tokens were unpriced: the figure is not
    /// an invoice. Absent (unknown) for cells recorded before labelling.
    public let costIsEstimate: Bool?
    /// Coverage of the receipts that added to this cell.
    public let coverage: UsageCoverageCounts?
}

/// Owner-set ceiling on what one worker may spend in a UTC day, in budget tokens. Admission
/// stops starting new executions past it; running ones are never stopped.
public struct WorkerBudget: Codable, Equatable, Sendable {
    public let workerID: WorkerID
    public let revision: Int
    public let tokensPerDay: Int64?
}

/// An owner's explicit release of one execution's admission hold when its usage cannot be
/// settled from a transcript. Collection still runs; this only stops the hold.
public struct UsageWaiver: Codable, Equatable, Sendable {
    public let executionID: ExecutionID
    public let workerID: WorkerID
    public let reason: String
    public let waivedAt: String
    /// The receipt's coverage when waived, or nil if none had been written yet.
    public let priorCoverage: UsageCoverage?
}

/// Owner-set signal that an account's capacity is scarce until a time (for example from a
/// provider cooldown). Supervised admission defers workers whose declared accounts are all held.
public struct CapacityHold: Codable, Equatable, Sendable {
    public let account: String
    public let until: String
    public let reason: String
    public let setAt: String
}

struct UsageChainTotal: Codable { var tokens: Int64; var executions: Int }

enum UsageReceiptLimits {
    static let maximumCellsPerReceipt = 16
    static let overflowModel = "other models"
    static let maximumReasonBytes = 512
    static let maximumAccountBytes = 256
}

extension ControllerStore {
    /// Stopped executions whose receipt has not been written yet, oldest first.
    public func pendingUsage(limit: Int = 8) throws -> [ExecutionID] {
        let rows = try db.rows("SELECT execution FROM usage_pending ORDER BY rowid LIMIT ?", [.integer(Int64(min(limit, 100)))])
        return try rows.map { try ExecutionID($0.text(0)) }
    }

    /// Commits the receipt, its daily cells and labels and chain total together, and clears the
    /// pending entry. Idempotent: a second write for the same execution returns the first.
    /// `accounts` is the declared attempt order; it defaults to the launch recipe's.
    public func recordUsageReceipt(_ executionID: ExecutionID, runtime: String, account: String,
                                   cells: [UsageCell], coverage: UsageCoverage, reason: String?,
                                   accounts: [String]? = nil, pricingVersion: String? = nil) throws -> UsageReceipt {
        try db.transaction {
            if let existing: UsageReceipt = try optional("usageReceipt", executionID.description) {
                try db.run("DELETE FROM usage_pending WHERE execution=?", [.text(executionID.description)])
                return existing
            }
            let launch = try launch(executionID)
            guard launch.state == .stopped, let stoppedAt = launch.stoppedAt else { throw ControllerError.conflict }
            let work = try work(launch.workID)
            let context: MailContext? = try optional("mailContext", executionID.description)
            let trigger = work.key.hasPrefix("trigger:") ? work.key.split(separator: ":").dropFirst().first.map(String.init) : nil
            let primary = String(account.prefix(UsageReceiptLimits.maximumAccountBytes))
            let attributed = cells.map { cell -> UsageCell in
                var cell = cell
                cell.account = String((cell.account ?? primary).prefix(UsageReceiptLimits.maximumAccountBytes))
                return cell
            }
            let declared = accounts ?? launch.spec.usage?.attempts.map(\.account) ?? [primary]
            let bounded = Self.bounded(attributed)
            let receipt = UsageReceipt(executionID: executionID, workID: work.id, workerID: work.workerID, source: work.source,
                                       chainID: context?.chainID, triggerID: trigger, runtime: runtime,
                                       account: primary, cells: bounded, coverage: coverage,
                                       reason: reason.map { String($0.prefix(UsageReceiptLimits.maximumReasonBytes)) }, endedAt: stoppedAt,
                                       startedAt: launch.startedAt, durationSeconds: Self.duration(launch.startedAt, stoppedAt),
                                       providerSessionID: launch.providerTranscript?.sessionID,
                                       accounts: Self.accountTotals(attributed, declared: declared), pricingVersion: pricingVersion)
            try insert("usageReceipt", executionID.description, parent: work.id.description, state: coverage.rawValue,
                       scope: work.workerID.description, value: receipt)
            let day = String(receipt.endedAt.prefix(10))
            for (index, cell) in bounded.enumerated() {
                let cellAccount = cell.account ?? primary
                try db.run("""
                    INSERT INTO usage_daily(day,worker,account,model,uncached,cached,cache_write,output,reasoning,cost,requests,executions)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(day,worker,account,model) DO UPDATE SET uncached=uncached+excluded.uncached,
                    cached=cached+excluded.cached, cache_write=cache_write+excluded.cache_write, output=output+excluded.output,
                    reasoning=reasoning+excluded.reasoning, cost=cost+excluded.cost, requests=requests+excluded.requests,
                    executions=executions+excluded.executions
                    """, [.text(day), .text(work.workerID.description), .text(cellAccount), .text(cell.model),
                          .integer(cell.tokens.uncachedInput), .integer(cell.tokens.cachedInput), .integer(cell.tokens.cacheWrite),
                          .integer(cell.tokens.output), .integer(cell.tokens.reasoning), .text(String(cell.costUSD)),
                          .integer(Int64(cell.requests)), .integer(index == 0 ? 1 : 0)])
                try labelDailyCell(day: day, worker: work.workerID, account: cellAccount, cell: cell,
                                   coverage: coverage, pricingVersion: pricingVersion)
            }
            if let chain = context?.chainID {
                let id = chain.uuidString.lowercased()
                var total: UsageChainTotal = try optional("usageChain", id) ?? UsageChainTotal(tokens: 0, executions: 0)
                let isNew = (try optional("usageChain", id) as UsageChainTotal?) == nil
                total.tokens += receipt.budgetTokens; total.executions += 1
                if isNew { try insert("usageChain", id, value: total) } else { try update("usageChain", id, value: total) }
            }
            if coverage == .complete {
                try db.run("DELETE FROM usage_unsettled WHERE execution=?", [.text(executionID.description)])
            }
            try db.run("DELETE FROM usage_pending WHERE execution=?", [.text(executionID.description)])
            try event("usage.recorded", executionID.description)
            return receipt
        }
    }

    /// Bounds a receipt to `maximumCellsPerReceipt` largest cells; the rest fold into one
    /// "other models" cell per account, so per-account totals stay exact.
    static func bounded(_ cells: [UsageCell]) -> [UsageCell] {
        let sorted = cells.sorted { UsageReceipt.budgetTokens($0.tokens) > UsageReceipt.budgetTokens($1.tokens) }
        let keep = UsageReceiptLimits.maximumCellsPerReceipt - 1
        guard sorted.count > UsageReceiptLimits.maximumCellsPerReceipt else { return sorted }
        var overflow: [String: UsageCell] = [:]
        var order: [String] = []
        for cell in sorted[keep...] {
            let account = cell.account ?? ""
            if overflow[account] == nil { order.append(account); overflow[account] = UsageCell(model: UsageReceiptLimits.overflowModel, account: cell.account) }
            overflow[account]?.add(cell)
        }
        return Array(sorted[..<keep]) + order.compactMap { overflow[$0] }
    }

    static func accountTotals(_ cells: [UsageCell], declared: [String]) -> [UsageAccountTotal] {
        var names = declared
        for cell in cells { if let account = cell.account, !names.contains(account) { names.append(account) } }
        return names.map { name in
            let mine = cells.filter { $0.account == name }
            let tokens = mine.reduce(UsageTokenCounts()) { $0 + $1.tokens }
            return UsageAccountTotal(account: name, tokens: tokens, budgetTokens: UsageReceipt.budgetTokens(tokens),
                                     requests: mine.reduce(0) { $0 + $1.requests }, costUSD: mine.reduce(0) { $0 + $1.costUSD },
                                     unpricedTokens: mine.reduce(0) { $0 + $1.unpricedTokens })
        }
    }

    /// The label's id is computed by SQLite's own `json_array`, so the summary can join on
    /// exactly the same spelling without any escaping rule living in two languages.
    private func labelDailyCell(day: String, worker: WorkerID, account: String, cell: UsageCell,
                                coverage: UsageCoverage, pricingVersion: String?) throws {
        guard let id = try db.rows("SELECT json_array(?,?,?,?)",
                                   [.text(day), .text(worker.description), .text(account), .text(cell.model)]).first?.strings[0] else {
            throw ControllerError.storage(0)
        }
        let prior: UsageDailyLabel? = try optional("usageDailyLabel", id)
        var label = prior ?? UsageDailyLabel()
        label.unpricedTokens += cell.unpricedTokens
        label.catalogCostUSD += cell.catalogCostUSD ?? 0
        if let pricingVersion, label.pricingVersion.map({ $0 < pricingVersion }) ?? true { label.pricingVersion = pricingVersion }
        label.coverage.add(coverage)
        if prior == nil { try insert("usageDailyLabel", id, scope: worker.description, value: label) }
        else { try update("usageDailyLabel", id, value: label) }
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
    /// Each cell's label is one indexed lookup on the record table's (kind,id) key.
    public func usageSummary(from: String, through: String, after: Int64 = 0, limit: Int = 100) throws -> ControllerPage<UsageDailyCell> {
        try Limits.page(after, limit)
        guard from.count == 10, through.count == 10 else { throw ControllerError.invalidInput("day") }
        let rows = try db.rows("""
            SELECT d.rowid,d.day,d.worker,d.account,d.model,d.uncached,d.cached,d.cache_write,d.output,d.reasoning,d.cost,
            d.requests,d.executions,l.payload
            FROM usage_daily d LEFT JOIN record l ON l.kind='usageDailyLabel' AND l.id=json_array(d.day,d.worker,d.account,d.model)
            WHERE d.day>=? AND d.day<=? AND d.rowid>? ORDER BY d.rowid LIMIT ?
            """, [.text(from), .text(through), .integer(after), .integer(Int64(limit))])
        let cells = try rows.map { row in
            let label: UsageDailyLabel? = try row.strings[13].map { try decode($0) }
            return UsageDailyCell(day: try row.text(1), workerID: try WorkerID(row.text(2)), account: try row.text(3), model: try row.text(4),
                                  uncachedInput: row.integers[5], cachedInput: row.integers[6], cacheWrite: row.integers[7],
                                  output: row.integers[8], reasoning: row.integers[9], costUSD: Double(try row.text(10)) ?? 0,
                                  requests: row.integers[11], executions: row.integers[12],
                                  unpricedTokens: label?.unpricedTokens, catalogCostUSD: label?.catalogCostUSD,
                                  pricingVersion: label?.pricingVersion,
                                  costIsEstimate: label.map { $0.catalogCostUSD > 0 || $0.unpricedTokens > 0 },
                                  coverage: label?.coverage)
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

    /// Releases one stopped execution's admission hold when its usage cannot be settled from a
    /// transcript. Audited (`launch.usage_waived`, with the reason, on the work's activity);
    /// idempotent; collection is left owed, so a transcript that appears later still counts.
    public func waiveUsage(_ executionID: ExecutionID, reason: String) throws -> UsageWaiver {
        try Limits.text(reason, field: "waive_reason", maximum: UsageReceiptLimits.maximumReasonBytes)
        return try db.transaction {
            if let existing: UsageWaiver = try optional("usageWaiver", executionID.description) { return existing }
            let launch = try launch(executionID)
            guard launch.state == .stopped else { throw ControllerError.conflict }
            guard !(try db.rows("SELECT execution FROM usage_unsettled WHERE execution=? LIMIT 1",
                                [.text(executionID.description)])).isEmpty else { throw ControllerError.conflict }
            let work = try work(launch.workID)
            let receipt = try usageReceipt(executionID)
            let waiver = UsageWaiver(executionID: executionID, workerID: work.workerID, reason: reason,
                                     waivedAt: Self.now(), priorCoverage: receipt?.coverage)
            try insert("usageWaiver", executionID.description, parent: work.id.description, scope: work.workerID.description, value: waiver)
            try db.run("DELETE FROM usage_unsettled WHERE execution=?", [.text(executionID.description)])
            try event("launch.usage_waived", executionID.description, text: reason, source: "owner")
            return waiver
        }
    }
    public func usageWaiver(_ executionID: ExecutionID) throws -> UsageWaiver? { try optional("usageWaiver", executionID.description) }

    // MARK: - Capacity holds

    public func setCapacityHold(account: String, until: String, reason: String) throws -> CapacityHold {
        try Limits.text(account, field: "hold_account", maximum: UsageReceiptLimits.maximumAccountBytes)
        try Limits.text(reason, field: "hold_reason", maximum: UsageReceiptLimits.maximumReasonBytes)
        guard let date = ISO8601DateFormatter().date(from: until) else { throw ControllerError.invalidInput("hold_until") }
        return try db.transaction {
            let hold = CapacityHold(account: account, until: ISO8601DateFormatter().string(from: date), reason: reason, setAt: Self.now())
            if (try optional("capacityHold", account) as CapacityHold?) == nil { try insert("capacityHold", account, value: hold) }
            else { try update("capacityHold", account, value: hold) }
            try event("capacity.hold_set", account, text: reason, source: "owner")
            return hold
        }
    }
    @discardableResult
    public func clearCapacityHold(account: String) throws -> CapacityHold? {
        try db.transaction {
            guard let hold: CapacityHold = try optional("capacityHold", account) else { return nil }
            try db.run("DELETE FROM record WHERE kind='capacityHold' AND id=?", [.text(account)])
            try event("capacity.hold_cleared", account, source: "owner")
            return hold
        }
    }
    public func capacityHolds(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<CapacityHold> {
        try page("capacityHold", after: after, limit: limit)
    }
    /// When the first of `accounts` is released, or nil when one of them is free now: work
    /// defers only while every login it may use is held. O(declared accounts) lookups.
    func capacityHeldUntil(_ accounts: [String], now: Date = Date()) throws -> String? {
        guard !accounts.isEmpty else { return nil }
        var earliestRelease: Date?
        let formatter = ISO8601DateFormatter()
        for account in accounts {
            guard let hold: CapacityHold = try optional("capacityHold", account),
                  let until = formatter.date(from: hold.until), until > now else { return nil }
            earliestRelease = min(earliestRelease ?? until, until)
        }
        return earliestRelease.map { formatter.string(from: $0) }
    }

    // MARK: - Admission

    /// Today's budget tokens for a worker, read from its daily cells (a handful of rows).
    func workerSpendToday(_ worker: WorkerID) throws -> Int64 {
        let day = String(Self.now().prefix(10))
        let rows = try db.rows("SELECT COALESCE(SUM(uncached+cache_write+output),0) FROM usage_daily WHERE day=? AND worker=?",
                               [.text(day), .text(worker.description)])
        return rows.first?.integers[0] ?? 0
    }
    static func duration(_ start: String?, _ end: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        guard let start, let began = formatter.date(from: start), let ended = formatter.date(from: end) else { return nil }
        return max(0, ended.timeIntervalSince(began))
    }
    func workerWithinBudget(_ worker: WorkerID) throws -> Bool { try workerCapacity(worker).admitted }

    /// A local authority today. Account/window coordination may later supply another decision
    /// without moving credentials or admission out of the host's transaction.
    public func workerCapacity(_ worker: WorkerID) throws -> WorkerCapacity {
        let policy: ControllerWorkerPolicy? = try optional("workerPolicy", worker.description)
        let budget = try budgetDecision(worker, usage: policy?.spec.usage)
        let heldUntil = try policy?.spec.usage.flatMap { try capacityHeldUntil($0.attempts.map(\.account)) }
        let reason: WorkerCapacity.Reason
        if policy?.enabled != true { reason = .paused }
        else if heldUntil != nil { reason = .capacityHeld }
        else { reason = budget.reason }
        return WorkerCapacity(workerID: worker, authority: try host().id, scope: "host", reason: reason,
                              spentTokens: budget.spent, limitTokens: budget.limit,
                              unsettledExecution: budget.unsettled, heldUntil: heldUntil)
    }

    /// The budget half of admission, shared by supervised and manual launches. `usage` is the
    /// recipe the launch would run, which for a manual launch is not the stored policy's.
    func budgetDecision(_ worker: WorkerID, usage: ControllerUsageSource?)
        throws -> (reason: WorkerCapacity.Reason, spent: Int64, limit: Int64?, unsettled: ExecutionID?) {
        let _: ControllerWorker = try required("worker", worker.description)
        let limit = try workerBudget(worker)?.tokensPerDay
        let spend = try workerSpendToday(worker)
        let today = String(Self.now().prefix(10))
        let unsettled = try db.rows("SELECT execution FROM usage_unsettled WHERE worker=? AND (stopped_day IS NULL OR stopped_day=?) LIMIT 1",
                                    [.text(worker.description), .text(today)])
        let unsettledExecution = try unsettled.first.map { try ExecutionID($0.text(0)) }
        let reason: WorkerCapacity.Reason
        if limit == nil { reason = .ready }
        else if usage == nil { reason = .usageNotConfigured }
        else if unsettledExecution != nil { reason = .usageUnsettled }
        else if spend >= (limit ?? 0) { reason = .dailyBudget }
        else { reason = .ready }
        return (reason, spend, limit, unsettledExecution)
    }
}

public struct WorkerCapacity: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case ready, paused, usageNotConfigured, usageUnsettled, dailyBudget, capacityHeld }
    public let workerID: WorkerID
    public let authority: HostID
    public let scope: String
    public let reason: Reason
    public let spentTokens: Int64
    public let limitTokens: Int64?
    public let unsettledExecution: ExecutionID?
    /// With `capacityHeld`: when the first of the worker's held accounts is released.
    public let heldUntil: String?
    public var admitted: Bool { reason == .ready }
}
