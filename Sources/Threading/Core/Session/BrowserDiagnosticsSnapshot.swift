import Foundation

// MARK: - Snapshot

/// What a page reported about itself at one moment: timings, console, network and accessibility.
///
/// **Bounded and versioned, exactly like the visual attribution state.** The plan this comes from is
/// explicit that none of these is free just because pixels already work — each needs its own
/// before/after snapshot with its own caps, or the baseline store quietly becomes a generic
/// diagnostics database.
///
/// **Console and network carry a window.** The live buffers clear on their own schedule, so "this
/// 404 is new" is meaningless without saying what interval was looked at. Both halves of a
/// comparison state their window, and a comparison across windows of very different lengths says so
/// rather than pretending the counts are comparable.
struct BrowserDiagnosticsSnapshot: Codable, Equatable, Sendable {

    /// Timings, from the same bounded report `browser_performance` returns.
    struct Performance: Codable, Equatable, Sendable {
        let timeToFirstByte: Double?
        let domContentLoaded: Double?
        let loadComplete: Double?
        let firstContentfulPaint: Double?
        let largestContentfulPaint: Double?
        let cumulativeLayoutShift: Double?
        let longTaskCount: Int
        let longTaskDuration: Double
        let resourceCount: Int
        let resourceTransferSize: Int

        private enum CodingKeys: String, CodingKey {
            case timeToFirstByte = "ttfb"
            case domContentLoaded = "dom_content_loaded"
            case loadComplete = "load_complete"
            case firstContentfulPaint = "fcp"
            case largestContentfulPaint = "lcp"
            case cumulativeLayoutShift = "cls"
            case longTaskCount = "long_task_count"
            case longTaskDuration = "long_task_duration"
            case resourceCount = "resource_count"
            case resourceTransferSize = "resource_transfer_size"
        }
    }

    /// One console line reduced to what can be matched across two captures.
    ///
    /// The message is truncated and its digits are masked, because a line carrying a timestamp, an
    /// id or a retry counter is otherwise "new" on every single capture. What survives is the shape
    /// of the message, which is what "you introduced a new warning" actually means.
    struct ConsoleEntry: Codable, Equatable, Sendable, Hashable {
        let level: String
        let fingerprint: String
        let count: Int

        /// What "the same line" means across two captures. Deliberately excludes `count`: a
        /// warning that happened forty times instead of once is the *same* warning, and folding
        /// the count into identity would report it as both new and gone at once.
        var identity: String { "\(level)|\(fingerprint)" }
    }

    /// One request, reduced the same way. The URL is redacted before it gets here.
    struct NetworkEntry: Codable, Equatable, Sendable, Hashable {
        let method: String
        let fingerprint: String
        let status: Int?
        let isError: Bool
        let count: Int

        /// Status is part of identity and count is not: the same request now returning 500 is the
        /// news, while the same request happening more often is not.
        var identity: String {
            "\(method)|\(fingerprint)|\(status.map(String.init) ?? "-")"
        }
    }

    /// One accessibility finding. Matched on rule and element description, never on a ref: refs are
    /// document-local and mean nothing across two captures.
    struct AccessibilityFinding: Codable, Equatable, Sendable, Hashable {
        let severity: String
        let code: String
        let element: String

        var identity: String { "\(severity)|\(code)|\(element)" }
    }

    let schemaVersion: Int
    let capturedAt: Date
    /// The interval the console and network entries were collected over, when it is known. A
    /// capture taken from a buffer of unknown age says so by leaving this absent.
    let windowStart: Date?
    let windowEnd: Date?
    let performance: Performance?
    let console: [ConsoleEntry]
    let network: [NetworkEntry]
    let accessibility: [AccessibilityFinding]
    /// Whether any of the lists hit its cap, so a missing entry can be read as "not recorded"
    /// rather than "not there".
    let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case performance, console, network, accessibility, truncated
        case schemaVersion = "schema_version"
        case capturedAt = "captured_at"
        case windowStart = "window_start"
        case windowEnd = "window_end"
    }

    var windowSeconds: Double? {
        guard let windowStart, let windowEnd else { return nil }
        return max(0, windowEnd.timeIntervalSince(windowStart))
    }
}

