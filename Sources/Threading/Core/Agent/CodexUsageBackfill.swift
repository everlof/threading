import Foundation

// MARK: - Codex Usage Backfill

/// Recovers rate-limit history from Codex's own rollouts.
///
/// Codex writes a `rate_limits` block into its transcripts on almost every turn — 3.28 million
/// of them on this machine — each stamped with a time, a percentage and a reset. That is a
/// burn-down curve of every week the user has worked, sitting on disk unread, and it means a
/// Codex account can have a forecast the first time the page is opened rather than after a day
/// of watching.
///
/// Claude has no equivalent: its transcripts carry no rate-limit records at all (checked), so
/// its history necessarily starts when Threading starts looking.
///
/// **Bounded on purpose.** A full pass over the rollouts took 38 seconds and produced millions
/// of samples where a few hundred would say the same thing. Only files touched within the
/// window's own span are opened, and each contributes at most one sample per bucket — the shape
/// of a curve does not need every point on it.
enum CodexUsageBackfill {

    // MARK: - Public Methods

    /// Samples recovered for one account, oldest first.
    ///
    /// Blocks on the filesystem, so callers hop to a queue of their own first.
    static func samples(forAccountAt configPath: String, now: Date = Date()) -> [UsageSample] {
        let cutoff = now.addingTimeInterval(-CodexBackfillDefaults.span)
        let sessions = URL(fileURLWithPath: configPath)
            .appendingPathComponent(CodexBackfillDefaults.sessionsDirectory)

        guard let walker = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        // Newest first, so the cap keeps the most recent evidence rather than the oldest.
        let recent = (walker.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == AgentDefaults.transcriptExtension }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, modified > cutoff else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(CodexBackfillDefaults.maximumFiles)
            .map(\.0)

        var byBucket: [Int: UsageSample] = [:]

        for url in recent {
            for sample in samples(inRolloutAt: url) {
                // One sample per bucket: a curve is a shape, and thousands of readings of the
                // same ten minutes describe it no better than one does.
                let bucket = Int(sample.at.timeIntervalSince1970 / CodexBackfillDefaults.bucket)
                if let existing = byBucket[bucket], existing.at >= sample.at { continue }
                byBucket[bucket] = sample
            }
        }

        return byBucket.values.sorted { $0.at < $1.at }
    }

    /// Every rate-limit reading in one rollout.
    static func samples(inRolloutAt url: URL) -> [UsageSample] {
        var found: [UsageSample] = []
        let marker = Data(CodexBackfillDefaults.marker.utf8)

        JSONLReader.forEachLine(at: url, limit: CodexBackfillDefaults.maximumBytesPerFile) { line in
            guard line.range(of: marker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = record[CodexBackfillDefaults.payloadKey] as? [String: Any],
                  let limits = payload[CodexBackfillDefaults.limitsKey] as? [String: Any],
                  let primary = limits[CodexBackfillDefaults.primaryKey] as? [String: Any],
                  let percent = (primary[CodexBackfillDefaults.percentKey] as? NSNumber)?.doubleValue,
                  let stamp = record[CodexBackfillDefaults.timestampKey] as? String,
                  let at = UsageHTTP.parseISO8601(stamp)
            else { return true }

            let resetsAt = (primary[CodexBackfillDefaults.resetKey] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }

            found.append(UsageSample(
                at: at,
                fraction: min(max(percent / 100, 0), 1),
                resetsAt: resetsAt
            ))
            return true
        }

        return found
    }

    /// The window a recovered sample belongs to, named the way `CodexUsageFetcher` names it so
    /// the history keys match the live readings'.
    static func windowID(minutes: Double) -> String {
        let seconds = minutes * 60
        let hours = Int(seconds / 3600)
        return hours >= 24 ? "\(hours / 24)d" : "\(hours)h"
    }
}

// MARK: - Codex Backfill Defaults

enum CodexBackfillDefaults {
    static let sessionsDirectory = "sessions"

    /// The substring that makes a line worth parsing, so most of a rollout costs nothing.
    static let marker = "\"rate_limits\""

    static let payloadKey = "payload"
    static let limitsKey = "rate_limits"
    static let primaryKey = "primary"
    static let percentKey = "used_percent"
    static let resetKey = "resets_at"
    static let timestampKey = "timestamp"

    /// How far back to look: a little beyond the longest window, so a weekly one is covered.
    static let span: TimeInterval = 8 * 24 * 3600

    /// One sample per ten minutes is plenty of curve.
    static let bucket: TimeInterval = 10 * 60

    /// A ceiling on the walk, since the rollouts run to gigabytes and the newest files carry
    /// everything the forecast can use.
    static let maximumFiles = 120

    /// Read from the head of each rollout only.
    ///
    /// Measured the hard way: reading 200 rollouts in full took **403 seconds** — several
    /// gigabytes for a curve that needs a few hundred points. Codex writes a rate-limit block
    /// on nearly every turn, so the opening stretch of a session already carries a timestamped
    /// reading, and one per session across a week is more curve than the projection can use.
    static let maximumBytesPerFile = 256 * 1024
}
