import Foundation

/// A colour a project may give a word in its decoded Bluetooth rows (`highlight:` in the YAML).
///
/// System hues by name rather than theme roles: the author is marking *their* vocabulary
/// ("LOCATION is the one I care about"), not choosing a grammar role.
enum BluetoothHighlightColor: String, CaseIterable, Sendable, Equatable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
}

/// What one run of a log message is, so the pane can draw its structure.
enum LogMessageStyle: Sendable, Equatable {
    /// `RX` (received by the phone) or `TX`.
    case direction(received: Bool)
    /// `Pulse 4F2A → iPhone`, the route in front of a decoded value.
    case route
    /// The definitions' characteristic name.
    case characteristic
    /// `notify`, `write`, `read` …
    case verb
    /// An identifier immediately followed by `=`.
    case key
    /// Brackets, separators, arrows and `=`.
    case punctuation
    case string
    /// Decimal, hex, `#412`, `59.3°`, `<dead…+4>`.
    case number
    /// An all-caps word in a decoded value: an enum case. Protocol rows are full of them
    /// (HCI, ACL, ATT, LE), so there they stay in the row's ink.
    case constant
    case uuid
    /// `⚠` and what it says.
    case warning
    /// ` · 14 bytes | 01 9c …`, the raw tail of a packet row.
    case preview
    case custom(BluetoothHighlightColor)
    /// An enum case name — a command, a message kind — coloured by the name itself, so the same
    /// name is the same colour in every row and every capture.
    case named(String)
}

struct LogMessageSpan: Sendable, Equatable {
    /// UTF-16 offsets, as `NSAttributedString` counts them.
    let range: NSRange
    let style: LogMessageStyle
}

/// Splits a log message into styled runs. Pure and bounded, so it runs per visible cell.
///
/// Scaling contract: called for the table's viewport rows only (tens per reload), and each call
/// examines at most `Limits.scannedUnits` UTF-16 units — a cell truncates long before that, so the
/// unstyled remainder is never on screen. No allocation proportional to anything but that prefix.
enum LogMessageHighlighter {
    enum Limits {
        static let scannedUnits = 2_048
    }

    enum Kind: Sendable {
        /// Any log line: strings, numbers, `key=value`, constants.
        case plain
        /// A Bluetooth packet row: also its direction and raw preview tail.
        case bluetooth
        /// A row decoded by the project's definitions: also its route, characteristic and verb.
        case bluetoothApp
    }

