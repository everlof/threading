import Foundation

// MARK: - Markdown Document

/// A Markdown text as plain values: blocks that stack, and the inline runs inside them.
///
/// The subset is what an agent's terminal output uses — headings, paragraphs, lists, quotes,
/// fenced code, GitHub pipe tables, rules, and inline strong, emphasis, strikethrough, code and
/// links — so a question or a message reads as clearly on a phone or a web page as in a TUI. It
/// holds no fonts, colours or views: the iPhone draws it in SwiftUI and the workroom portal as
/// HTML (`MarkdownHTML`), each in its own style, from one reading of the text.
///
/// The block rules are `ThreadingMarkdownKit`'s, which the Mac's conversation renders with; the
/// one difference is that a line break inside a paragraph is kept, because a question to a
/// person is laid out by its author the way a terminal shows it, not reflowed.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlockNode]

    public init(blocks: [MarkdownBlockNode]) {
        self.blocks = blocks
    }

    /// Reads `text`. Never fails: what is not Markdown is a paragraph, and an unclosed delimiter
    /// is the character itself.
    public init(parsing text: String) {
        self = MarkdownParser.parse(text)
    }

    /// The words without their markup, block by block, for an accessibility label or a preview.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

/// One block of a document. Blocks stack vertically.
public enum MarkdownBlockNode: Equatable, Sendable {
    case paragraph([MarkdownInline])
    /// `level` is 1 to 6, as the number of `#` that began it.
    case heading(level: Int, [MarkdownInline])
    case bullets([[MarkdownInline]])
    /// `start` is the first item's own number, so a list resumed after a paragraph keeps counting.
    case ordered(start: Int, [[MarkdownInline]])
    case quote([MarkdownInline])
    /// Verbatim: inline syntax inside a fence is never interpreted. `language` is the fence's
    /// info word, empty when there is none.
    case code(language: String, text: String)
    case table(MarkdownTableNode)
    /// `---`, `***` or `___` alone on a line.
    case rule

    public var plainText: String {
        switch self {
        case .paragraph(let runs), .heading(_, let runs), .quote(let runs):
            return MarkdownInline.plainText(runs)
        case .bullets(let items), .ordered(_, let items):
            return items.map(MarkdownInline.plainText).joined(separator: "\n")
        case .code(_, let text):
            return text
        case .table(let table):
            return ([table.headers] + table.rows)
                .map { $0.map(MarkdownInline.plainText).joined(separator: "\t") }
                .joined(separator: "\n")
        case .rule:
            return ""
        }
    }
}

/// A run of inline text and what it is: the words, or a styled span that holds more runs.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    /// `url` is as written. A renderer makes it a link only when `MarkdownLinkPolicy` allows the
    /// URL; otherwise the label stands as text.
    case link(label: [MarkdownInline], url: String)
    /// A line break the author wrote inside a paragraph, quote or list item.
    case lineBreak

    public static func plainText(_ runs: [MarkdownInline]) -> String {
        runs.map { run in
            switch run {
            case .text(let text), .code(let text): return text
            case .strong(let inner), .emphasis(let inner), .strikethrough(let inner): return plainText(inner)
            case .link(let label, _): return plainText(label)
            case .lineBreak: return "\n"
            }
        }.joined()
    }
}

/// A GitHub pipe table. Every row has exactly as many cells as the header: a short row is padded
/// with empty cells, and a long one's extra cells are joined into its last.
public struct MarkdownTableNode: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public var headers: [[MarkdownInline]]
    public var alignments: [Alignment]
    public var rows: [[[MarkdownInline]]]

    public init(headers: [[MarkdownInline]], alignments: [Alignment], rows: [[[MarkdownInline]]]) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }
}

// MARK: - Links

/// Which written URLs become links. Markdown from an agent is untrusted content shown to a
/// person: `file:`, custom-app and script schemes never become something to tap, whatever the
/// label says. The same rule as the Mac's conversation (`MarkdownExternalURLPolicy`).
public enum MarkdownLinkPolicy {
    public static func webURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// MARK: - Limits

public enum MarkdownModelLimits {
    /// Inline spans nest no deeper than this; past it, the remaining syntax is literal text. The
    /// Mac's conversation keeps the same ceiling.
    public static let maximumInlineNestingDepth = 32
    /// Text past this many bytes is not read. Generous for anything a workroom carries — a
    /// question's prompt is 4 KiB, its background 8 KiB — and a bound on the work for anything else.
    public static let maximumSourceBytes = 256 * 1_024
}
