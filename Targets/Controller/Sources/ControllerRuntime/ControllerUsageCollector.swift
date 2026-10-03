import Foundation
import ThreadingController
import ThreadingUsage

/// Writes a stopped execution's usage receipt from its transcript, through the same adapters
/// and pricing as the Mac's Usage page. A transcript it cannot finish reading yields a partial
/// or failed receipt, visibly; one it cannot find yields `unavailable` — never a guessed total.
public enum ControllerUsageCollector {
    public static func collect(store: ControllerStore, executionID: ExecutionID) async throws -> UsageReceipt {
        let launch = try await store.launch(executionID)
        guard launch.state == .stopped else { throw ControllerError.conflict }
        guard let usage = launch.spec.usage else {
            return try await store.recordUsageReceipt(executionID, runtime: "unknown", account: "unknown", cells: [],
                                                      coverage: .unavailable, reason: "recipe_names_no_transcript")
        }
        let account = usage.account ?? usage.home
        let found: (records: [UsageLedgerRecord], coverage: UsageCoverage, reason: String?)
        switch usage.runtime {
        case .claude: found = claude(home: usage.home, session: executionID.description, account: account)
        case .codex: found = codex(home: usage.home, transcript: launch.providerTranscript, account: account)
        }
        return try await store.recordUsageReceipt(executionID, runtime: usage.runtime.rawValue, account: account,
                                                  cells: cells(found.records),
                                                  coverage: launch.providerTranscriptChanged == true ? .partial : found.coverage,
                                                  reason: launch.providerTranscriptChanged == true ? "provider_transcript_changed" : found.reason)
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
        var incomplete = false
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents")
        if let children = try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil) {
            files += children.filter { $0.pathExtension == "jsonl" }.prefix(200)
            incomplete = children.filter { $0.pathExtension == "jsonl" }.count > 200
        } else if FileManager.default.fileExists(atPath: subagents.path) {
            incomplete = true
        }
        let result = read(files) { try ClaudeUsageAdapter.records(inTranscriptAt: $0, accountID: account, accountName: account) }
        return incomplete ? (result.0, .partial, "subagent_transcripts_incomplete") : result
    }

    /// A host hook binds the exact path/session while the execution credential is live.
    /// Check the resolved path again at read time, including symlinks, and verify file identity.
    static func codex(home: String, transcript: ProviderTranscript?, account: String) -> ([UsageLedgerRecord], UsageCoverage, String?) {
        guard let transcript else { return ([], .unavailable, "provider_transcript_unbound") }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"
        let file = URL(fileURLWithPath: transcript.path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root), file.pathExtension == "jsonl",
              let handle = try? FileHandle(forReadingFrom: file) else {
            return ([], .unavailable, "provider_transcript_unreadable")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), let line = data.split(separator: 10).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any], payload["id"] as? String == transcript.sessionID else {
            return ([], .failed, "provider_transcript_identity")
        }
        return read([file]) { try CodexUsageAdapter.records(inRolloutAt: $0, accountID: account, accountName: account) }
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
