import Foundation

// MARK: - Codex Patch

/// Reads Codex's `apply_patch` argument, which is a patch rather than a set of fields.
///
/// Claude's edit tools hand over `old_string`/`new_string` and `EditDiff` builds the change
/// from those. Codex hands over the change already written, in its own envelope:
///
/// ```
/// *** Begin Patch
/// *** Update File: Sources/App.swift
/// @@
///  unchanged context
/// -removed
/// +added
/// *** End Patch
/// ```
///
/// Without this, a Codex edit reached the renderer as `["input": <the whole patch>]`: the row's
/// subject was empty, because nothing looked like a path, and no diff was drawn at all —
/// despite the diff being *right there* in the argument. So Codex sessions showed their edits
/// as anonymous blank rows while Claude's showed a coloured diff, and the difference was
/// invisible until whole rollouts were rendered and looked at.
enum CodexPatch {

    private enum Marker {
        static let begin = "*** Begin Patch"
        static let end = "*** End Patch"
        static let hunk = "@@"

        /// Each introduces a file and names it after the colon.
        static let fileHeaders = ["*** Add File:", "*** Update File:", "*** Delete File:"]

        /// `*** Move to:` renames rather than opening a new file, so it is not a file header.
        static let moveTo = "*** Move to:"
    }

    // MARK: - Public Methods

    /// The renderer's arguments for a patch: the file it touches, and the change itself.
    ///
    /// `diff` is handed over pre-built rather than as `old_string`/`new_string`, because a patch
    /// already *is* a diff — reconstructing two sides from it only to align them again would
    /// throw away the alignment the patch states.
    static func toolInput(patch: String) -> [String: Any] {
        var input: [String: Any] = ["patch": patch]
        if let path = firstPath(in: patch) {
            input["file_path"] = path
        }
        return input
    }

    /// The paths a patch touches, in the order it touches them.
    static func paths(in patch: String) -> [String] {
        patch.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let line = String(line)
            guard let header = Marker.fileHeaders.first(where: { line.hasPrefix($0) }) else {
                return nil
            }
            let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
    }

    static func firstPath(in patch: String) -> String? {
        paths(in: patch).first
    }

    /// The patch as diff lines, ready to draw.
    ///
    /// A patch spanning several files keeps its file headers as context lines: dropping them
    /// would run two files' changes together as though they were one.
    static func lines(in patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix(Marker.begin) || line.hasPrefix(Marker.end) { continue }

            if Marker.fileHeaders.contains(where: { line.hasPrefix($0) })
                || line.hasPrefix(Marker.moveTo) {
                lines.append(DiffLine(kind: .context, text: line))
                continue
            }

            // A bare `@@` carries no information a reader needs once the lines around it are
            // shown; one carrying a section name does.
            if line.hasPrefix(Marker.hunk) {
                let detail = line.dropFirst(Marker.hunk.count).trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty {
                    lines.append(DiffLine(kind: .context, text: detail))
                }
                continue
            }

            switch line.first {
            case "+":
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            case "-":
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            default:
                // Context lines carry a leading space in the envelope; a genuinely blank line
                // has nothing to drop.
                lines.append(DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
            }
        }

        // Trailing blanks are an artefact of splitting on the envelope's final newline.
        while case .context = lines.last?.kind, lines.last?.text.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }
}
