import Foundation
import ThreadingPTYHostKit

// MARK: - Text

/// How the command-line client turns the daemon's vocabulary into lines a person reads.
///
/// Plain aligned text, one line per row, no colour and no progress. The reader is at a shell
/// prompt and may be piping this into `grep`; a spinner would be noise in a pipe and a colour
/// code would be a byte in a diff.
///
/// Every function here is pure, so what the tool prints is testable without a daemon.
enum PTYHostCLIFormatting {

    // MARK: - Identity

    /// The leading characters of a session id, which is what a person types back at `stop`.
    ///
    /// A session id is a UUID string, so the first eight characters separate the sessions one
    /// machine holds without asking anybody to read thirty-six. It is a *display* shortening
    /// only: `stop` matches a prefix of any length against the whole id, so an ambiguous eight
    /// characters can always be disambiguated by typing more.
    static func shortIdentifier(_ identity: PTYHostSessionIdentity) -> String {
        String(identity.description.prefix(PTYHostCLIDefaults.shortIdentifierLength))
    }

    // MARK: - Values

    /// How long ago something started, as a person says it.
    ///
    /// Two units, never three: "3h 12m" is the question a wedged agent raises and the seconds in
    /// it are noise. The largest unit decides the pair, so the answer stays the same width as it
    /// grows.
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let total = Int(max(now.timeIntervalSince(start), 0).rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// A window size, or a dash for a session that has no terminal.
    ///
    /// A `.pipes` session reports zeroes rather than a plausible 80x24, because a window size it
    /// does not have is a fact somebody would act on. The dash carries that through instead of
    /// printing "0x0", which reads as a broken terminal rather than as no terminal.
    static func grid(_ grid: PTYHostGrid) -> String {
        guard grid.cols > 0 || grid.rows > 0 else { return "-" }
        return "\(grid.cols)x\(grid.rows)"
    }

    /// What a row says about a session's state.
    static func state(_ summary: PTYHostSessionSummary) -> String {
        if summary.exit != nil { return "exited" }
        return summary.isAttached ? "attached" : "detached"
    }

    /// The exit status, or a dash while the child is still running.
    static func exitStatus(_ summary: PTYHostSessionSummary) -> String {
        guard let exit = summary.exit else { return "-" }
        return String(exit)
    }

    /// The name of the program, without the path the app happened to name it by.
    static func command(_ executable: String) -> String {
        (executable as NSString).lastPathComponent
    }

    // MARK: - Tables

    /// Left-aligned columns, padded to the widest cell, two spaces between.
    ///
    /// The last column is never padded, so a long executable path cannot push trailing spaces
    /// into whatever is reading this. Rows of differing length are tolerated: a short row simply
    /// ends, which is what makes the same function usable for the label/value pairs `status`
    /// prints and for the header/body table `sessions` prints.
    static func table(_ rows: [[String]]) -> [String] {
        guard !rows.isEmpty else { return [] }
        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated()
                .map { index, cell in
                    index == row.count - 1 ? cell : cell.padding(
                        toLength: widths[index],
                        withPad: " ",
                        startingAt: 0
                    )
                }
                .joined(separator: PTYHostCLIDefaults.columnGap)
                // A short row's own last cell is not padded, but an earlier row may have padded
                // past it; trimming here keeps every line free of trailing space.
                .replacingOccurrences(
                    of: "\\s+$",
                    with: "",
                    options: .regularExpression
                )
        }
    }
}

// MARK: - Registration

/// What launchd says about the agent that starts this daemon.
///
/// **Read through `launchctl`, not through ServiceManagement.** The daemon may link Foundation,
/// Darwin, Dispatch and the wire package and nothing else, which is the lint that keeps its
/// safety argument true; the app's own `PTYHostRegistration` is the one place that talks to
/// `SMAppService`, and it lives in the app. So the tool asks the same question the way a person
/// at a prompt would, and parses the answer.
///
/// Three answers, because they mean different things to whoever is reading. Registered and
/// running is the ordinary case. Registered and not running is launchd holding a job it has not
/// started, or has stopped restarting. Not registered is launchd having never been told, which is
/// the one that explains a socket nobody is listening on.
enum PTYHostCLIRegistration: Equatable {

    /// launchd holds the job. `state` is its own word for what it is doing, and `pid` is set only
    /// while it has a running process.
    case registered(state: String?, pid: Int32?)

    /// launchd has never heard of the label, or has forgotten it.
    case notRegistered

    /// `launchctl` said something this build cannot read. Carried rather than flattened into
    /// `notRegistered`, because "I could not tell" and "it is not there" would send somebody
    /// looking in two different places.
    case unreadable(String)

    /// What `status` says about the label, with the label itself supplied by the caller so the
    /// line reads as one sentence about one service.
    var sentence: String {
        switch self {
        case .registered(let state, let pid):
            var parts: [String] = []
            if let state, !state.isEmpty { parts.append("state \(state)") }
            if let pid { parts.append("pid \(pid)") }
            guard !parts.isEmpty else { return "is registered" }
            return "is registered: " + parts.joined(separator: ", ")
        case .notRegistered:
            return "is not registered"
        case .unreadable(let detail):
            return "could not be read from launchctl: \(detail)"
        }
    }

    // MARK: - Parsing

    /// Reads one `launchctl print gui/<uid>/<label>` answer.
    ///
    /// `launchctl` writes its refusal to standard output on some releases and standard error on
    /// others, so the caller hands both in as one string and the shape of the text decides rather
    /// than which descriptor it arrived on. The exit status is not the discriminator either: it
    /// is non-zero for "no such service" and for "bad domain" alike, and those are not the same
    /// finding.
    static func parse(output: String, status: Int32) -> PTYHostCLIRegistration {
        if output.contains(PTYHostCLIDefaults.launchctlMissingServiceMarker) {
            return .notRegistered
        }
        guard status == 0 else {
            let firstLine = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "exit \(status)"
            return .unreadable(firstLine)
        }
        return .registered(state: value(of: "state", in: output), pid: pid(in: output))
    }

    /// The right-hand side of a `key = value` line, at any indentation.
    ///
    /// Matched on the whole line rather than searched for as a substring: `launchctl` prints
    /// `spawn type`, `program identifier` and a dozen other keys that end in the ones being
    /// asked for, and a substring search would answer with whichever came first.
    private static func value(of key: String, in output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + " ") || trimmed.hasPrefix(key + "=") else { continue }
            let remainder = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard remainder.hasPrefix("=") else { continue }
            let answer = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
            return answer.isEmpty ? nil : answer
        }
        return nil
    }

    private static func pid(in output: String) -> Int32? {
        guard let raw = value(of: "pid", in: output) else { return nil }
        return Int32(raw)
    }
}
