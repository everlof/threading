import Foundation

/// The part of a unified diff a panel draws: one global line budget across every file and hunk.
///
/// Shared by the Compare tab and the attachments pane's diff preview, so a comparison reads the
/// same in both places. One budget rather than one per hunk, because a generated diff with
/// thousands of tiny hunks otherwise built thousands of rows on the main thread.
struct DiffDisplayLines: Sendable {
    let lines: [GitDiffLine]
    /// Whether lines past the budget were left out, which the surface says in a note.
    let hasMore: Bool
    /// The newer side's path, which is what picks the syntax highlighter.
    let path: String?

    /// Takes at most the budget without first flattening or copying the unbounded diff. Line
    /// numbers stay attached to each source line, so hunk and file boundaries remain legible as
    /// jumps even though they no longer allocate separate views.
    init(files: [GitFileDiff], budget: Int = DiffDefaults.displayCap) {
        var lines: [GitDiffLine] = []
        lines.reserveCapacity(budget)
        var hasMore = false

        collecting: for file in files {
            for hunk in file.hunks where !hunk.lines.isEmpty {
                let remaining = budget - lines.count
                guard remaining > 0 else {
                    hasMore = true
                    break collecting
                }
                lines.append(contentsOf: hunk.lines.prefix(remaining))
                if hunk.lines.count > remaining {
                    hasMore = true
                    break collecting
                }
            }
        }
        self.lines = lines
        self.hasMore = hasMore
        path = files.first?.path
    }

    /// Reads and parses a diff file. Blocking — callers run it on a worker.
    ///
    /// Bounded by the size the comparison itself may produce, so a frozen comparison always
    /// reads back; a larger hand-made patch answers nil and the pane says it is too large.
    static func read(_ url: URL) -> DiffDisplayLines? {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: GitReviewDefaults.maximumDiffBytes
        ) else { return nil }
        return DiffDisplayLines(files: GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(data)))
    }
}
