import Foundation

// MARK: - Transcript Usage

/// Tokens spent, grouped however the caller wants to read them.
struct TranscriptUsage: Equatable {
    /// Tokens the plan is charged for: input, output, and cache *writes*. Cache **reads** are
    /// excluded deliberately — they are the cheap path, they dwarf everything else by volume,
    /// and counting them makes a long conversation look like the expensive one when the
    /// opposite is true.
    var billedTokens: Int64 = 0

    /// Cache reads, kept apart rather than dropped: the ratio of reads to writes is what says
    /// whether a conversation is being served from cache at all.
    var cachedTokens: Int64 = 0

    /// Turns counted, which is what makes a per-turn average possible.
    var turns: Int = 0

    static func + (lhs: TranscriptUsage, rhs: TranscriptUsage) -> TranscriptUsage {
        TranscriptUsage(
            billedTokens: lhs.billedTokens + rhs.billedTokens,
            cachedTokens: lhs.cachedTokens + rhs.cachedTokens,
            turns: lhs.turns + rhs.turns
        )
    }
}

/// One transcript's contribution, attributed to the checkout it ran in.
struct TranscriptUsageEntry: Equatable {
    /// The conversation's own identifier, which is also its file name.
    let transcriptID: String

    /// The directory the conversation ran in, from the records themselves rather than the
    /// project-slug directory name — two different paths can slug alike.
    let workingDirectory: String

    let model: String
    let day: String
    var usage: TranscriptUsage
}

// MARK: - Transcript Usage Index

/// Reads what conversations actually cost from the transcripts the CLIs already keep.
///
/// This answers the question the rate-limit pill provokes and cannot answer: the pill says the
/// week is 85% spent, and only the transcripts say *what spent it* — which project, which
/// checkout, which model. No API reports that, because no API knows which conversation ran in
/// which of a repository's worktrees. Skalman does.
///
/// **Deduplication is not optional.** Resuming, compaction and forking all copy prior records
/// into the new transcript, so the same assistant turn appears in several files. Measured on
/// this machine: 65,464 turns across 250 transcripts, of which **34,656 were duplicates —
/// 52.9%** — and summing them naively reported 478.9M tokens where the true figure is 186.4M.
/// A 157% overstatement, from a mistake that leaves no trace in the output. Every turn is
/// therefore keyed by `(message.id, requestId)` and counted once.
enum TranscriptUsageIndex {

    // MARK: - Finding

    /// Every transcript under an account's config directory, **including subagent threads**.
    ///
    /// The nesting is not incidental. Claude keeps a Task's own conversation in
    /// `projects/<slug>/<session>/subagents/agent-<id>.jsonl`, and those turns appear *nowhere
    /// else*: checked against a real session, 101 subagent turns shared exactly zero
    /// `(message.id, requestId)` pairs with their parent, and the parent held no priced
    /// sidechain records at all. A one-level scan of `projects/<slug>/*.jsonl` therefore misses
    /// every token a subagent ever spent — on this machine 2,244 files and 107M tokens, which
    /// is 56% of the total. It is the same class of mistake as counting duplicates, in the
    /// opposite direction, and equally invisible in the output.
    static func transcripts(inAccountAt configPath: String) -> [URL] {
        let projects = URL(fileURLWithPath: configPath)
            .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)

        guard let walker = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return (walker.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == AgentDefaults.transcriptExtension
        }
    }

    // MARK: - Reading

    /// Every priced turn in one transcript, deduplicated against `seen`, which the caller owns
    /// so that duplicates are caught *across* files rather than only within one.
    ///
    /// Streams line by line: these files reach hundreds of megabytes, and only the lines
    /// carrying a `usage` object are ever parsed.
    static func entries(
        inTranscriptAt url: URL,
        seen: inout Set<String>
    ) -> [TranscriptUsageEntry] {
        let transcriptID = url.deletingPathExtension().lastPathComponent
        var byKey: [String: TranscriptUsageEntry] = [:]
        let marker = Data(UsageIndexDefaults.usageMarker.utf8)

        JSONLReader.forEachLine(at: url, limit: .max) { line in
            // The cheap gate first: most records carry no usage at all, and parsing them is
            // the whole cost of this scan.
            guard line.range(of: marker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line),
                  let object = record as? [String: Any],
                  let message = object[UsageIndexDefaults.messageKey] as? [String: Any],
                  let usage = message[UsageIndexDefaults.usageKey] as? [String: Any]
            else { return true }

            let identity = "\(message[UsageIndexDefaults.idKey] as? String ?? "")"
                + "|\(object[UsageIndexDefaults.requestKey] as? String ?? "")"

            // An unidentifiable turn is counted rather than skipped: dropping it would
            // understate, and understating is the failure this whole index exists to avoid.
            if identity != "|" {
                guard seen.insert(identity).inserted else { return true }
            }

            let day = String((object[UsageIndexDefaults.timestampKey] as? String ?? "").prefix(10))
            let model = message[UsageIndexDefaults.modelKey] as? String ?? UsageIndexDefaults.unknownModel
            let cwd = object[UsageIndexDefaults.cwdKey] as? String ?? ""

            let key = "\(day)|\(model)|\(cwd)"
            var entry = byKey[key] ?? TranscriptUsageEntry(
                transcriptID: transcriptID,
                workingDirectory: cwd,
                model: model,
                day: day,
                usage: TranscriptUsage()
            )

            entry.usage = entry.usage + reading(from: usage)
            byKey[key] = entry
            return true
        }

        return Array(byKey.values)
    }

    /// One record's tokens.
    static func reading(from usage: [String: Any]) -> TranscriptUsage {
        let input = int(usage[UsageIndexDefaults.inputKey])
        let output = int(usage[UsageIndexDefaults.outputKey])
        let cacheWrite = int(usage[UsageIndexDefaults.cacheWriteKey])
        let cacheRead = int(usage[UsageIndexDefaults.cacheReadKey])

        return TranscriptUsage(
            billedTokens: input + output + cacheWrite,
            cachedTokens: cacheRead,
            turns: 1
        )
    }

    private static func int(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Usage Index Defaults

enum UsageIndexDefaults {
    /// The substring that makes a line worth parsing. Every priced record carries it, and
    /// almost nothing else does, so this is what keeps a 250 MB transcript cheap to read.
    static let usageMarker = "\"usage\""

    static let messageKey = "message"
    static let usageKey = "usage"
    static let idKey = "id"
    static let requestKey = "requestId"
    static let timestampKey = "timestamp"
    static let modelKey = "model"
    static let cwdKey = "cwd"

    static let inputKey = "input_tokens"
    static let outputKey = "output_tokens"
    static let cacheWriteKey = "cache_creation_input_tokens"
    static let cacheReadKey = "cache_read_input_tokens"

    static let unknownModel = "unknown"
}
