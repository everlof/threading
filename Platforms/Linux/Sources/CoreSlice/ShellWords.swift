import Foundation

/// A command line read the way a POSIX shell reads it: split into simple commands at unquoted
/// operators, and each command into the words its program receives.
///
/// Permission code needs exactly that reading, because a looser one is wrong in both directions.
/// Splitting at every `|` read `rg -n 'Next|onNext' ios` as a search plus a command named
/// `onNext' ios`, so an unattended automation run whose allow-list named `rg` was refused the
/// search and stopped, with nobody there to approve it. Taking off one layer of quotes per word
/// admitted `find . -de'l'ete`, which the shell runs as `find . -delete`.
///
/// It reads only what it can be exact about, and refuses (`nil`) anything whose words are not
/// known until the shell runs: substitution, redirection, a subshell, brace expansion,
/// backgrounding, a newline or an unterminated quote. Pathname expansion is the one exception:
/// `*`, `?` and `[` stay literal, because refusing them would refuse `ls *.md`. A glob only
/// names files that already exist, but a file named like a flag can still arrive through one.
enum ShellWords {

    /// One simple command.
    struct Segment: Equatable, Sendable {
        /// The command as typed, for a reason shown to a person or an agent.
        let text: String
        /// The command name, then its arguments as the program receives them. The name keeps its
        /// spelling when any of it is quoted or escaped: unquoting it would admit `"ls"` as `ls`,
        /// and a policy built on this must never widen what passes.
        let words: [String]
    }

    /// The simple commands of `line`, or nil when it holds a construct with no exact reading.
    /// Empty commands (the middle of `||`, a stray `;`) are dropped, so `"&&"` reads as `[]`.
    static func segments(of line: String) -> [Segment]? {
        var reader = Reader(line)
        return reader.read()
    }

    /// `word` spelled so `segments(of:)` reads it back unchanged: bare when no character in it
    /// means anything to the reader, otherwise in single quotes.
    static func quoted(_ word: String) -> String {
        if !word.isEmpty, !word.unicodeScalars.contains(where: specialCharacters.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static let specialCharacters = CharacterSet(charactersIn: " \t\n\r'\"\\|;&<>`$(){}")

    /// Reads by Unicode scalar, not `Character`, because the shell reads bytes: a quote followed
    /// by a combining mark is one `Character` to Swift and still a quote to the shell.
    private struct Reader {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private var segments: [Segment] = []
        private var segmentStart = 0
        private var words: [String] = []
        /// The word being read, as its program will receive it.
        private var word = String.UnicodeScalarView()
        /// The same word with every quoted or escaped character masked, which is all brace
        /// expansion looks at: `'{a,b}'` and `\{a,b}` stay literal.
        private var bare = String.UnicodeScalarView()
        private var wordStart: Int?
        private var wordIsQuoted = false

        init(_ line: String) { scalars = Array(line.unicodeScalars) }

        mutating func read() -> [Segment]? {
            guard !scalars.contains("\n"), !scalars.contains("\r") else { return nil }
            while index < scalars.count {
                let scalar = scalars[index]
                switch scalar {
                case " ", "\t":
                    guard endWord() else { return nil }
                case "'":
                    guard readSingleQuoted() else { return nil }
                case "\"":
                    guard readDoubleQuoted() else { return nil }
                case "\\":
                    // A trailing backslash would continue onto a line that is not there.
                    guard index + 1 < scalars.count else { return nil }
                    begin(quoted: true)
                    index += 1
                    append(scalars[index], quoted: true)
                case "|", ";":
                    guard endSegment(resumingAt: index + 1) else { return nil }
                case "&":
                    // `&&` chains two commands, each vetted on its own; a lone `&` backgrounds
                    // what came before it, and `|&` is caught here too.
                    guard index + 1 < scalars.count, scalars[index + 1] == "&",
                          endSegment(resumingAt: index + 2) else { return nil }
                    index += 1
                case "<", ">", "$", "`", "(", ")":
                    return nil
                default:
                    begin(quoted: false)
                    append(scalar, quoted: false)
                }
                index += 1
            }
            guard endSegment(resumingAt: scalars.count) else { return nil }
            return segments
        }

        /// `'…'`: every character up to the next `'` is literal, `$` and `|` included.
        private mutating func readSingleQuoted() -> Bool {
            begin(quoted: true)
            guard let close = scalars[(index + 1)...].firstIndex(of: "'") else { return false }
            for scalar in scalars[(index + 1)..<close] { append(scalar, quoted: true) }
            index = close
            return true
        }

        /// `"…"`: literal, except that `$` and backticks still expand and so are refused, and a
        /// backslash escapes `$`, a backtick, `"` or `\`. Before anything else it is literal.
        private mutating func readDoubleQuoted() -> Bool {
            begin(quoted: true)
            index += 1
            while index < scalars.count {
                let scalar = scalars[index]
                switch scalar {
                case "\"":
                    return true
                case "$", "`":
                    return false
                case "\\" where index + 1 < scalars.count && "$`\"\\".unicodeScalars.contains(scalars[index + 1]):
                    index += 1
                    append(scalars[index], quoted: true)
                default:
                    append(scalar, quoted: true)
                }
                index += 1
            }
            return false
        }

        private mutating func begin(quoted: Bool) {
            if wordStart == nil { wordStart = index }
            if quoted { wordIsQuoted = true }
        }

        private mutating func append(_ scalar: Unicode.Scalar, quoted: Bool) {
            word.append(scalar)
            bare.append(quoted ? "_" : scalar)
        }

        /// Closes the word being read, if there is one. False when the shell would brace-expand
        /// it into words this reading cannot know, such as `{--pre=sh,x}`.
        private mutating func endWord() -> Bool {
            guard let start = wordStart else { return true }
            defer {
                word = String.UnicodeScalarView()
                bare = String.UnicodeScalarView()
                wordStart = nil
                wordIsQuoted = false
            }
            guard String(bare).range(of: #"\{.*(,|\.\.).*\}"#, options: .regularExpression) == nil else {
                return false
            }
            if words.isEmpty, wordIsQuoted {
                words.append(String(String.UnicodeScalarView(scalars[start..<index])))
            } else {
                words.append(String(word))
            }
            return true
        }

        private mutating func endSegment(resumingAt next: Int) -> Bool {
            guard endWord() else { return false }
            if !words.isEmpty {
                let text = String(String.UnicodeScalarView(scalars[segmentStart..<index]))
                    .trimmingCharacters(in: .whitespaces)
                segments.append(Segment(text: text, words: words))
                words = []
            }
            segmentStart = next
            return true
        }
    }
}
