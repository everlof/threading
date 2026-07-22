import Foundation

// MARK: - Roles

/// What a run of characters is, as far as colour is concerned. Deliberately few: a diff row is
/// read for what changed, and a palette with a hue per grammar rule competes with the wash that
/// carries the change itself.
enum SyntaxRole {
    case keyword
    case type
    case string
    case number
    case comment
}

/// A coloured run. Plain code produces no token at all, so the caller's default colour stands.
struct SyntaxToken {
    let range: Range<String.Index>
    let role: SyntaxRole
}

// MARK: - Language

/// A language's lexical surface — everything the scanner needs to know about it.
///
/// One scanner, a table of languages, in the shape `Markdown`'s reader table already uses:
/// the alternative is a parser per language, and a diff row needs to know a string from a
/// comment, not a grammar.
struct SyntaxLanguage {
    let lineComments: [String]
    let blockComment: (open: String, close: String)?
    /// Quote characters that open a string. Escapes are `\` unless `escapesWithBackslash` is off.
    let stringDelimiters: [Character]
    let escapesWithBackslash: Bool
    let keywords: Set<String>
    /// Named types and builtins, coloured apart from control flow.
    let types: Set<String>
    /// Whether an unknown Capitalized identifier reads as a type — true in Swift and Go, false
    /// in Python, where it is as likely to be a variable.
    let capitalizedIsType: Bool
    /// `#if`, `@main`: a sigil plus an identifier, in languages where `#` is not a comment.
    let sigils: Set<Character>
}

// MARK: - Highlighter

/// A hand-written lexer for the handful of things a diff needs coloured. Not a parser: it has
/// no grammar, no AST and no opinion about what is valid — an unterminated string simply ends
/// at the line, which is exactly what a half-written line in a diff looks like.
enum Syntax {

    /// Carried between lines, because a block comment is the one construct that outlives one.
    struct State {
        var inBlockComment = false
    }

    // MARK: - Public Methods

    /// The language a file's contents are in, or nil when the extension is unknown — which
    /// renders as plain text rather than as a guess.
    static func language(forPath path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent
        if let named = SyntaxLanguages.byFilename[name.lowercased()] { return named }

        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return SyntaxLanguages.byExtension[ext]
    }

    /// Tokenizes one line, advancing the block-comment state for the next.
    static func tokens(in line: String, language: SyntaxLanguage, state: inout State) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = line.startIndex

        if state.inBlockComment, let close = language.blockComment?.close {
            let start = index
            if let end = range(of: close, in: line, from: index) {
                index = end.upperBound
                state.inBlockComment = false
            } else {
                index = line.endIndex
            }
            tokens.append(SyntaxToken(range: start..<index, role: .comment))
        }

        while index < line.endIndex {
            let character = line[index]

            if character.isWhitespace {
                index = line.index(after: index)
                continue
            }

            // Comments first, always: a `#` is a comment in Python and a directive in Swift,
            // and a `*` inside a comment is not an operator anywhere.
            if language.lineComments.contains(where: { matches($0, in: line, at: index) }) {
                tokens.append(SyntaxToken(range: index..<line.endIndex, role: .comment))
                break
            }

            if let block = language.blockComment, matches(block.open, in: line, at: index) {
                let start = index
                let afterOpen = line.index(index, offsetBy: block.open.count)
                if let end = range(of: block.close, in: line, from: afterOpen) {
                    index = end.upperBound
                } else {
                    index = line.endIndex
                    state.inBlockComment = true
                }
                tokens.append(SyntaxToken(range: start..<index, role: .comment))
                continue
            }

            if language.stringDelimiters.contains(character) {
                let start = index
                index = endOfString(in: line, from: index, quote: character, escaping: language.escapesWithBackslash)
                tokens.append(SyntaxToken(range: start..<index, role: .string))
                continue
            }

            if character.isNumber {
                let start = index
                index = endOfNumber(in: line, from: index)
                tokens.append(SyntaxToken(range: start..<index, role: .number))
                continue
            }

            if language.sigils.contains(character),
               let next = line.index(index, offsetBy: 1, limitedBy: line.endIndex),
               next < line.endIndex, isIdentifierStart(line[next]) {
                let start = index
                index = endOfIdentifier(in: line, from: next)
                tokens.append(SyntaxToken(range: start..<index, role: .keyword))
                continue
            }

            if isIdentifierStart(character) {
                let start = index
                index = endOfIdentifier(in: line, from: index)
                let word = String(line[start..<index])

                if language.keywords.contains(word) {
                    tokens.append(SyntaxToken(range: start..<index, role: .keyword))
                } else if language.types.contains(word)
                            || (language.capitalizedIsType && word.first?.isUppercase == true) {
                    tokens.append(SyntaxToken(range: start..<index, role: .type))
                }
                continue
            }

            index = line.index(after: index)
        }

        return tokens
    }

    // MARK: - Private Methods

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func endOfIdentifier(in line: String, from start: String.Index) -> String.Index {
        var index = start
        while index < line.endIndex, isIdentifierStart(line[index]) || line[index].isNumber {
            index = line.index(after: index)
        }
        return index
    }

    /// Digits, and whatever a literal glues to them — `0xFF`, `1_000`, `3.14e-2`, `10px`. The
    /// scanner is not validating the literal, only finding where it stops.
    private static func endOfNumber(in line: String, from start: String.Index) -> String.Index {
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if character.isHexDigit || character == "." || character == "_" || character.isLetter {
                index = line.index(after: index)
            } else if character == "-" || character == "+",
                      let previous = line.index(index, offsetBy: -1, limitedBy: line.startIndex),
                      line[previous] == "e" || line[previous] == "E" {
                index = line.index(after: index)
            } else {
                break
            }
        }
        return index
    }

    /// Ends at the closing quote, or at the line — a diff shows lines out of context, and half
    /// a multi-line string is a normal thing to be looking at.
    private static func endOfString(
        in line: String,
        from start: String.Index,
        quote: Character,
        escaping: Bool
    ) -> String.Index {
        var index = line.index(after: start)
        while index < line.endIndex {
            let character = line[index]
            if escaping, character == "\\" {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            index = line.index(after: index)
            if character == quote { return index }
        }
        return line.endIndex
    }

    private static func matches(_ token: String, in line: String, at index: String.Index) -> Bool {
        guard let end = line.index(index, offsetBy: token.count, limitedBy: line.endIndex) else {
            return false
        }
        return line[index..<end] == token
    }

    private static func range(of token: String, in line: String, from start: String.Index) -> Range<String.Index>? {
        line.range(of: token, range: start..<line.endIndex)
    }
}
