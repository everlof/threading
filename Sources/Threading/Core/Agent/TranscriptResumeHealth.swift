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
        guard CodexRolloutNumbering.isMixed(at: url) else { return .usable }

        return .unusable(
            reason: L10n.string(
                "The end of this conversation's saved file was written without the record "
                    + "numbering Codex needs to reopen it."
            ),
            cause: SessionLaunchDiagnosis.Cause.transcriptUnreadable
        )
    }

}
