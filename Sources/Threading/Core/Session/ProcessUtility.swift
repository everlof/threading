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

/// The cheap half of `ProcessDetails`: what one pass over the process table can answer without
/// a further syscall per process. Enough to reconstruct parentage and name a process.
struct ProcessSummary {
    let pid: pid_t
    let parentPid: pid_t
    let command: String
}

/// Utility for querying process information.
enum ProcessUtility {

    /// Every live pid, with the buffer sized from the kernel's own count.
    ///
    /// `proc_listallpids` fills whatever buffer it is handed and returns how many it wrote, and a
    /// **full** buffer is indistinguishable from a machine that happens to have exactly that many
    /// processes. Three walks here each passed a fixed 4096, so on a busy machine the list was
    /// silently cut off — and the info panel above it reported "Processes 12" with no way to know
    /// it had been handed a truncated table. A short answer now means *that is all of them*:
    /// the count is asked for first, and a reply that fills the buffer is grown and asked again.
    ///
    /// The one case that cannot be resolved by growing is reported rather than trimmed away,
    /// because a process list quietly missing entries is the failure this exists to end.
    static func liveProcessIdentifiers() -> [pid_t] {
        var capacity = max(Int(proc_listallpids(nil, 0)), ProcessScan.minimumProcesses)

        for attempt in 1...ProcessScan.attempts {
            capacity += ProcessScan.headroom

            var pids = [pid_t](repeating: 0, count: capacity)
            let written = proc_listallpids(
                &pids,
                Int32(capacity * MemoryLayout<pid_t>.size)
            )
            guard written > 0 else { return [] }

            let count = Int(written)
            if count < capacity {
                return pids.prefix(count).filter { $0 > 0 }
            }

            if attempt == ProcessScan.attempts {
                ThreadingLogger.session.error(
                    """
                    Process table filled a \(capacity, privacy: .public)-pid buffer after \
                    \(attempt, privacy: .public) attempts; the list may be short.
                    """
                )
                return pids.filter { $0 > 0 }
            }
        }

        return []
    }