// MARK: - Fingerprints

/// Reduces a page-authored string to something that can be matched across two captures.
///
/// Every rule here exists because of a way the naive version failed. Digits are masked because a
/// message carrying a timestamp, a request id or a retry count is otherwise new every time. Case is
/// left alone because it distinguishes real messages. Length is capped because a stack trace pasted
/// into a warning is not an identity.
enum BrowserDiagnosticsFingerprint {

    static func of(_ value: String, limit: Int = BrowserDiagnosticsDefaults.maximumFingerprint) -> String {
        var collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        collapsed = collapsed.replacingOccurrences(
            of: #"\d+"#,
            with: "#",
            options: .regularExpression
        )
        return String(collapsed.prefix(limit))
    }

    /// A URL's shape: scheme, host and path with numeric and UUID-looking segments masked, so one
    /// resource fetched for a hundred ids is one entry rather than a hundred.
    static func ofURL(_ value: String) -> String {
        guard let components = URLComponents(string: value) else { return of(value) }
        let path = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let text = String(segment)
                if text.isEmpty { return text }
                if text.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil {
                    return "*"
                }
                if text.range(of: #"^\d+$"#, options: .regularExpression) != nil { return "*" }
                return text
            }
            .joined(separator: "/")
        let host = components.host ?? ""
        let scheme = components.scheme ?? ""
        return String("\(scheme)://\(host)\(path)".prefix(BrowserDiagnosticsDefaults.maximumFingerprint))
    }
}

// MARK: - Comparison

/// What changed between two diagnostics snapshots.
///
/// **Noise is reported separately from the verdict.** A timing that moved by three milliseconds is
/// not a regression, and a comparator that presented it as one would train everybody to ignore the
/// whole report. Timings therefore carry both the delta and whether it cleared the noise floor, and
/// nothing here calls a run "worse" on its own.
struct BrowserDiagnosticsComparison: Equatable, Sendable {

    struct TimingChange: Equatable, Sendable {
        let name: String
        let before: Double?
        let after: Double?
        /// Whether the change is larger than what two runs of the same page differ by anyway.
        let exceedsNoiseFloor: Bool

        var delta: Double? {
            guard let before, let after else { return nil }
            return after - before
        }
    }

    let timings: [TimingChange]
    let consoleAdded: [BrowserDiagnosticsSnapshot.ConsoleEntry]
    let consoleRemoved: [BrowserDiagnosticsSnapshot.ConsoleEntry]
    let networkAdded: [BrowserDiagnosticsSnapshot.NetworkEntry]
    let networkRemoved: [BrowserDiagnosticsSnapshot.NetworkEntry]
    let accessibilityAdded: [BrowserDiagnosticsSnapshot.AccessibilityFinding]
    let accessibilityRemoved: [BrowserDiagnosticsSnapshot.AccessibilityFinding]
    /// Set when the two console/network windows are too different in length for their counts to be
    /// compared honestly.
    let windowMismatch: String?

    var hasChanges: Bool {
        !consoleAdded.isEmpty || !consoleRemoved.isEmpty
            || !networkAdded.isEmpty || !networkRemoved.isEmpty
            || !accessibilityAdded.isEmpty || !accessibilityRemoved.isEmpty
            || timings.contains { $0.exceedsNoiseFloor }
    }
}

enum BrowserDiagnosticsComparator {

