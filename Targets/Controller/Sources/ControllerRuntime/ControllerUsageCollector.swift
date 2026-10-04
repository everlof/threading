import Foundation
import ThreadingController
import ThreadingUsage

/// Writes a stopped execution's usage receipt from its transcripts, through the same adapters,
/// merge and pricing as the Mac's Usage page. Every declared account home is read; a response
/// copied between homes by an account failover is counted once, on the earliest declared
/// account it appears in. A transcript it cannot finish reading keeps the records it could read
/// and yields a partial receipt, visibly; one it cannot find at all, after a provider session was
/// bound, is a gap — never a guessed total.
public enum ControllerUsageCollector {
    /// A Codex rollout's first line is its `session_meta`; it can carry a large instruction
    /// block, so identity is read through its own bound rather than one 64 KB chunk.
    static let codexIdentityLineBytes = 1_048_576
    static let maximumProjectDirectories = 5_000
    static let maximumSubagentTranscripts = 200

    /// What one declared account home contributed for this execution.
    struct AccountRead {
        var records: [UsageLedgerRecord] = []
        /// A transcript for this execution exists in this home.
        var found = false
        /// Explicit coverage gaps, as short reason tokens.
        var gaps: [String] = []
        var files = 0
        var failedFiles = 0
        /// The home has no Claude `projects` directory at all.
        var missingProjects = false
    }

    public static func collect(store: ControllerStore, executionID: ExecutionID) async throws -> UsageReceipt {
        let launch = try await store.launch(executionID)
        guard launch.state == .stopped else { throw ControllerError.conflict }
        guard let usage = launch.spec.usage else {
            return try await store.recordUsageReceipt(executionID, runtime: "unknown", account: "unknown", cells: [],
                                                      coverage: .unavailable, reason: "recipe_names_no_transcript")
        }
        let attempts = usage.attempts
        let accounts = attempts.map(\.account)
        // Never dispatched (an obsolete preparation, a stop confirmed before spawn): no process
        // ever ran, so it owes nothing and must not hold the worker's budget.
        guard launch.startedAt != nil else {
            return try await store.recordUsageReceipt(executionID, runtime: usage.runtime.rawValue, account: accounts[0], cells: [],
                                                      coverage: .complete, reason: "never_spawned", accounts: accounts)
        }
        let bindings = launch.transcriptBindings
        let reads = attempts.map { attempt -> AccountRead in
            let binding = bindings.first { $0.account == attempt.account }
            switch usage.runtime {
            case .claude:
                return claude(home: attempt.home, session: executionID.description, bound: binding?.path, account: attempt.account)
            case .codex:
                return codex(home: attempt.home, transcript: binding.map { ProviderTranscript(sessionID: $0.sessionID, path: $0.path) },
                             account: attempt.account)
            }
        }
        let records = merge(reads, accounts: accounts)
        let settled = coverage(reads, accounts: accounts, transcriptChanged: launch.providerTranscriptChanged == true)
        return try await store.recordUsageReceipt(executionID, runtime: usage.runtime.rawValue, account: accounts[0],
                                                  cells: cells(records), coverage: settled.coverage, reason: settled.reason,
                                                  accounts: accounts, pricingVersion: records.isEmpty ? nil : UsagePricingCatalog.version)
    }

    /// One coverage for the receipt from every declared home.
    ///
    /// No transcript in any home and no gap means no provider session ever started: Claude
    /// writes its transcript before its first request, and Codex's session-start hook binds
    /// before its first turn (the hook is a documented requirement). That settles as zero.
    static func coverage(_ reads: [AccountRead], accounts: [String], transcriptChanged: Bool) -> (coverage: UsageCoverage, reason: String?) {
        let labelled = zip(accounts, reads).flatMap { account, read in
            read.gaps.map { accounts.count > 1 ? "\(account): \($0)" : $0 }
        }
        let gaps = labelled.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if transcriptChanged { return (.partial, (["provider_transcript_changed"] + gaps).joined(separator: "; ")) }
        let found = reads.contains { $0.found }
        if !found {
            if !gaps.isEmpty { return (.failed, gaps.joined(separator: "; ")) }
            if reads.allSatisfy(\.missingProjects) { return (.unavailable, "no_projects_directory") }
            return (.complete, "no_provider_session")
        }
        if gaps.isEmpty { return (.complete, nil) }
        let files = reads.reduce(0) { $0 + $1.files }
        let failed = reads.reduce(0) { $0 + $1.failedFiles }
        let anyRecords = reads.contains { !$0.records.isEmpty }
        return (failed == files && !anyRecords ? .failed : .partial, gaps.joined(separator: "; "))
    }

