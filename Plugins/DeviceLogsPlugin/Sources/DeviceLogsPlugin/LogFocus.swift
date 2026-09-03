import Foundation

/// What matters right now, and what may be folded away until it does.
///
/// Filtering and focusing are not the same thing, and the difference is the whole point. A filter
/// *removes* what does not match, so the answer to "what happened just before this error" is gone.
/// A focus keeps everything and folds the uninteresting runs into a marker that says how many are
/// in there, so the surrounding lines are one click away.
///
/// This is the shape an agent debugging drives: it says what matters, the rest collapses, and the
/// evidence either side is still reachable.
public struct LogFocus: Equatable, Sendable {

    /// Case-insensitive substring over message, process and subsystem. Empty means no text test.
    public let pattern: String

    /// Rows below this `severity` are not matches. 0 means no level test.
    public let minimumSeverity: Int

    /// Rows kept either side of a match. A line on its own rarely explains itself; the two before
    /// it usually do, which is why `grep -C` exists.
    public let context: Int

    /// The pattern folded to lowercase bytes, once.
    ///
    /// The search below is byte-wise for a measured reason. Over a full ring this runs 50,000
    /// times per drain, and both obvious spellings were too slow to leave on: `lowercased()` per
    /// field allocated three Strings a row and took 57 ms, and `range(of:options:.caseInsensitive)`
    /// bridges into ICU and took 158 ms. A log line is bytes.
    private let needle: [UInt8]

    public init(pattern: String = "", minimumSeverity: Int = 0, context: Int = 2) {
        self.pattern = pattern
        self.minimumSeverity = minimumSeverity
        self.context = context
        self.needle = Array(pattern.lowercased().utf8)
    }

    /// Nothing is folded when nothing has been asked for.
    public var isActive: Bool { !pattern.isEmpty || minimumSeverity > 0 }

    /// Whether this row is one of the ones being looked for — which is also what gets highlighted.
    /// Context rows are shown but are not matches, so the eye still lands on the reason.
    public func matches(_ row: DeviceLogRow) -> Bool {
        guard row.severity >= minimumSeverity else { return false }
        guard !pattern.isEmpty else { return true }
        return Self.contains(row.message, needle)
            || Self.contains(row.process, needle)
            || (row.subsystem.map { Self.contains($0, needle) } ?? false)
    }

    /// Case-insensitive substring over UTF-8, folding ASCII only.
    ///
    /// ASCII folding is the honest limit and it is the right one here: a log's identifiers,
    /// levels and symbol names are ASCII, and a byte that is not gets compared exactly — so
    /// searching for `Ä` still finds `Ä`, it just will not also find `ä`. Paying ICU's price on
    /// every row to change that would cost the feature its ability to stay on.
    @inline(__always)
    static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        var found = false
        haystack.utf8.withContiguousStorageIfAvailable { buffer in
            found = search(buffer, needle)
        }
        if found { return true }
        // A String without contiguous UTF-8 storage is rare; fall back rather than miss a match.
        return haystack.utf8.count >= needle.count && Array(haystack.utf8).withUnsafeBufferPointer {
            search($0, needle)
        }
    }

    @inline(__always)
    private static func search(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        let count = haystack.count
        let length = needle.count
        guard count >= length else { return false }
        let first = needle[0]
        var index = 0
        while index <= count - length {
            var byte = haystack[index]
            if byte >= 65, byte <= 90 { byte |= 0x20 }
            if byte == first {
                var offset = 1
                while offset < length {
                    var candidate = haystack[index + offset]
                    if candidate >= 65, candidate <= 90 { candidate |= 0x20 }
                    if candidate != needle[offset] { break }
                    offset += 1
                }
                if offset == length { return true }
            }
            index += 1
        }
        return false
    }
}

/// One line of the table: a real row, or a fold standing in for a run of them.
public enum LogDisplayEntry: Equatable, Sendable {
    case row(Int)
    case gap(Range<Int>)

    public var hiddenCount: Int {
        if case .gap(let range) = self { return range.count }
        return 0
    }
}

/// Turns rows plus a focus into the list the table draws.
///
/// A **value model**, deliberately: the table owns viewport views only, and a fold must cost
/// nothing for the rows inside it. Hiding views after building them would save pixels and not the
/// construction, layout or memory — which is the trap the Scaling Gate names.
public enum LogFocusLayout {

    /// `expanded` holds the lower bound of each fold the reader has opened.
    public static func entries(
        rows: [DeviceLogRow],
        focus: LogFocus,
        expanded: Set<Int> = []
    ) -> [LogDisplayEntry] {
        guard focus.isActive, !rows.isEmpty else {
            return rows.indices.map { .row($0) }
        }

        var kept = [Bool](repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() where focus.matches(row) {
            let lower = max(0, index - focus.context)
            let upper = min(rows.count - 1, index + focus.context)
            for neighbour in lower...upper { kept[neighbour] = true }
        }

        var entries: [LogDisplayEntry] = []
        var index = 0
        while index < rows.count {
            if kept[index] {
                entries.append(.row(index))
                index += 1
                continue
            }
            var end = index
            while end < rows.count, !kept[end] { end += 1 }
            let range = index..<end
            // An opened fold shows its rows and keeps its place, so closing it again is where the
            // reader left off rather than wherever the list settled.
            if expanded.contains(range.lowerBound) {
                entries.append(contentsOf: range.map { .row($0) })
            } else {
                entries.append(.gap(range))
            }
            index = end
        }
        return entries
    }
}
