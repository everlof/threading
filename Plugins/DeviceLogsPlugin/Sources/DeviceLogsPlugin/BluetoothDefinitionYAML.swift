import Foundation

/// One parsed YAML value with the 1-based source line it started on.
struct YAMLNode: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case null
        /// A plain scalar, trimmed, comments removed. Numbers stay text: the schema interprets them.
        case scalar(String)
        /// A single- or double-quoted scalar with its escapes resolved.
        case quoted(String)
        case sequence([YAMLNode])
        /// Source order preserved; a duplicate key is an error.
        case mapping([YAMLEntry])
    }

    let line: Int
    let value: Value
}

struct YAMLEntry: Sendable, Equatable {
    let key: String
    let line: Int
    let value: YAMLNode
}

struct YAMLError: Error, Equatable, LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "line \(line): \(message)" }
}

/// The YAML a packet definitions file needs, and nothing a reader would have to look up.
///
/// Block mappings and sequences, flow collections (which may span lines), plain and quoted
/// scalars and comments. Anchors, aliases, tags, block scalars and multiple documents are refused
/// with the line they appear on rather than half-supported: a definitions file is short, written
/// by hand or by an agent, and an exact error is worth more than a feature nobody needs.
///
/// Work is linear in the input. Each line is scanned a bounded number of times (once to strip
/// comments, once per nesting level a compact `- key:` item rewrites it), and the three limits
/// bound bytes, nesting and node count before anything is built from them.
enum YAMLSubset {
    enum Limits {
        static let bytes = 256 * 1_024
        static let depth = 32
        static let nodes = 50_000
    }

    static func parse(_ text: String) throws -> YAMLNode {
        guard text.utf8.count <= Limits.bytes else {
            throw YAMLError(line: 1, message: "the file is larger than \(Limits.bytes / 1_024) KiB")
        }
        let parser = YAMLSubsetParser(lines: try YAMLSubsetParser.scan(text))
        return try parser.document()
    }
}

// MARK: - Parser

/// One non-blank source line: its indentation and its content with the comment removed.
private struct YAMLLine {
    let number: Int
    let indent: Int
    let text: ArraySlice<Character>
}

private final class YAMLSubsetParser {
    private var lines: [YAMLLine]
    private var index = 0
    private var nodeCount = 0

    // The flow reader's cursor: which line, its characters, and the column within them.
    private var flowRow = 0
    private var flowChars: ArraySlice<Character> = []
    private var flowCol = 0

    init(lines: [YAMLLine]) {
        self.lines = lines
    }

    // MARK: Scanning

