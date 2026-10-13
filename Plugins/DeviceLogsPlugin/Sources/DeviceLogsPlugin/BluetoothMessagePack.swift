import Foundation

/// One parsed MessagePack value.
///
/// Parsed rather than rendered straight from the bytes because a definition can *match* it:
/// `{ $cmd: $value }` binds parts of the value, and a learned enum is read out of it. The tree is
/// bounded by its input — every node consumes at least one byte — and by `MessagePack.Limits`.
indirect enum MessagePackValue: Sendable, Equatable {
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary([UInt8])
    case array([MessagePackValue])
    case map([MessagePackEntry])
    case bool(Bool)
    case null
    case ext(type: Int8, data: [UInt8])

    var integer: Int64? {
        switch self {
        case .int(let value): return value
        case .uint(let value): return value <= UInt64(Int64.max) ? Int64(value) : nil
        default: return nil
        }
    }
}

struct MessagePackEntry: Sendable, Equatable {
    let key: MessagePackValue
    let value: MessagePackValue
}

enum MessagePack {
    enum Limits {
        static let depth = 16
        static let nodes = 20_000
        /// Items shown per array or map; the rest are counted, not drawn.
        static let renderedItems = 64
        static let renderedBytes = 32
    }

    struct Failure: Error, Equatable { let message: String }

    /// Parses the value starting at `offset`, never reading at or past `end`.
    static func parse(_ bytes: [UInt8], offset: inout Int, end: Int) throws -> MessagePackValue {
        var nodes = 0
        return try parse(bytes, offset: &offset, end: end, depth: 0, nodes: &nodes)
    }

