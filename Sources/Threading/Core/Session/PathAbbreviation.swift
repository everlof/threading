import Foundation

/// Folds the user's home directory into `~` wherever it appears in a line of text.
///
/// The Info panel shows paths the machine reported — an agent's settings file, a socket under
/// Application Support, the directory a process runs in — and every one of them begins with the
/// same forty characters nobody needs to read twice. `NSString.abbreviatingWithTildeInPath` only
/// answers for a string that *is* a path; a command line carries paths in the middle
/// (`--settings=/Users/…`, `--socket /Users/…`), so this looks for the home directory at any
/// token boundary and leaves a longer name that merely starts the same way (`/Users/davidson`)
/// alone.
enum PathAbbreviation {

    /// Characters that may precede a path inside a command line without being part of it.
    private static let openers: Set<Character> = ["=", ":", ",", "\"", "'", "@", "("]

    /// Characters that may follow a path inside a command line without being part of it.
    private static let closers: Set<Character> = ["/", ":", ",", "\"", "'", ";", ")"]

    static func abbreviatingHome(
        in text: String,
        home: String = NSHomeDirectory()
    ) -> String {
        guard home.count > 1, text.contains(home) else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex

        for range in text.ranges(of: home) {
            guard range.lowerBound >= cursor else { continue }
            let opensAtBoundary = range.lowerBound == text.startIndex
                || isBoundary(text[text.index(before: range.lowerBound)], in: openers)
            let closesAtBoundary = range.upperBound == text.endIndex
                || isBoundary(text[range.upperBound], in: closers)
            guard opensAtBoundary, closesAtBoundary else { continue }

            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append("~")
            cursor = range.upperBound
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    private static func isBoundary(_ character: Character, in set: Set<Character>) -> Bool {
        character.isWhitespace || set.contains(character)
    }
}
