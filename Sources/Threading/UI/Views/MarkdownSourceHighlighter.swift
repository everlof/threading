import AppKit

/// Quiet Markdown syntax in the editor's source. The marks that make structure — heading
/// hashes, list and quote markers, fences, table pipes, rules, emphasis and code delimiters,
/// link targets — recede to tertiary ink so the words read first.
///
/// Only colour changes: never font, weight or metrics, so the code font's recorded role, line
/// height and caret geometry stay exactly what TextKit measured. Both inks are the theme's
/// dynamic colours, which resolve at draw time and so follow a live theme switch untouched.
///
/// Scaling: an edit re-tints only the paragraphs it touched, inside TextKit's own edit pass,
/// with no undo registration, reading the storage's own string rather than a bridged copy.
/// Loading a document tints its first `chunkLength` UTF-16 units at once — the viewport and the
/// whole of an expected note — and the remainder in slices of the same size, one per main-actor
/// turn, so a 1 MiB document never holds the main thread for a whole-document pass. Every line
/// is tinted on its own, so a fenced block's content is not tracked across lines; a fence line
/// itself recedes, its body stays ordinary text.
@MainActor
final class MarkdownSourceHighlighter: NSObject, NSTextStorageDelegate {
    static let chunkLength = 65_536
    private static let chunkPause: Duration = .milliseconds(1)
    private let textInk: NSColor
    private let markInk: NSColor
    private var buffer: [unichar] = []
    /// Where the deferred remainder of a loaded document starts, or nil when all is tinted.
    private(set) var untintedLocation: Int?
    private var remainder: Task<Void, Never>?
    private weak var loadingStorage: NSTextStorage?

    override init() {
        textInk = Design.Text.label
        markInk = Design.Text.tertiary
        super.init()
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // A text view's storage is edited on the main thread; it never crosses an isolation.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated { process(storage, edited: editedRange, delta: delta) }
    }

    /// Lets deterministic evidence observe a completely tinted document.
    func waitUntilTinted() async { await remainder?.value }

    private func process(_ storage: NSTextStorage, edited: NSRange, delta: Int) {
        let string = storage.mutableString
        let location = min(edited.location, string.length)
        let replacesDocument = location == 0 && edited.length == string.length
        guard !replacesDocument || string.length <= Self.chunkLength else {
            let first = string.lineRange(for: NSRange(location: 0, length: Self.chunkLength))
            tint(storage, lines: first)
            untintedLocation = NSMaxRange(first)
            tintRemainder(of: storage)
            return
        }
        if replacesDocument {
            remainder?.cancel()
            untintedLocation = nil
        } else if let pending = untintedLocation, location < pending {
            // The deferred slice moves with the text an edit inserted or removed before it.
            untintedLocation = min(max(pending + delta, location), string.length)
        }
        tint(storage, lines: string.lineRange(for: NSRange(location: location, length: edited.length)))
    }

