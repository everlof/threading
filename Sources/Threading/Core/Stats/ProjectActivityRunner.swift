import Foundation

// MARK: - Project Activity Runner

/// Reads a small, path-scoped slice of Git history without walking the working tree.
///
/// Two bounded commands keep dormant repositories cheap: one commit for the all-time latest
/// change and at most 20,001 timestamps for the rolling window. The extra timestamp detects the
/// cap; a capped result stays useful as "20,000+" but deliberately does not draw a biased chart.
enum ProjectActivityRunner {

    enum Measurement: Equatable {
        case notRepository
        case activity(ProjectActivity)
    }

    static func measure(folder: String, now: Date = Date()) -> Measurement? {
        guard GitInfo.worktreeLocation(for: folder) != nil else { return .notRepository }

        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let latestDates: [Date]
        if let latestOutput = run(
            arguments: ProjectActivityDefaults.latestArguments,
            in: directory
        ) {
            guard let parsed = parseTimestamps(latestOutput), parsed.count <= 1 else { return nil }
            latestDates = parsed
        } else {
            // `git log` exits 128 before the first commit. Prove that HEAD alone is absent so a
            // corrupt repository or unrelated command failure never becomes "No commits yet."
            guard isUnbornRepository(directory) else { return nil }
            return .activity(ProjectActivity.make(
                recentCommitDates: [],
                latestCommitAt: nil,
                now: now
            ))
        }

        let since = Int(
            now.addingTimeInterval(
                -Double(ProjectActivity.bucketCount) * ProjectActivity.bucketDuration
            ).timeIntervalSince1970
        )
        let recentArguments = ProjectActivityDefaults.recentArguments(since: since)
        guard let recentOutput = run(arguments: recentArguments, in: directory),
              var recentDates = parseTimestamps(recentOutput)
        else { return nil }

        let isTruncated = recentDates.count > ProjectActivity.maximumCommitCount
        if isTruncated {
            recentDates.removeLast(recentDates.count - ProjectActivity.maximumCommitCount)
        }

        return .activity(ProjectActivity.make(
            recentCommitDates: recentDates,
            latestCommitAt: latestDates.first,
            now: now,
            isTruncated: isTruncated
        ))
    }

    /// Parses Git's one-Unix-timestamp-per-line format. Malformed output fails closed rather
    /// than quietly presenting a partial count as complete.
    static func parseTimestamps(_ data: Data) -> [Date]? {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var dates: [Date] = []
        dates.reserveCapacity(lines.count)
        for line in lines {
            guard let timestamp = TimeInterval(line) else { return nil }
            dates.append(Date(timeIntervalSince1970: timestamp))
        }
        return dates
    }

    private static func run(arguments: [String], in directory: URL) -> Data? {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: GitDefaults.executablePath,
                arguments: arguments,
                workingDirectory: directory,
                timeout: ProjectActivityDefaults.timeout,
                maximumOutputBytes: ProjectActivityDefaults.maximumOutputBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.agent.error(
                "Could not read project activity: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        guard result.termination == .exited(0), !result.outputWasTruncated else { return nil }
        return result.output
    }

    private static func isUnbornRepository(_ directory: URL) -> Bool {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: GitDefaults.executablePath,
                arguments: ProjectActivityDefaults.verifyHeadArguments,
                workingDirectory: directory,
                timeout: ProjectActivityDefaults.timeout,
                maximumOutputBytes: 4_096,
                output: .standardOutput
            )
        } catch {
            return false
        }
        return result.termination == .exited(1)
            && !result.outputWasTruncated
            && result.output.isEmpty
    }
}

// MARK: - Defaults

enum ProjectActivityDefaults {
    static let verifyHeadArguments = ["rev-parse", "--verify", "--quiet", "HEAD"]

    static let latestArguments = [
        "-c", "color.ui=false", "-c", "log.showSignature=false",
        "log", "-1", "--format=%ct", "--", "."
    ]

    static func recentArguments(since: Int) -> [String] {
        [
            "-c", "color.ui=false", "-c", "log.showSignature=false", "log",
            "--format=%ct",
            "--since=@\(since)",
            "--max-count=\(ProjectActivity.maximumCommitCount + 1)",
            "--", "."
        ]
    }

    static let timeout: TimeInterval = 15
    static let maximumOutputBytes = 512 * 1024
    static let fileName = "project-activity.json"
}
