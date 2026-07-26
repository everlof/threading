import Darwin
import Foundation

enum ExtensionSpawnError: LocalizedError {
    case spawnFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            return "The extension could not be started: \(String(cString: strerror(code)))."
        }
    }
}

/// Spawns a child with an exact descriptor map.
///
/// `Process` cannot do this. It exposes only the three standard streams and spawns with
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a descriptor past 2 — the host broker socket — cannot
/// reach the child through it at all. That limitation is the reason
/// `SandboxExecLaunchPolicy` refuses a request carrying `extraDescriptors`, and this is what a
/// containment wrapper that can honour one is built on.
///
/// This type is a primitive, not a launch policy, and deliberately does not conform to
/// `ExtensionLaunchPolicy`. Anything reachable through that protocol contains the child;
/// spawning without containment is a step in building one, never a way to run an extension.
enum ExtensionChildSpawner {
    /// - Parameter descriptors: child descriptor number → the parent descriptor to install
    ///   there. The parent keeps its own copies; the caller closes them once the child holds
    ///   them, which for a socket pair is what lets the child's exit reach end-of-file.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        descriptors: [Int32: Int32]
    ) throws -> ExtensionChildProcess {
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
        // Everything not named above is closed. The extension inherits exactly what it was
        // given and nothing the app happened to have open. It also leads a fresh process group:
        // the signed helper denies new processes, but group ownership is defence in depth for
        // launch failures and for any future capability which deliberately permits children.
        posix_spawnattr_setpgroup(&attributes, 0)
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
            throw ExtensionSpawnError.spawnFailed(code: result)
        }
        return SpawnedChildProcess(processIdentifier: pid)
    }
}

/// A child this process spawned directly, reaped exactly once.
///
/// The exit is observed with a `DispatchSourceProcess` and the child is reaped inside that
/// handler, which is also where the source is cancelled. Reaping without cancelling is the bug
/// that crashed this app once already (see the SwiftTerm note in `CLAUDE.md`): `waitpid`
/// destroys the kernel event the source is registered for, and libdispatch treats the
/// `EV_VANISHED` it then sees on an unrelated re-arm as a fatal client error.
private final class SpawnedChildProcess: ExtensionChildProcess, @unchecked Sendable {
    let processIdentifier: pid_t

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
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        self.source = source
        source.setEventHandler { [weak self] in
            self?.reap()
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
            status = _WSTATUS(raw) == 0 ? (raw >> 8) & 0xFF : 128 + _WSTATUS(raw)
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

    private func _WSTATUS(_ status: Int32) -> Int32 {
        status & 0x7F
    }
}
