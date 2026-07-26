import Foundation

/// Parses `git diff` / `git show` unified output without running git.
public enum UnifiedDiffParser {
    public static func files(from text: String) -> [DiffFile] {
        var files: [DiffFile] = []
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

    private final class FileBuilder {
        private var headerPaths: (old: String?, new: String?)
        private var oldPath: String?
        private var newPath: String?
        private var renamedFrom: String?
        private var isNew = false
        private var isDeleted = false
        private var isBinary = false
        private var hunks: [DiffHunk] = []
        private var hunkHeader: String?
        private var hunkLines: [DiffLine] = []
        private var oldNumber = 0
        private var newNumber = 0
        private var added = 0
        private var removed = 0

        init(gitLine: String) {
            headerPaths = Self.paths(fromGitLine: gitLine)
        }

        func consume(_ line: String) {
            if hunkHeader != nil {
                switch line.first {
                case " ":
                    append(.context, String(line.dropFirst()), old: oldNumber, new: newNumber)
                    oldNumber += 1
                    newNumber += 1
                    return
                case "+":
                    append(.added, String(line.dropFirst()), old: nil, new: newNumber)
                    newNumber += 1
                    added += 1
                    return
                case "-":
                    append(.removed, String(line.dropFirst()), old: oldNumber, new: nil)
                    oldNumber += 1
                    removed += 1
                    return
                case "\\":
                    hunkLines.append(DiffLine(kind: .context, text: line))
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
        }

        func build() -> DiffFile? {
            closeHunk()
            let path = newPath ?? oldPath ?? headerPaths.new ?? headerPaths.old
            guard let path else { return nil }

            let change: DiffFile.Change
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

            return DiffFile(
                path: path,
                change: change,
                hunks: hunks,
                added: added,
                removed: removed
            )
        }

        private func append(_ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) {
            hunkLines.append(DiffLine(kind: kind, text: text, oldNumber: old, newNumber: new))
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
            hunks.append(DiffHunk(header: header, lines: hunkLines))
            hunkHeader = nil
            hunkLines = []
        }

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

        private static func strippedSide(_ line: String, prefix: String, marker: String) -> String? {
            var raw = String(line.dropFirst(prefix.count))
            while raw.hasSuffix("\t") { raw.removeLast() }
            let rest = unquote(raw)
            if rest == Marker.devNull { return nil }
            if rest.hasPrefix(marker) { return String(rest.dropFirst(marker.count)) }
            return rest
        }

        private static func paths(fromGitLine line: String) -> (old: String?, new: String?) {
            let rest = String(line.dropFirst(Marker.fileStart.count))
            if rest.hasPrefix("\"") {
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
            if path.hasPrefix(Marker.oldPathPrefix) {
                return String(path.dropFirst(Marker.oldPathPrefix.count))
            }
            if path.hasPrefix(Marker.newPathPrefix) {
                return String(path.dropFirst(Marker.newPathPrefix.count))
            }
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

    public static func unquote(_ path: String) -> String {
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