    static func compare(
        baseline: BrowserDiagnosticsSnapshot,
        actual: BrowserDiagnosticsSnapshot
    ) -> BrowserDiagnosticsComparison {
        var timings: [TimingPair] = []
        if let before = baseline.performance, let after = actual.performance {
            timings = [
                TimingPair("TTFB", before.timeToFirstByte, after.timeToFirstByte),
                TimingPair("DOMContentLoaded", before.domContentLoaded, after.domContentLoaded),
                TimingPair("Load complete", before.loadComplete, after.loadComplete),
                TimingPair("FCP", before.firstContentfulPaint, after.firstContentfulPaint),
                TimingPair("LCP", before.largestContentfulPaint, after.largestContentfulPaint),
                TimingPair(
                    "Long tasks",
                    Double(before.longTaskCount),
                    Double(after.longTaskCount),
                    floor: BrowserDiagnosticsDefaults.countNoiseFloor
                ),
                TimingPair(
                    "Layout shift",
                    before.cumulativeLayoutShift,
                    after.cumulativeLayoutShift,
                    floor: BrowserDiagnosticsDefaults.layoutShiftNoiseFloor
                )
            ]
        }

        // Counts are only comparable over comparable windows. Rather than silently normalising —
        // which would invent a rate the page never reported — the mismatch is stated and the
        // membership comparison (what is new, what is gone) is left to stand on its own.
        var windowMismatch: String?
        if let before = baseline.windowSeconds, let after = actual.windowSeconds,
           before > 0, after > 0 {
            let ratio = max(before, after) / min(before, after)
            if ratio > BrowserDiagnosticsDefaults.maximumWindowRatio {
                windowMismatch = L10n.format(
                    "the two capture windows are %lld and %lld seconds long, so counts are not comparable",
                    Int64(before.rounded()),
                    Int64(after.rounded())
                )
            }
        }

        return BrowserDiagnosticsComparison(
            timings: timings.map(\.change),
            consoleAdded: difference(actual.console, baseline.console, by: \.identity),
            consoleRemoved: difference(baseline.console, actual.console, by: \.identity),
            networkAdded: difference(actual.network, baseline.network, by: \.identity),
            networkRemoved: difference(baseline.network, actual.network, by: \.identity),
            accessibilityAdded: difference(actual.accessibility, baseline.accessibility, by: \.identity),
            accessibilityRemoved: difference(baseline.accessibility, actual.accessibility, by: \.identity),
            windowMismatch: windowMismatch
        )
    }

    /// Set membership on identity, not on the whole value: "this warning is new" is a different
    /// claim from "this warning happened more often", and only the first survives a short window.
    ///
    /// The distinction is easy to lose. `count` is part of these values because it is worth
    /// showing, and any `Set` built on the value itself would therefore report one warning that
    /// happened more often as both added and removed.
    private static func difference<Element>(
        _ lhs: [Element],
        _ rhs: [Element],
        by identity: (Element) -> String
    ) -> [Element] {
        let known = Set(rhs.map(identity))
        return lhs.filter { !known.contains(identity($0)) }
    }

    private struct TimingPair {
        let name: String
        let before: Double?
        let after: Double?
        let floor: Double

        init(_ name: String, _ before: Double?, _ after: Double?, floor: Double = BrowserDiagnosticsDefaults.timingNoiseFloor) {
            self.name = name
            self.before = before
            self.after = after
            self.floor = floor
        }

        var change: BrowserDiagnosticsComparison.TimingChange {
            let delta = before.flatMap { before in after.map { abs($0 - before) } } ?? 0
            let hasPair = before != nil && after != nil
            return BrowserDiagnosticsComparison.TimingChange(
                name: name,
                before: before,
                after: after,
                exceedsNoiseFloor: hasPair && delta > floor
            )
        }
    }
}

// MARK: - Defaults

enum BrowserDiagnosticsDefaults {
    static let schemaVersion = 1

    static let maximumConsoleEntries = 40
    static let maximumNetworkEntries = 60
    static let maximumAccessibilityFindings = 40
    static let maximumFingerprint = 160

    /// One capture's serialized state.
    static let maximumBytes = 512 * 1_024

    /// How much two runs of the same page differ by anyway. Milliseconds: below this a timing
    /// change is measurement noise, and calling it a regression would train everyone to ignore the
    /// report. Provisional, and stated as such in `agent-browser.md` — the honest value comes from
    /// measuring repeat captures of one unchanged page.
    static let timingNoiseFloor: Double = 40

    /// Long-task counts are integers, so anything above one is a real change.
    static let countNoiseFloor: Double = 1

    /// Cumulative layout shift is unitless and small; 0.01 is the smallest shift anybody notices.
    static let layoutShiftNoiseFloor: Double = 0.01

    /// How different two console/network windows may be before their counts stop being comparable.
    static let maximumWindowRatio: Double = 3
}