    private static func parse(
        _ bytes: [UInt8], offset: inout Int, end: Int, depth: Int, nodes: inout Int
    ) throws -> MessagePackValue {
        nodes += 1
        guard nodes <= Limits.nodes else { throw Failure(message: "msgpack value has more than \(Limits.nodes) elements") }
        guard depth < Limits.depth else { throw Failure(message: "msgpack nested deeper than \(Limits.depth)") }
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, end - offset >= count else {
                throw Failure(message: "needs \(count) bytes, \(max(0, end - offset)) left")
            }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
        func unsigned(_ width: Int) throws -> UInt64 {
            try take(width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func length(_ width: Int) throws -> Int { Int(clamping: try unsigned(width)) }
        func signed(_ width: Int) throws -> Int64 {
            let bits = try unsigned(width)
            guard width < 8 else { return Int64(bitPattern: bits) }
            let shift = UInt64(64 - width * 8)
            return Int64(bitPattern: bits << shift) >> Int64(shift)
        }
        func string(_ count: Int) throws -> MessagePackValue { .string(String(decoding: try take(count), as: UTF8.self)) }
        func array(_ count: Int) throws -> MessagePackValue {
            // Each element is at least a byte, so a declared count beyond the input is a lie.
            guard count <= end - offset else { throw Failure(message: "needs \(count) elements, \(end - offset) bytes left") }
            var items: [MessagePackValue] = []
            items.reserveCapacity(min(count, 256))
            for _ in 0..<count { items.append(try parse(bytes, offset: &offset, end: end, depth: depth + 1, nodes: &nodes)) }
            return .array(items)
        }
        func map(_ count: Int) throws -> MessagePackValue {
            guard count <= (end - offset) / 2 else { throw Failure(message: "needs \(count) entries, \(end - offset) bytes left") }
            var entries: [MessagePackEntry] = []
            entries.reserveCapacity(min(count, 256))
            for _ in 0..<count {
                let key = try parse(bytes, offset: &offset, end: end, depth: depth + 1, nodes: &nodes)
                let value = try parse(bytes, offset: &offset, end: end, depth: depth + 1, nodes: &nodes)
                entries.append(.init(key: key, value: value))
            }
            return .map(entries)
        }
        func ext(_ count: Int) throws -> MessagePackValue {
            let type = Int8(truncatingIfNeeded: try signed(1))
            return .ext(type: type, data: Array(try take(count)))
        }

        let marker = try take(1).first!
        switch marker {
        case 0x00...0x7f: return .int(Int64(marker))
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: marker)))
        case 0x80...0x8f: return try map(Int(marker & 0x0f))
        case 0x90...0x9f: return try array(Int(marker & 0x0f))
        case 0xa0...0xbf: return try string(Int(marker & 0x1f))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(Array(try take(length(1))))
        case 0xc5: return .binary(Array(try take(length(2))))
        case 0xc6: return .binary(Array(try take(length(4))))
        case 0xc7: return try ext(length(1))
        case 0xc8: return try ext(length(2))
        case 0xc9: return try ext(length(4))
        case 0xca: return .float(Double(Float(bitPattern: UInt32(try unsigned(4)))))
        case 0xcb: return .float(Double(bitPattern: try unsigned(8)))
        case 0xcc: return .int(Int64(try unsigned(1)))
        case 0xcd: return .int(Int64(try unsigned(2)))
        case 0xce: return .int(Int64(try unsigned(4)))
        case 0xcf: return .uint(try unsigned(8))
        case 0xd0: return .int(try signed(1))
        case 0xd1: return .int(try signed(2))
        case 0xd2: return .int(try signed(4))
        case 0xd3: return .int(try signed(8))
        case 0xd4: return try ext(1)
        case 0xd5: return try ext(2)
        case 0xd6: return try ext(4)
        case 0xd7: return try ext(8)
        case 0xd8: return try ext(16)
        case 0xd9: return try string(length(1))
        case 0xda: return try string(length(2))
        case 0xdb: return try string(length(4))
        case 0xdc: return try array(length(2))
        case 0xdd: return try array(length(4))
        case 0xde: return try map(length(2))
        case 0xdf: return try map(length(4))
        default: throw Failure(message: "0xc1 is not a msgpack value")
        }
    }

    // MARK: Rendering

    /// Renders like the rest of a decoded row: maps as `{key=value …}`, arrays as `[a, b]`,
    /// strings quoted, binary as hex. `keyName` names integer map keys.
    static func render(_ value: MessagePackValue, keyName: ((Int64) -> String?)? = nil) -> String {
        switch value {
        case .int(let number): return String(number)
        case .uint(let number): return String(number)
        case .float(let number): return decimal(number)
        case .string(let text): return quoted(text)
        case .binary(let data): return hex(data)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "nil"
        case .ext(let type, let data): return "ext\(type)" + hex(data)
        case .array(let items):
            let shown = items.prefix(Limits.renderedItems).map { render($0, keyName: keyName) }
            let more = items.count - shown.count
            return "[" + shown.joined(separator: ", ") + (more > 0 ? ", …+\(more)" : "") + "]"
        case .map(let entries):
            let shown = entries.prefix(Limits.renderedItems).map { "\(key($0.key, keyName: keyName))=\(render($0.value, keyName: keyName))" }
            let more = entries.count - shown.count
            return "{" + shown.joined(separator: " ") + (more > 0 ? " …+\(more)" : "") + "}"
        }
    }

    /// A map key as a field id: a named integer, a plain word unquoted, anything else rendered.
    static func key(_ value: MessagePackValue, keyName: ((Int64) -> String?)?) -> String {
        if let number = value.integer, let name = keyName?(number) { return name }
        if case .string(let text) = value, !text.isEmpty,
           text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return text
        }
        return render(value, keyName: keyName)
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func hex(_ data: [UInt8]) -> String {
        guard !data.isEmpty else { return "<>" }
        let shown = data.prefix(Limits.renderedBytes).map { String(format: "%02x", $0) }.joined()
        return "<" + shown + (data.count > Limits.renderedBytes ? "…+\(data.count - Limits.renderedBytes)" : "") + ">"
    }

    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        var text = String(format: "%.7f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

// MARK: - Patterns

/// A shape a MessagePack value may have, with named parts to bind.
///
/// The grammar is deliberately tiny, because definition files are untrusted input:
///
/// ```
/// pattern := map | array | atom
/// map     := "{" pattern ":" pattern "}"          every entry must match; one binding per entry
/// array   := "[" (item ("," item)*)? "]"
/// item    := pattern | "..." ["$" name]           the rest of the array, optionally bound
/// atom    := "$" name [":" kind] | "_" [":" kind] | number | "quoted" | word
/// kind    := int | str | float | bool | nil | bin | map | array
/// word    := a name, `*` matching any run: matched against a string, or an integer's enum name
/// ```
indirect enum MessagePackPattern: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case int, str, float, bool, `nil`, bin, map, array
    }

    case capture(String, Kind?)
    case any(Kind?)
    case number(Int64)
    case text(String)
    case word(String)
    case map(key: MessagePackPattern, value: MessagePackPattern)
    case array([MessagePackPattern], rest: String?, hasRest: Bool)

    enum Limits {
        static let characters = 256
        static let nodes = 64
        static let depth = 8
        /// Bindings one match may produce: a map pattern yields one per entry, nested maps multiply.
        static let bindings = 4_096
    }

    /// Every name the pattern binds, in order.
    var captures: [String] {
        switch self {
        case .capture(let name, _): return [name]
        case .map(let key, let value): return key.captures + value.captures
        case .array(let items, let rest, _): return items.flatMap(\.captures) + (rest.map { [$0] } ?? [])
        default: return []
        }
    }

    // MARK: Parsing

    static func parse(_ text: String) throws -> MessagePackPattern {
        guard text.count <= Limits.characters else {
            throw MessagePack.Failure(message: "pattern is longer than \(Limits.characters) characters")
        }
        var parser = Parser(characters: Array(text))
        let pattern = try parser.pattern(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.characters.count else {
            throw MessagePack.Failure(message: "pattern has unexpected '\(String(parser.characters[parser.index...]))'")
        }
        return pattern
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var nodes = 0

        mutating func skipSpace() {
            while index < characters.count, characters[index] == " " { index += 1 }
        }

        mutating func expect(_ character: Character) throws {
            skipSpace()
            guard index < characters.count, characters[index] == character else {
                throw MessagePack.Failure(message: "pattern expects '\(character)' at column \(index + 1)")
            }
            index += 1
        }

        mutating func peek() -> Character? {
            skipSpace()
            return index < characters.count ? characters[index] : nil
        }

        mutating func pattern(depth: Int) throws -> MessagePackPattern {
            nodes += 1
            guard nodes <= Limits.nodes, depth < Limits.depth else {
                throw MessagePack.Failure(message: "pattern is too large or deep")
            }
            switch peek() {
            case "{":
                index += 1
                let key = try pattern(depth: depth + 1)
                try expect(":")
                let value = try pattern(depth: depth + 1)
                try expect("}")
                return .map(key: key, value: value)
            case "[":
                index += 1
                var items: [MessagePackPattern] = []
                var rest: String?
                var hasRest = false
                if peek() == "]" { index += 1; return .array([], rest: nil, hasRest: false) }
                while true {
                    if peek() == ".", characters[index...].starts(with: Array("...")) {
                        index += 3
                        hasRest = true
                        if peek() == "$" { index += 1; rest = try name() }
                        try expect("]")
                        return .array(items, rest: rest, hasRest: true)
                    }
                    items.append(try pattern(depth: depth + 1))
                    if peek() == "," { index += 1; continue }
                    try expect("]")
                    return .array(items, rest: rest, hasRest: hasRest)
                }
            case "$":
                index += 1
                return .capture(try name(), try kind())
            case "\"":
                index += 1
                var text = ""
                while index < characters.count, characters[index] != "\"" { text.append(characters[index]); index += 1 }
                try expect("\"")
                return .text(text)
            case nil:
                throw MessagePack.Failure(message: "pattern ends early")
            default:
                let word = try name(allowGlob: true)
                if word == "_" { return .any(try kind()) }
                if let number = Self.number(word) { return .number(number) }
                return .word(word)
            }
        }

        static func number(_ word: String) -> Int64? {
            let negative = word.hasPrefix("-")
            let digits = negative ? String(word.dropFirst()) : word
            let value = digits.lowercased().hasPrefix("0x") ? Int64(digits.dropFirst(2), radix: 16) : Int64(digits)
            return value.map { negative ? -$0 : $0 }
        }

        mutating func name(allowGlob: Bool = false) throws -> String {
            skipSpace()
            let start = index
            while index < characters.count {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" || character == "-"
                        || (allowGlob && character == "*") else { break }
                index += 1
            }
            guard index > start else {
                throw MessagePack.Failure(message: "pattern expects a name at column \(start + 1)")
            }
            return String(characters[start..<index])
        }

        mutating func kind() throws -> Kind? {
            guard index < characters.count, characters[index] == ":" ,
                  // `{ $k: $v }` uses ':' between key and value; a kind follows only without a space.
                  index + 1 < characters.count, characters[index + 1].isLetter else { return nil }
            let save = index
            index += 1
            let word = try name()
            guard let kind = Kind(rawValue: word) else {
                index = save
                return nil
            }
            return kind
        }
    }

    // MARK: Matching

    typealias Binding = [String: MessagePackValue]

    /// Every way the value matches, or an empty list. `name` resolves an integer to the word a
    /// glob is compared with — an enum, possibly one learned from this very traffic.
    func match(_ value: MessagePackValue, name: (Int64) -> String?) -> [Binding] {
        var budget = Limits.bindings
        return match(value, name: name, budget: &budget)
    }

    private func match(_ value: MessagePackValue, name: (Int64) -> String?, budget: inout Int) -> [Binding] {
        guard budget > 0 else { return [] }
        switch self {
        case .capture(let capture, let kind):
            return Self.fits(value, kind) ? [[capture: value]] : []
        case .any(let kind):
            return Self.fits(value, kind) ? [[:]] : []
        case .number(let number):
            return value.integer == number ? [[:]] : []
        case .text(let text):
            if case .string(let string) = value, string == text { return [[:]] }
            return []
        case .word(let glob):
            let word: String?
            switch value {
            case .string(let string): word = string
            default: word = value.integer.flatMap(name)
            }
            return word.map { Self.glob(glob, matches: $0) } == true ? [[:]] : []
        case .map(let keyPattern, let valuePattern):
            guard case .map(let entries) = value, !entries.isEmpty else { return [] }
            var result: [Binding] = []
            for entry in entries {
                let keys = keyPattern.match(entry.key, name: name, budget: &budget)
                guard !keys.isEmpty else { return [] }
                let values = valuePattern.match(entry.value, name: name, budget: &budget)
                guard !values.isEmpty else { return [] }
                for key in keys {
                    for value in values {
                        guard budget > 0 else { return result }
                        budget -= 1
                        result.append(key.merging(value) { _, new in new })
                    }
                }
            }
            return result
        case .array(let items, let rest, let hasRest):
            guard case .array(let values) = value,
                  hasRest ? values.count >= items.count : values.count == items.count else { return [] }
            var result: [Binding] = [[:]]
            for (pattern, item) in zip(items, values) {
                let matches = pattern.match(item, name: name, budget: &budget)
                guard !matches.isEmpty else { return [] }
                var next: [Binding] = []
                for partial in result {
                    for match in matches {
                        guard budget > 0 else { break }
                        budget -= 1
                        next.append(partial.merging(match) { _, new in new })
                    }
                }
                result = next
            }
            if let rest {
                let tail = MessagePackValue.array(Array(values.dropFirst(items.count)))
                result = result.map { $0.merging([rest: tail]) { _, new in new } }
            }
            return result
        }
    }

    private static func fits(_ value: MessagePackValue, _ kind: Kind?) -> Bool {
        guard let kind else { return true }
        switch (kind, value) {
        case (.int, .int), (.int, .uint), (.str, .string), (.float, .float), (.bool, .bool),
             (.nil, .null), (.bin, .binary), (.map, .map), (.array, .array):
            return true
        default:
            return false
        }
    }

    /// `*` matches any run of characters; everything else literally.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == text }
        guard text.hasPrefix(parts[0]), text.hasSuffix(parts[parts.count - 1]),
              text.count >= parts[0].count + parts[parts.count - 1].count else { return false }
        var remainder = Substring(text.dropFirst(parts[0].count).dropLast(parts[parts.count - 1].count))
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = remainder.range(of: part) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }
}
