import Foundation

/// The tools Device Logs offers the agent.
///
/// The point of the set is that an agent debugging can *read its own log* and then say what
/// matters: search reaches back through everything recorded, focus folds the rest away, and what
/// is left is what a person looking over its shoulder sees too — the pane's own controls move, so
/// the user can see what was asked for and undo it.
public enum DeviceLogToolNames {
    public static let search = "search"
    public static let focus = "focus"
    public static let clearFocus = "clear_focus"
    public static let timeRange = "time_range"
    public static let visible = "visible"
}

/// How many rows a tool will put in one answer.
///
/// A log is unbounded and a reply is not: a search that matched forty thousand lines and returned
/// them would bury the answer and cost more than the question. The count is always reported, so a
/// truncated answer says it is truncated.
public enum DeviceLogToolLimits {
    public static let rowsPerAnswer = 50
    public static let searchScan = 1_000
}

/// Renders rows the way an agent reads them: one line each, no table drawing.
public enum DeviceLogToolFormatting {

    public static func lines(_ rows: [DeviceLogRow]) -> String {
        rows.map { row in
            let subsystem = row.subsystem.map { " (\($0))" } ?? ""
            return "\(row.time)  \(row.level)  \(row.process)\(subsystem)  \(row.message)"
        }.joined(separator: "\n")
    }

    /// An answer that says how much it is not showing.
    public static func answer(rows: [DeviceLogRow], total: Int, subject: String) -> String {
        guard !rows.isEmpty else { return "No rows \(subject)." }
        var text = "\(total) \(total == 1 ? "row" : "rows") \(subject)"
        if total > rows.count { text += ", showing the last \(rows.count)" }
        return text + ":\n" + lines(rows)
    }
}

/// The level names a tool accepts, mapped onto the ordering the rows use.
public enum DeviceLogToolLevels {

    public static func severity(named name: String?) -> Int {
        switch name?.lowercased() {
        case "fault", "critical", "emergency", "alert": return 4
        case "error": return 3
        case "warning", "notice", "default": return 2
        case "info": return 1
        default: return 0
        }
    }

    public static let accepted = ["debug", "info", "notice", "warning", "error", "fault"]
}
