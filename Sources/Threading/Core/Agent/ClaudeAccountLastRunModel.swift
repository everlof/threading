import Foundation
import os

// MARK: - Claude Account Last Run Model

/// The model a **login** last ran, read back from the transcripts it has already written.
///
/// `ClaudeTranscriptModel` answers the same question for one conversation Threading is showing.
/// This answers it for an account with no conversation on screen — the composer's case, and a
/// brand-new install's — which is the last gap where the model row had nothing to say.
///
/// The other sources are all configuration, and configuration is exactly what a login that leaves
/// the choice to the CLI does not have: `settings.json` names no model, the organisation names
/// none, and Threading has never watched a session on it start. Measured on a real account with
/// 167 transcripts and no `model` key anywhere, the newest one records `claude-opus-5` — the
/// answer the user wanted, sitting on disk the whole time.
///
/// **This reports what ran, not what was configured**, so callers must label it that way. A
/// session launched with an explicit `--model` writes a transcript like any other, and nothing in
/// the file says whether the model was chosen or inherited. "Last used" is true either way;
/// "account default" would not be.
///
/// Three costs this deliberately avoids:
///
/// - **Bounded breadth.** A heavy login has hundreds of project directories. Only the few most
///   recently touched are considered — a directory's modification date moves when a transcript is
///   added to it, so the newest activity is in the newest directories — and the scan stops there
///   rather than walking every conversation the account has ever held.
/// - **Bounded depth.** The chosen transcript is read backwards through
///   `ClaudeTranscriptModel.newestModel(at:)`, which caps how far it looks before giving up.
/// - **Asked once.** The result is memoised for the lifetime of the process. This is a fallback
///   for an account Threading has not yet watched run; the moment it does watch one,
///   `AccountPreference.lastReportedModel` answers first and this is never consulted again.
enum ClaudeAccountLastRunModel {

    // MARK: - Properties

    /// Keyed by config path. Caches misses too: an account with no transcripts is the common
    /// case on a fresh install, and re-walking its directories per menu open would be the cost
    /// this whole type exists to avoid.
    private enum CachedModel: Sendable {
        case found(String)
        case missing

        var value: String? {
            switch self {
            case .found(let model): return model
            case .missing: return nil
            }
        }
    }

    private struct Cache: Sendable {
        var generation = 0
        var models: [String: CachedModel] = [:]
    }

    /// The compiler can see that the mutable dictionary is lock-owned. A bare global dictionary
    /// beside an `NSLock` was safe by convention but remained a Swift 6 data-race error, and a
    /// concurrent `forgetAll()` could be undone by a scan that had started just before it.
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    // MARK: - Public Methods

    /// The model this login's newest transcript recorded, or nil when it has never run.
    static func lastRunModel(account: AgentAccount) -> String? {
        guard account.provider.supports(.transcriptModelRecord) else { return nil }

        let lookup = cache.withLock { state in
            (model: state.models[account.configPath], generation: state.generation)
        }
        if let cached = lookup.model {
            return cached.value
        }
        let generation = lookup.generation

        let resolved = newestTranscript(inProjectsOf: account.configPath)
            .flatMap { ClaudeTranscriptModel.newestModel(at: $0) }

        cache.withLock { state in
            // `forgetAll()` is an invalidation boundary. A slow scan that crossed it may return
            // its own answer, but must not repopulate the cache with the value just invalidated.
            guard state.generation == generation else { return }
            state.models[account.configPath] = resolved.map(CachedModel.found) ?? .missing
        }

        return resolved
    }

    /// Drops the memo, so a test can watch the same account answer differently.
    static func forgetAll() {
        cache.withLock { state in
            state.generation &+= 1
            state.models.removeAll()
        }
    }

    // MARK: - Private Methods

    /// The most recently modified `.jsonl` among the most recently modified project directories.
    private static func newestTranscript(inProjectsOf configPath: String) -> URL? {
        let projects = URL(fileURLWithPath: configPath)
            .appendingPathComponent(TranscriptModelDefaults.claudeProjectsDirectory)

        let directories = newestEntries(
            in: projects,
            limit: TranscriptModelDefaults.projectDirectoryBudget
        )
        guard !directories.isEmpty else { return nil }

        return directories
            .flatMap { newestEntries(in: $0, limit: TranscriptModelDefaults.transcriptBudget) }
            .filter { $0.pathExtension == TranscriptModelDefaults.transcriptExtension }
            .max { modificationDate(of: $0) < modificationDate(of: $1) }
    }

    /// The `limit` most recently modified entries of a directory, newest first. An unreadable
    /// directory is empty rather than an error: this is a best-effort fallback throughout.
    private static func newestEntries(in directory: URL, limit: Int) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .prefix(limit)
            .map { $0 }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
