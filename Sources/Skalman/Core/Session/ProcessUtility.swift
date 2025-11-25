import Foundation
import Darwin

/// Information about a process.
struct ProcessDetails {
    let pid: pid_t
    let parentPid: pid_t
    let command: String
    let workingDirectory: String?
    let startTime: Date?
}

/// Resource usage for a process.
struct ProcessResourceUsage {
    let cpuTime: UInt64      // Total CPU time in nanoseconds
    let memoryBytes: UInt64  // Physical memory footprint
}

/// Utility for querying process information.
enum ProcessUtility {

    /// Finds all processes system-wide and returns those that are children of our app.
    static func findAllChildProcesses() -> [pid_t] {
        let ourPid = getpid()

        var allPids = [pid_t](repeating: 0, count: 4096)
        let bufferSize = Int32(allPids.count * MemoryLayout<pid_t>.size)
        let count = proc_listallpids(&allPids, bufferSize)

        guard count > 0 else { return [] }

        let numPids = Int(count)
        var children: [pid_t] = []

        for i in 0..<numPids {
            let pid = allPids[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))

            if result == size && taskInfo.pbi_ppid == ourPid {
                children.append(pid)
            }
        }

        return children
    }

    /// Gets the working directory for a given process ID.
    static func workingDirectory(forPid pid: pid_t) -> URL? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(size))

        guard result == size else { return nil }

        let path = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cpath in
                String(cString: cpath)
            }
        }

        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Gets detailed process information for a given PID.
    static func getProcessInfo(forPid pid: pid_t) -> ProcessDetails? {
        var taskInfo = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))

        guard result == size else { return nil }

        let command = withUnsafePointer(to: &taskInfo.pbi_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cpath in
                String(cString: cpath)
            }
        }

        let cwd = workingDirectory(forPid: pid)?.path

        // Get process start time from pbi_start_tvsec (seconds since epoch)
        let startTime: Date?
        if taskInfo.pbi_start_tvsec > 0 {
            startTime = Date(timeIntervalSince1970: TimeInterval(taskInfo.pbi_start_tvsec))
        } else {
            startTime = nil
        }

        return ProcessDetails(
            pid: pid,
            parentPid: pid_t(taskInfo.pbi_ppid),
            command: command,
            workingDirectory: cwd,
            startTime: startTime
        )
    }

    /// Gets all direct children of a given process.
    static func getProcessChildren(forPid parentPid: pid_t) -> [pid_t] {
        var allPids = [pid_t](repeating: 0, count: 4096)
        let bufferSize = Int32(allPids.count * MemoryLayout<pid_t>.size)
        let count = proc_listallpids(&allPids, bufferSize)

        guard count > 0 else { return [] }

        let numPids = Int(count)
        var children: [pid_t] = []

        for i in 0..<numPids {
            let pid = allPids[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))

            if result == size && taskInfo.pbi_ppid == parentPid {
                children.append(pid)
            }
        }

        return children
    }

    /// Gets resource usage (CPU time, memory) for a process.
    static func getResourceUsage(forPid pid: pid_t) -> ProcessResourceUsage? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
        }

        guard result == 0 else { return nil }

        return ProcessResourceUsage(
            cpuTime: usage.ri_user_time + usage.ri_system_time,
            memoryBytes: usage.ri_phys_footprint
        )
    }

    /// Checks if a process with the given PID exists.
    static func processExists(pid: pid_t) -> Bool {
        var taskInfo = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))
        return result == size
    }
}
