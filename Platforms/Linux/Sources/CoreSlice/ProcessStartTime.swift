import Foundation
import ThreadingPTYHostKit
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The other half of a process identity: a pid alone can be reused after a crash.
/// Darwin reports microseconds; Linux reports ticks plus boot time, matching the daemon.
struct ProcessStartTime: Equatable, Codable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    static func read(forPid pid: pid_t) -> ProcessStartTime? {
        guard pid > 0 else { return nil }
#if os(Linux)
        let frequency = sysconf(Int32(_SC_CLK_TCK))
        guard let stat = readProcFile("/proc/\(pid)/stat"),
              let ticks = PTYHostProcStat.startTicks(fromStat: stat),
              let boot = readProcFile("/proc/stat").flatMap(PTYHostProcStat.bootTime),
              frequency > 0 else { return nil }
        let hertz = UInt64(frequency)
        return ProcessStartTime(seconds: boot + ticks / hertz,
                                microseconds: (ticks % hertz) * 1_000_000 / hertz)
#else
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        return ProcessStartTime(seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec))
#endif
    }

#if os(Linux)
    private static func readProcFile(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let maximumBytes = 1_024 * 1_024
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
#endif
}
