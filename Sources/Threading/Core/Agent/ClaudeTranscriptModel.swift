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
/// Three properties, each one a cost this would otherwise have:
///
/// - **Backwards and capped.** The model sits on assistant records and a transcript ends on
///   whatever the last tool wrote, so the answer is near the end but rarely on the last line.
///   `TranscriptModelDefaults.scanBytes` bounds how far back a scan looks before giving up; a
///   conversation whose recent tail is all tool output answers `nil` rather than walking the
///   whole file.
/// - **Never on the main thread.** `known(at:)` answers from memory and touches no disk, so the
///   card can paint the moment a session is selected. Even the size check that decides whether a
///   re-read is needed happens on the background queue.
/// - **Called back only on a change.** `ProjectsDidChange` fires for content edits, which
///   includes the terminal titles agents rewrite constantly. A completion per event would redraw
///   the card for an answer that had not moved.
@MainActor
enum ClaudeTranscriptModel {

    // MARK: - Types

    /// One transcript's answer and the size it was read at. The size is the invalidation: a file
    /// that has not grown cannot have recorded a different model.
    private struct Reading: Sendable {
        let size: Int
        let model: String?
    }

    // MARK: - Properties

    /// In memory rather than on disk, unlike `ClaudeStatusLineCoverage`'s. That one records what
    /// a *program* does, which is worth remembering across launches; this records what a running
    /// conversation is doing, where an answer from a previous launch is worth less than reading
    /// the file again.
    private static var readings: [String: Reading] = [:]

    /// One scan per transcript at a time, so a burst of refreshes cannot queue a stack of reads
    /// behind each other.
    private static var scanning: Set<String> = []

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    static func known(at url: URL) -> String? {
        readings[url.path]?.model
    }

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let path = url.path
        guard !scanning.contains(path) else { return }

        let previous = readings[path]
        scanning.insert(path)

        DispatchQueue.global(qos: .utility).async {
            let reading = read(at: url, unchangedFrom: previous)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    scanning.remove(path)
                    guard let reading else { return }

                    readings[path] = reading
                    guard reading.model != previous?.model else { return }
                    completion(reading.model)
                }
            }
        }
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    ///
    /// Deliberately leaves `scanning` alone: a scan already in flight clears its own entry when
    /// it lands, and dropping the entry here would let a second scan start over the same file.
    /// What that in-flight read writes back is what the file says, which is the right answer for
    /// a forgotten transcript anyway.
    static func forgetAll() {
        readings.removeAll()
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

    // MARK: - Private Methods

    /// The transcript's answer, or nil when the file has not grown since `previous` — which is
    /// "nothing to update", not "no model".
    private nonisolated static func read(at url: URL, unchangedFrom previous: Reading?) -> Reading? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        guard previous?.size != size else { return nil }

        return Reading(size: size, model: newestModel(at: url))
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
}
