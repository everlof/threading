import Foundation

// MARK: - Claude Transcript Model

/// The model a Claude **terminal** session actually ran, read back from its own transcript.
///
/// Threading knows a session's model only when Threading chose it. `session.model` is what the
/// user pinned in the composer, and `AgentModels.defaultModel` reads `"model"` from the account's
/// `settings.json`. Neither is set for a login that leaves the choice to the CLI — Claude then
/// resolves its own default from a layer this app does not read — and the corner card had a
/// session plainly running Opus 5 with nothing to say about it but its effort.
///
/// The transcript is the one source that cannot be wrong about this: every assistant record
/// carries the model that produced it, so this reports what ran rather than what was configured.
/// It is also the only *live* source of the three, which is what makes `/model` mid-conversation
/// visible at all.
///
/// The caching, the size gate and the queue hop are `TranscriptFactReader`'s, shared with the
/// permission-mode reader beside it; what stays here is the scan and the reason for its budget.
/// The model sits on assistant records and a transcript ends on whatever the last tool wrote, so
/// the answer is near the end but rarely on the last line: `TranscriptModelDefaults.scanBytes`
/// bounds how far back to look, and a conversation whose recent tail is all tool output answers
/// `nil` rather than walking the whole file.
@MainActor
enum ClaudeTranscriptModel {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<String> { url in
        newestModel(at: url)
    }

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    static func known(at url: URL) -> String? {
        reader.known(at: url)
    }

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    static func forgetAll() {
        reader.forgetAll()
    }

    /// The newest model a transcript records, or nil when none lies within the budget.
    ///
    /// Kept out of the memo and off the actor so the read itself is testable without a queue —
    /// the same split `ConfirmationAlert.remembers(accepted:suppressionChecked:)` keeps from its
    /// modal. Callers in the app should ask `known`/`revalidate` instead; this touches the disk.
    nonisolated static func newestModel(at url: URL) -> String? {
        var model: String?
        JSONLReader.forEachRecordFromEnd(at: url, limit: TranscriptModelDefaults.scanBytes) { record in
            guard let message = record[TranscriptModelDefaults.messageKey] as? [String: Any],
                  let identifier = message[TranscriptModelDefaults.modelKey] as? String,
                  !identifier.isEmpty
            else { return true }

            model = identifier
            return false
        }
        return model
    }
}

// MARK: - Defaults

enum TranscriptModelDefaults {
    /// How far back a scan looks. Two chunks covers the last several turns of an ordinary
    /// conversation, including a tail of tool results, without letting one card refresh read a
    /// transcript that has grown to hundreds of megabytes.
    static let scanBytes = 2 * JSONLDefaults.chunkBytes
    static let messageKey = "message"
    static let modelKey = "model"

    /// Where Claude keeps one directory of transcripts per project it has been run in, under the
    /// account's own config directory.
    static let claudeProjectsDirectory = "projects"
    static let transcriptExtension = "jsonl"

    /// How wide an account-level search goes before settling. A directory's modification date
    /// moves when a transcript is added to it, so the newest activity is in the newest
    /// directories and a handful of them is enough to find the newest conversation — measured
    /// against a login with 15 project directories and 167 transcripts. The alternative is
    /// walking every conversation an account has ever held to answer one menu row.
    static let projectDirectoryBudget = 5
    static let transcriptBudget = 10
}
