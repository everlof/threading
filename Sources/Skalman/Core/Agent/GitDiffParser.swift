import Foundation

/// Parses git's own output formats into the review models. Pure text transforms — nothing
/// here runs git or touches disk, which is what keeps every branch of it unit-testable.
enum GitDiffParser {

    // MARK: - Unified Diff

    /// Splits `git diff` / `git show` output into per-file diffs with numbered lines.
    static func files(fromUnifiedDiff text: String) -> [GitFileDiff] {
        var files: [GitFileDiff] = []
        var current: FileBuilder?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(Marker.fileStart) {
                if let built = current?.build() { files.append(built) }
                current = FileBuilder(gitLine: String(line))
            } else {
                current?.consume(String(line))
            }
        }
        if let built = current?.build() { files.append(built) }

        return files
    }

    /// Accumulates one `diff --git` record: header facts first, then hunks.
    private final class FileBuilder {
        private var headerPaths: (old: String?, new: String?)
        private var oldPath: String?
        private var newPath: String?
        private var renamedFrom: String?
        private var isNew = false
        private var isDeleted = false
        private var isBinary = false

        private var hunks: [GitHunk] = []
        private var hunkHeader: String?
        private var hunkLines: [GitDiffLine] = []
        private var oldNumber = 0
        private var newNumber = 0
        private var added = 0
        private var removed = 0

        init(gitLine: String) {
            headerPaths = Self.paths(fromGitLine: gitLine)
        }

        func consume(_ line: String) {
            if hunkHeader != nil {
                // Inside a hunk, until a line that cannot belong to one.
                switch line.first {
                case " ":
                    appendLine(.context, String(line.dropFirst()), old: oldNumber, new: newNumber)
                    oldNumber += 1
                    newNumber += 1
                    return
                case "+":
                    appendLine(.added, String(line.dropFirst()), old: nil, new: newNumber)
                    newNumber += 1
                    added += 1
                    return
                case "-":
                    appendLine(.removed, String(line.dropFirst()), old: oldNumber, new: nil)
                    oldNumber += 1
                    removed += 1
                    return
                case "\\":
                    // "\ No newline at end of file" — a note about the previous line, not a
                    // line of the file. No numbers, no count.
                    hunkLines.append(GitDiffLine(kind: .context, text: line, oldNumber: nil, newNumber: nil))
                    return
                default:
                    closeHunk()
                }
            }

            if line.hasPrefix(Marker.hunk) {
                openHunk(line)
            } else if line.hasPrefix(Marker.renameFrom) {
                renamedFrom = unquote(String(line.dropFirst(Marker.renameFrom.count)))
            } else if line.hasPrefix(Marker.renameTo) {
                newPath = unquote(String(line.dropFirst(Marker.renameTo.count)))
            } else if line.hasPrefix(Marker.newFile) {
                isNew = true
            } else if line.hasPrefix(Marker.deletedFile) {
                isDeleted = true
            } else if line.hasPrefix(Marker.binary) {
                isBinary = true
            } else if line.hasPrefix(Marker.oldSide) {
                oldPath = Self.strippedSide(line, prefix: Marker.oldSide, marker: Marker.oldPathPrefix)
            } else if line.hasPrefix(Marker.newSide) {
                newPath = Self.strippedSide(line, prefix: Marker.newSide, marker: Marker.newPathPrefix) ?? newPath
            }
            // similarity/index/mode lines carry nothing the pane shows.
        }

        func build() -> GitFileDiff? {
            closeHunk()

            let path = newPath ?? oldPath ?? headerPaths.new ?? headerPaths.old
            guard let path else { return nil }

            let change: GitFileDiff.Change
            if isBinary {
                change = .binary
            } else if let renamedFrom {
                change = .renamed(from: renamedFrom)
            } else if isNew {
                change = .added
            } else if isDeleted {
                change = .deleted
            } else {
                change = .modified
            }

            return GitFileDiff(path: path, change: change, hunks: hunks, added: added, removed: removed)
        }

        private func appendLine(_ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) {
            hunkLines.append(GitDiffLine(kind: kind, text: text, oldNumber: old, newNumber: new))
        }

        private func openHunk(_ line: String) {
            closeHunk()
            let starts = Self.hunkStarts(line)
            oldNumber = starts.old
            newNumber = starts.new
            hunkHeader = line
        }

        private func closeHunk() {
            guard let header = hunkHeader else { return }
            hunks.append(GitHunk(header: header, lines: hunkLines))
            hunkHeader = nil
            hunkLines = []
        }

        /// `@@ -12,7 +12,9 @@ …` → the two start numbers. A missing count defaults to 1 and
        /// does not matter here; only the starts seed the running numbering.
        private static func hunkStarts(_ line: String) -> (old: Int, new: Int) {
            var old = 1
            var new = 1
            for part in line.split(separator: " ") {
                if part.hasPrefix("-") {
                    old = Int(part.dropFirst().prefix { $0.isNumber }) ?? old
                } else if part.hasPrefix("+") {
                    new = Int(part.dropFirst().prefix { $0.isNumber }) ?? new
                    break
                }
            }
            return (old, new)
        }

        /// `--- a/path`, `+++ b/path` or `/dev/null` → the path, nil for `/dev/null`.
        /// git ends the line with a tab when the path contains spaces; it is not part of it.
        private static func strippedSide(_ line: String, prefix: String, marker: String) -> String? {
            var raw = String(line.dropFirst(prefix.count))
            while raw.hasSuffix("\t") { raw.removeLast() }
            let rest = unquote(raw)
            if rest == Marker.devNull { return nil }
            if rest.hasPrefix(marker) { return String(rest.dropFirst(marker.count)) }
            return rest
        }

        /// Best-effort paths from `diff --git a/X b/Y`, needed when no `---`/`+++` lines
        /// follow — binary files and pure renames. For a quoted path the quotes decide; for
        /// an unquoted one the ` b/` separator does, searching from the end so an ` a/` or
        /// ` b/` inside the old path cannot split it early.
        private static func paths(fromGitLine line: String) -> (old: String?, new: String?) {
            let rest = String(line.dropFirst(Marker.fileStart.count))

            if rest.hasPrefix("\"") {
                // "a/old" "b/new" — unquote each half.
                let halves = splitQuoted(rest)
                return (halves.0.map(stripSidePrefix), halves.1.map(stripSidePrefix))
            }

            guard let separator = rest.range(of: " " + Marker.newPathPrefix, options: .backwards) else {
                return (nil, nil)
            }
            let old = String(rest[rest.startIndex..<separator.lowerBound])
            let new = String(rest[separator.upperBound...])
            return (stripSidePrefix(unquote(old)), new.isEmpty ? nil : new)
        }

        private static func stripSidePrefix(_ path: String) -> String {
            if path.hasPrefix(Marker.oldPathPrefix) { return String(path.dropFirst(Marker.oldPathPrefix.count)) }
            if path.hasPrefix(Marker.newPathPrefix) { return String(path.dropFirst(Marker.newPathPrefix.count)) }
            return path
        }

        private static func splitQuoted(_ text: String) -> (String?, String?) {
            var parts: [String] = []
            var current = ""
            var inQuotes = false
            var escaped = false
            for character in text {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" && inQuotes {
                    current.append(character)
                    escaped = true
                } else if character == "\"" {
                    if inQuotes { parts.append(unquote("\"" + current + "\"")) }
                    current = ""
                    inQuotes.toggle()
                } else if inQuotes {
                    current.append(character)
                }
            }
            return (parts.first, parts.count > 1 ? parts[1] : nil)
        }
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
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }

        var bytes: [UInt8] = []
        let characters = Array(path.dropFirst().dropLast().utf8)
        var index = 0
        while index < characters.count {
            let byte = characters[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < characters.count else {
                bytes.append(byte)
                index += 1
                continue
            }

            let next = characters[index + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n")); index += 2
            case UInt8(ascii: "t"): bytes.append(UInt8(ascii: "\t")); index += 2
            case UInt8(ascii: "\\"), UInt8(ascii: "\""): bytes.append(next); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits.
                var value = 0
                var count = 0
                while count < 3, index + 1 + count < characters.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(characters[index + 1 + count]) {
                    value = value * 8 + Int(characters[index + 1 + count] - UInt8(ascii: "0"))
                    count += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + count
            default:
                bytes.append(next)
                index += 2
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Markers

    private enum Marker {
        static let fileStart = "diff --git "
        static let hunk = "@@ "
        static let renameFrom = "rename from "
        static let renameTo = "rename to "
        static let newFile = "new file mode "
        static let deletedFile = "deleted file mode "
        static let binary = "Binary files "
        static let oldSide = "--- "
        static let newSide = "+++ "
        static let oldPathPrefix = "a/"
        static let newPathPrefix = "b/"
        static let devNull = "/dev/null"
    }
}
