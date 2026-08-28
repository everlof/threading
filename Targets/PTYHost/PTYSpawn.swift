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
            // The daemon ignores SIGPIPE; an ignored disposition survives `exec`, so a child
            // that inherited it would be a terminal where ^C does nothing. Every disposition a
            // terminal cares about goes back to the default first.
            _ = signal(SIGHUP, SIG_DFL)
            _ = signal(SIGINT, SIG_DFL)
            _ = signal(SIGQUIT, SIG_DFL)
            _ = signal(SIGTERM, SIG_DFL)
            _ = signal(SIGPIPE, SIG_DFL)
            _ = signal(SIGTSTP, SIG_DFL)
            _ = signal(SIGTTIN, SIG_DFL)
            _ = signal(SIGTTOU, SIG_DFL)

            // The mask too, which the dispositions do not cover. This fork happens on the
            // server's dispatch queue, and a libdispatch worker thread blocks every signal; a
            // thread's mask survives `fork` and `exec` exactly as a disposition does. A child
            // left with it never receives the `SIGWINCH` a resize raises — Node does not
            // unblock the signals it handles — so an agent's TUI stays on its spawn grid while
            // the pane moves, and `SIGTERM` needs the `SIGKILL` escalation to end it. The
            // measured symptom was a Claude painting 82 rows into a 77-row emulator: every
            // frame scrolled and its bottom rows interleaved. `sigprocmask` is async-signal-safe.
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            _ = sigprocmask(SIG_SETMASK, &unblocked, nil)

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

    /// Applies a window size and raises `SIGWINCH` on the foreground group, answering the grid
    /// the terminal actually took — or nil when it took none.
    ///
    /// Darwin's `TIOCSWINSZ` signals the foreground process group itself, and the explicit signal
    /// is the belt to that braces: a program that changed the foreground group between the two
    /// calls still learns. Both are cheap and neither is conditional on the other succeeding.
    ///
    /// The answer is the *applied* grid rather than a `Bool` because the four numbers are
    /// clamped on the way into a `winsize`, and the app reconciles its own window size against
    /// what the child's terminal holds. Telling it "yes" while the terminal holds something else
    /// would be exactly the divergence the acknowledgement exists to close.
    static func applyWindowSize(_ grid: PTYHostGrid, to master: Int32) -> PTYHostGrid? {
        guard master >= 0 else { return nil }
        var size = winsize(
            ws_row: UInt16(clamping: grid.rows),
            ws_col: UInt16(clamping: grid.cols),
            ws_xpixel: UInt16(clamping: grid.xpixel),
            ws_ypixel: UInt16(clamping: grid.ypixel)
        )
        guard ioctl(master, TIOCSWINSZ, &size) == 0 else { return nil }
        let foreground = tcgetpgrp(master)
        if foreground > 0 { _ = Darwin.kill(-foreground, SIGWINCH) }
        return PTYHostGrid(
            cols: Int(size.ws_col),
            rows: Int(size.ws_row),
            xpixel: Int(size.ws_xpixel),
            ypixel: Int(size.ws_ypixel)
        )
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

// MARK: - Pipes

/// The pipe half of `PTYSpawn`: three descriptors, a process group, and nothing else.
///
/// Deliberately a second entry point rather than a branch inside `spawn`. The two share no
/// mechanism — one is `forkpty` and a controlling terminal, the other is `posix_spawn` and three
/// `dup2` actions — and the one thing they must agree about, that the child leads its own group
/// so `kill(-pid, …)` is the whole job's ending, is stated in both places because it is the
/// property that makes teardown correct rather than an implementation detail of either.
extension PTYSpawn {

    /// A child wired to three pipes. The descriptors are the **parent's** ends.
    struct PipeChild {
        let pid: pid_t
        /// The daemon writes the child's standard input here.
        let input: Int32
        /// The daemon reads the child's standard output here.
        let output: Int32
        /// And its standard error here. Separate, because merging the two would corrupt the
        /// newline-delimited JSON the app's transports parse.
        let errors: Int32
        let startTime: PTYHostProcessStartTime?
    }

    /// Spawns a child on three pipes, leading its own process group.
    ///
    /// `posix_spawn` rather than `fork`/`exec` here, where `forkpty` is unavoidable next door:
    /// between `fork` and `exec` only async-signal-safe calls are allowed, and `posix_spawn` does
    /// the whole dance — descriptor actions, working directory, signal dispositions, process
    /// group — inside the kernel with none of that hazard. It is the same primitive, and the same
    /// flags, the app's own `ChildProcessSpawn` uses for exactly this child.
    ///
    /// **Every signal disposition goes back to the default.** The daemon ignores `SIGPIPE` and
    /// libdispatch masks signals of its own; an ignored disposition survives `exec`, so a child
    /// that inherited them would be a CLI that cannot be interrupted and cannot notice a closed
    /// reader.
    static func spawnPipes(
        executable: String,
        arguments: [String],
        execName: String?,
        environment: [String],
        workingDirectory: String?
    ) -> Result<PipeChild, Failure> {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.executableUnavailable)
        }

        guard let input = DescriptorPair(), let output = DescriptorPair() else {
            return .failure(.forkFailed(errno))
        }
        guard let errors = DescriptorPair() else {
            input.closeBoth()
            output.closeBoth()
            return .failure(.forkFailed(errno))
        }

        var argumentVector = arguments
        argumentVector.insert(execName ?? executable, at: 0)
        guard let argv = CStringVector(argumentVector) else {
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(ENOMEM))
        }
        guard let envp = CStringVector(environment) else {
            argv.deallocate()
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(ENOMEM))
        }
        defer {
            argv.deallocate()
            envp.deallocate()
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(errno))
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        if let workingDirectory {
            // The `_np` spelling deliberately: the unsuffixed one arrived in macOS 26 and this
            // daemon deploys to 13, so the deprecation is the price of the only form that exists
            // on the deployment target.
            guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else {
                [input, output, errors].forEach { $0.closeBoth() }
                return .failure(.forkFailed(errno))
            }
        }
        let map: [(Int32, Int32)] = [
            (PTYHostDefaults.childStandardInput, input.readEnd),
            (PTYHostDefaults.childStandardOutput, output.writeEnd),
            (PTYHostDefaults.childStandardError, errors.writeEnd)
        ]
        for (target, source) in map {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
                [input, output, errors].forEach { $0.closeBoth() }
                return .failure(.forkFailed(errno))
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(errno))
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaulted = sigset_t()
        sigfillset(&defaulted)
        _ = posix_spawnattr_setsigdefault(&attributes, &defaulted)
        // Default dispositions *and* an empty mask: `posix_spawn` inherits the calling thread's
        // mask like `fork` does, and this runs on a libdispatch worker whose mask blocks every
        // signal. See the `forkpty` path for what a child left with that mask cannot receive.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        _ = posix_spawnattr_setsigmask(&attributes, &unblocked)
        // A pgid of zero means "lead your own group", so the child's group id is its pid and
        // `kill(-pid, …)` reaches it and every grandchild it starts. `CLOEXEC_DEFAULT` means it
        // inherits exactly the three descriptors named above and nothing else the daemon
        // happened to have open — including the socket its own app is talking to.
        guard posix_spawnattr_setpgroup(&attributes, PTYHostDefaults.leadOwnGroup) == 0,
              posix_spawnattr_setflags(
                  &attributes,
                  Int16(
                      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                  )
              ) == 0 else {
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(errno))
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv.base, envp.base)
        guard result == 0 else {
            [input, output, errors].forEach { $0.closeBoth() }
            return .failure(.forkFailed(result))
        }

        // The child holds its own copies now. Until these go, the child's stdout never reaches
        // end of file for the daemon and closing its stdin never reads as end of input to the
        // CLI — which is the graceful shutdown every one of these transports depends on.
        input.closeReadEnd()
        output.closeWriteEnd()
        errors.closeWriteEnd()

        let parentEnds = [input.writeEnd, output.readEnd, errors.readEnd]
        for descriptor in parentEnds { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        return .success(PipeChild(
            pid: pid,
            input: input.writeEnd,
            output: output.readEnd,
            errors: errors.readEnd,
            startTime: startTime(of: pid)
        ))
    }
}

// MARK: - Descriptor pairs

/// One `pipe(2)`, with each end released exactly once.
///
/// Raw descriptors rather than anything owning: the daemon hands two of the six to `DispatchIO`
/// channels that close them from their own cleanup handlers, and a second apparent owner is how
/// a descriptor the kernel has already recycled gets closed under an unrelated file.
private final class DescriptorPair {

    private(set) var readEnd: Int32
    private(set) var writeEnd: Int32

    init?() {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        readEnd = descriptors[0]
        writeEnd = descriptors[1]
    }

    func closeReadEnd() {
        guard readEnd >= 0 else { return }
        close(readEnd)
        readEnd = -1
    }

    func closeWriteEnd() {
        guard writeEnd >= 0 else { return }
        close(writeEnd)
        writeEnd = -1
    }

    func closeBoth() {
        closeReadEnd()
        closeWriteEnd()
    }
}
