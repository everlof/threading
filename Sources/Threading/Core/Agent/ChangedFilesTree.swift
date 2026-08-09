import Foundation
import NativeDiffCore

// MARK: - Changed Files Tree

/// A turn's changed files as an indented directory tree — the model behind the per-turn
/// changed-files card, t3code's `changedFilesPresentation` in the shape this codebase uses:
/// a pure derivation with its own tests, drawn by a dumb view.
///
/// Directories carry their subtree's ±counts rolled up, and a directory whose only child is
/// another directory is compressed into one `a/b` row — a scaffolded project is mostly
/// single-child chains, and a column of rows each introducing one path component reads as
/// indentation with no information in it.
struct ChangedFilesTree: Equatable {

    /// One changed file, as the reader reports it.
    struct File: Equatable {
        let path: String
        let added: Int
        let removed: Int
    }

    /// One row of the flattened tree, in display order.
    struct Node: Equatable {
        /// The display name — one path component, or a compressed `a/b` chain for a
        /// directory, relative to its parent.
        let name: String

        /// The full repository-relative path, so a row can be acted on without re-deriving it.
        let path: String

        /// Nesting level after compression, which is what indentation draws.
        let depth: Int

        let isDirectory: Bool

        let added: Int
        let removed: Int
    }

    /// Pre-order: each directory followed by its children, subdirectories before files,
    /// both alphabetical.
    let nodes: [Node]

    let fileCount: Int
    let added: Int
    let removed: Int

    /// Whether the card opens expanded: small turns show their tree outright, big ones start
    /// with every directory folded so forty files do not land in the transcript as forty rows.
    /// t3code's rule and thresholds, computed once when the card is built.
    var autoExpands: Bool {
        fileCount <= ChangedFilesDefaults.autoExpandFileCap
            && added + removed <= ChangedFilesDefaults.autoExpandLineCap
    }

    /// The indices of the rows a directory hides when collapsed: everything after it that is
    /// deeper, up to the next row at its own depth or above.
    func descendantIndices(of directoryIndex: Int) -> Range<Int> {
        let depth = nodes[directoryIndex].depth
        var end = directoryIndex + 1
        while end < nodes.count, nodes[end].depth > depth { end += 1 }
        return (directoryIndex + 1)..<end
    }

    // MARK: - Building

    static func build(from files: [File]) -> ChangedFilesTree {
        let root = Directory()
        for file in files {
            var components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            let name = components.removeLast()
            root.insert(file: (name, file.added, file.removed), at: components)
        }
        root.compress()

        var nodes: [Node] = []
        root.flatten(into: &nodes, prefix: "", depth: 0)

        return ChangedFilesTree(
            nodes: nodes,
            fileCount: files.count,
            added: files.reduce(0) { $0 + $1.added },
            removed: files.reduce(0) { $0 + $1.removed }
        )
    }

    // MARK: - Private Methods

    /// The mutable intermediate the builder works in; never leaves this type.
    private final class Directory {
        var name = ""
        var directories: [Directory] = []
        var files: [(name: String, added: Int, removed: Int)] = []

        func insert(file: (String, Int, Int), at components: [String]) {
            guard let head = components.first else {
                files.append(file)
                return
            }
            let child: Directory
            if let existing = directories.first(where: { $0.name == head }) {
                child = existing
            } else {
                child = Directory()
                child.name = head
                directories.append(child)
            }
            child.insert(file: file, at: Array(components.dropFirst()))
        }

        /// Merges single-child directory chains — `src` containing only `layouts` becomes one
        /// `src/layouts` row. The root never merges: its children are top-level rows.
        func compress() {
            for child in directories {
                while child.files.isEmpty, child.directories.count == 1 {
                    let only = child.directories[0]
                    child.name += "/" + only.name
                    child.files = only.files
                    child.directories = only.directories
                }
                child.compress()
            }
        }

        var added: Int {
            files.reduce(0) { $0 + $1.added } + directories.reduce(0) { $0 + $1.added }
        }

        var removed: Int {
            files.reduce(0) { $0 + $1.removed } + directories.reduce(0) { $0 + $1.removed }
        }

