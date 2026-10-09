import Foundation

// MARK: - /proc parsing

/// The two numbers the Linux start time is made of, read from text the kernel writes.
///
/// Pure functions over strings, so the parsing is tested on every platform rather than only where
/// `/proc` exists.
public enum PTYHostProcStat {

    /// Field 22 of `/proc/<pid>/stat`: the start time in clock ticks since boot.
    ///
    /// Field 2 is the command name in parentheses and may itself contain spaces and parentheses,
    /// so the fields are counted from the **last** closing parenthesis: the next field is 3.
    public static func startTicks(fromStat text: String) -> UInt64? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\n" })
        let index = 22 - 3
        guard fields.indices.contains(index) else { return nil }
        return UInt64(fields[index])
    }

    /// The `btime` line of `/proc/stat`: boot time in seconds since the epoch.
    public static func bootTime(fromProcStat text: String) -> UInt64? {
        for line in text.split(separator: "\n") where line.hasPrefix("btime ") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return nil }
            return UInt64(parts[1])
        }
        return nil
    }
}
