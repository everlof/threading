import Darwin
import Foundation

// MARK: - Errors

enum ChildSpawnError: LocalizedError {
    case spawnFailed(code: Int32)
    case pipeFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code), .pipeFailed(let code):
            return String(cString: strerror(code))
        }
    }
}

// MARK: - Child Process Spawn

/// Spawns a child that **leads its own process group**, with an exact descriptor map.
///
/// `Process` can do neither. It exposes only the three standard streams, so a descriptor past 2
/// cannot reach the child through it at all; and it offers no way to set a process group, so
/// every `Process` child of this app sits in the app's own group along with everything that
/// child goes on to spawn. That second limitation is what made a crash leak agents: on the app's
/// death the CLIs reparented to launchd, alive and unowned, and there was no group to signal
/// even if something had noticed. A group led by the child is what makes "end this child and
/// everything under it" one call rather than a process-table walk.
///
/// This is a primitive, not a launch policy. Extensions reach it through
/// `ExtensionChildSpawner`, which contains the child; native agent conversations reach it
/// through `AgentChildProcess`, which adds pipe stdio and the live-children ledger. Spawning
/// without one of those is a step in building one, never a way to run something.
enum ChildProcessSpawn {

    /// - Parameter descriptors: child descriptor number → the parent descriptor to install
    ///   there. The parent keeps its own copies; the caller closes them once the child holds
    ///   them, which for a pipe or socket pair is what lets the child's exit reach end-of-file.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        descriptors: [Int32: Int32]
    ) throws -> SpawnedChildProcess {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory {
            // The `_np` spelling deliberately: the unsuffixed one arrived in macOS 26 and this
            // app deploys to 13, so the deprecation warning is the price of the only form that
            // exists on the deployment target.
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        }
        // Sorted so the mapping is deterministic. `dup2` to a target that is also a source
        // would be order-dependent, and a caller that needs that has asked for something this
        // primitive should not quietly guess at.
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            posix_spawn_file_actions_adddup2(&fileActions, source, target)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Everything not named above is closed: the child inherits exactly what it was given
        // and nothing the app happened to have open. A pgid of zero means "lead your own
        // group", so the child's group id is its pid and `kill(-pid, …)` reaches the child and
        // every grandchild it starts.
        posix_spawnattr_setpgroup(&attributes, ChildProcessSpawnDefaults.leadOwnGroup)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        )

        let argv = [executableURL.path] + arguments
        var cArguments = argv.map { strdup($0) }
        cArguments.append(nil)
        var cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer {
            cArguments.forEach { pointer in pointer.map { free($0) } }
            cEnvironment.forEach { pointer in pointer.map { free($0) } }
        }

        var pid: pid_t = 0
        let result = posix_spawn(
            &pid,
            executableURL.path,
            &fileActions,
            &attributes,
            &cArguments,
            &cEnvironment
        )
        guard result == 0 else {
            throw ChildSpawnError.spawnFailed(code: result)
        }
        return SpawnedChildProcess(processIdentifier: pid)
    }
}

// MARK: - Spawned Child Process

/// A child this process spawned directly, reaped exactly once.
///
/// The exit is observed with a `DispatchSourceProcess` and the child is reaped inside that
/// handler, which is also where the source is cancelled. Reaping without cancelling is the bug
/// that crashed this app on 22 July 2026 (see `EventLog`'s header): `waitpid` destroys the
/// kernel event the source is registered for, and libdispatch treats the `EV_VANISHED` it then
/// sees on an unrelated re-arm as a fatal client error. One mechanism, one queue, one reap.
///
/// `@unchecked Sendable`: every mutable member is guarded by `lock`, and the only place
/// `waitpid` runs is `reap()` on this child's own serial `exitQueue`. Nothing here is confined
/// to an actor, because a child outlives whichever executor asked for it.
final class SpawnedChildProcess: @unchecked Sendable {
    let processIdentifier: pid_t

    /// This child's own queue rather than a shared one: a supervisor whose exit handler blocks
    /// must not delay an unrelated child's reap. `.userInitiated` because a caller may block on
    /// `waitUntilExit`, and a default-priority reap under a higher-priority waiter is a priority
    /// inversion the thread performance checker reports at every launch.
    private let exitQueue = DispatchQueue(
        label: ChildProcessSpawnDefaults.exitQueueLabel,
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var source: DispatchSourceProcess?
    private var exitStatus: Int32?
    private var exitHandler: ((Int32) -> Void)?

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier

        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: exitQueue
        )
        self.source = source
        // Strongly, deliberately: a supervisor released before its child exits would otherwise
        // leave a zombie nobody can reap, because the pid is only waitable by this process. The
        // cycle is broken by the cancel inside `reap()`, which releases the handler with it.
        source.setEventHandler {
            self.reap()
        }
        source.resume()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus == nil
    }

    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus ?? 0
    }

    func waitUntilExit() {
        exited.wait()
        // Restored, so a second caller — and `isRunning` afterwards — still sees the exit.
        exited.signal()
    }

    func terminate() {
        // Negative pid means the whole process group. Do not guard on the leader still running:
        // a descendant can remain in the group after the leader exits, and that is exactly the
        // lifecycle leak this supervisor exists to prevent.
        Darwin.kill(-processIdentifier, SIGTERM)
    }

    func kill() {
        Darwin.kill(-processIdentifier, SIGKILL)
    }

    func observeExit(_ handler: ((Int32) -> Void)?) {
        lock.lock()
        guard let handler else {
            exitHandler = nil
            lock.unlock()
            return
        }
        if let exitStatus {
            lock.unlock()
            handler(exitStatus)
            return
        }
        exitHandler = handler
        lock.unlock()
    }

    private func reap() {
        var raw: Int32 = 0
        var status: Int32 = 0
        if waitpid(processIdentifier, &raw, 0) == processIdentifier {
            // Report a signalled death the way a shell does, so callers comparing against a
            // `Process`-backed child see the same number for the same outcome.
            status = waitStatus(raw) == 0
                ? (raw >> ChildProcessSpawnDefaults.exitStatusShift)
                    & ChildProcessSpawnDefaults.exitStatusMask
                : ChildProcessSpawnDefaults.signalledExitBase + waitStatus(raw)
        }

        lock.lock()
        guard exitStatus == nil else {
            lock.unlock()
            return
        }
        exitStatus = status
        let handler = exitHandler
        exitHandler = nil
        let source = source
        self.source = nil
        lock.unlock()

        // Cancelled here, after the reap, and never in `terminate()`: cancelling before the
        // exit event arrives would leave a zombie instead.
        source?.cancel()
        exited.signal()
        handler?(status)
    }

    private func waitStatus(_ status: Int32) -> Int32 {
        status & ChildProcessSpawnDefaults.waitStatusMask
    }
}

// MARK: - Child Process Spawn Defaults

enum ChildProcessSpawnDefaults {
    /// `posix_spawnattr_setpgroup`'s "be your own group leader" value.
    static let leadOwnGroup: pid_t = 0

    static let exitQueueLabel = "codes.threading.child-exit"

    /// `wait(2)`'s encoding, spelled out because the `W*` macros are unavailable in Swift.
    static let waitStatusMask: Int32 = 0x7F
    static let exitStatusShift: Int32 = 8
    static let exitStatusMask: Int32 = 0xFF

    /// What a shell reports for a signalled death — `128 + signal`.
    static let signalledExitBase: Int32 = 128
}