        func flatten(into nodes: inout [Node], prefix: String, depth: Int) {
            for child in directories.sorted(by: { $0.name < $1.name }) {
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                nodes.append(Node(
                    name: child.name,
                    path: path,
                    depth: depth,
                    isDirectory: true,
                    added: child.added,
                    removed: child.removed
                ))
                child.flatten(into: &nodes, prefix: path, depth: depth + 1)
            }
            for file in files.sorted(by: { $0.name < $1.name }) {
                nodes.append(Node(
                    name: file.name,
                    path: prefix.isEmpty ? file.name : prefix + "/" + file.name,
                    depth: depth,
                    isDirectory: false,
                    added: file.added,
                    removed: file.removed
                ))
            }
        }
    }
}

// MARK: - Changed File Diff Preview

/// One changed file's diff as the card keeps it, for the preview a file row shows under the
/// pointer.
///
/// **Bounded when it is captured, not when it is drawn.** The card is retained for as long as
/// the conversation it sits in, so holding each turn's whole diff would pin every line of every
/// file a session ever touched — a wide sweep is thousands of lines, and there is one card per
/// turn. The cap is spent in hunk order and what it could not cover is *counted*, so a preview
/// that stops early says so rather than ending mid-file.
struct ChangedFileDiffPreview: Equatable {
    let path: String
    let added: Int
    let removed: Int

    /// Hunks in order, the last one possibly cut short by the cap.
    let hunks: [GitHunk]

    /// Lines the cap left out.
    let omittedLines: Int

    /// Whether there is anything to draw: a binary file, or one git reported without hunks,
    /// has no preview to show and its row raises none.
    var isEmpty: Bool { hunks.allSatisfy { $0.lines.isEmpty } }

    /// Every file's bounded diff, keyed by path — what a card is built with.
    static func previews(
        from files: [GitFileDiff],
        lineCap: Int = ChangedFilesDefaults.previewLineCap,
        aggregateLineCap: Int = ChangedFilesDefaults.previewAggregateLineCap
    ) -> [String: ChangedFileDiffPreview] {
        var previews: [String: ChangedFileDiffPreview] = [:]
        let previewable = Set(files.indices.filter { index in
            files[index].hunks.contains { !$0.lines.isEmpty }
        })
        var remainingFiles = previewable.count
        var remainingLines = max(aggregateLineCap, 0)
        let perFileCeiling = max(lineCap, 0)

        for (index, file) in files.enumerated() {
            let cap: Int
            if remainingFiles > 0, previewable.contains(index), remainingLines > 0 {
                // Divide what remains across every file that can actually draw a preview. Short
                // files return their unused share to later files, while no one file may exceed
                // the existing per-file ceiling. The retained product is therefore bounded by
                // the card-wide budget rather than `files × 400`.
                cap = min(
                    perFileCeiling,
                    Int(ceil(Double(remainingLines) / Double(remainingFiles)))
                )
                remainingFiles -= 1
            } else {
                cap = 0
            }

            let value = preview(of: file, lineCap: cap)
            let retained = value.hunks.reduce(0) { $0 + $1.lines.count }
            remainingLines = max(remainingLines - retained, 0)
            previews[file.path] = value
        }
        return previews
    }

    static func preview(
        of file: GitFileDiff,
        lineCap: Int = ChangedFilesDefaults.previewLineCap
    ) -> ChangedFileDiffPreview {
        var remaining = max(lineCap, 0)
        var kept: [GitHunk] = []
        var omitted = 0

        for hunk in file.hunks {
            if hunk.lines.count <= remaining {
                kept.append(hunk)
                remaining -= hunk.lines.count
            } else {
                if remaining > 0 {
                    kept.append(GitHunk(
                        header: hunk.header,
                        lines: Array(hunk.lines.prefix(remaining))
                    ))
                }
                omitted += hunk.lines.count - remaining
                remaining = 0
            }
        }

        return ChangedFileDiffPreview(
            path: file.path,
            added: file.added,
            removed: file.removed,
            hunks: kept,
            omittedLines: omitted
        )
    }
}

// MARK: - Changed Files Defaults

enum ChangedFilesDefaults {
    /// A turn changing at most this many files and lines opens its tree outright.
    static let autoExpandFileCap = 5
    static let autoExpandLineCap = 200

    /// How much of one file's diff a card keeps for its hover preview. Deep enough that a
    /// normal edit is shown whole, shallow enough that a generated file does not ride along
    /// in memory for the rest of the session.
    static let previewLineCap = 400

    /// The whole retained card, not each file independently. Five ordinary files can still use
    /// the full per-file reading; a generated sweep shares the same finite 2,000-line product
    /// instead of retaining hundreds of lines times hundreds of files for the conversation's
    /// remaining lifetime.
    static let previewAggregateLineCap = 2_000
}
