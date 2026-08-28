import Foundation

// MARK: - Edit Diff

/// Turns an edit tool's arguments into a line diff, so an approval or a tool row can show the
/// change rather than just the file it touches.
///
/// The arguments already carry everything needed — `Edit` gives the old and new text, `Write`
/// gives a whole new file, `MultiEdit` a list of hunks — so nothing is read from disk and the
/// diff is known before the tool even runs.
enum EditDiff {

    /// The file-level form retained on a timeline tool call. The ordinary row still draws the
    /// flattened diff, while replay uses these exact sections to rebuild the card the live Git
    /// baseline produced. No checkout read is involved in replay.
    struct FileChange: Equatable {
        let path: String
        let lines: [DiffLine]
    }

    static func fileChanges(forTool name: String, input: [String: Any]) -> [FileChange] {
        if let patch = input["patch"] as? String {
            return CodexPatch.fileChanges(in: patch).map {
                FileChange(path: $0.path, lines: $0.lines)
            }
        }

        guard let path = (input["file_path"] ?? input["notebook_path"]) as? String,
              !path.isEmpty,
              let lines = lines(forTool: name, input: input),
              !lines.isEmpty else { return [] }
        return [FileChange(path: path, lines: lines)]
    }

    /// The diff for a tool call, or nil when the tool does not edit a file.
    static func lines(forTool name: String, input: [String: Any]) -> [DiffLine]? {
        // Codex states its change as a patch rather than as two strings, and a patch already
        // *is* a diff — reconstructing both sides only to align them again would discard the
        // alignment it states. Checked before the tool name, since `apply_patch` arrives here
        // renamed to `Edit`.
        if let patch = input["patch"] as? String {
            let lines = CodexPatch.lines(in: patch)
            return lines.isEmpty ? nil : lines
        }

        switch name {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            return diff(old, new)

        case "Write":
            // A new or replaced file has no prior text to compare against, so every line reads
            // as added. Whatever was there before is not in the arguments.
            guard let content = input["content"] as? String else { return nil }
            return content.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) }

        case "MultiEdit":
            // All-or-nothing, in both directions. A diff is read as *the* change a call will
            // make — it is what a person approves — so a hunk this reader cannot open must not
            // simply be left out of the picture: that does not under-report the edit, it
            // misdescribes it, and there is nothing on the card to say a hunk is missing.
            // Showing no diff falls back to naming the file, which claims nothing false.
            //
            // The inner refusal is the same decision and used to disagree with the outer one:
            // an unreadable *element* withdrew the whole diff while an unreadable *member*
            // silently dropped that one hunk and drew the rest.
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            var hunks: [DiffLine] = []
            for edit in edits {
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { return nil }
                hunks.append(contentsOf: diff(old, new))
            }
            return hunks

        default:
            return nil
        }
    }

    /// How many lines a diff adds and removes, for the one-line summary on a collapsed row.
    static func counts(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    // MARK: - Line Diff

    /// A line-level diff of two strings via a longest-common-subsequence walk.
    ///
    /// Edit hunks are small, so the quadratic table is cheap. A pathologically large pair —
    /// a whole-file replacement passed as one Edit — skips the table and shows every old line
    /// removed then every new line added, which is correct if less tidy than aligned context.
    static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        if oldLines.isEmpty { return newLines.map { DiffLine(kind: .added, text: $0) } }
        if newLines.isEmpty { return oldLines.map { DiffLine(kind: .removed, text: $0) } }

        guard oldLines.count <= DiffDefaults.alignmentCap,
              newLines.count <= DiffDefaults.alignmentCap else {
            return oldLines.map { DiffLine(kind: .removed, text: $0) }
                + newLines.map { DiffLine(kind: .added, text: $0) }
        }

        return align(oldLines, newLines)
    }

    private static func align(_ old: [String], _ new: [String]) -> [DiffLine] {
        let rows = old.count
        let cols = new.count

        // lcs[r][c] = length of the longest common subsequence of old[r...] and new[c...].
        var lcs = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for col in stride(from: cols - 1, through: 0, by: -1) {
                lcs[row][col] = old[row] == new[col]
                    ? lcs[row + 1][col + 1] + 1
                    : max(lcs[row + 1][col], lcs[row][col + 1])
            }
        }

        var result: [DiffLine] = []
        var row = 0
        var col = 0

        while row < rows, col < cols {
            if old[row] == new[col] {
                result.append(DiffLine(kind: .context, text: old[row]))
                row += 1
                col += 1
            } else if lcs[row + 1][col] >= lcs[row][col + 1] {
                result.append(DiffLine(kind: .removed, text: old[row]))
                row += 1
            } else {
                result.append(DiffLine(kind: .added, text: new[col]))
                col += 1
            }
        }
        while row < rows { result.append(DiffLine(kind: .removed, text: old[row])); row += 1 }
        while col < cols { result.append(DiffLine(kind: .added, text: new[col])); col += 1 }

        return result
    }
}

// MARK: - Diff Defaults

enum DiffDefaults {
    /// Above this many lines on either side, the aligned walk is skipped for a plain
    /// removed-then-added rendering — the table would cost more than the tidiness is worth.
    static let alignmentCap = 800

    /// Lines a diff draws before it is truncated with a note. Collapsed by default, so this is
    /// about layout cost, not attention.
    static let displayCap = 300

    static let fontSize: CGFloat = 11
    static let gutterWidth: CGFloat = 14
}
