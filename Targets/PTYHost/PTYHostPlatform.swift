#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Foundation
import ThreadingPTYHostKit
#if os(Linux)
import CPTYHostPlatform
#endif

// MARK: - POSIX

/// Every call the daemon makes whose spelling differs between Darwin and Linux, and nothing else.
///
/// The daemon is one program on both systems. What differs is a handful of names — the C module,
/// a struct field Linux lacks, a socket option Linux does not have, a process-exit event source
/// libdispatch only offers on Darwin — and each difference is answered here once, so the files
/// that own sessions, connections and the journal read the same on both.
///
/// **This is not a portability layer for its own sake.** The daemon runs on Linux so a session's
/// agent can run on a machine the person owns and reach it over SSH; see
/// `docs/feature-drafts/remote-execution-hosts.md`. A difference that is behaviour rather than
/// spelling is stated where it applies, not hidden behind a name here.
enum PTYHostPOSIX {

    // MARK: - Descriptors

    /// `close(2)`, qualified. Several types here have a method of their own called `close`, and an
    /// unqualified call inside one of them resolves to the method.
    @discardableResult
    static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(descriptor)
        #elseif canImport(Glibc)
        return Glibc.close(descriptor)
        #else
        return Musl.close(descriptor)
        #endif
    }

    /// `read(2)`, qualified for the same reason as `close`.
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.read(descriptor, buffer, count)
        #else
        return Musl.read(descriptor, buffer, count)
        #endif
    }

    /// Writes every byte or answers false, retrying an interrupted write.
    ///
    /// One loop rather than one per caller: the journal, the state file and the command-line
    /// client all need exactly this and nothing more.
    @discardableResult
    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return raw.isEmpty }
            var offset = 0
            while offset < raw.count {
                let written = rawWrite(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private static func rawWrite(
        _ descriptor: Int32,
        _ buffer: UnsafeRawPointer,
        _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, buffer, count)
        #else
        return Musl.write(descriptor, buffer, count)
        #endif
    }

    /// Which directions `shutdown(2)` ends.
    enum ShutdownDirection {
        case read
        case readWrite
    }

    /// `shutdown(2)`. Glibc imports `SHUT_RD` and `SHUT_RDWR` as `Int`, Darwin and musl as `Int32`.
    static func shutdown(_ descriptor: Int32, _ direction: ShutdownDirection) {
        let how: Int32
        switch direction {
        case .read: how = Int32(SHUT_RD)
        case .readWrite: how = Int32(SHUT_RDWR)
        }
        #if canImport(Darwin)
        _ = Darwin.shutdown(descriptor, how)
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(descriptor, how)
        #else
        _ = Musl.shutdown(descriptor, how)
        #endif
    }

    /// A `pipe(2)` whose two ends are close-on-exec from the moment they exist.
    ///
    /// On Darwin the pipes spawn names `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the child inherits only
    /// the three descriptors it was given whatever else is open, and a plain `pipe` is enough.
    /// Linux has no such flag: there, a descriptor that is not close-on-exec *is* inherited, so
    /// the guarantee has to be made where each descriptor is created — `pipe2(O_CLOEXEC)` here,
    /// and `dup2` onto the child's 0, 1 and 2 clears the flag on exactly those three.
    static func makePipe() -> (read: Int32, write: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        #if os(Linux)
        guard threading_pipe_cloexec(&descriptors) == 0 else { return nil }
        #else
        guard pipe(&descriptors) == 0 else { return nil }
        #endif
        return (descriptors[0], descriptors[1])
    }

    // MARK: - Signals

    /// `kill(2)`, qualified: `PTYHostServer` has a `kill` frame handler of its own.
    @discardableResult
    static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.kill(pid, signal)
        #elseif canImport(Glibc)
        return Glibc.kill(pid, signal)
        #else
        return Musl.kill(pid, signal)
        #endif
    }

    // MARK: - Unix sockets

    /// `SOCK_STREAM` as the `Int32` `socket(2)` takes. Glibc imports it as an enum case.
    static var streamSocketType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    /// The largest path a `sockaddr_un` holds, terminator included: 104 bytes on Darwin, 108 on
    /// Linux.
    static var unixPathCapacity: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// A filled-in `sockaddr_un`, or nil when the path does not fit.
    ///
    /// Refused rather than truncated: a truncated path is a different rendezvous, and a daemon
    /// bound there would be listening somewhere nobody is looking.
    static func unixAddress(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        let capacity = unixPathCapacity
        guard bytes.count < capacity else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        // Linux's `sockaddr_un` has no length field; the length travels as `bind`'s argument.
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// `bind(2)` on a unix address.
    static func bind(_ descriptor: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Darwin)
                Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Glibc)
                Glibc.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Musl.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
    }

    /// `connect(2)` to a unix address.
    static func connect(_ descriptor: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Darwin)
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Glibc)
                Glibc.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Musl.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
    }

    /// Asks a socket not to raise `SIGPIPE` when its peer is gone.
    ///
    /// Darwin has a per-socket option for it. **Linux has none**, so there the process-wide
    /// `SIG_IGN` in `main()` is the whole guard rather than one of two — which is why that line's
    /// comment says it must never be removed.
    static func suppressBrokenPipeSignal(on descriptor: Int32) {
        #if canImport(Darwin)
        var suppress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
    }

    // MARK: - Pseudo-terminals

    /// `forkpty(3)` under a window of `size`. Answers the pid (zero in the child) and the master.
    ///
    /// Linux reaches it through the C shim, because glibc and musl disagree about which header
    /// and which library declare it and the Swift overlays expose neither consistently.
    static func forkpty(master: inout Int32, size: winsize) -> pid_t {
        var size = size
        #if os(Linux)
        return threading_forkpty(&master, &size)
        #else
        return Darwin.forkpty(&master, nil, nil, &size)
        #endif
    }

    /// `ioctl(TIOCSWINSZ)`. Answers true when the terminal took the size.
    static func setWindowSize(_ size: winsize, on master: Int32) -> Bool {
        var size = size
        #if os(Linux)
        return threading_set_window_size(master, &size) == 0
        #else
        return ioctl(master, TIOCSWINSZ, &size) == 0
        #endif
    }

    // MARK: - Process identity

    /// The kernel start time of a pid, to the resolution the kernel keeps.
    ///
    /// Darwin keeps microseconds in `proc_bsdinfo`. Linux keeps clock ticks since boot in field 22
    /// of `/proc/<pid>/stat`, so the start time is the boot time plus those ticks, at the tick's
    /// resolution (normally 10 ms) — ample to tell two incarnations of one pid apart.
    ///
    /// **Linux's boot time can move.** `btime` is derived from the wall clock, so a clock step
    /// between a spawn and a later probe changes the answer. The failure is in the safe
    /// direction: the probe says "not the same process", so a restart reports the session lost
    /// and signals nothing, rather than killing a stranger that happens to hold the pid.
    static func startTime(of pid: pid_t) -> PTYHostProcessStartTime? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
              info.pbi_start_tvsec > 0 else { return nil }
        return PTYHostProcessStartTime(
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec)
        )
        #else
        guard let stat = readSmallFile("/proc/\(pid)/stat"),
              let ticks = PTYHostProcStat.startTicks(fromStat: stat),
              let procStat = readSmallFile("/proc/stat"),
              let bootTime = PTYHostProcStat.bootTime(fromProcStat: procStat) else { return nil }
        let hertz = UInt64(max(threading_clock_ticks_per_second(), 1))
        return PTYHostProcessStartTime(
            seconds: bootTime + ticks / hertz,
            microseconds: (ticks % hertz) * 1_000_000 / hertz
        )
        #endif
    }

    #if os(Linux)
    /// Reads a `/proc` file, which reports a size of zero and so has to be read to end of file.
    ///
    /// Bounded by `PTYHostDefaults.procReadLimitBytes`; see there for why `/proc/stat` needs more
    /// than its first page.
    private static func readSmallFile(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: PTYHostDefaults.procReadChunkBytes)
        while collected.count < PTYHostDefaults.procReadLimitBytes {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: collected, as: UTF8.self)
    }
    #endif

    // MARK: - Process exit

    /// A dispatch source that fires once `pid` has exited and can be reaped.
    ///
    /// Darwin has a process source for exactly this. Linux libdispatch does not; there, a pidfd
    /// becomes readable when its process exits, and a read source on it is the same event. The
    /// source owns the pidfd and closes it when cancelled. Nil when the pidfd could not be opened —
    /// a kernel before 5.3, or no descriptors left — and the caller then polls.
    static func makeExitSource(
        for pid: pid_t,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> DispatchSourceProtocol? {
        #if os(Linux)
        let descriptor = threading_pidfd_open(pid)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { _ = close(descriptor) }
        return source
        #else
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        return source
        #endif
    }

    // MARK: - Spawning on pipes

    /// The `posix_spawn` flags for a pipes child.
    ///
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` is Darwin's. Linux relies on every daemon descriptor being
    /// close-on-exec from creation instead; see `makePipe()`.
    static var pipeSpawnFlags: Int16 {
        var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        #if canImport(Darwin)
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        #endif
        return Int16(flags)
    }
}

// MARK: - /proc parsing

/// The two numbers the Linux start time is made of, read from text the kernel writes.
///
/// Pure functions over strings, so the parsing is tested on every platform rather than only where
/// `/proc` exists.
enum PTYHostProcStat {

    /// Field 22 of `/proc/<pid>/stat`: the start time in clock ticks since boot.
    ///
    /// Field 2 is the command name in parentheses and may itself contain spaces and parentheses,
    /// so the fields are counted from the **last** closing parenthesis: the next field is 3.
    static func startTicks(fromStat text: String) -> UInt64? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\n" })
        let index = PTYHostDefaults.procStartTimeField - PTYHostDefaults.procFirstFieldAfterName
        guard fields.indices.contains(index) else { return nil }
        return UInt64(fields[index])
    }

    /// The `btime` line of `/proc/stat`: boot time in seconds since the epoch.
    static func bootTime(fromProcStat text: String) -> UInt64? {
        for line in text.split(separator: "\n") where line.hasPrefix(PTYHostDefaults.procBootTimeKey) {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return nil }
            return UInt64(parts[1])
        }
        return nil
    }
}
