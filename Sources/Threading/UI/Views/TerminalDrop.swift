import Foundation
import ThreadingRemoteKit

/// What a file dropped on a terminal becomes.
///
/// A terminal carries text, so a drop is a **path pasted into it** — which is also exactly what
/// both agent CLIs read, since neither can be handed an image any other way. Terminal.app and
/// iTerm have done this for as long as anyone has dragged a file onto a shell, and this is the
/// same answer rather than a new one: the user's reference point is a path that arrived
/// backslash-escaped in a normal terminal, and a path Threading quoted differently would be a
/// path the agent then failed to open.
///
/// **Pasted, not typed** — the drop goes out wrapped in bracketed paste (`pasteText`, our
/// SwiftTerm seam), and that is what turns a dropped screenshot into an attached image instead
/// of a line of path. Both CLIs treat one arriving paste as a unit and read it as an image when
/// it is a path ending in an image extension: Claude Code answers with `[Image #1]`
/// (`png|jpe?g|gif|webp`, several paths at once), Codex with its own attachment (PNG and JPEG,
/// one path per paste). Neither inspects typed characters for a path, so the same bytes sent
/// through `insertText` stay text — which is what they did before, and the whole of the bug.
///
/// The escaping below survives the trip: both strip surrounding quotes and undo backslash
/// escapes before testing the extension, so a name with spaces still arrives as one path.
///
/// A drop in a format the reader does not match is made into one first — see
/// `TerminalDropImage`, which is where the extension lists live.
///
/// Kept apart from the view because the escaping is the part that can be wrong, and a rule
/// about backslashes is not something a running PTY should be needed to check.
enum TerminalDrop {

    /// The text a drop inserts: every path escaped, separated by spaces, and one trailing
    /// space so a second drop or a typed word does not run into the first.
    static func text(for paths: [String]) -> String {
        RemoteTerminalPaste.filePathText(for: paths)
    }

    /// One path, escaped the way a shell reads it back as a single word.
    ///
    /// The backslash goes first, or escaping it afterwards would escape the backslashes this
    /// adds. Everything in `escapable` is a character that changes a shell's mind about where
    /// a word ends — the set is deliberately generous, because a needless backslash before a
    /// bracket costs nothing and a missing one before a space loses the file.
    static func escaped(_ path: String) -> String {
        RemoteTerminalPaste.escapedFilePath(path)
    }
}
