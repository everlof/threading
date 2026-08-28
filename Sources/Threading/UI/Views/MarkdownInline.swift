import AppKit

// MARK: - Inline Styling

extension Markdown {

    /// Styles the inline runs within one block of text: `**bold**`, `*italic*`, `` `code` ``
    /// and `[label](url)`. Unmatched delimiters render as themselves rather than eating the
    /// rest of the line — half-typed emphasis is common while a message is still streaming.
    static func inline(_ text: String, style: MarkdownStyle, heading: Bool = false) -> NSAttributedString {
        let baseFont = heading ? headingFont(style) : style.font
        // Most assistant prose has no inline syntax. Avoid allocating a grapheme array, a
        // scanner and a mutable attributed string merely to append one plain run. UTF-8
        // continuation bytes cannot alias these ASCII markers, so the byte check is both
        // Unicode-safe and substantially cheaper than materializing `[Character]`.
        let containsMarkupCandidate = text.utf8.contains { byte in
            byte == 0x60 || byte == 0x2A || byte == 0x5F || byte == 0x5B
        }
        if !containsMarkupCandidate {
            return NSAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: style.textColor
            ])
        }

        let result = NSMutableAttributedString()
        appendInline(
            text,
            to: result,
            style: style,
            baseFont: baseFont,
            traits: InlineFontTraits(),
            depth: 0
        )
        return result
    }

    /// Recurses only inside emphasis. Blocks stay deliberately small, while inline containers
    /// can carry the code spans and links coding agents routinely put inside a highlighted run.
    private static func appendInline(
        _ text: String,
        to result: NSMutableAttributedString,
        style: MarkdownStyle,
        baseFont: NSFont,
        traits: InlineFontTraits,
        depth: Int
    ) {
        // Transcript text is provider input. Preserve ordinary nesting while bounding both the
        // call stack and the repeated Character arrays a deliberately pathological line could
        // otherwise force. At the ceiling the remaining syntax is honest literal text.
        guard depth < MarkdownDefaults.maximumInlineNestingDepth else {
            result.append(NSAttributedString(string: text, attributes: [
                .font: applying(traits, to: baseFont),
                .foregroundColor: style.textColor
            ]))
            return
        }

        var scanner = InlineScanner(text: Array(text))
        while let token = scanner.next() {
            switch token {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: applying(traits, to: baseFont),
                    .foregroundColor: style.textColor
                ]))

            case .code(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: applying(traits, to: style.codeFont),
                    .foregroundColor: style.codeColor,
                    .backgroundColor: style.codeBackground
                ]))

            case .strong(let value):
                appendInline(
                    value,
                    to: result,
                    style: style,
                    baseFont: baseFont,
                    traits: traits.adding(bold: true),
                    depth: depth + 1
                )

            case .emphasis(let value):
                appendInline(
                    value,
                    to: result,
                    style: style,
                    baseFont: baseFont,
                    traits: traits.adding(italic: true),
                    depth: depth + 1
                )

            case .strongEmphasis(let value):
                appendInline(
                    value,
                    to: result,
                    style: style,
                    baseFont: baseFont,
                    traits: traits.adding(bold: true, italic: true),
                    depth: depth + 1
                )

            case .link(let label, let url):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: applying(traits, to: baseFont),
                    .foregroundColor: style.textColor
                ]
                // Assistant Markdown is untrusted document content. AppKit opens a `.link`
                // attribute through the system handler, so file:, custom-app and executable
                // schemes must never become actions merely because an agent wrote them.
                if let link = AgentAuthoredURLPolicy.externalWebURL(url) {
                    attributes[.foregroundColor] = style.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.link] = link
                }
                result.append(NSAttributedString(string: label, attributes: attributes))
            }
        }
    }

    // MARK: - Font Variants

    /// In the style's own surface: the heading re-enters the four resolution layers, and asking
    /// as chrome from inside a conversation-styled document could answer in a different family
    /// than the paragraph under it.
    private static func headingFont(_ style: MarkdownStyle) -> NSFont {
        Design.Typography.markdownHeading(from: style.font, surface: style.fontSurface)
    }

    private static func bold(_ base: NSFont) -> NSFont {
        NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    private static func italic(_ base: NSFont) -> NSFont {
        NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private static func applying(_ traits: InlineFontTraits, to base: NSFont) -> NSFont {
        var font = base
        if traits.bold { font = bold(font) }
        if traits.italic { font = italic(font) }
        return font
    }
}

private struct InlineFontTraits {
    var bold = false
    var italic = false

    func adding(bold: Bool = false, italic: Bool = false) -> InlineFontTraits {
        InlineFontTraits(bold: self.bold || bold, italic: self.italic || italic)
    }
}

// MARK: - Inline Scanner

/// Walks a line once, emitting styled runs. Code spans are recognised first, so a `*` inside
/// backticks is never mistaken for emphasis.
private struct InlineScanner {
    enum Token {
        case text(String)
        case code(String)
        case strong(String)
        case emphasis(String)
        case strongEmphasis(String)
        case link(label: String, url: String)
    }

    private let characters: [Character]
    private var index = 0

    init(text: [Character]) {
        self.characters = text
    }

    mutating func next() -> Token? {
        guard index < characters.count else { return nil }

        switch characters[index] {
        case "`":
            if let span = delimited(by: "`") { return .code(span) }

        case "*", "_":
            let marker = characters[index]
            let runLength = delimiterRunLength(at: index, marker: marker)
            if runLength == 3,
               let combined = emphasis(by: marker, width: 3) {
                return .strongEmphasis(combined)
            }
            if runLength >= 2,
               let strong = emphasis(by: marker, width: 2) {
                return .strong(strong)
            }
            if let emphasis = emphasis(by: marker, width: 1) {
                return .emphasis(emphasis)
            }

        case "[":
            if let link = link() { return link }

        default:
            break
        }

        // No markup started here, so gather plain text up to the next character that might.
        return .text(plainRun())
    }

    // MARK: - Recognisers

    /// A run between two single-character delimiters, e.g. `` `code` ``. Consumes both.
    private mutating func delimited(by marker: Character) -> String? {
        guard index + 1 < characters.count,
              let close = characters[(index + 1)...].firstIndex(of: marker) else { return nil }

        let content = String(characters[(index + 1)..<close])
        guard !content.isEmpty else { return nil }

        index = close + 1
        return content
    }

    /// A flanking emphasis run. `_` inside an identifier and `*` surrounded by arithmetic
    /// spaces are ordinary characters; a delimiter must face content on the side it opens or
    /// closes. Runs of a different width are skipped so `*italic **bold** italic*` can recurse
    /// without the inner strong opener prematurely closing the outer run.
    private mutating func emphasis(by marker: Character, width: Int) -> String? {
        let openingRun = delimiterRunLength(at: index, marker: marker)
        guard openingRun >= width,
              canOpenDelimiter(at: index, marker: marker, runLength: openingRun),
              index + width < characters.count else { return nil }

        var cursor = index + width
        while cursor < characters.count {
            if characters[cursor] == "`",
               let closeCode = characters[(cursor + 1)...].firstIndex(of: "`") {
                cursor = closeCode + 1
                continue
            }

            if characters[cursor] == "[", let end = linkEnd(startingAt: cursor) {
                cursor = end
                continue
            }

            guard characters[cursor] == marker else {
                cursor += 1
                continue
            }

            let closingRun = delimiterRunLength(at: cursor, marker: marker)
            let matchesWidth = width == 1 ? closingRun == 1 : closingRun >= width
            if matchesWidth,
               canCloseDelimiter(at: cursor, marker: marker, runLength: closingRun) {
                let content = String(characters[(index + width)..<cursor])
                guard !content.isEmpty else { return nil }
                index = cursor + width
                return content
            }
            cursor += closingRun
        }
        return nil
    }

    private func delimiterRunLength(at start: Int, marker: Character) -> Int {
        var cursor = start
        while cursor < characters.count, characters[cursor] == marker {
            cursor += 1
        }
        return cursor - start
    }

    /// CommonMark's left/right-flanking rules, including the extra intraword guard for `_`.
    private func canOpenDelimiter(at start: Int, marker: Character, runLength: Int) -> Bool {
        let before = start > 0 ? characters[start - 1] : nil
        let afterIndex = start + runLength
        let after = afterIndex < characters.count ? characters[afterIndex] : nil
        let leftFlanking = !isWhitespace(after)
            && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
        let rightFlanking = !isWhitespace(before)
            && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        return marker == "_"
            ? leftFlanking && (!rightFlanking || isPunctuation(before))
            : leftFlanking
    }

    private func canCloseDelimiter(at start: Int, marker: Character, runLength: Int) -> Bool {
        let before = start > 0 ? characters[start - 1] : nil
        let afterIndex = start + runLength
        let after = afterIndex < characters.count ? characters[afterIndex] : nil
        let leftFlanking = !isWhitespace(after)
            && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
        let rightFlanking = !isWhitespace(before)
            && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        return marker == "_"
            ? rightFlanking && (!leftFlanking || isPunctuation(after))
            : rightFlanking
    }

    /// A line boundary behaves like whitespace in the delimiter rules.
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
                true
            default:
                false
            }
        }
    }

    /// `[label](url)`. Both brackets must close on the same line to count.
    private mutating func link() -> InlineScanner.Token? {
        guard let closeBracket = characters[index...].firstIndex(of: "]"),
              closeBracket + 1 < characters.count,
              characters[closeBracket + 1] == "(",
              let closeParen = characters[(closeBracket + 1)...].firstIndex(of: ")") else {
            return nil
        }

        let label = String(characters[(index + 1)..<closeBracket])
        let url = String(characters[(closeBracket + 2)..<closeParen])
        index = closeParen + 1
        return .link(label: label, url: url)
    }

    private func linkEnd(startingAt start: Int) -> Int? {
        guard let closeBracket = characters[start...].firstIndex(of: "]"),
              closeBracket + 1 < characters.count,
              characters[closeBracket + 1] == "(",
              let closeParen = characters[(closeBracket + 1)...].firstIndex(of: ")") else {
            return nil
        }
        return closeParen + 1
    }

    /// Plain text up to the next character that could begin markup.
    private mutating func plainRun() -> String {
        let start = index
        index += 1  // always consume at least the character we are on

        while index < characters.count {
            switch characters[index] {
            case "`", "*", "_", "[":
                return String(characters[start..<index])
            default:
                index += 1
            }
        }
        return String(characters[start..<index])
    }
}

// MARK: - Markdown Defaults

enum MarkdownDefaults {
    static let codeFontSize: CGFloat = 12
    static let headingBump: CGFloat = 3
    static let codePadding: CGFloat = 8
    static let listIndent: CGFloat = 18
    static let blockSpacing: CGFloat = 6
    static let quoteBarWidth: CGFloat = 2
    static let tableColumnWidth: CGFloat = 180

    /// AppKit work a single markdown surface may materialize at once. The source document stays
    /// complete and the pager reaches every block; these are view/constraint budgets, not content
    /// truncation limits.
    static let maximumBlocksPerPage = 48
    static let maximumSourceLinesPerPage = 96
    static let maximumListItemsPerPage = 64
    static let maximumTableRowsPerPage = 48
    static let maximumTableColumnsPerPage = 8
    /// Recursion and repeated grapheme materialization allowed within one provider-authored line.
    static let maximumInlineNestingDepth = 32
}
