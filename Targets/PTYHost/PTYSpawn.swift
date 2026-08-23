import Darwin
import Foundation
import ThreadingPTYHostKit

// MARK: - Spawn

/// The one place the daemon touches `fork`, and the smallest amount of code that can be.
///
/// Everything it needs is decided by the caller and arrives in the frame: the executable, the
/// argument vector, `argv[0]`, the environment and the working directory. The daemon adds
/// nothing and removes nothing — it inherits *launchd's* environment rather than the user's, and
/// the composition rules live in the app, where the measured leakage list and the login-shell
/// command line already live.
enum PTYSpawn {

    // MARK: - Types

    /// A child that exists.
    struct Child {
        let pid: pid_t
        /// The pseudo-terminal master. `FD_CLOEXEC`, so the next child spawned does not inherit
        /// this one's terminal — ten agent CLIs once inherited a descriptor of the app's and held
        /// it open long after the app was gone.
        let master: Int32
        /// The kernel start time, read straight back after the fork. Paired with the pid it is
        /// the identity that makes a restart probe safe.
        let startTime: PTYHostProcessStartTime?
    }

    /// Why a spawn could not be attempted. Structural, and each maps to a wire token.
    enum Failure: Error, Equatable {
        case executableUnavailable
        case forkFailed(Int32)
    }

    // MARK: - Public Methods

    /// Forks a child under a new pseudo-terminal sized by `grid`.
    ///
    /// `forkpty` gives the child its own session (`setsid`) and makes the slave its controlling
    /// terminal, so the child is a session leader and its process group id equals its pid. That
    /// is what makes `kill(-pid, …)` the whole job's ending rather than one process's, and it is
    /// why the daemon never has to track a group id separately.
    ///
    /// The argument and environment vectors are built **before** the fork. Between `fork` and
    /// `exec` only async-signal-safe calls are allowed, and allocating there is the classic way
    /// to deadlock in a malloc lock the parent happened to hold.
    static func spawn(
        executable: String,
        arguments: [String],
        execName: String?,
        environment: [String],
        workingDirectory: String?,
        grid: PTYHostGrid
    ) -> Result<Child, Failure> {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.executableUnavailable)
        }

        var argumentVector = arguments
        argumentVector.insert(execName ?? executable, at: 0)

        guard let argv = CStringVector(argumentVector) else {
            return .failure(.forkFailed(ENOMEM))
        }
        guard let envp = CStringVector(environment) else {
            argv.deallocate()
            return .failure(.forkFailed(ENOMEM))
        }
        guard let path = strdup(executable) else {
            argv.deallocate()
            envp.deallocate()
            return .failure(.forkFailed(ENOMEM))
        }
        let directory = workingDirectory.flatMap { strdup($0) }
        defer {
            argv.deallocate()
            envp.deallocate()
            free(path)
            if let directory { free(directory) }
        }

        var size = winsize(
            ws_row: UInt16(clamping: grid.rows),
            ws_col: UInt16(clamping: grid.cols),
            ws_xpixel: UInt16(clamping: grid.xpixel),
            ws_ypixel: UInt16(clamping: grid.ypixel)
        )
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return .failure(.forkFailed(errno)) }

        if pid == 0 {
            // The daemon ignores SIGPIPE and libdispatch masks signals of its own; an ignored
            // disposition survives `exec`, so a child that inherited them would be a terminal
            // where ^C does nothing. Every disposition a terminal cares about goes back to the
            // default first.
            _ = signal(SIGHUP, SIG_DFL)
            _ = signal(SIGINT, SIG_DFL)
            _ = signal(SIGQUIT, SIG_DFL)
            _ = signal(SIGTERM, SIG_DFL)
            _ = signal(SIGPIPE, SIG_DFL)
            _ = signal(SIGTSTP, SIG_DFL)
            _ = signal(SIGTTIN, SIG_DFL)
            _ = signal(SIGTTOU, SIG_DFL)

            // A working directory that cannot be entered ends the child rather than starting it
            // somewhere else. The app names the directory because the session is *of* that
            // checkout, and an agent writing files into whatever `/` happens to be is a worse
            // outcome than a launch that failed and said so.
            if let directory, chdir(directory) != 0 {
                _exit(PTYHostDefaults.childDirectoryFailureStatus)
            }
            _ = execve(path, argv.base, envp.base)
            _exit(PTYHostDefaults.childExecFailureStatus)
        }

        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return .success(Child(pid: pid, master: master, startTime: startTime(of: pid)))
    }

    // MARK: - Process identity

    /// The kernel start time of a pid, to the microsecond.
    ///
    /// A minimal copy of the application's `ProcessUtility.startTime(forPid:)`: the daemon must
    /// not link the app, and this is two fields of one `proc_pidinfo` call. Seconds alone would
    /// not do — two processes started in the same second are ordinary at launch.
    static func startTime(of pid: pid_t) -> PTYHostProcessStartTime? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
              info.pbi_start_tvsec > 0 else { return nil }
        return PTYHostProcessStartTime(
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    /// Whether a pid exists at all, asked with a *different* mechanism from the start-time read.
    ///
    /// If the first one fails, the second must not fail identically and turn "cannot read" into
    /// "gone". `EPERM` is a process owned by somebody else: it exists, and it is emphatically not
    /// ours to signal.
    static func exists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Signals

    /// Signals a child's whole process group.
    ///
    /// The group, not the process: `forkpty` made the child a session leader, so its pid is also
    /// its group id, and an agent CLI's own children are in that group. Signalling the leader
    /// alone leaves them running, which is the orphan class the app's sweep exists to clean up.
    static func signalGroup(_ pid: pid_t, _ number: Int32) {
        guard pid > 0 else { return }
        _ = Darwin.kill(-pid, number)
    }

    // MARK: - The terminal

    /// Applies a window size and raises `SIGWINCH` on the foreground group.
    ///
    /// Darwin's `TIOCSWINSZ` signals the foreground process group itself, and the explicit signal
    /// is the belt to that braces: a program that changed the foreground group between the two
    /// calls still learns. Both are cheap and neither is conditional on the other succeeding.
    static func applyWindowSize(_ grid: PTYHostGrid, to master: Int32) {
        guard master >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: grid.rows),
            ws_col: UInt16(clamping: grid.cols),
            ws_xpixel: UInt16(clamping: grid.xpixel),
            ws_ypixel: UInt16(clamping: grid.ypixel)
        )
        _ = ioctl(master, TIOCSWINSZ, &size)
        let foreground = tcgetpgrp(master)
        if foreground > 0 { _ = Darwin.kill(-foreground, SIGWINCH) }
    }

    /// Which process group owns the terminal, or nil when nothing does.
    ///
    /// One syscall, no parsing — which is what lets the daemon answer a question the app can no
    /// longer answer for a host-backed session, without learning anything about the byte stream.
    static func foregroundProcessGroup(of master: Int32) -> pid_t? {
        guard master >= 0 else { return nil }
        let group = tcgetpgrp(master)
        return group > 0 ? group : nil
    }
}

// MARK: - C string vectors

/// A `char *const []` built before the fork and freed after it.
private final class CStringVector {

    let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init?(_ strings: [String]) {
        let allocated = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: strings.count + 1)
        var written = 0
        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanup in 0..<written { free(allocated[cleanup]) }
                allocated.deallocate()
                return nil
            }
            allocated[index] = duplicated
            written += 1
        }
        allocated[strings.count] = nil
        base = allocated
        count = strings.count
    }

    func deallocate() {
        for index in 0..<count { free(base[index]) }
        base.deallocate()
    }
}
