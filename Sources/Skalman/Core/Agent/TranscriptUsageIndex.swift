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

    /// `2026-07-22T14:15` — the quarter-hour the turns fell in.
    ///
    /// Quarter-hours rather than days because the windows that meter an account are five hours
    /// long, and a day-resolution series cannot say what a five-hour window has consumed. Cut
    /// from the timestamp's own characters rather than parsed into a `Date`: there are tens of
    /// thousands of these per scan and none of them need calendar arithmetic.
    let bucket: String

    var day: String { String(bucket.prefix(10)) }
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
        let marker = Array(UsageIndexDefaults.usageMarker.utf8)

        JSONLReader.forEachLine(at: url, limit: .max) { line in
            // The cheap gate first: most records carry no usage at all, and parsing them is
            // the whole cost of this scan.
            guard contains(marker, in: line),
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

            let bucket = quarterHour(of: object[UsageIndexDefaults.timestampKey] as? String ?? "")
            let model = message[UsageIndexDefaults.modelKey] as? String ?? UsageIndexDefaults.unknownModel
            let cwd = object[UsageIndexDefaults.cwdKey] as? String ?? ""

            let key = "\(bucket)|\(model)|\(cwd)"
            var entry = byKey[key] ?? TranscriptUsageEntry(
                transcriptID: transcriptID,
                workingDirectory: cwd,
                model: model,
                bucket: bucket,
                usage: TranscriptUsage()
            )

            entry.usage = entry.usage + reading(from: usage)
            byKey[key] = entry
            return true
        }

        return Array(byKey.values)
    }

    /// Whether `needle` appears in `haystack`, through `memmem`.
    ///
    /// `Data.range(of:)` is the obvious way to write this and is far too slow to run once per
    /// line across a gigabyte — this gate is the only thing standing between the scan and
    /// parsing every record in every transcript, so it has to cost almost nothing.
    static func contains(_ needle: [UInt8], in haystack: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        return haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return needle.withUnsafeBytes { pattern -> Bool in
                guard let patternBase = pattern.baseAddress else { return false }
                return memmem(base, raw.count, patternBase, pattern.count) != nil
            }
        }
    }

    /// `2026-07-22T14:37:02.000Z` → `2026-07-22T14:30`.
    ///
    /// String surgery on a format both CLIs write identically, because a `DateFormatter` here
    /// would run tens of thousands of times per scan to answer a question that is four
    /// characters wide. `String(format:)` is avoided for the same reason — it is not cheap, and
    /// this runs once per priced turn.
    static func quarterHour(of timestamp: String) -> String {
        guard timestamp.count >= 16 else { return timestamp }

        let hour = String(timestamp.prefix(13))
        let minuteStart = timestamp.index(timestamp.startIndex, offsetBy: 14)
        let minuteEnd = timestamp.index(minuteStart, offsetBy: 2)
        let minute = Int(timestamp[minuteStart..<minuteEnd]) ?? 0

        let quarter = (minute / 15) * 15
        return hour + (quarter < 10 ? ":0" : ":") + String(quarter)
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
