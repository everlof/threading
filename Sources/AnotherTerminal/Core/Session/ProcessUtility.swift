import Foundation
import Darwin

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
}