    /// Finds all processes system-wide and returns those that are children of our app.
    static func findAllChildProcesses() -> [pid_t] {
        getProcessChildren(forPid: getpid())
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
        liveProcessIdentifiers().filter { pid in
            var taskInfo = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))
            return result == size && taskInfo.pbi_ppid == parentPid
        }
    }

    /// Every live process keyed by pid, with its parent and command, in a single pass.
    ///
    /// `getProcessChildren(forPid:)` walks the machine's whole process table to answer about one
    /// parent, so building a tree with it costs that walk once per node. The info panel polls
    /// while it is on screen, which turns that into a repeated cost for an answer one pass
    /// already contains. Working directories are deliberately not read here: that is a second
    /// syscall per process, and the panel needs the directory of the session, not of each child.
    static func processTable() -> [pid_t: ProcessSummary] {
        let pids = liveProcessIdentifiers()
        guard !pids.isEmpty else { return [:] }

        var table: [pid_t: ProcessSummary] = [:]
        table.reserveCapacity(pids.count)

        for pid in pids {
            var taskInfo = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size)) == size else { continue }

            let command = withUnsafePointer(to: &taskInfo.pbi_comm) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }

            table[pid] = ProcessSummary(pid: pid, parentPid: pid_t(taskInfo.pbi_ppid), command: command)
        }

        return table
    }

    /// Gets resource usage (CPU time, memory) for a process.
    static func getResourceUsage(forPid pid: pid_t) -> ProcessResourceUsage? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
        }

        guard result == 0 else { return nil }

        return ProcessResourceUsage(
            cpuTime: nanoseconds(fromMachTime: usage.ri_user_time + usage.ri_system_time),
            memoryBytes: usage.ri_phys_footprint
        )
    }

    /// Converts `rusage_info`'s CPU times to nanoseconds.
    ///
    /// **They are mach time units, not nanoseconds**, which is easy to miss because on Intel the
    /// timebase is 1/1 and the two are the same number. On Apple Silicon it is 125/3 — about
    /// 41.7ns a tick — so reading the raw value as nanoseconds under-reports CPU by ~42×, and a
    /// process saturating a core renders as a flat 2%. That reads as "idle", which is the one
    /// answer a busy process must never give.
    private static func nanoseconds(fromMachTime ticks: UInt64) -> UInt64 {
        UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // A zeroed timebase would divide by zero; the identity ratio is the safe reading, and
        // is what Intel reports anyway.
        return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
    }()

    /// Checks if a process with the given PID exists.
    static func processExists(pid: pid_t) -> Bool {
        var taskInfo = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &taskInfo, Int32(size))
        return result == size
    }

    /// What the process calls itself — `argv[0]`'s last component, which is what `ps` reports.
    ///
    /// `proc_bsdinfo.pbi_comm` is the *executable file's* name, truncated to 16 characters, and
    /// for a versioned install that is the version rather than the tool: Claude Code's binary
    /// lives at `…/versions/2.1.218`, so the agent — the row this panel exists to show — renders
    /// as "2.1.218", which names nothing a user recognises. `argv[0]` says "claude".
    ///
    /// Callers should cache the answer: a process cannot rename itself here, and this copies the
    /// argument area out of the kernel, which is far more than a poll should repeat.
    static func processName(forPid pid: pid_t) -> String? {
        var argumentMaximum: Int32 = 0
        var maximumSize = MemoryLayout<Int32>.size
        var maximumMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumMib, 2, &argumentMaximum, &maximumSize, nil, 0) == 0,
              argumentMaximum > 0 else { return nil }

        var size = Int(argumentMaximum)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // The region is `[argc][exec_path\0][\0 padding][argv[0]\0][argv[1]\0]…`, so reaching
        // argv[0] means stepping over the executable path and the alignment nulls behind it.
        let headerSize = MemoryLayout<Int32>.size
        guard size > headerSize else { return nil }

        var index = headerSize
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        guard index < size else { return nil }

        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }

        let name = (String(decoding: buffer[start..<index], as: UTF8.self) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    // MARK: - Listening Sockets

    /// Every TCP port the process is listening on.
    ///
    /// This is what `lsof -iTCP -sTCP:LISTEN` reports, asked of the kernel directly rather than
    /// by spawning it: the panel re-reads while it is on screen, and a subprocess per refresh
    /// per pid is a cost paid several times a second for an answer libproc already holds. It
    /// also reads the *bind address*, which is the half of the answer a port number omits.
    ///
    /// No privilege is needed for the processes this is asked about — they are the app's own
    /// descendants, running as the same user.
    ///
    /// The caller passes the command name because it has already read it while walking the
    /// tree; looking it up again here would be a second `proc_pidinfo` per process per refresh.
    static func listeningPorts(forPid pid: pid_t, command: String) -> [ListeningPort] {
        let reported = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard reported > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(reported) / stride + SocketScan.descriptorHeadroom
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)

        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity * stride))
        guard used > 0 else { return [] }

        let count = min(Int(used) / stride, capacity)
        var ports: [ListeningPort] = []

        for index in 0..<count {
            let descriptor = descriptors[index]
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            guard let port = listeningPort(pid: pid, fd: descriptor.proc_fd, command: command) else { continue }
            ports.append(port)
        }

        return ports
    }

    // MARK: - Private Methods

    /// Reads one descriptor, keeping it only if it is a TCP socket in the listening state.
    private static func listeningPort(pid: pid_t, fd: Int32, command: String) -> ListeningPort? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }

        // Only TCP has a listening state. A bound UDP socket is not a server waiting for
        // connections, and showing it as one would claim something the panel cannot stand behind.
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }

        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

        let socket = tcp.tcpsi_ini

        // The local port rides in network byte order in the low half of an int.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport))
        guard port > 0 else { return nil }

        let isIPv6 = (socket.insi_vflag & UInt8(INI_IPV6)) != 0
        guard let address = localAddress(of: socket, isIPv6: isIPv6) else { return nil }

        return ListeningPort(port: port, pid: pid, command: command, address: address, isIPv6: isIPv6)
    }

    /// Renders the socket's local bind address, from whichever half of the union its family names.
    private static func localAddress(of socket: in_sockinfo, isIPv6: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var local = socket.insi_laddr

        let rendered: UnsafePointer<CChar>? = isIPv6
            ? inet_ntop(AF_INET6, &local.ina_6, &buffer, socklen_t(INET6_ADDRSTRLEN))
            : inet_ntop(AF_INET, &local.ina_46.i46a_addr4, &buffer, socklen_t(INET_ADDRSTRLEN))

        guard rendered != nil else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Constants

    private enum ProcessScan {
        /// The floor for the pid buffer, for the case where the kernel's own count comes back
        /// unusable. Every ordinary machine is well under it.
        static let minimumProcesses = 4096

        /// Room over the count the kernel just reported. Processes keep being spawned while the
        /// table is being read, so the answer is stale by the time it is used.
        static let headroom = 256

        /// How many times to grow and ask again before reporting a short answer as short.
        static let attempts = 3
    }

    private enum SocketScan {
        /// Extra room over the size libproc last reported. The process keeps running while it is
        /// being asked, so a descriptor opened between the two calls would otherwise be cut off
        /// the end of the answer.
        static let descriptorHeadroom = 32
    }
}
