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
    /// Exact process name, not a substring of another process's message.
    public let process: String?
    /// Exact subsystem, so "App packets only" in the Bluetooth tab cannot also match a packet whose
    /// message happens to contain the letters.
    public let subsystem: String?
    /// Rows whose message contains this (case-insensitively) are not matches. "Fully decoded
    /// only" uses it to drop app packets whose bytes did not fit their definition: their level
    /// cannot say so, because an app's own definitions may rightly call a packet an error.
    public let excluding: String?

    /// The pattern folded to lowercase bytes, once.
    ///
    /// The search below is byte-wise for a measured reason. Over a full ring this runs 50,000
    /// times per drain, and both obvious spellings were too slow to leave on: `lowercased()` per
    /// field allocated three Strings a row and took 57 ms, and `range(of:options:.caseInsensitive)`
    /// bridges into ICU and took 158 ms. A log line is bytes.
    private let needle: [UInt8]
    private let excludedNeedle: [UInt8]?
    public let textMode: DeviceLogPanelFilter.TextMode
    public let levels: [String]
    public let bundleID: String?
    public let pid: Int?
    public let category: String?
    public let sourceBundleID: String?
    public let sourceProcess: String?
    /// A source-mode constraint, intersected with the user's independent subsystem filter.
    public let requiredSubsystem: String?
    private let acceptedLevels: Set<String>
    private let regularExpression: NSRegularExpression?

    public init(
        pattern: String = "", minimumSeverity: Int = 0, context: Int = 2,
        process: String? = nil, subsystem: String? = nil, excluding: String? = nil,
        textMode: DeviceLogPanelFilter.TextMode = .literal, levels: [String] = [],
        bundleID: String? = nil, pid: Int? = nil, category: String? = nil,
        sourceBundleID: String? = nil, sourceProcess: String? = nil, requiredSubsystem: String? = nil
    ) {
        self.textMode = textMode
        self.levels = levels
        self.bundleID = bundleID
        self.pid = pid
        self.category = category
        self.sourceBundleID = sourceBundleID
        self.sourceProcess = sourceProcess
        self.requiredSubsystem = requiredSubsystem
        self.acceptedLevels = Set(levels.map(Self.canonicalLevel))
        self.regularExpression = textMode == .regex
            ? try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) : nil
        self.pattern = pattern
        self.minimumSeverity = minimumSeverity
        self.context = context
        self.process = process
        self.subsystem = subsystem
        self.excluding = excluding
        self.needle = Self.foldedASCII(pattern)
        self.excludedNeedle = excluding.map(Self.foldedASCII)
    }

    /// Nothing is folded when nothing has been asked for.
    public var isActive: Bool {
        !pattern.isEmpty || minimumSeverity > 0 || !levels.isEmpty || process != nil
            || subsystem != nil || requiredSubsystem != nil || excluding != nil || bundleID != nil || pid != nil || category != nil
    }

    /// Whether this row is one of the ones being looked for — which is also what gets highlighted.
    /// Context rows are shown but are not matches, so the eye still lands on the reason.
    public func matches(_ row: DeviceLogRow) -> Bool { evaluation(of: row).matches }

    /// Export callers also disclose when the explicit regex safety budget limited evaluation.
    func evaluation(of row: DeviceLogRow, deadline: UInt64? = nil) -> (matches: Bool, limited: Bool) {
        guard process == nil || row.process == process else { return (false, false) }
        guard bundleID == nil || row.bundleID == bundleID
            || (row.bundleID == nil && sourceBundleID == bundleID && sourceProcess == row.process) else { return (false, false) }
        guard pid == nil || row.pid == pid else { return (false, false) }
        guard category == nil || row.category == category else { return (false, false) }
        guard acceptedLevels.isEmpty || acceptedLevels.contains(Self.canonicalLevel(row.level)) else { return (false, false) }
        guard subsystem == nil || row.subsystem == subsystem else { return (false, false) }
        guard requiredSubsystem == nil || row.subsystem == requiredSubsystem else { return (false, false) }
        guard minimumSeverity == 0 || row.severity >= minimumSeverity else { return (false, false) }
        if let excludedNeedle, Self.contains(row.message, excludedNeedle) { return (false, false) }
        guard !pattern.isEmpty else { return (true, false) }
        if textMode == .regex {
            guard let regularExpression else { return (false, true) }
            var limited = false
            for field in [row.message, row.process, row.subsystem ?? "", row.category ?? ""] {
                let result = Self.regexMatches(regularExpression, text: field, deadline: deadline)
                limited = limited || result.limited
                if result.matches { return (true, limited) }
            }
            return (false, limited)
        }
        return (Self.contains(row.message, needle)
            || Self.contains(row.process, needle)
            || (row.subsystem.map { Self.contains($0, needle) } ?? false)
            || (row.category.map { Self.contains($0, needle) } ?? false), false)
    }

    private static func foldedASCII(_ value: String) -> [UInt8] {
        value.utf8.map { (65...90).contains($0) ? $0 | 0x20 : $0 }
    }

    private static func canonicalLevel(_ value: String) -> String {
        switch value.lowercased() {
        case "default": return "notice"
        case "emergency", "alert", "critical": return "fault"
        case "trace", "log": return "debug"
        default: return value.lowercased()
        }
    }

    /// ICU periodically calls the progress handler even before a match. Abort expensive patterns
    /// cooperatively, and never feed it an unbounded device payload.
    private static func regexMatches(_ expression: NSRegularExpression, text: String, deadline aggregateDeadline: UInt64?) -> (matches: Bool, limited: Bool) {
        let input = String(text.prefix(4_096))
        let deadline = min(DispatchTime.now().uptimeNanoseconds + 2_000_000, aggregateDeadline ?? .max)
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return (false, true) }
        var found = false
        var limited = input.utf8.count < text.utf8.count
        expression.enumerateMatches(in: input, options: [.reportProgress, .reportCompletion],
                                    range: NSRange(input.startIndex..., in: input)) { match, _, stop in
            if match != nil { found = true; stop.pointee = true }
            if Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline { limited = true; stop.pointee = true }
        }
        return (found, limited)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pattern == rhs.pattern && lhs.minimumSeverity == rhs.minimumSeverity
            && lhs.context == rhs.context && lhs.process == rhs.process
            && lhs.subsystem == rhs.subsystem && lhs.excluding == rhs.excluding
            && lhs.textMode == rhs.textMode && lhs.levels == rhs.levels
            && lhs.bundleID == rhs.bundleID && lhs.pid == rhs.pid && lhs.category == rhs.category
            && lhs.sourceBundleID == rhs.sourceBundleID && lhs.sourceProcess == rhs.sourceProcess
            && lhs.requiredSubsystem == rhs.requiredSubsystem
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
        if let result = haystack.utf8.withContiguousStorageIfAvailable({ buffer in
            search(buffer, needle)
        }) {
            return result
        }
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
        expanded: Set<Int> = [],
        showingContext: Bool = true,
        evaluationDeadline: UInt64? = nil
    ) -> [LogDisplayEntry] {
        guard focus.isActive, !rows.isEmpty else {
            return rows.indices.map { .row($0) }
        }
        if !showingContext {
            return rows.indices.compactMap { index in
                if let evaluationDeadline, DispatchTime.now().uptimeNanoseconds >= evaluationDeadline { return nil }
                return focus.evaluation(of: rows[index], deadline: evaluationDeadline).matches ? .row(index) : nil
            }
        }

        // Matches arrive in row order, so their context windows can be merged as they are found.
        // Keeping intervals avoids allocating and then walking a full-ring bitmap on every drain.
        let context = max(0, focus.context)
        var keptRanges: [Range<Int>] = []
        keptRanges.reserveCapacity(min(rows.count, 1_024))
        for (index, row) in rows.enumerated() {
            if index % 128 == 0, Task.isCancelled { return [] }
            if let evaluationDeadline, DispatchTime.now().uptimeNanoseconds >= evaluationDeadline { break }
            guard focus.evaluation(of: row, deadline: evaluationDeadline).matches else { continue }
            let lower = max(0, index - context)
            let upper = min(rows.count, index + context + 1)
            if let previous = keptRanges.last, lower <= previous.upperBound {
                keptRanges[keptRanges.count - 1] = previous.lowerBound..<max(previous.upperBound, upper)
            } else {
                keptRanges.append(lower..<upper)
            }
        }

        var entries: [LogDisplayEntry] = []
        func appendGap(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            // An opened fold shows its rows and keeps its place, so closing it again is where the
            // reader left off rather than wherever the list settled.
            if expanded.contains(range.lowerBound) {
                for index in range { entries.append(.row(index)) }
            } else {
                entries.append(.gap(range))
            }
        }

        var cursor = 0
        for range in keptRanges {
            appendGap(cursor..<range.lowerBound)
            for index in range { entries.append(.row(index)) }
            cursor = range.upperBound
        }
        appendGap(cursor..<rows.count)
        return entries
    }
}
