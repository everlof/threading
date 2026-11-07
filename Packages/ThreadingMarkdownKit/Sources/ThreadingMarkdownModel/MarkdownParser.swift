import Foundation

// MARK: - Markdown Parser

/// Reads a Markdown text into a `MarkdownDocument`, by the block rules the Mac's conversation
/// uses (`ThreadingMarkdownKit.Markdown`): fenced code first, then tables, headings, quotes and
/// lists, and a paragraph for everything else.
///
/// Linear in the text and bounded by `MarkdownModelLimits`; it never fails.
enum MarkdownParser {

    static func parse(_ source: String) -> MarkdownDocument {
        let bounded = source.utf8.count > MarkdownModelLimits.maximumSourceBytes
            ? String(decoding: source.utf8.prefix(MarkdownModelLimits.maximumSourceBytes), as: UTF8.self)
            : source
        let lines = bounded.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlockNode] = []
        var index = 0
        while index < lines.count {
            if trimmed(lines, index).isEmpty {
                index += 1
                continue
            }
            let (block, next) = readBlock(lines, index)
            blocks.append(block)
            // Every reader consumes at least its first line; this keeps a future reader's bug
            // from ever looping on one.
            index = max(next, index + 1)
        }
        return MarkdownDocument(blocks: blocks)
    }

    // MARK: - Blocks

    private static func readBlock(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        let line = trimmed(lines, index)
        if line.hasPrefix("```") { return readFence(lines, index) }
        if let table = readTable(lines, index) { return table }
        if let level = headingLevel(line) {
            return (.heading(level: level, inline(String(line.dropFirst(level + 1)))), index + 1)
        }
        if isRule(line) { return (.rule, index + 1) }
        if line.hasPrefix(">") { return readQuote(lines, index) }
        if isBullet(line) { return readBullets(lines, index) }
        if orderedItem(line) != nil { return readOrdered(lines, index) }
        return readParagraph(lines, index)
    }

    /// Fenced code runs verbatim to the closing fence, so a `*` in a shell glob is not emphasis.
    private static func readFence(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        let language = String(trimmed(lines, index).dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        var cursor = index + 1
        while cursor < lines.count, !trimmed(lines, cursor).hasPrefix("```") {
            code.append(lines[cursor])
            cursor += 1
        }
        return (.code(language: language, text: code.joined(separator: "\n")), cursor + 1)
    }

    /// The separator row is the unambiguous signal; a sentence containing `|` stays a paragraph.
    private static func readTable(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(lines[index]),
              let delimiters = tableCells(lines[index + 1]),
              headers.count == delimiters.count else { return nil }
        let alignments = delimiters.compactMap(tableAlignment)
        guard alignments.count == delimiters.count else { return nil }

        var rows: [[[MarkdownInline]]] = []
        var cursor = index + 2
        while cursor < lines.count, let cells = tableCells(lines[cursor]) {
            var normalized = cells
            if normalized.count < headers.count {
                normalized += Array(repeating: "", count: headers.count - normalized.count)
            } else if normalized.count > headers.count {
                let overflow = normalized.dropFirst(headers.count - 1).joined(separator: " | ")
                normalized = Array(normalized.prefix(headers.count - 1)) + [overflow]
            }
            rows.append(normalized.map(inline))
            cursor += 1
        }
        let table = MarkdownTableNode(headers: headers.map(inline), alignments: alignments, rows: rows)
        return (.table(table), cursor)
    }

    private static func readQuote(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        var quoted: [String] = []
        var cursor = index
        while cursor < lines.count, trimmed(lines, cursor).hasPrefix(">") {
            var line = String(trimmed(lines, cursor).dropFirst())
            if line.hasPrefix(" ") { line.removeFirst() }
            quoted.append(line)
            cursor += 1
        }
        return (.quote(inlineLines(quoted)), cursor)
    }

    private static func readBullets(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        var items: [[MarkdownInline]] = []
        var cursor = index
        while cursor < lines.count, isBullet(trimmed(lines, cursor)) {
            items.append(inline(String(trimmed(lines, cursor).dropFirst(2))))
            cursor += 1
        }
        return (.bullets(items), cursor)
    }

    private static func readOrdered(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        var items: [[MarkdownInline]] = []
        var start = 1
        var cursor = index
        while cursor < lines.count, let item = orderedItem(trimmed(lines, cursor)) {
            if items.isEmpty { start = item.number }
            items.append(inline(item.text))
            cursor += 1
        }
        return (.ordered(start: start, items), cursor)
    }

    /// A paragraph runs until a blank line or a line that begins another block, and keeps the
    /// line breaks its author wrote.
    private static func readParagraph(_ lines: [String], _ index: Int) -> (MarkdownBlockNode, Int) {
        var paragraph: [String] = []
        var cursor = index
        while cursor < lines.count {
            let line = trimmed(lines, cursor)
            if line.isEmpty || (cursor > index && (startsBlock(line) || isTableStart(lines, cursor))) { break }
            paragraph.append(line)
            cursor += 1
        }
        return (.paragraph(inlineLines(paragraph)), cursor)
    }

    // MARK: - Block Recognition

    private static func trimmed(_ lines: [String], _ index: Int) -> String {
        lines[index].trimmingCharacters(in: .whitespaces)
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || headingLevel(line) != nil || line.hasPrefix(">")
            || isBullet(line) || orderedItem(line) != nil || isRule(line)
    }

    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count,
              let headers = tableCells(lines[index]),
              let delimiters = tableCells(lines[index + 1]),
              headers.count == delimiters.count else { return false }
        return delimiters.allSatisfy { tableAlignment($0) != nil }
    }

    /// Splits on unescaped pipes outside code spans. Leading and trailing pipes are optional and
    /// make no empty column.
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
        if source.last == "|", !cells.isEmpty { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func tableAlignment(_ cell: String) -> MarkdownTableNode.Alignment? {
        let value = cell.trimmingCharacters(in: .whitespaces)
        let left = value.first == ":"
        let right = value.last == ":" && value.count > 1
        let rule = value.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
        guard rule.count >= 3, rule.allSatisfy({ $0 == "-" }) else { return nil }
        if left, right { return .center }
        return right ? .trailing : .leading
    }

    private static func headingLevel(_ line: String) -> Int? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return level
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func isBullet(_ line: String) -> Bool {
        (line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")) && !isRule(line)
    }

    /// `12. text` → (12, "text"); `12) text` too.
    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> [MarkdownInline] {
        MarkdownInlineParser.parse(text)
    }

    /// Lines of one block, each read on its own and joined by the breaks between them.
    private static func inlineLines(_ lines: [String]) -> [MarkdownInline] {
        var runs: [MarkdownInline] = []
        for (offset, line) in lines.enumerated() {
            if offset > 0 { runs.append(.lineBreak) }
            runs += inline(line)
        }
        return runs
    }
}