    static func scan(_ text: String) throws -> [YAMLLine] {
        var result: [YAMLLine] = []
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            var chars = Array(raw)
            if chars.last == "\r" { chars.removeLast() }
            var start = 0
            var sawTab = false
            while start < chars.count, chars[start] == " " || chars[start] == "\t" {
                if chars[start] == "\t" { sawTab = true }
                start += 1
            }
            if start == chars.count || chars[start] == "#" { continue }
            if sawTab {
                throw YAMLError(line: number, message: "tabs are not allowed in indentation; use spaces")
            }
            let end = commentStart(chars, from: start)
            var trimmedEnd = end
            while trimmedEnd > start, chars[trimmedEnd - 1] == " " || chars[trimmedEnd - 1] == "\t" {
                trimmedEnd -= 1
            }
            result.append(YAMLLine(number: number, indent: start, text: chars[start..<trimmedEnd]))
        }
        return result
    }

    /// Where a `#` comment starts, ignoring one inside a quoted scalar. A quote opens a scalar
    /// only where a scalar can begin, so the apostrophe in a plain `don't` is just a letter.
    private static func commentStart(_ chars: [Character], from start: Int) -> Int {
        var quote: Character?
        var j = start
        while j < chars.count {
            let c = chars[j]
            if let open = quote {
                if open == "\"" {
                    if c == "\\" { j += 2; continue }
                    if c == "\"" { quote = nil }
                } else if c == "'" {
                    if j + 1 < chars.count, chars[j + 1] == "'" { j += 2; continue }
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                if j == start || [" ", "\t", "[", "{", ","].contains(chars[j - 1]) { quote = c }
            } else if c == "#", j == start || chars[j - 1] == " " || chars[j - 1] == "\t" {
                return j
            }
            j += 1
        }
        return chars.count
    }

    // MARK: Document

    func document() throws -> YAMLNode {
        guard !lines.isEmpty else { return try node(1, .null) }
        var markerLine = 1
        for (position, line) in lines.enumerated() where line.indent == 0 {
            let text = String(line.text)
            if position == 0, text == "---" {
                markerLine = line.number
                index = 1
            } else if text == "---" || text == "..." || text.hasPrefix("--- ") {
                throw YAMLError(line: line.number, message: position == 0
                    ? "content on the '---' line is not supported"
                    : "multiple documents are not supported")
            } else if text.hasPrefix("%") {
                throw YAMLError(line: line.number, message: "directives are not supported")
            }
        }
        guard index < lines.count else { return try node(markerLine, .null) }
        let rootIndent = lines[index].indent
        let root = try block(depth: 1)
        if index < lines.count {
            let line = lines[index]
            throw error(line, line.indent == rootIndent
                ? "a mapping and a sequence cannot share one indentation level"
                : "inconsistent indentation")
        }
        return root
    }

    // MARK: Block structure

    private func block(depth: Int) throws -> YAMLNode {
        let line = lines[index]
        try checkDepth(depth, line.number)
        if Self.isSequenceItem(line.text) {
            return try sequence(indent: line.indent, depth: depth, sharesParentIndent: false)
        }
        if try splitKey(line.text, line.number) != nil {
            return try mapping(indent: line.indent, depth: depth)
        }
        return try inlineValue(line.text, depth: depth)
    }

    private func mapping(indent: Int, depth: Int) throws -> YAMLNode {
        let startLine = lines[index].number
        var entries: [YAMLEntry] = []
        var seen = Set<String>()
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent {
                throw error(line, "inconsistent indentation: expected \(indent) spaces, found \(line.indent)")
            }
            if Self.isSequenceItem(line.text) {
                throw error(line, "a mapping and a sequence cannot share one indentation level")
            }
            guard let (key, rest) = try splitKey(line.text, line.number) else {
                try Self.rejectIndicator(line.text.first, line.number)
                throw error(line, "expected 'key: value'")
            }
            guard seen.insert(key).inserted else { throw error(line, "duplicate key '\(key)'") }
            let value: YAMLNode
            if !rest.isEmpty {
                value = try inlineValue(rest, depth: depth + 1)
            } else {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    value = try block(depth: depth + 1)
                } else if index < lines.count, lines[index].indent == indent,
                          Self.isSequenceItem(lines[index].text) {
                    // `key:` followed by `- item` at the key's own indentation.
                    try checkDepth(depth + 1, lines[index].number)
                    value = try sequence(indent: indent, depth: depth + 1, sharesParentIndent: true)
                } else {
                    value = try node(line.number, .null)
                }
            }
            entries.append(YAMLEntry(key: key, line: line.number, value: value))
        }
        return try node(startLine, .mapping(entries))
    }

    private func sequence(indent: Int, depth: Int, sharesParentIndent: Bool) throws -> YAMLNode {
        let startLine = lines[index].number
        var items: [YAMLNode] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent {
                throw error(line, "inconsistent indentation: expected \(indent) spaces, found \(line.indent)")
            }
            guard Self.isSequenceItem(line.text) else {
                if sharesParentIndent { break }
                throw error(line, "a mapping and a sequence cannot share one indentation level")
            }
            var offset = line.text.startIndex + 1
            while offset < line.text.endIndex, line.text[offset] == " " { offset += 1 }
            let rest = line.text[offset...]
            if rest.isEmpty {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    items.append(try block(depth: depth + 1))
                } else {
                    items.append(try node(line.number, .null))
                }
            } else if try Self.isSequenceItem(rest) || splitKey(rest, line.number) != nil {
                // A compact `- key: value` (or `- - item`): the rest of the line opens a nested
                // block whose indentation is the column it starts at.
                let column = indent + (offset - line.text.startIndex)
                lines[index] = YAMLLine(number: line.number, indent: column, text: rest)
                items.append(try block(depth: depth + 1))
            } else {
                items.append(try inlineValue(rest, depth: depth + 1))
            }
        }
        return try node(startLine, .sequence(items))
    }

    /// A value written on the same line as its key or dash. Consumes the line, and every further
    /// line a flow collection spans.
    private func inlineValue(_ text: ArraySlice<Character>, depth: Int) throws -> YAMLNode {
        let line = lines[index].number
        try checkDepth(depth, line)
        guard let first = text.first else {
            index += 1
            return try node(line, .null)
        }
        try Self.rejectIndicator(first, line)
        switch first {
        case "[", "{":
            flowRow = index
            flowChars = text
            flowCol = text.startIndex
            let value = try flowValue(depth: depth)
            while flowCol < flowChars.endIndex, flowChars[flowCol] == " " { flowCol += 1 }
            guard flowCol == flowChars.endIndex else {
                throw YAMLError(line: lines[flowRow].number, message: "unexpected text after a flow collection")
            }
            index = flowRow + 1
            return value
        case "\"", "'":
            let (value, end) = try Self.quoted(text, start: text.startIndex, line: line)
            guard text[end...].allSatisfy({ $0 == " " || $0 == "\t" }) else {
                throw YAMLError(line: line, message: "unexpected text after a quoted string")
            }
            index += 1
            return try node(line, .quoted(value))
        default:
            if Self.isSequenceItem(text) {
                throw YAMLError(line: line, message: "a sequence cannot start on the same line as its key")
            }
            let plain = String(text)
            if plain.contains(": ") || plain.hasSuffix(":") {
                throw YAMLError(line: line, message: "a nested mapping must start on its own line; quote the value if ': ' is part of it")
            }
            index += 1
            return try node(line, .scalar(plain))
        }
    }

    /// `key: rest` when the line is a mapping entry, otherwise nil.
    private func splitKey(
        _ text: ArraySlice<Character>, _ line: Int
    ) throws -> (String, ArraySlice<Character>)? {
        guard let first = text.first else { return nil }
        if first == "\"" || first == "'" {
            let (key, end) = try Self.quoted(text, start: text.startIndex, line: line)
            var j = end
            while j < text.endIndex, text[j] == " " { j += 1 }
            guard j < text.endIndex, text[j] == ":",
                  j + 1 == text.endIndex || text[j + 1] == " " else { return nil }
            return (key, Self.trimmedLeading(text[(j + 1)...]))
        }
        if "[{&*!|>%@`".contains(first) || Self.isSequenceItem(text) { return nil }
        var j = text.startIndex
        while j < text.endIndex {
            if text[j] == ":", j + 1 == text.endIndex || text[j + 1] == " " { break }
            j += 1
        }
        guard j < text.endIndex else { return nil }
        let key = String(text[..<j]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw YAMLError(line: line, message: "a mapping key cannot be empty") }
        return (key, Self.trimmedLeading(text[(j + 1)...]))
    }

    // MARK: Flow collections

    private func flowValue(depth: Int) throws -> YAMLNode {
        let line = lines[flowRow].number
        try checkDepth(depth, line)
        let c = flowChars[flowCol]
        switch c {
        case "[": return try flowSequence(depth: depth)
        case "{": return try flowMapping(depth: depth)
        case "\"", "'":
            let (value, end) = try Self.quoted(flowChars, start: flowCol, line: line)
            flowCol = end
            return try node(line, .quoted(value))
        case ",", "]", "}":
            throw YAMLError(line: line, message: "expected a value before '\(c)'")
        default:
            try Self.rejectIndicator(c, line)
            return try node(line, .scalar(flowPlain()))
        }
    }

    private func flowSequence(depth: Int) throws -> YAMLNode {
        let open = lines[flowRow].number
        flowCol += 1
        var items: [YAMLNode] = []
        while true {
            try flowSkip(open: open, kind: "flow sequence")
            if flowChars[flowCol] == "]" { flowCol += 1; break }
            items.append(try flowValue(depth: depth + 1))
            try flowSkip(open: open, kind: "flow sequence")
            switch flowChars[flowCol] {
            case ",": flowCol += 1
            case "]": flowCol += 1; return try node(open, .sequence(items))
            case ":":
                throw YAMLError(line: lines[flowRow].number, message: "write a mapping inside a sequence as { key: value }")
            default:
                throw YAMLError(line: lines[flowRow].number, message: "expected ',' or ']'")
            }
        }
        return try node(open, .sequence(items))
    }

    private func flowMapping(depth: Int) throws -> YAMLNode {
        let open = lines[flowRow].number
        flowCol += 1
        var entries: [YAMLEntry] = []
        var seen = Set<String>()
        while true {
            try flowSkip(open: open, kind: "flow mapping")
            if flowChars[flowCol] == "}" { flowCol += 1; break }
            let keyLine = lines[flowRow].number
            let key: String
            let c = flowChars[flowCol]
            if c == "\"" || c == "'" {
                let (value, end) = try Self.quoted(flowChars, start: flowCol, line: keyLine)
                flowCol = end
                key = value
            } else {
                try Self.rejectIndicator(c, keyLine)
                key = flowPlain()
            }
            guard !key.isEmpty else { throw YAMLError(line: keyLine, message: "a mapping key cannot be empty") }
            try flowSkip(open: open, kind: "flow mapping")
            guard flowChars[flowCol] == ":" else {
                throw YAMLError(line: lines[flowRow].number, message: "expected ':' after '\(key)'")
            }
            flowCol += 1
            try flowSkip(open: open, kind: "flow mapping")
            let value: YAMLNode
            if flowChars[flowCol] == "," || flowChars[flowCol] == "}" {
                value = try node(keyLine, .null)
            } else {
                value = try flowValue(depth: depth + 1)
            }
            guard seen.insert(key).inserted else {
                throw YAMLError(line: keyLine, message: "duplicate key '\(key)'")
            }
            entries.append(YAMLEntry(key: key, line: keyLine, value: value))
            try flowSkip(open: open, kind: "flow mapping")
            switch flowChars[flowCol] {
            case ",": flowCol += 1
            case "}": flowCol += 1; return try node(open, .mapping(entries))
            default: throw YAMLError(line: lines[flowRow].number, message: "expected ',' or '}'")
            }
        }
        return try node(open, .mapping(entries))
    }

    /// Skips spaces and line breaks inside an open collection; running out of lines means it
    /// was never closed, which is reported where it was opened.
    private func flowSkip(open: Int, kind: String) throws {
        while true {
            while flowCol < flowChars.endIndex, flowChars[flowCol] == " " || flowChars[flowCol] == "\t" {
                flowCol += 1
            }
            if flowCol < flowChars.endIndex { return }
            flowRow += 1
            guard flowRow < lines.count else {
                throw YAMLError(line: open, message: "unterminated \(kind)")
            }
            flowChars = lines[flowRow].text
            flowCol = flowChars.startIndex
        }
    }

    /// A plain scalar inside a flow collection: up to a flow indicator, a `: `, or the line end.
    private func flowPlain() -> String {
        let start = flowCol
        while flowCol < flowChars.endIndex {
            let c = flowChars[flowCol]
            if ",[]{}".contains(c) { break }
            if c == ":" {
                let next = flowCol + 1
                if next == flowChars.endIndex || " ,[]{}".contains(flowChars[next]) { break }
            }
            flowCol += 1
        }
        return String(flowChars[start..<flowCol]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Scalars

    private static func quoted(
        _ text: ArraySlice<Character>, start: Int, line: Int
    ) throws -> (String, Int) {
        let quote = text[start]
        var j = start + 1
        var out = ""
        while j < text.endIndex {
            let c = text[j]
            if quote == "'" {
                if c == "'" {
                    if j + 1 < text.endIndex, text[j + 1] == "'" { out.append("'"); j += 2; continue }
                    return (out, j + 1)
                }
                out.append(c)
                j += 1
                continue
            }
            if c == "\"" { return (out, j + 1) }
            guard c == "\\" else { out.append(c); j += 1; continue }
            guard j + 1 < text.endIndex else { break }
            let escape = text[j + 1]
            j += 2
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"", "\\", "/", " ": out.append(escape)
            case "x", "u", "U":
                let digits = escape == "x" ? 2 : escape == "u" ? 4 : 8
                guard j + digits <= text.endIndex,
                      let code = UInt32(String(text[j..<j + digits]), radix: 16),
                      let scalar = Unicode.Scalar(code) else {
                    throw YAMLError(line: line, message: "invalid \\\(escape) escape")
                }
                out.unicodeScalars.append(scalar)
                j += digits
            default:
                throw YAMLError(line: line, message: "unknown escape '\\\(escape)'")
            }
        }
        throw YAMLError(line: line, message: "unterminated quoted string")
    }

    private static func rejectIndicator(_ first: Character?, _ line: Int) throws {
        let message: String
        switch first {
        case "&": message = "anchors (&) are not supported"
        case "*": message = "aliases (*) are not supported"
        case "!": message = "tags (!) are not supported"
        case "|", ">": message = "block scalars (| and >) are not supported; use a quoted string"
        case "%": message = "directives are not supported"
        case "@", "`": message = "'\(first ?? " ")' is reserved in YAML; quote the value"
        default: return
        }
        throw YAMLError(line: line, message: message)
    }

    private static func isSequenceItem(_ text: ArraySlice<Character>) -> Bool {
        guard text.first == "-" else { return false }
        return text.count == 1 || text[text.startIndex + 1] == " "
    }

    private static func trimmedLeading(_ text: ArraySlice<Character>) -> ArraySlice<Character> {
        var start = text.startIndex
        while start < text.endIndex, text[start] == " " { start += 1 }
        return text[start...]
    }

    // MARK: Bounds

    private func node(_ line: Int, _ value: YAMLNode.Value) throws -> YAMLNode {
        nodeCount += 1
        guard nodeCount <= YAMLSubset.Limits.nodes else {
            throw YAMLError(line: line, message: "more than \(YAMLSubset.Limits.nodes) values")
        }
        return YAMLNode(line: line, value: value)
    }

    private func checkDepth(_ depth: Int, _ line: Int) throws {
        guard depth <= YAMLSubset.Limits.depth else {
            throw YAMLError(line: line, message: "nested deeper than \(YAMLSubset.Limits.depth) levels")
        }
    }

    private func error(_ line: YAMLLine, _ message: String) -> YAMLError {
        YAMLError(line: line.number, message: message)
    }
}
