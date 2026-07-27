import Foundation

/// What a file dropped on a terminal becomes.
///
/// A terminal carries text, so a drop is a **path typed into it** — which is also exactly what
/// both agent CLIs read, since neither can be handed an image any other way. Terminal.app and
/// iTerm have done this for as long as anyone has dragged a file onto a shell, and this is the
/// same answer rather than a new one: the user's reference point is a path that arrived
/// backslash-escaped in a normal terminal, and a path Skalman quoted differently would be a
/// path the agent then failed to open.
///
/// Kept apart from the view because the escaping is the part that can be wrong, and a rule
/// about backslashes is not something a running PTY should be needed to check.
enum TerminalDrop {

    /// The text a drop inserts: every path escaped, separated by spaces, and one trailing
    /// space so a second drop or a typed word does not run into the first.
    static func text(for paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map(escaped).joined(separator: " ") + " "
    }

    /// One path, escaped the way a shell reads it back as a single word.
    ///
    /// The backslash goes first, or escaping it afterwards would escape the backslashes this
    /// adds. Everything in `escapable` is a character that changes a shell's mind about where
    /// a word ends — the set is deliberately generous, because a needless backslash before a
    /// bracket costs nothing and a missing one before a space loses the file.
    static func escaped(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count)

        for character in path {
            if character == "\\" || escapable.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Shell word-breaking and expansion characters. Newline and tab are in here for the same
    /// reason as space: a file may legally contain them, and a terminal reads one as *enter*.
    private static let escapable: Set<Character> = [
        " ", "\t", "\n", "\"", "'", "`", "$", "&", "*", "?", ";", "|",
        "<", ">", "(", ")", "[", "]", "{", "}", "!", "#", "~"
    ]
}
