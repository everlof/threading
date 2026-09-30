#if os(Linux)
import Foundation
import Glibc
import ThreadingPTYHostKit

/// A bounded Linux process leaf. Callers anchor once from the daemon's authenticated root PID;
/// neither a failed read nor a reused PID is permission to anchor a different process later.
enum LinuxProcessDirectory {
    struct Identity: Equatable {
        let pid: Int32
        let startTicks: UInt64
    }

    static func identity(pid: Int32, expectedStartTime: PTYHostProcessStartTime) -> Identity? {
        guard pid > 0, let ticks = startTicks(pid: pid) else { return nil }
        // Match the daemon's Linux tick-to-epoch conversion. A PID on its own could name a new
        // process by the time an exited session's retained attachment reaches this window.
        let hertz = Glibc.sysconf(Int32(_SC_CLK_TCK))
        guard hertz > 0, let boot = bootTime(),
              expectedStartTime.seconds == boot + ticks / UInt64(hertz),
              expectedStartTime.microseconds == (ticks % UInt64(hertz)) * 1_000_000 / UInt64(hertz),
              startTicks(pid: pid) == ticks else { return nil }
        return Identity(pid: pid, startTicks: ticks)
    }

    static func directory(for identity: Identity) -> String? {
        guard startTicks(pid: identity.pid) == identity.startTicks else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = bytes.withUnsafeMutableBytes {
            Glibc.readlink("/proc/\(identity.pid)/cwd", $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
        }
        guard count > 0, count < bytes.count,
              startTicks(pid: identity.pid) == identity.startTicks,
              let path = String(bytes: bytes.prefix(count), encoding: .utf8),
              path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return path
    }

    private static func startTicks(pid: Int32) -> UInt64? {
        guard let text = readSmallFile("/proc/\(pid)/stat", limit: 8192),
              text.hasPrefix("\(pid) ("), let close = text.lastIndex(of: ")") else { return nil }
        // comm (field 2) may contain spaces and parentheses; fields after its final ')' start
        // at field 3. Field 22 is the immutable process start tick, never wall-clock time.
        let fields = text[text.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count > 19, fields[0] != "Z", fields[0] != "X" else { return nil }
        return UInt64(fields[19])
    }

    private static func bootTime() -> UInt64? {
        guard let text = readSmallFile("/proc/stat", limit: 256 * 1024),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }) else { return nil }
        return UInt64(line.dropFirst(6))
    }

    private static func readSmallFile(_ path: String, limit: Int) -> String? {
        let fd = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Glibc.close(fd) }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var used = 0
        // proc's seq_file reads may return a short chunk before EOF. Bound both total bytes and
        // syscall count, rather than assuming one read returned the complete btime record.
        for _ in 0..<64 {
            let count = bytes.withUnsafeMutableBytes {
                Glibc.read(fd, $0.baseAddress!.advanced(by: used), $0.count - used)
            }
            if count == 0 { return used > 0 ? String(bytes: bytes.prefix(used), encoding: .utf8) : nil }
            guard count > 0 else { return nil }
            used += count
            guard used < bytes.count else { return nil }
        }
        return nil
    }
}
#endif
