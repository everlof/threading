import Foundation
import ThreadingController
import ThreadingUsage

/// Writes a stopped execution's usage receipt from its transcript, through the same adapters
/// and pricing as the Mac's Usage page. A transcript it cannot finish reading yields a partial
/// or failed receipt, visibly; one it cannot find yields `unavailable` — never a guessed total.
public enum ControllerUsageCollector {
    public static func collect(store: ControllerStore, executionID: ExecutionID) async throws -> UsageReceipt {
        let launch = try await store.launch(executionID)
        guard let usage = launch.spec.usage else {
            return try await store.recordUsageReceipt(executionID, runtime: "unknown", account: "unknown", cells: [],
                                                      coverage: .unavailable, reason: "recipe_names_no_transcript")
        }
        let account = usage.account ?? usage.home
        let started = launch.startSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let found: (records: [UsageLedgerRecord], coverage: UsageCoverage, reason: String?)
        switch usage.runtime {
        case .claude: found = claude(home: usage.home, session: executionID.description, account: account)
        case .codex: found = codex(home: usage.home, directory: launch.spec.directory, started: started, account: account)
        }
        return try await store.recordUsageReceipt(executionID, runtime: usage.runtime.rawValue, account: account,
                                                  cells: cells(found.records), coverage: found.coverage, reason: found.reason)
    }

    /// Claude writes `<home>/projects/<project>/<session>.jsonl`, and a session's subagents under
    /// `<session>/subagents/`. The session id is the execution id the recipe passed.
    static func claude(home: String, session: String, account: String) -> ([UsageLedgerRecord], UsageCoverage, String?) {
        let projects = URL(fileURLWithPath: home).appendingPathComponent("projects")
        guard let directories = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return ([], .unavailable, "no_projects_directory")
        }
        guard let main = directories.prefix(5_000).map({ $0.appendingPathComponent(session + ".jsonl") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return ([], .unavailable, "transcript_not_found")
        }
        var files = [main]
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents")
        if let children = try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil) {
            files += children.filter { $0.pathExtension == "jsonl" }.prefix(200)
        }
        return read(files) { try ClaudeUsageAdapter.records(inTranscriptAt: $0, accountID: account, accountName: account) }
    }

    /// Codex names its own session, so the rollout is the one in this launch's date folders,
    /// written since it started, whose recorded working directory is the recipe's. Anything but
    /// exactly one candidate is reported, not guessed.
    static func codex(home: String, directory: String, started: Date?, account: String) -> ([UsageLedgerRecord], UsageCoverage, String?) {
        guard let started else { return ([], .unavailable, "launch_start_unknown") }
        let calendar = Calendar(identifier: .gregorian)
        var candidates: [URL] = []
        var day = calendar.startOfDay(for: started.addingTimeInterval(-86_400))
        while day <= Date().addingTimeInterval(86_400), candidates.count <= 50 {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = URL(fileURLWithPath: home).appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified >= started.addingTimeInterval(-60), rolloutDirectory(file) == directory { candidates.append(file) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? Date.distantFuture
        }
        guard candidates.count == 1 else { return ([], .unavailable, candidates.isEmpty ? "rollout_not_found" : "rollout_ambiguous") }
        return read(candidates) { try CodexUsageAdapter.records(inRolloutAt: $0, accountID: account, accountName: account) }
    }

    static func rolloutDirectory(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 65_536) else { return nil }
        try? handle.close()
        guard let line = data.split(separator: 10).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    static func read(_ files: [URL], _ adapter: (URL) throws -> [UsageLedgerRecord]) -> ([UsageLedgerRecord], UsageCoverage, String?) {
        var records: [UsageLedgerRecord] = []
        var identities = Set<String>()
        var failures = 0
        for file in files {
            do {
                for record in try adapter(file) where identities.insert(record.identity).inserted { records.append(record) }
            } catch { failures += 1 }
        }
        if failures == 0 { return (records, .complete, nil) }
        return (records, failures == files.count ? .failed : .partial, "\(failures) of \(files.count) transcripts unreadable")
    }

    static func cells(_ records: [UsageLedgerRecord]) -> [UsageCell] {
        var byModel: [String: UsageCell] = [:]
        for record in records {
            let priced = UsagePricingCatalog.price(record)
            var cell = byModel[priced.model] ?? UsageCell(model: priced.model)
            cell.tokens += priced.tokens
            cell.requests += 1
            if let cost = priced.costUSD { cell.costUSD += cost }
            else { cell.unpricedTokens += priced.tokens.uncachedInput + priced.tokens.cachedInput + priced.tokens.cacheWrite + priced.tokens.output }
            byModel[priced.model] = cell
        }
        return byModel.values.sorted { $0.model < $1.model }
    }
}