    /// Claude writes `<home>/projects/<project>/<session>.jsonl`, and a session's subagents under
    /// `<session>/subagents/`. The session id is the execution id the recipe passed. A path the
    /// hook bound is required when present: it must resolve inside the home's `projects` and be
    /// named for this execution.
    static func claude(home: String, session: String, bound: String?, account: String) -> AccountRead {
        var read = AccountRead()
        let main: URL
        if let bound {
            let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().appendingPathComponent("projects").path + "/"
            let file = URL(fileURLWithPath: bound).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root), file.lastPathComponent == session + ".jsonl",
                  FileManager.default.fileExists(atPath: file.path) else {
                read.gaps.append("provider_transcript_unreadable")
                return read
            }
            main = file
        } else {
            let projects = URL(fileURLWithPath: home).appendingPathComponent("projects")
            guard let directories = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
                read.missingProjects = true
                return read
            }
            guard let match = directories.prefix(maximumProjectDirectories).map({ $0.appendingPathComponent(session + ".jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return read }
            main = match
        }
        read.found = true
        var files = [main]
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents")
        if let children = try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil) {
            let transcripts = children.filter { $0.pathExtension == "jsonl" }
            files += transcripts.prefix(maximumSubagentTranscripts)
            if transcripts.count > maximumSubagentTranscripts { read.gaps.append("subagent_transcripts_incomplete") }
        } else if FileManager.default.fileExists(atPath: subagents.path) {
            read.gaps.append("subagent_transcripts_incomplete")
        }
        read.add(files) { try ClaudeUsageAdapter.reading(transcriptAt: $0, accountID: account, accountName: account) }
        return read
    }

    /// A host hook binds the exact path/session while the execution credential is live.
    /// Check the resolved path again at read time, including symlinks, and verify file identity.
    static func codex(home: String, transcript: ProviderTranscript?, account: String) -> AccountRead {
        var read = AccountRead()
        guard let transcript else { return read }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"
        let file = URL(fileURLWithPath: transcript.path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root), file.pathExtension == "jsonl", FileManager.default.isReadableFile(atPath: file.path) else {
            read.gaps.append("provider_transcript_unreadable")
            return read
        }
        var first: Data?
        JSONLReader.forEachLine(at: file, limit: codexIdentityLineBytes) { line in first = line; return false }
        guard let first, let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any], payload["id"] as? String == transcript.sessionID else {
            read.gaps.append("provider_transcript_identity")
            return read
        }
        read.found = true
        read.add([file]) { try CodexUsageAdapter.reading(rolloutAt: $0, accountID: account, accountName: account) }
        return read
    }

    /// Every declared home's records, one per response identity. Repeated observations — a
    /// streaming partial, a copy made by a failover — merge through the shared component-wise
    /// maximum, attributed to the earliest declared account they appear in.
    static func merge(_ reads: [AccountRead], accounts: [String]) -> [UsageLedgerRecord] {
        let rank = Dictionary(accounts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let precedes = { (lhs: UsageLedgerRecord, rhs: UsageLedgerRecord) -> Bool in
            let left = rank[lhs.accountID] ?? Int.max, right = rank[rhs.accountID] ?? Int.max
            return left != right ? left < right : UsageLedgerRecord.attributionPrecedes(lhs, rhs)
        }
        var byIdentity: [String: UsageLedgerRecord] = [:]
        var order: [String] = []
        for record in reads.flatMap(\.records) {
            if let prior = byIdentity[record.identity] {
                byIdentity[record.identity] = prior.mergingUsageMaximums(with: record, attributingTo: precedes)
            } else {
                byIdentity[record.identity] = record
                order.append(record.identity)
            }
        }
        return order.compactMap { byIdentity[$0] }
    }

    /// Cells per (account, model), with the catalogue-estimated part of the cost kept apart.
    static func cells(_ records: [UsageLedgerRecord]) -> [UsageCell] {
        struct Key: Hashable { let account: String; let model: String }
        var byKey: [Key: UsageCell] = [:]
        for record in records {
            let priced = UsagePricingCatalog.price(record)
            let key = Key(account: priced.accountID, model: priced.model)
            var cell = byKey[key] ?? UsageCell(model: priced.model, account: priced.accountID, catalogCostUSD: 0)
            cell.tokens += priced.tokens
            cell.requests += 1
            if let cost = priced.costUSD {
                cell.costUSD += cost
                if priced.costSource == .catalogPriced { cell.catalogCostUSD = (cell.catalogCostUSD ?? 0) + cost }
            } else {
                cell.unpricedTokens += priced.tokens.uncachedInput + priced.tokens.cachedInput + priced.tokens.cacheWrite + priced.tokens.output
            }
            byKey[key] = cell
        }
        return byKey.values.sorted { ($0.account ?? "", $0.model) < ($1.account ?? "", $1.model) }
    }
}

extension ControllerUsageCollector.AccountRead {
    /// Reads each file through the recovering adapter, keeping every readable record and
    /// turning unreadable lines, an unterminated tail or an unopenable file into named gaps.
    mutating func add(_ files: [URL], _ adapter: (URL) throws -> UsageTranscriptReading) {
        for file in files {
            self.files += 1
            do {
                let reading = try adapter(file)
                records += reading.records
                if reading.unreadableRecordCount > 0 { gaps.append("unreadable_usage_records") }
                if reading.endsUnterminated { gaps.append("transcript_unterminated") }
            } catch {
                failedFiles += 1
                gaps.append("transcript_unreadable")
            }
        }
    }
}
