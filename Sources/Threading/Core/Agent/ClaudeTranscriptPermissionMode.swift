import Foundation

// MARK: - Claude Transcript Permission Mode

/// The permission mode a Claude **terminal** session is in, read back from its own transcript.
///
/// Threading knows a session's posture only when Threading chose it: `session.permissionMode`,
/// or `AppSettings.defaultPermissionMode` behind it, become `--permission-mode` on the launch
/// line and then stop being true the moment the user presses Shift+Tab. A session left to the
/// CLI's own configuration was never known at all.
///
/// Claude writes the answer down. Every assertion of the posture appends one record:
///
/// ```json
/// {"type":"permission-mode","permissionMode":"auto","sessionId":"cb0f164f-…"}
/// ```
///
/// Two things about that record decide the shape of this reader, and both were measured against
/// real transcripts rather than assumed.
///
/// **It is dense, not one-per-change.** Across the logins on the machine this was written
/// against, a transcript carries between 9 and 48 of them, and the newest sits 101 bytes to
/// 20 KB from the end of the file — inside a scan budget that is two chunks. A record written
/// only when the mode changed would have sat at the head of a long conversation, out of reach of
/// any capped scan, and this would have had to be a whole-file read or nothing.
///
/// **It carries Claude's own vocabulary, which includes the name this app does not persist.**
/// `default` appears alongside `auto`, `plan` and `acceptEdits` — Claude's internal name for
/// Manual — so the value goes through `AgentPermissionMode(externalValue:for:)` and never
/// through `init(rawValue:)`. An unrecognised value reads as nil: a newer CLI's seventh mode
/// must leave the surfaces asking silent rather than get rounded to a posture it is not.
///
/// The caching, the size gate and the background hop are `TranscriptFactReader`'s, shared with
/// `ClaudeTranscriptModel`. Callers in the app should ask `ObservedPermissionMode`, which is
/// where the choice of *which* runtime can answer is made.
@MainActor
enum ClaudeTranscriptPermissionMode {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<AgentPermissionMode> { url in
        newestMode(at: url)
    }

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    static func known(at url: URL) -> AgentPermissionMode? {
        reader.known(at: url)
    }

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (AgentPermissionMode?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    static func forgetAll() {
        reader.forgetAll()
    }

    /// The newest mode a transcript records, or nil when none lies within the budget and nil
    /// again when the value recorded is not one of the six.
    ///
    /// Kept out of the memo and off the actor so the read itself is testable without a queue,
    /// the same split `ClaudeTranscriptModel.newestModel(at:)` keeps. Callers in the app should
    /// ask `known`/`revalidate` instead; this touches the disk.
    nonisolated static func newestMode(at url: URL) -> AgentPermissionMode? {
        guard let value = newestRecordedValue(at: url) else { return nil }
        return AgentPermissionMode(externalValue: value, for: .claude)
    }

    /// The newest value the transcript states, in Claude's own spelling and unmapped.
    ///
    /// Separate from `newestMode` so a record carrying a value this app does not know can be
    /// told apart from a transcript that states no mode at all — the first is a CLI that has
    /// moved ahead of us, the second is a scan that came up empty, and only a test can see the
    /// difference once both have become nil.
    nonisolated static func newestRecordedValue(at url: URL) -> String? {
        var value: String?
        JSONLReader.forEachRecordFromEnd(
            at: url,
            limit: TranscriptPermissionModeDefaults.scanBytes
        ) { record in
            guard record[TranscriptPermissionModeDefaults.typeKey] as? String
                    == TranscriptPermissionModeDefaults.recordType,
                  let recorded = record[TranscriptPermissionModeDefaults.modeKey] as? String,
                  !recorded.isEmpty
            else { return true }

            value = recorded
            return false
        }
        return value
    }
}

// MARK: - Defaults

enum TranscriptPermissionModeDefaults {
    /// How far back a scan looks, and the same two chunks the model reader uses.
    ///
    /// The budget is not shared with it, though the number is: the two facts sit at different
    /// distances from the end of a file — the newest permission-mode record was measured between
    /// 101 bytes and 20 KB back, an assistant record can be a long tail of tool output further —
    /// so one constant serving both would tie a change made for one to the other's evidence.
    static let scanBytes = 2 * JSONLDefaults.chunkBytes
    static let typeKey = "type"
    static let recordType = "permission-mode"
    static let modeKey = "permissionMode"
}
