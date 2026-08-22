import Foundation

// MARK: - Transcript Resume Health

/// Whether a conversation's own file is in a state its runtime will still open.
///
/// Threading already refuses to pass Claude a `--resume` for a transcript that is not there
/// (`AgentLauncher.claudeCommand`), and the comment beside that check says why: without it the
/// relaunch exits 1 within a second, which "is what a Resume button doing nothing looks like
/// from outside". Codex had no such check at all — `codex resume <id>` was appended whenever an
/// identifier existed — so a conversation the runtime refuses produced exactly that symptom, for
/// exactly that reason, on every press forever.
///
/// This is the general form of that check: ask before launching, and when the answer is no, say
/// so instead of spending a process to be told.
enum TranscriptResumeHealth {

    // MARK: - Types

    enum Verdict: Equatable {
        /// Nothing here says the file is unusable. Not a promise that the resume will work — a
        /// preflight that claimed that would be wrong the first time a runtime changed its mind.
        case usable
        /// The file exists and is structurally unusable to its runtime, with a reason.
        case unusable(reason: String, cause: String)
    }

    // MARK: - Public Methods

    /// Reads what can be read cheaply about a conversation file.
    ///
    /// A missing file is `usable`: "there is no transcript" is the launcher's existing question
    /// and it has its own answer — starting fresh — which is not this one's to give.
    static func verdict(for url: URL, kind: AgentKind) -> Verdict {
        switch kind {
        case .codex:
            return CodexRolloutHealth.verdict(for: url)
        case .claude, .grok, .openCode, .cursor:
            return .usable
        }
    }
}

// MARK: - Codex Rollout Health

/// The one structural failure of a Codex rollout that Threading can recognise before launching.
///
/// Codex numbers its rollout records with an `ordinal`, and its thread store resumes by reading
/// the tail. If the *final* record has no ordinal, `thread/resume` fails outright:
///
/// ```
/// thread-store internal error: failed to resume local thread recorder:
/// final paginated rollout record at … is missing an ordinal (code -32603)
/// ```
///
/// Both halves of the test are load-bearing, and the second one is the part that took measuring.
/// A rollout with *no* ordinals anywhere is the older format and resumes perfectly well — 1,818
/// of the 1,842 files on the machine this was written against are that shape, and one picked at
/// random was confirmed to resume under the CLI that refuses the broken one. So the fault is not
/// "no ordinal on the last record", it is the **mixed** state: a file that started being numbered
/// and stopped. Testing only the last record would have condemned nearly every conversation the
/// user has.
///
/// The scan is bounded to the tail regardless of file size — the specimen was 38.9 MB — because
/// this runs on the way to a launch and a launch may not read a conversation to decide to start
/// one.
enum CodexRolloutHealth {

    // MARK: - Public Methods

    static func verdict(for url: URL) -> TranscriptResumeHealth.Verdict {
        guard let tail = tail(of: url) else { return .usable }

        let lines = tail
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        guard let last = lines.last else { return .usable }

        // The first line of a tail read may be half a record. Ordinals are looked for across the
        // whole window, so one clipped line cannot make a healthy file look unnumbered; the final
        // line is whole by construction, because the writer appends complete records.
        let fileUsesOrdinals = lines.contains { hasOrdinal($0) }
        guard fileUsesOrdinals, !hasOrdinal(last) else { return .usable }

        return .unusable(
            reason: L10n.string(
                "The end of this conversation's saved file was written without the record "
                    + "numbering Codex needs to reopen it."
            ),
            cause: SessionLaunchDiagnosis.Cause.transcriptUnreadable
        )
    }

    // MARK: - Private Methods

    /// The last window of the file, or nil when it cannot be read.
    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > CodexRolloutHealthDefaults.tailBytes
            ? size - CodexRolloutHealthDefaults.tailBytes
            : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    /// Matched on the raw bytes rather than by decoding the record.
    ///
    /// A rollout line can be a quarter of a megabyte of tool output — three such lines sit in the
    /// specimen — and `JSONSerialization` on the tail window would parse all of it to answer a
    /// question about one key. The key is written by the runtime's own serializer directly after
    /// the timestamp, so its byte form is stable in a way its position in a decoded dictionary
    /// is not.
    private static func hasOrdinal(_ line: Data) -> Bool {
        // Bounded to the head of the record: the key belongs to the record's own envelope, and
        // scanning a 250 KB payload for it would find one that a nested tool result happened to
        // contain.
        let window = line.prefix(CodexRolloutHealthDefaults.envelopeBytes)
        return window.range(of: CodexRolloutHealthDefaults.ordinalKeyBytes) != nil
    }
}

// MARK: - Defaults

enum CodexRolloutHealthDefaults {

    /// How much of the end of a rollout is read. Large enough to contain several whole records
    /// even when they are long, small enough that the check is a single read of a page or two.
    static let tailBytes: UInt64 = 65_536

    /// How far into one record the envelope keys are looked for.
    static let envelopeBytes = 512

    static let ordinalKey = "\"ordinal\":"

    static let ordinalKeyBytes = Data(ordinalKey.utf8)
}
