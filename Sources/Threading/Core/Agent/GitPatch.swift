import Foundation

/// Rebuilds a unified-diff patch from a parsed hunk, so one hunk can be handed to
/// `git apply --cached` on its own.
///
/// Reconstructed rather than sliced out of the original text, because the pane parsed that
/// text into a model and no longer has the bytes. The reconstruction is exact for what
/// `git apply` reads: the `@@` header verbatim (its counts describe this hunk and nothing
/// else), one prefixed line per line, and the `\ No newline at end of file` note passed
/// through unprefixed — it is a comment about the line before it, not a line of the file, and
/// dropping it silently re-adds a newline the file never had.
///
/// Offsets do not need fixing up. A hunk header taken from `diff` against the index applies
/// to the index; one taken against HEAD does not, which is why only the index-based modes
/// offer hunk actions at all — the guard is at the call site, not here.
enum GitPatch {

    // MARK: - Public Methods

    /// A one-hunk patch, newline-terminated as `git apply` requires.
    static func patch(for hunk: GitHunk, path: String) -> String {
        var text = "diff --git a/\(path) b/\(path)\n"
        text += "--- a/\(path)\n"
        text += "+++ b/\(path)\n"
        text += hunk.header + "\n"

        for line in hunk.lines {
            text += body(of: line) + "\n"
        }
        return text
    }

    /// Whether a file's diff can be staged a hunk at a time.
    ///
    /// Only a modification can. A rename, a binary and an untracked file have no partial form
    /// at all — and neither, for this reconstruction, do an added or a deleted file: their
    /// diffs carry a `new file mode` / `deleted file mode` header and a `/dev/null` side that
    /// a rebuilt one-hunk patch does not, and git does not treat the difference as cosmetic.
    /// Measured, both ways round: reverse-applying a rebuilt patch for an added file *silently
    /// staged an empty blob* rather than unstaging the file, and for a deleted file git refused
    /// with "does not exist in index". Nothing is lost by excluding them, since a new or
    /// deleted file's diff is always exactly one hunk — the whole file — which is what the
    /// row's own Stage File does correctly through `git add` / `git reset`.
    static func supportsHunkStaging(_ file: GitFileDiff) -> Bool {
        switch file.change {
        case .renamed, .binary, .untracked, .added, .deleted: return false
        case .modified: return !file.hunks.isEmpty
        }
    }

    // MARK: - Private Methods

    private static func body(of line: GitDiffLine) -> String {
        if isNoNewlineNote(line) { return line.text }

        switch line.kind {
        case .added: return "+" + line.text
        case .removed: return "-" + line.text
        case .context: return " " + line.text
        }
    }

    /// The parser keeps git's note as a context line carrying its whole raw text, which is the
    /// only thing that tells it from a context line that happens to start with a backslash.
    private static func isNoNewlineNote(_ line: GitDiffLine) -> Bool {
        line.kind == .context
            && line.oldNumber == nil
            && line.newNumber == nil
            && line.text.hasPrefix(GitWriteDefaults.noNewlineMarker)
    }
}
