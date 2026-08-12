import Foundation
import os

// MARK: - Claude Account Transcripts

/// The newest conversation a **login** has written, wherever it was run.
///
/// Two facts are read this way — the model an unpinned session resolved to, and the posture the
/// CLI put it in — and both need the same walk. It is shared rather than copied because the two
/// costs it avoids are the whole reason it is written the way it is, and a second copy would
/// eventually stop avoiding one of them:
///
/// - **Bounded breadth.** A heavy login has hundreds of project directories. Only the few most
///   recently touched are considered — a directory's modification date moves when a transcript is
///   added to it, so the newest activity is in the newest directories — and the scan stops there
///   rather than walking every conversation the account has ever held.
/// - **Bounded depth.** The reader given the chosen transcript caps how far back it looks.
enum ClaudeAccountTranscripts {

    // MARK: - Public Methods

    /// The most recently modified `.jsonl` among the most recently modified project directories.
    static func newest(inProjectsOf configPath: String) -> URL? {
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

    // MARK: - Private Methods

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

// MARK: - Claude Account Fact Memo

/// One answer per login, asked once.
///
/// These facts are fallbacks for an account Threading has not watched run, and each one costs a
/// directory walk plus a capped file scan. Misses are memoised too: an account with no
/// transcripts is the common case on a fresh install, and re-walking its directories per menu
/// open would be the cost the walk above exists to avoid.
///
/// The lock owns the dictionary rather than sitting beside it. A bare global dictionary next to
/// an `NSLock` was safe by convention but remained a Swift 6 data-race error, and a concurrent
/// `forgetAll()` could be undone by a scan that had started just before it — which is what the
/// generation counter is for.
final class ClaudeAccountFactMemo<Value: Sendable>: Sendable {

    // MARK: - Types

    /// A miss is a cached answer, not an absence of one.
    private enum Fact: Sendable {
        case found(Value)
        case missing

        var value: Value? {
            switch self {
            case .found(let value): return value
            case .missing: return nil
            }
        }
    }

    private struct State: Sendable {
        var generation = 0
        var facts: [String: Fact] = [:]
    }

    // MARK: - Properties

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Public Methods

    /// The memoised answer for this config directory, resolving it once if it has not been asked.
    func value(forConfigPath configPath: String, resolve: () -> Value?) -> Value? {
        let lookup = state.withLock { state in
            (fact: state.facts[configPath], generation: state.generation)
        }
        if let fact = lookup.fact { return fact.value }

        let resolved = resolve()

        state.withLock { state in
            // `forgetAll()` is an invalidation boundary. A slow scan that crossed it may return
            // its own answer, but must not repopulate the memo with the value just invalidated.
            guard state.generation == lookup.generation else { return }
            state.facts[configPath] = resolved.map(Fact.found) ?? .missing
        }

        return resolved
    }

    /// Drops the memo, so a test can watch the same account answer differently.
    func forgetAll() {
        state.withLock { state in
            state.generation &+= 1
            state.facts.removeAll()
        }
    }
}
