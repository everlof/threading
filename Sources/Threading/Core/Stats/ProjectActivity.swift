import Foundation

// MARK: - Project Activity

/// A bounded glance at recent Git activity for one project folder.
///
/// Buckets run oldest to newest and cover fixed seven-day intervals. The model carries no Git
/// details, authors, messages, or file names: the hover card needs only enough history to answer
/// whether the project is active and when it last changed.
struct ProjectActivity: Codable, Equatable, Sendable {
    static let bucketCount = 12
    static let bucketDuration: TimeInterval = 7 * 24 * 60 * 60
    static let maximumCommitCount = 20_000

    let weeklyCommits: [Int]
    let commitCount: Int
    let latestCommitAt: Date?
    let isTruncated: Bool

    /// Folds commit dates into the twelve rolling weeks ending at `now`.
    static func make(
        recentCommitDates: [Date],
        latestCommitAt: Date?,
        now: Date,
        isTruncated: Bool = false
    ) -> Self {
        let windowDuration = Double(bucketCount) * bucketDuration
        let windowStart = now.addingTimeInterval(-windowDuration)
        var buckets = Array(repeating: 0, count: bucketCount)
        var includedCount = 0

        for date in recentCommitDates {
            let offset = date.timeIntervalSince(windowStart)
            guard offset >= 0 else { continue }
            let index = min(Int(offset / bucketDuration), bucketCount - 1)
            buckets[index] += 1
            includedCount += 1
        }

        return Self(
            weeklyCommits: buckets,
            commitCount: min(includedCount, maximumCommitCount),
            latestCommitAt: latestCommitAt,
            isTruncated: isTruncated
        )
    }
}
