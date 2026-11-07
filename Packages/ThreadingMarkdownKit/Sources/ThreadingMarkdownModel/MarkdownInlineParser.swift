import Foundation

// MARK: - Inline Parser

/// Reads the inline runs of one line: `**strong**`, `*emphasis*`, `***both***`, `~~struck~~`,
/// `` `code` `` and `[label](url)`. The rules are the Mac conversation's scanner's
/// (`ThreadingMarkdownKit`): code spans first, so a `*` inside backticks is never emphasis;
/// CommonMark's flanking rules, so `2 * 3` and `snake_case` stay as written; and an unmatched
/// delimiter is the character itself rather than eating the rest of the line.
enum MarkdownInlineParser {

    static func parse(_ text: String) -> [MarkdownInline] {
        parse(Array(text), depth: 0)
    }

    private static func parse(_ characters: [Character], depth: Int) -> [MarkdownInline] {
        // Agent text is untrusted input: past the nesting ceiling the rest is literal.
        guard depth < MarkdownModelLimits.maximumInlineNestingDepth else {
            return characters.isEmpty ? [] : [.text(String(characters))]
        }
        var scanner = Scanner(characters: characters)
        var runs: [MarkdownInline] = []
        while let token = scanner.next() {
            switch token {
            case .text(let text):
                if case .text(let previous)? = runs.last {
                    runs[runs.count - 1] = .text(previous + text)
                } else {
                    runs.append(.text(text))
                }
            case .code(let code):
                runs.append(.code(code))
            case .strong(let inner):
                runs.append(.strong(parse(inner, depth: depth + 1)))
            case .emphasis(let inner):
                runs.append(.emphasis(parse(inner, depth: depth + 1)))
            case .strongEmphasis(let inner):
                runs.append(.strong([.emphasis(parse(inner, depth: depth + 1))]))
            case .strikethrough(let inner):
                runs.append(.strikethrough(parse(inner, depth: depth + 1)))
            case .link(let label, let url):
                runs.append(.link(label: parse(label, depth: depth + 1), url: url))
            }
        }
        return runs
    }

    // MARK: - Scanner

    private struct Scanner {
        enum Token {
            case text(String)
            case code(String)
            case strong([Character])
            case emphasis([Character])
            case strongEmphasis([Character])
            case strikethrough([Character])
            case link(label: [Character], url: String)
        }

        let characters: [Character]
        var index = 0

        init(characters: [Character]) {
            self.characters = characters
        }

        mutating func next() -> Token? {
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "`":
                if let code = codeSpan() { return .code(code) }
            case "*", "_":
                let marker = characters[index]
                let run = runLength(at: index, of: marker)
                if run == 3, let inner = emphasis(marker, width: 3) { return .strongEmphasis(inner) }
                if run >= 2, let inner = emphasis(marker, width: 2) { return .strong(inner) }
                if let inner = emphasis(marker, width: 1) { return .emphasis(inner) }
            case "~":
                if runLength(at: index, of: "~") == 2, let inner = emphasis("~", width: 2) {
                    return .strikethrough(inner)
                }
            case "[":
                if let link = link() { return link }
            default:
                break
            }
            return .text(plainRun())
        }

        /// `` `code` `` and ``` ``code with a ` inside`` ```: the closing run matches the opening.
        private mutating func codeSpan() -> String? {
            let width = runLength(at: index, of: "`")
            var cursor = index + width
            while cursor < characters.count {
                if characters[cursor] == "`" {
                    let closing = runLength(at: cursor, of: "`")
                    if closing == width {
                        var content = String(characters[(index + width)..<cursor])
                        // One space either side lets a span begin or end with a backtick.
                        if content.count >= 2, content.first == " ", content.last == " ",
                           content.contains(where: { $0 != " " }) {
                            content = String(content.dropFirst().dropLast())
                        }
                        guard !content.isEmpty else { return nil }
                        index = cursor + width
                        return content
                    }
                    cursor += closing
                } else {
                    cursor += 1
                }
            }
            return nil
        }

        /// A flanking run of `width` markers to a matching closing run on the same line. Code
        /// spans and links inside are skipped whole, so their characters cannot close it.
        private mutating func emphasis(_ marker: Character, width: Int) -> [Character]? {
            let opening = runLength(at: index, of: marker)
            guard opening >= width, canOpen(at: index, marker: marker, run: opening),
                  index + width < characters.count else { return nil }
            var cursor = index + width
            while cursor < characters.count {
                if characters[cursor] == "`", let close = characters[(cursor + 1)...].firstIndex(of: "`") {
                    cursor = close + 1
                    continue
                }
                if characters[cursor] == "[", let end = linkEnd(from: cursor) {
                    cursor = end
                    continue
                }
                guard characters[cursor] == marker else {
                    cursor += 1
                    continue
                }
                let closing = runLength(at: cursor, of: marker)
                let fits = width == 1 ? closing == 1 : closing >= width
                if fits, canClose(at: cursor, marker: marker, run: closing) {
                    let inner = Array(characters[(index + width)..<cursor])
                    guard !inner.isEmpty else { return nil }
                    index = cursor + width
                    return inner
                }
                cursor += closing
            }
            return nil
        }

        private func runLength(at start: Int, of marker: Character) -> Int {
            var cursor = start
            while cursor < characters.count, characters[cursor] == marker { cursor += 1 }
            return cursor - start
        }

        /// CommonMark's left- and right-flanking rules, with the intraword guard for `_`.
        private func flanking(at start: Int, run: Int) -> (left: Bool, right: Bool, before: Character?, after: Character?) {
            let before = start > 0 ? characters[start - 1] : nil
            let after = start + run < characters.count ? characters[start + run] : nil
            let left = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
            let right = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
            return (left, right, before, after)
        }

        private func canOpen(at start: Int, marker: Character, run: Int) -> Bool {
            let side = flanking(at: start, run: run)
            return marker == "_" ? side.left && (!side.right || isPunctuation(side.before)) : side.left
        }

        private func canClose(at start: Int, marker: Character, run: Int) -> Bool {
            let side = flanking(at: start, run: run)
            return marker == "_" ? side.right && (!side.left || isPunctuation(side.after)) : side.right
        }

        private func isWhitespace(_ character: Character?) -> Bool {
            guard let character else { return true }
            return character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
        }

        private func isPunctuation(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.unicodeScalars.contains { scalar in
                switch scalar.properties.generalCategory {
                case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                     .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol,
                     .currencySymbol, .modifierSymbol, .otherSymbol:
                    return true
                default:
                    return false
                }
            }
        }

        /// `[label](url)` with both brackets closing on the line.
        private mutating func link() -> Token? {
            guard let closeBracket = characters[index...].firstIndex(of: "]"),
                  closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(",
                  let closeParen = characters[(closeBracket + 1)...].firstIndex(of: ")") else { return nil }
            let label = Array(characters[(index + 1)..<closeBracket])
            let url = String(characters[(closeBracket + 2)..<closeParen])
            guard !label.isEmpty else { return nil }
            index = closeParen + 1
            return .link(label: label, url: url)
        }

        private func linkEnd(from start: Int) -> Int? {
            guard let closeBracket = characters[start...].firstIndex(of: "]"),
                  closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(",
                  let closeParen = characters[(closeBracket + 1)...].firstIndex(of: ")") else { return nil }
            return closeParen + 1
        }

        /// Plain text up to the next character that could begin markup; always at least one.
        private mutating func plainRun() -> String {
            let start = index
            index += 1
            while index < characters.count, !"`*_[~".contains(characters[index]) {
                index += 1
            }
            return String(characters[start..<index])
        }
    }
}
