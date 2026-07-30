import Foundation
import NativeDiffCore

/// Parses git's own output formats into the review models. Pure text transforms — nothing
/// here runs git or touches disk, which is what keeps every branch of it unit-testable.
enum GitDiffParser {

    // MARK: - Unified Diff

    /// Splits `git diff` / `git show` output into per-file diffs with numbered lines.
    static func files(fromUnifiedDiff text: String) -> [GitFileDiff] {
        UnifiedDiffParser.files(from: text)
    }

    // MARK: - Status (porcelain v2)

    /// Parses `git status --porcelain=v2 -z`. With `-z`, records are NUL-separated and a
    /// rename entry's original path arrives as the *next* record.
    static func status(fromPorcelainV2 data: Data) -> GitStatus {
        let text = decode(data)
        var entries: [GitStatus.Entry] = []
        var untracked: [String] = []

        let records = text.split(separator: "\u{00}", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1

            switch record.first {
            case "1":
                if let entry = changedEntry(record, renamedFrom: nil) { entries.append(entry) }
            case "2":
                let original = index < records.count ? records[index] : nil
                index += 1
                if let entry = changedEntry(record, renamedFrom: original) { entries.append(entry) }
            case "u":
                // An unmerged path is work in the tree even if the pane cannot diff it cleanly.
                if let path = unmergedPath(record) {
                    entries.append(GitStatus.Entry(path: path, renamedFrom: nil, staged: false, unstaged: true))
                }
            case "?":
                untracked.append(String(record.dropFirst(2)))
            default:
                break // headers ("#"), ignored ("!")
            }
        }

        return GitStatus(entries: entries, untracked: untracked)
    }

    /// `1 XY sub mH mI mW hH hI path` / `2 XY sub … X<score> path`. The path is everything
    /// after the fixed field count, so spaces inside it survive.
    private static func changedEntry(_ record: String, renamedFrom: String?) -> GitStatus.Entry? {
        let fieldCount = record.hasPrefix("2") ? 9 : 8
        let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard fields.count > fieldCount, fields[1].count == 2 else { return nil }

        let states = Array(fields[1])
        return GitStatus.Entry(
            path: String(fields[fieldCount]),
            renamedFrom: renamedFrom,
            staged: states[0] != ".",
            unstaged: states[1] != "."
        )
    }

    /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`.
    private static func unmergedPath(_ record: String) -> String? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count > 10 else { return nil }
        return String(fields[10])
    }

    // MARK: - Numstat

    /// Sums `--numstat` output — `added<TAB>removed<TAB>path` per line — into one total.
    /// Binary files report `-` in both columns, which counts the file and no lines.
    static func summary(fromNumstat data: Data) -> GitChangeSummary {
        var files = 0
        var added = 0
        var removed = 0

        for line in decode(data).split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            files += 1
            added += Int(columns[0]) ?? 0
            removed += Int(columns[1]) ?? 0
        }

        return GitChangeSummary(files: files, added: added, removed: removed)
    }

    // MARK: - Log

    /// Parses `git log` in the reader's control-character format: records begin with 0x01,
    /// header fields are NUL-separated, 0x02 ends the header, and `--numstat` lines follow.
    static func commits(fromLog data: Data) -> [GitCommitSummary] {
        decode(data)
            .split(separator: "\u{01}", omittingEmptySubsequences: true)
            .compactMap { commit(fromRecord: String($0)) }
    }

    private static func commit(fromRecord record: String) -> GitCommitSummary? {
        let sections = record.split(separator: "\u{02}", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = sections[0].split(separator: "\u{00}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, let seconds = TimeInterval(fields[4]) else { return nil }

        var added = 0
        var removed = 0
        if sections.count > 1 {
            for line in sections[1].split(separator: "\n") {
                let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard columns.count == 3 else { continue }
                // Binary files report "-", which counts as nothing rather than failing the row.
                added += Int(columns[0]) ?? 0
                removed += Int(columns[1]) ?? 0
            }
        }

        return GitCommitSummary(
            hash: fields[0],
            shortHash: fields[1],
            subject: fields[2],
            author: fields[3],
            date: Date(timeIntervalSince1970: seconds),
            added: added,
            removed: removed,
            parents: fields.count > 5 ? fields[5].split(separator: " ").map(String.init) : [],
            refs: fields.count > 6 ? decorations(in: fields[6]) : []
        )
    }

    /// `%D` reads `HEAD -> main, origin/main, tag: v1.2`. HEAD is separated out — it points at
    /// a branch rather than being one — and `tag:` keeps its prefix, which is what tells a tag
    /// from a branch of the same name.
    private static func decorations(in field: String) -> [String] {
        field
            .split(separator: ",")
            .flatMap { entry -> [String] in
                let name = entry.trimmingCharacters(in: .whitespaces)
                guard let arrow = name.range(of: " -> ") else { return name.isEmpty ? [] : [name] }
                return [String(name[..<arrow.lowerBound]), String(name[arrow.upperBound...])]
            }
    }

    // MARK: - Shared

    /// Diff output is raw file bytes; a non-UTF-8 file should degrade to readable-ish text,
    /// not to an error for the whole diff.
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Undoes git's C-style quoting: `"path with \"quotes\" and \303\244"`. Paths without
    /// quotes pass through untouched (`core.quotepath=false` keeps non-ASCII literal, but
    /// quotes and control characters are always quoted).
    static func unquote(_ path: String) -> String {
        UnifiedDiffParser.unquote(path)
    }
}
