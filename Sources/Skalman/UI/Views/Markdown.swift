import AppKit

// MARK: - Markdown Style

/// The fonts and colours a rendered document draws with.
///
/// Passed in rather than read from `Design` directly, so the same renderer can draw an
/// assistant message in full colour and a quieter thing — a quoted reply, a tool note — by
/// handing it a dimmer palette.
struct MarkdownStyle {
    var font: NSFont
    var textColor: NSColor
    var secondaryColor: NSColor
    var codeFont: NSFont
    var codeColor: NSColor
    var codeBackground: NSColor
    var linkColor: NSColor

    static var assistant: MarkdownStyle {
        MarkdownStyle(
            font: Design.Typography.body(),
            textColor: Design.Text.label,
            secondaryColor: Design.Text.secondary,
            codeFont: .monospacedSystemFont(ofSize: MarkdownDefaults.codeFontSize, weight: .regular),
            codeColor: Design.Text.label,
            codeBackground: Design.Surface.panel,
            linkColor: Design.Surface.accent
        )
    }
}

// MARK: - Markdown Block

/// One block of a document. Blocks stack vertically; a code block draws on its own surface,
/// which is why the model is blocks rather than a single attributed string.
enum MarkdownBlock {
    case paragraph(NSAttributedString)
    case heading(NSAttributedString)
    case bullets([NSAttributedString])
    case ordered([NSAttributedString])
    case code(String)
    case quote(NSAttributedString)
}

// MARK: - Markdown

/// A small CommonMark subset — enough to make an assistant reply read as written rather than
/// as a wall of asterisks. Deliberately not a full parser: no tables, no nested lists, no
/// reference links. What it does cover is what a coding agent actually emits — headings,
/// paragraphs, fenced code, simple lists, inline emphasis and code spans.
///
/// Written by hand rather than pulled in, because the project depends only on SwiftTerm and a
/// hundred lines of well-understood scanning is cheaper to own than a package to track.
enum Markdown {

    /// Reads one block starting at `index`, returning it and the line after it — or nil if the
    /// line does not begin this kind of block, so the next reader gets a turn.
    private typealias Reader = (_ lines: [String], _ index: Int, _ style: MarkdownStyle)
        -> (MarkdownBlock, Int)?

    /// Ordered by precedence: a `> - item` is a quote, not a list, because quote reads first.
    private static let readers: [Reader] = [readFence, readHeading, readQuote, readBullets, readOrdered]

    /// Splits a document into blocks, styling the inline runs within each.
    static func parse(_ text: String, style: MarkdownStyle) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let (block, next) = firstMatch(lines, index, style) {
                blocks.append(block)
                index = next
            } else {
                let (block, next) = readParagraph(lines, index, style)
                blocks.append(block)
                index = next
            }
        }

        return blocks
    }

    private static func firstMatch(
        _ lines: [String],
        _ index: Int,
        _ style: MarkdownStyle
    ) -> (MarkdownBlock, Int)? {
        for reader in readers {
            if let result = reader(lines, index, style) { return result }
        }
        return nil
    }

    // MARK: - Block Readers

    /// Fenced code runs verbatim to the closing fence, so inline styling never touches it — a
    /// `*` in a shell glob is not emphasis.
    private static func readFence(_ lines: [String], _ index: Int, _ style: MarkdownStyle) -> (MarkdownBlock, Int)? {
        guard trimmed(lines, index).hasPrefix("```") else { return nil }

        var code: [String] = []
        var cursor = index + 1
        while cursor < lines.count, !trimmed(lines, cursor).hasPrefix("```") {
            code.append(lines[cursor])
            cursor += 1
        }
        return (.code(code.joined(separator: "\n")), cursor + 1)
    }

    private static func readHeading(_ lines: [String], _ index: Int, _ style: MarkdownStyle) -> (MarkdownBlock, Int)? {
        let line = trimmed(lines, index)
        guard let level = headingLevel(line) else { return nil }
        return (.heading(inline(String(line.dropFirst(level + 1)), style: style, heading: true)), index + 1)
    }

    private static func readQuote(_ lines: [String], _ index: Int, _ style: MarkdownStyle) -> (MarkdownBlock, Int)? {
        guard trimmed(lines, index).hasPrefix("> ") else { return nil }

        var quote: [String] = []
        var cursor = index
        while cursor < lines.count, trimmed(lines, cursor).hasPrefix("> ") {
            quote.append(String(trimmed(lines, cursor).dropFirst(2)))
            cursor += 1
        }
        return (.quote(inline(quote.joined(separator: " "), style: style)), cursor)
    }

    private static func readBullets(_ lines: [String], _ index: Int, _ style: MarkdownStyle) -> (MarkdownBlock, Int)? {
        guard isBullet(trimmed(lines, index)) else { return nil }

        var items: [NSAttributedString] = []
        var cursor = index
        while cursor < lines.count, isBullet(trimmed(lines, cursor)) {
            items.append(inline(String(trimmed(lines, cursor).dropFirst(2)), style: style))
            cursor += 1
        }
        return (.bullets(items), cursor)
    }

    private static func readOrdered(_ lines: [String], _ index: Int, _ style: MarkdownStyle) -> (MarkdownBlock, Int)? {
        guard orderedContent(trimmed(lines, index)) != nil else { return nil }

        var items: [NSAttributedString] = []
        var cursor = index
        while cursor < lines.count, let rest = orderedContent(trimmed(lines, cursor)) {
            items.append(inline(rest, style: style))
            cursor += 1
        }
        return (.ordered(items), cursor)
    }

    /// A paragraph runs until a blank line or a line that begins some other block.
    private static func readParagraph(
        _ lines: [String],
        _ index: Int,
        _ style: MarkdownStyle
    ) -> (MarkdownBlock, Int) {
        var paragraph: [String] = []
        var cursor = index
        while cursor < lines.count {
            let line = trimmed(lines, cursor)
            if line.isEmpty || startsBlock(line) { break }
            paragraph.append(line)
            cursor += 1
        }
        return (.paragraph(inline(paragraph.joined(separator: " "), style: style)), cursor)
    }

    // MARK: - Block Recognition

    private static func trimmed(_ lines: [String], _ index: Int) -> String {
        lines[index].trimmingCharacters(in: .whitespaces)
    }

    /// Whether a line begins a block other than a paragraph, which is where a paragraph ends.
    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || headingLevel(line) != nil || line.hasPrefix("> ")
            || isBullet(line) || orderedContent(line) != nil
    }

    private static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return level
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// The text of an ordered-list item (`1. thing` → `thing`), or nil if the line is not one.
    private static func orderedContent(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }

        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        return String(afterDigits.dropFirst(2))
    }
}