    static func spans(
        _ message: String, kind: Kind, highlights: [String: BluetoothHighlightColor] = [:],
        names: Set<String> = []
    ) -> [LogMessageSpan] {
        let units = Array(message.utf16.prefix(Limits.scannedUnits))
        var spans: [LogMessageSpan] = []
        var bodyStart = 0
        var bodyEnd = units.count

        if kind != .plain {
            if units.count >= 2, units[1] == ascii("X"), units[0] == ascii("R") || units[0] == ascii("T") {
                spans.append(.init(range: NSRange(location: 0, length: 2), style: .direction(received: units[0] == ascii("R"))))
                bodyStart = 2
            }
            // The tail: " · 14 bytes | 01 9c …". The last " | " is the preview; the separator
            // before it starts the byte count.
            if let bar = lastIndex(of: [0x20, ascii("|"), 0x20], in: units, before: units.count) {
                let start = lastIndex(of: separator, in: units, before: bar) ?? bar
                spans.append(.init(range: NSRange(location: start, length: units.count - start), style: .preview))
                bodyEnd = start
            }
            if kind == .bluetoothApp,
               let first = firstIndex(of: separator, in: units, from: bodyStart, before: bodyEnd) {
                // "RX <route> · <characteristic> <verb> · <value>"
                let routeStart = bodyStart == 0 ? 0 : bodyStart + 1
                spans.append(.init(range: NSRange(location: routeStart, length: max(0, first - routeStart)), style: .route))
                spans.append(.init(range: NSRange(location: first + 1, length: 1), style: .punctuation))
                let nameStart = first + separator.count
                let second = firstIndex(of: separator, in: units, from: nameStart, before: bodyEnd) ?? bodyEnd
                if let space = lastIndex(of: [0x20], in: units, before: second), space > nameStart {
                    spans.append(.init(range: NSRange(location: nameStart, length: space - nameStart), style: .characteristic))
                    spans.append(.init(range: NSRange(location: space + 1, length: second - space - 1), style: .verb))
                }
                bodyStart = second
            }
        }
        if let warning = firstIndex(of: [0x26A0], in: units, from: bodyStart, before: bodyEnd) {
            spans.append(.init(range: NSRange(location: warning, length: bodyEnd - warning), style: .warning))
            bodyEnd = warning
        }
        tokenize(units, from: bodyStart, to: bodyEnd, highlights: highlights,
                 names: kind == .bluetoothApp ? names : [], constants: kind == .bluetoothApp, into: &spans)
        return spans.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Tokens

    private static func tokenize(
        _ units: [UInt16], from start: Int, to end: Int,
        highlights: [String: BluetoothHighlightColor], names: Set<String>, constants: Bool,
        into spans: inout [LogMessageSpan]
    ) {
        var index = start
        // The colour a `highlight:` key gives the value after its `=`.
        var valueColor: BluetoothHighlightColor?
        while index < end {
            let unit = units[index]
            if unit == 0x20 { index += 1; continue }
            if unit == ascii("\"") {
                var close = index + 1
                while close < end, units[close] != ascii("\"") {
                    close += units[close] == ascii("\\") ? 2 : 1
                }
                let length = min(close + 1, end) - index
                spans.append(.init(range: NSRange(location: index, length: length), style: valueColor.map { .custom($0) } ?? .string))
                valueColor = nil
                index += length
                continue
            }
            if unit == ascii("<"), let close = firstIndex(of: [ascii(">")], in: units, from: index, before: end) {
                spans.append(.init(range: NSRange(location: index, length: close + 1 - index), style: .number))
                index = close + 1
                continue
            }
            if punctuation.contains(unit) {
                spans.append(.init(range: NSRange(location: index, length: 1), style: .punctuation))
                if unit != ascii("=") { valueColor = nil }
                index += 1
                continue
            }
            guard isWord(unit) || unit == ascii("#") || unit == ascii("-") else {
                index += 1
                continue
            }
            var stop = index + 1
            while stop < end, isWord(units[stop]) || units[stop] == ascii("-") && stop + 1 < end && isWord(units[stop + 1]) {
                stop += 1
            }
            let range = NSRange(location: index, length: stop - index)
            let word = String(utf16CodeUnits: Array(units[index..<stop]), count: stop - index)
            if stop < end, units[stop] == ascii("=") {
                spans.append(.init(range: range, style: highlights[word].map { .custom($0) }
                    ?? (names.contains(word) ? .named(word) : .key)))
                valueColor = highlights[word]
            } else if let color = valueColor ?? highlights[word] {
                spans.append(.init(range: range, style: .custom(color)))
                valueColor = nil
            } else if names.contains(word) {
                spans.append(.init(range: range, style: .named(word)))
                valueColor = nil
            } else if let style = classify(units[index..<stop]), constants || style != .constant {
                spans.append(.init(range: range, style: style))
                valueColor = nil
            } else {
                valueColor = nil
            }
            index = stop
        }
    }

    private static func classify(_ word: ArraySlice<UInt16>) -> LogMessageStyle? {
        var body = word
        if body.first == ascii("#") || body.first == ascii("-") { body = body.dropFirst() }
        guard let first = body.first else { return nil }
        if word.count == 36, word.allSatisfy({ isHex($0) || $0 == ascii("-") }),
           word.filter({ $0 == ascii("-") }).count == 4 {
            return .uuid
        }
        if body.count > 2, first == ascii("0"), body[body.startIndex + 1] == ascii("x") {
            return body.dropFirst(2).allSatisfy(isHex) ? .number : nil
        }
        if isDigit(first) {
            // Digits, one decimal point, then a unit glued on (°, %, ?): a number.
            let numeric = body.prefix { isDigit($0) || $0 == ascii(".") }
            let rest = body.dropFirst(numeric.count)
            return rest.allSatisfy { !isLetter($0) } || rest.allSatisfy(isUnitLetter) ? .number : nil
        }
        guard word.first != ascii("#"), word.first != ascii("-") else { return nil }
        let letters = word.filter(isLetter)
        if letters.count >= 2, letters.allSatisfy({ $0 >= ascii("A") && $0 <= ascii("Z") }) {
            return .constant
        }
        return nil
    }

    // MARK: Characters

    private static let separator: [UInt16] = [0x20, 0x00B7, 0x20]
    private static let punctuation: Set<UInt16> = [
        ascii("{"), ascii("}"), ascii("["), ascii("]"), ascii("("), ascii(")"), ascii(","), ascii("="),
        ascii("|"), 0x00B7, 0x2192, 0x2026,
    ]

    private static func ascii(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }
    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5a) || (unit >= 0x61 && unit <= 0x7a)
    }
    private static func isHex(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }
    /// Unit suffixes a decoded number may carry: `°`, `%`, `?` for an unknown enum value, and
    /// short SI letters (`ms`, `m`, `s`) when written without a space.
    private static func isUnitLetter(_ unit: UInt16) -> Bool { isLetter(unit) }
    /// Letters, digits, `_`, `.`, `:`, and the `°`/`%`/`?` a decoded value ends in.
    private static func isWord(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == ascii("_") || unit == ascii(".") || unit == ascii(":")
            || unit == 0x00B0 || unit == ascii("%") || unit == ascii("?")
            || unit >= 0xC0 && !punctuation.contains(unit) && unit != 0x26A0
    }

    private static func firstIndex(of needle: [UInt16], in units: [UInt16], from start: Int, before end: Int) -> Int? {
        guard needle.count <= end - start else { return nil }
        var index = start
        while index + needle.count <= end {
            if matches(needle, in: units, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func matches(_ needle: [UInt16], in units: [UInt16], at index: Int) -> Bool {
        for offset in needle.indices where units[index + offset] != needle[offset] { return false }
        return true
    }

    private static func lastIndex(of needle: [UInt16], in units: [UInt16], before end: Int) -> Int? {
        var index = end - needle.count
        while index >= 0 {
            if matches(needle, in: units, at: index) { return index }
            index -= 1
        }
        return nil
    }
}
