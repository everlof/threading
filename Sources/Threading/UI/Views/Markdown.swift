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
    /// The surface `font` was resolved in, carried so a font the renderer *derives* — the
    /// heading, which scales from the body through `Typography` — resolves in the same surface.
    /// Without it a `# Heading` re-entered the four layers as chrome and could come back in a
    /// different family than its own paragraph.
    var fontSurface: Design.Typography.FontSurface = .chrome

    /// The agent's prose, and the one place the conversation's own font is chosen for it.
    ///
    /// `.conversation` rather than `.chrome`: this is the transcript, which the reader may want
    /// set differently from the app around it — the same say the terminal has always had through
    /// `TerminalProfile`. `codeFont` stays code, here as everywhere.
    @MainActor
    static var assistant: MarkdownStyle {
        MarkdownStyle(
            font: Design.Typography.body(surface: .conversation),
            textColor: Design.Text.label,
            secondaryColor: Design.Text.secondary,
            codeFont: Design.Typography.inlineCode(),
            codeColor: Design.Text.label,
            codeBackground: Design.Surface.panel,
            linkColor: Design.Surface.accent,
            fontSurface: .conversation
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
    case table(MarkdownTable)
}

struct MarkdownTable {
    let headers: [NSAttributedString]
    let alignments: [NSTextAlignment]
    let rows: [[NSAttributedString]]
}

// MARK: - Markdown

/// A small CommonMark subset — enough to make an assistant reply read as written rather than
/// as a wall of asterisks. Deliberately not a full parser: no nested lists or reference links.
/// What it does cover is what a coding agent actually emits — headings, paragraphs, fenced
/// code, simple lists, GFM pipe tables, inline emphasis and code spans.
///
/// Written by hand rather than pulled in, because the project depends only on SwiftTerm and a
/// hundred lines of well-understood scanning is cheaper to own than a package to track.
@MainActor
enum Markdown {

    /// Reads one block starting at `index`, returning it and the line after it — or nil if the
    /// line does not begin this kind of block, so the next reader gets a turn.
    private typealias Reader = @MainActor (_ lines: [String], _ index: Int, _ style: MarkdownStyle)
        -> (MarkdownBlock, Int)?

    /// Ordered by precedence: a `> - item` is a quote, not a list, because quote reads first.
    private static let readers: [Reader] = [
        readFence,
        readTable,
        readHeading,
        readQuote,
        readBullets,
        readOrdered
    ]

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

    /// Splits a document at the same block boundaries as `parse` without constructing fonts,
    /// attributed strings, or views for content outside the viewport. Virtualized transcripts
    /// keep these small source values as their presentation model and style a block only when
    /// AppKit asks for its row.
    static func sourceBlocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var index = 0

        while index < lines.count {
            if trimmed(lines, index).isEmpty {
                index += 1
                continue
            }

            let end = sourceBlockEnd(lines, index)
            // Every non-empty line should be either a recognized block or a paragraph. Keep a
            // recovery path anyway: this parser consumes provider text, and a future reader bug
            // must render one line plainly rather than terminate the app.
            guard end > index else {
                blocks.append(lines[index])
                index += 1
                continue
            }
            blocks.append(lines[index..<end].joined(separator: "\n"))
            index = end
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

    /// The structural half of the reader table. Keep this in the same type as `parse`: adding a
    /// new Markdown block means its source boundary and styled reader must change together.
    private static func sourceBlockEnd(_ lines: [String], _ index: Int) -> Int {
        let line = trimmed(lines, index)

        if line.hasPrefix("```") {
            var cursor = index + 1
            while cursor < lines.count, !trimmed(lines, cursor).hasPrefix("```") {
                cursor += 1
            }
            return min(cursor + 1, lines.count)
        }

        if isTableStart(lines, index) {
            var cursor = index + 2
            while cursor < lines.count, tableCells(lines[cursor]) != nil {
                cursor += 1
            }
            return cursor
        }

        if headingLevel(line) != nil { return index + 1 }

        if line.hasPrefix("> ") {
            var cursor = index + 1
            while cursor < lines.count, trimmed(lines, cursor).hasPrefix("> ") {
                cursor += 1
            }
            return cursor
        }

        if isBullet(line) {
            var cursor = index + 1
            while cursor < lines.count, isBullet(trimmed(lines, cursor)) {
                cursor += 1
            }
            return cursor
        }

        if orderedContent(line) != nil {
            var cursor = index + 1
            while cursor < lines.count, orderedContent(trimmed(lines, cursor)) != nil {
                cursor += 1
            }
            return cursor
        }

        var cursor = index + 1
        while cursor < lines.count {
            let next = trimmed(lines, cursor)
            if next.isEmpty || startsBlock(next) || isTableStart(lines, cursor) { break }
            cursor += 1
        }
        return cursor
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

    /// GitHub-flavoured pipe tables are common in audit replies. Their separator row is the
    /// unambiguous signal; a prose sentence containing `|` remains an ordinary paragraph.
    private static func readTable(
        _ lines: [String],
        _ index: Int,
        _ style: MarkdownStyle
    ) -> (MarkdownBlock, Int)? {
        guard index + 1 < lines.count,
              let headerCells = tableCells(lines[index]),
              let delimiterCells = tableCells(lines[index + 1]),
              headerCells.count == delimiterCells.count else { return nil }

        let alignments = delimiterCells.compactMap(tableAlignment)
        guard alignments.count == delimiterCells.count else { return nil }

        var body: [[NSAttributedString]] = []
        var cursor = index + 2
        while cursor < lines.count, let cells = tableCells(lines[cursor]) {
            var normalized = cells
            if normalized.count < headerCells.count {
                normalized.append(contentsOf: repeatElement(
                    "",
                    count: headerCells.count - normalized.count
                ))
            } else if normalized.count > headerCells.count {
                let overflow = normalized.dropFirst(headerCells.count - 1).joined(separator: " | ")
                normalized = Array(normalized.prefix(headerCells.count - 1)) + [overflow]
            }
            body.append(normalized.map { inline($0, style: style) })
            cursor += 1
        }

        return (
            .table(MarkdownTable(
                headers: headerCells.map { inline($0, style: style) },
                alignments: alignments,
                rows: body
            )),
            cursor
        )
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
            if line.isEmpty || startsBlock(line) || isTableStart(lines, cursor) { break }
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

    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count,
              let headers = tableCells(lines[index]),
              let delimiters = tableCells(lines[index + 1]),
              headers.count == delimiters.count else { return false }
        return delimiters.allSatisfy { tableAlignment($0) != nil }
    }

    /// Splits on unescaped pipes outside inline-code spans. Leading and trailing pipes are
    /// optional in GFM and do not create empty columns.
    private static func tableCells(_ line: String) -> [String]? {
        let source = Array(line.trimmingCharacters(in: .whitespaces))
        guard source.contains("|") else { return nil }

        var cells: [String] = []
        var cell = ""
        var index = 0
        var isCode = false

        while index < source.count {
            let character = source[index]
            if character == "\\", index + 1 < source.count, source[index + 1] == "|" {
                cell.append("|")
                index += 2
                continue
            }
            if character == "`" {
                isCode.toggle()
                cell.append(character)
            } else if character == "|", !isCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if source.first == "|" { cells.removeFirst() }
        if source.last == "|" { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func tableAlignment(_ cell: String) -> NSTextAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let isLeftMarked = trimmed.first == ":"
        let isRightMarked = trimmed.last == ":"
        let rule = trimmed.dropFirst(isLeftMarked ? 1 : 0)
            .dropLast(isRightMarked ? 1 : 0)
        guard rule.count >= 3, rule.allSatisfy({ $0 == "-" }) else { return nil }

        if isLeftMarked, isRightMarked { return .center }
        if isRightMarked { return .right }
        return .left
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