    private func tintRemainder(of storage: NSTextStorage) {
        remainder?.cancel()
        loadingStorage = storage
        remainder = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.chunkPause) } catch { return }
                guard let self, let storage = loadingStorage, let start = untintedLocation else { return }
                let string = storage.mutableString
                guard start < string.length else { untintedLocation = nil; return }
                let lines = string.lineRange(for: NSRange(
                    location: start, length: min(Self.chunkLength, string.length - start)
                ))
                storage.beginEditing()
                tint(storage, lines: lines)
                storage.endEditing()
                untintedLocation = NSMaxRange(lines) < string.length ? NSMaxRange(lines) : nil
            }
        }
    }

    /// Ranges a line's syntax marks occupy, in the line's own UTF-16 offsets. Exposed for tests.
    func marks(in line: String) -> [NSRange] {
        let units = Array(line.utf16)
        var found: [NSRange] = []
        Self.scan(units, units.count) { found.append($0) }
        return found
    }

    private func tint(_ storage: NSTextStorage, lines: NSRange) {
        guard lines.length > 0 else { return }
        let string = storage.mutableString
        storage.addAttribute(.foregroundColor, value: textInk, range: lines)
        string.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            guard line.length > 0 else { return }
            if self.buffer.count < line.length {
                self.buffer = [unichar](repeating: 0, count: line.length)
            }
            string.getCharacters(&self.buffer, range: line)
            Self.scan(self.buffer, line.length) { mark in
                storage.addAttribute(
                    .foregroundColor,
                    value: self.markInk,
                    range: NSRange(location: line.location + mark.location, length: mark.length)
                )
            }
        }
    }

    // MARK: - Line Scanner

    private enum Unit {
        static let space: unichar = 0x20, tab: unichar = 0x09
        static let hash: unichar = 0x23, greater: unichar = 0x3E, pipe: unichar = 0x7C
        static let dash: unichar = 0x2D, star: unichar = 0x2A, plus: unichar = 0x2B, underscore: unichar = 0x5F
        static let backtick: unichar = 0x60, tilde: unichar = 0x7E, colon: unichar = 0x3A
        static let period: unichar = 0x2E, closeParen: unichar = 0x29, openParen: unichar = 0x28
        static let openBracket: unichar = 0x5B, closeBracket: unichar = 0x5D, bang: unichar = 0x21
        static let zero: unichar = 0x30, nine: unichar = 0x39
    }

    private static let maximumHeadingLevel = 6
    private static let minimumRuleLength = 3
    private static let fenceLength = 3

    private static func scan(_ line: [unichar], _ length: Int, mark: (NSRange) -> Void) {
        var index = 0
        while index < length, line[index] == Unit.space || line[index] == Unit.tab { index += 1 }
        guard index < length else { return }
        let start = index
        let first = line[start]
        let whole = NSRange(location: start, length: length - start)

        if first == Unit.backtick || first == Unit.tilde, run(of: first, in: line, from: start, length) >= fenceLength {
            mark(whole)
            return
        }
        if isRule(line, from: start, length) || isTableDivider(line, from: start, length) {
            mark(whole)
            return
        }

        if first == Unit.hash {
            let level = run(of: Unit.hash, in: line, from: start, length)
            if level <= maximumHeadingLevel, start + level == length || line[start + level] == Unit.space {
                mark(NSRange(location: start, length: level))
                index = start + level
            }
        } else if first == Unit.greater {
            mark(NSRange(location: start, length: 1))
            index = start + 1
        } else if first == Unit.dash || first == Unit.star || first == Unit.plus,
                  start + 1 < length, line[start + 1] == Unit.space {
            mark(NSRange(location: start, length: 1))
            index = start + 2
        } else if isDigit(first) {
            var cursor = start
            while cursor < length, isDigit(line[cursor]) { cursor += 1 }
            if cursor + 1 < length, line[cursor] == Unit.period || line[cursor] == Unit.closeParen,
               line[cursor + 1] == Unit.space {
                mark(NSRange(location: start, length: cursor + 1 - start))
                index = cursor + 1
            }
        }

        inline(line, from: index, length, mark: mark)
    }

    /// Emphasis asterisks, code backticks, table pipes and a link's brackets and target.
    /// Underscores are left alone: they are as often part of a `snake_case` word as emphasis.
    private static func inline(_ line: [unichar], from start: Int, _ length: Int, mark: (NSRange) -> Void) {
        var index = start
        while index < length {
            let unit = line[index]
            switch unit {
            case Unit.star, Unit.backtick:
                let count = run(of: unit, in: line, from: index, length)
                mark(NSRange(location: index, length: count))
                index += count
            case Unit.pipe:
                mark(NSRange(location: index, length: 1))
                index += 1
            case Unit.openBracket:
                guard let target = linkTarget(line, from: index, length) else { index += 1; continue }
                let opening = index > 0 && line[index - 1] == Unit.bang ? index - 1 : index
                mark(NSRange(location: opening, length: index + 1 - opening))
                mark(target)
                index += 1
            default:
                index += 1
            }
        }
    }

    /// The `](target)` that closes a `[label` opened at `start`, on the same line.
    private static func linkTarget(_ line: [unichar], from start: Int, _ length: Int) -> NSRange? {
        var cursor = start + 1
        while cursor + 1 < length, !(line[cursor] == Unit.closeBracket && line[cursor + 1] == Unit.openParen) {
            if line[cursor] == Unit.openBracket { return nil }
            cursor += 1
        }
        guard cursor + 1 < length else { return nil }
        var close = cursor + 2
        while close < length, line[close] != Unit.closeParen { close += 1 }
        guard close < length else { return nil }
        return NSRange(location: cursor, length: close + 1 - cursor)
    }

    /// `---`, `***` or `___`, optionally spaced: a thematic break or a heading underline.
    private static func isRule(_ line: [unichar], from start: Int, _ length: Int) -> Bool {
        let marker = line[start]
        guard marker == Unit.dash || marker == Unit.star || marker == Unit.underscore else { return false }
        var count = 0
        for index in start..<length {
            if line[index] == marker { count += 1 } else if line[index] != Unit.space { return false }
        }
        return count >= minimumRuleLength
    }

    /// `| --- | :-: |`: a pipe table's alignment row is structure from end to end.
    private static func isTableDivider(_ line: [unichar], from start: Int, _ length: Int) -> Bool {
        guard line[start] == Unit.pipe else { return false }
        var dashes = 0
        for index in start..<length {
            switch line[index] {
            case Unit.dash: dashes += 1
            case Unit.pipe, Unit.colon, Unit.space, Unit.tab: continue
            default: return false
            }
        }
        return dashes > 0
    }

    private static func run(of unit: unichar, in line: [unichar], from start: Int, _ length: Int) -> Int {
        var end = start
        while end < length, line[end] == unit { end += 1 }
        return end - start
    }

    private static func isDigit(_ unit: unichar) -> Bool { unit >= Unit.zero && unit <= Unit.nine }
}
