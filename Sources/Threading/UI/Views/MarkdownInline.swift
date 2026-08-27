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

        var scanner = InlineScanner(text: Array(text))

        while let token = scanner.next() {
            switch token {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: baseFont,
                    .foregroundColor: style.textColor
                ]))

            case .code(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: style.codeFont,
                    .foregroundColor: style.codeColor,
                    .backgroundColor: style.codeBackground
                ]))

            case .strong(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: bold(baseFont),
                    .foregroundColor: style.textColor
                ]))

            case .emphasis(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: italic(baseFont),
                    .foregroundColor: style.textColor
                ]))

            case .link(let label, let url):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: style.textColor
                ]
                // Assistant Markdown is untrusted document content. AppKit opens a `.link`
                // attribute through the system handler, so file:, custom-app and executable
                // schemes must never become actions merely because an agent wrote them.
                if let link = clickableLinkURL(url) {
                    attributes[.foregroundColor] = style.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.link] = link
                }
                result.append(NSAttributedString(string: label, attributes: attributes))
            }
        }

        return result
    }

    private static func clickableLinkURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
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
            if let strong = fenced(by: "\(marker)\(marker)") { return .strong(strong) }
            if let emphasis = delimited(by: marker) { return .emphasis(emphasis) }

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

    /// A run between two two-character fences, e.g. `**bold**`. Consumes both.
    private mutating func fenced(by fence: String) -> String? {
        let markers = Array(fence)
        guard index + markers.count < characters.count else { return nil }

        var cursor = index + markers.count
        while cursor + markers.count <= characters.count {
            if Array(characters[cursor..<(cursor + markers.count)]) == markers {
                let content = String(characters[(index + markers.count)..<cursor])
                guard !content.isEmpty else { return nil }
                index = cursor + markers.count
                return content
            }
            cursor += 1
        }
        return nil
    }

    /// `[label](url)`. Both brackets must close on the same line to count.
    private mutating func link() -> InlineScanner.Token? {
        guard let closeBracket = characters[index...].firstIndex(of: "]"),
              closeBracket + 1 < characters.count,
              characters[closeBracket + 1] == "(",
              let closeParen = characters[(closeBracket + 1)...].firstIndex(of: ")") else { return nil }

        let label = String(characters[(index + 1)..<closeBracket])
        let url = String(characters[(closeBracket + 2)..<closeParen])
        index = closeParen + 1
        return .link(label: label, url: url)
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
}
