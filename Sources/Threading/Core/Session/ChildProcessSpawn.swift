import Darwin
import Foundation

// MARK: - Errors

enum ChildSpawnError: LocalizedError {
    case spawnFailed(code: Int32)
    case pipeFailed(code: Int32)
    case configurationFailed(code: Int32)
    case invalidDescriptorMap
    case invalidArgument
    case invalidEnvironment
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code), .pipeFailed(let code), .configurationFailed(let code):
            return String(cString: strerror(code))
        case .invalidDescriptorMap:
            return "The child descriptor map is invalid."
        case .invalidArgument:
            return "A child-process argument contains a null byte."
        case .invalidEnvironment:
            return "The child-process environment is invalid."
        case .allocationFailed:
            return "The child-process argument vector could not be allocated."
        }
    }
}

/// What the child receives at one descriptor number.
///
/// `FileHandle.nullDevice.fileDescriptor` is `-1` on current Foundation: it is a semantic
/// process-redirection object, not an open descriptor. Keeping null as its own case prevents
/// that implementation detail from crossing the POSIX spawn boundary as if it were a file.
enum ChildDescriptorSource: Equatable {
    case inherited(Int32)
    case nullDevice
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

    /// - Parameter descriptors: child descriptor number → the parent descriptor or explicit
    ///   null device to install there. The parent keeps its own inherited copies; the caller
    ///   closes them once the child holds them, which for a pipe or socket pair is what lets the
    ///   child's exit reach end-of-file.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        descriptors: [Int32: ChildDescriptorSource]
    ) throws -> SpawnedChildProcess {
        guard !executableURL.path.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              workingDirectory?.path.contains("\0") != true else {
            throw ChildSpawnError.invalidArgument
        }
        guard descriptors.keys.allSatisfy({ $0 >= 0 }),
              descriptors.values.allSatisfy({ source in
                  if case .inherited(let descriptor) = source { return descriptor >= 0 }
                  return true
              }) else {
            throw ChildSpawnError.invalidDescriptorMap
        }

        var openedNullDevice: Int32?
        if descriptors.values.contains(.nullDevice) {
            let descriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ChildSpawnError.configurationFailed(code: errno)
            }
            openedNullDevice = descriptor
        }
        defer {
            if let openedNullDevice { Darwin.close(openedNullDevice) }
        }
        var resolvedDescriptors: [Int32: Int32] = [:]
        resolvedDescriptors.reserveCapacity(descriptors.count)
        for (target, source) in descriptors {
            switch source {
            case .inherited(let descriptor):
                resolvedDescriptors[target] = descriptor
            case .nullDevice:
                guard let openedNullDevice else {
                    throw ChildSpawnError.configurationFailed(code: EINVAL)
                }
                resolvedDescriptors[target] = openedNullDevice
            }
        }
        guard let descriptorActions = orderedDescriptorActions(resolvedDescriptors) else {
            throw ChildSpawnError.invalidDescriptorMap
        }

        var fileActions: posix_spawn_file_actions_t?
        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory {
            // The `_np` spelling deliberately: the unsuffixed one arrived in macOS 26 and this
            // app deploys to 13, so the deprecation warning is the price of the only form that
            // exists on the deployment target.
            result = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
            guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        }
        // A descriptor may legitimately be both a target and a source: test hosts can have a
        // closed standard stream, so the next pipe or `/dev/null` open reuses 0, 1 or 2. Apply
        // every reader before the action that overwrites its source. Only a true cycle is
        // ambiguous and refused by `orderedDescriptorActions`.
        for (target, source) in descriptorActions {
            result = posix_spawn_file_actions_adddup2(&fileActions, source, target)
            guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        }

        var attributes: posix_spawnattr_t?
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Everything not named above is closed: the child inherits exactly what it was given
        // and nothing the app happened to have open. A pgid of zero means "lead your own
        // group", so the child's group id is its pid and `kill(-pid, …)` reaches the child and
        // every grandchild it starts.
        result = posix_spawnattr_setpgroup(
            &attributes,
            ChildProcessSpawnDefaults.leadOwnGroup
        )
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        // Every signal back to its default disposition, and an empty mask. `posix_spawn` hands the
        // child the *calling thread's* mask, and the callers here are libdispatch workers, which
        // block every signal; an ignored disposition (the app ignores `SIGPIPE`) survives `exec`
        // too. A child left with either never receives the `SIGTERM` that `terminate()` sends:
        // measured, a supervised `ssh -N` tunnel survived `kill(-pid, SIGTERM)` indefinitely,
        // and every bounded helper was only ever ended by the `SIGKILL` escalation after its
        // grace. `threading-ptyd` fixed the same inheritance for its own children (`pty-host.md`).
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        result = posix_spawnattr_setsigdefault(&attributes, &defaulted)
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        result = posix_spawnattr_setsigmask(&attributes, &unblocked)
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }
        result = posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            )
        )
        guard result == 0 else { throw ChildSpawnError.configurationFailed(code: result) }

        let argv = [executableURL.path] + arguments
        let environmentStrings = try environment.sorted(by: { $0.key < $1.key }).map {
            guard !$0.key.isEmpty, !$0.key.contains("="), !$0.key.contains("\0"),
                  !$0.value.contains("\0") else {
                throw ChildSpawnError.invalidEnvironment
            }
            return "\($0.key)=\($0.value)"
        }
        var cArguments = try duplicate(argv)
        var cEnvironment: [UnsafeMutablePointer<CChar>?]
        do {
            cEnvironment = try duplicate(environmentStrings)
        } catch {
            cArguments.forEach { pointer in pointer.map { free($0) } }
            throw error
        }
        defer {
            cArguments.forEach { pointer in pointer.map { free($0) } }
            cEnvironment.forEach { pointer in pointer.map { free($0) } }
        }

        var pid: pid_t = 0
        result = posix_spawn(
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

    /// Orders `dup2(source, target)` actions without destroying a source before it is read.
    /// Returns nil for negative descriptors and genuine cycles such as 0←1, 1←0. Self maps are
    /// retained: with `POSIX_SPAWN_CLOEXEC_DEFAULT`, mentioning an otherwise unchanged standard
    /// descriptor is what tells spawn to keep it open.
    static func orderedDescriptorActions(
        _ descriptors: [Int32: Int32]
    ) -> [(target: Int32, source: Int32)]? {
        guard descriptors.allSatisfy({ $0.key >= 0 && $0.value >= 0 }) else { return nil }

        var remaining = descriptors
        var ordered: [(target: Int32, source: Int32)] = []
        ordered.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            let candidate = remaining.keys.sorted().first { target in
                guard remaining[target] != target else { return true }
                return !remaining.contains { other in
                    other.key != target && other.value == target
                }
            }
            guard let target = candidate, let source = remaining.removeValue(forKey: target) else {
                return nil
            }
            ordered.append((target, source))
        }
        return ordered
    }

    private static func duplicate(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { pointer in
                    if let pointer { free(pointer) }
                }
                throw ChildSpawnError.allocationFailed
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
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

// MARK: - Child Pipe

/// One `pipe(2)`, before either end has been handed to a `FileHandle`.
///
/// Raw descriptors rather than `Pipe`, because the parent must close the child's ends the
/// instant `posix_spawn` returns and `Pipe` owns both of its handles until it is released.
final class ChildPipe {
    private(set) var readEnd: Int32
    private(set) var writeEnd: Int32

    /// - Parameter closingOnFailure: pipes already created for this spawn, closed if this one
    /// cannot be made. A descriptor leak here is permanent for the life of the app.
    init(closingOnFailure opened: [ChildPipe] = []) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            let code = errno
            opened.forEach { $0.closeBothEnds() }
            throw ChildSpawnError.pipeFailed(code: code)
        }
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

    func closeBothEnds() {
        closeReadEnd()
        closeWriteEnd()
    }

    /// Transfers ownership of one end to Foundation without leaving a second apparent owner in
    /// this wrapper. This prevents a later cleanup path from closing a descriptor the kernel has
    /// already recycled for an unrelated file.
    func takeReadHandle() -> FileHandle {
        precondition(readEnd >= 0, "A pipe read end can be transferred once")
        let descriptor = readEnd
        readEnd = -1
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The same transfer without Foundation in the middle, for `ChildOutputStream`, which closes
    /// the descriptor from a dispatch cancel handler and must be its only owner.
    func takeReadDescriptor() -> Int32 {
        precondition(readEnd >= 0, "A pipe read end can be transferred once")
        let descriptor = readEnd
        readEnd = -1
        return descriptor
    }

    func takeWriteHandle() -> FileHandle {
        precondition(writeEnd >= 0, "A pipe write end can be transferred once")
        let descriptor = writeEnd
        writeEnd = -1
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The write end without Foundation in the middle, for `PTYHostPipeLink`, which hands it to a
    /// `DispatchIO` channel that closes the descriptor from its own cleanup handler and must be
    /// its only owner.
    func takeWriteDescriptor() -> Int32 {
        precondition(writeEnd >= 0, "A pipe write end can be transferred once")
        let descriptor = writeEnd
        writeEnd = -1
        return descriptor
    }
}

// MARK: - Bounded One-Shot Child

/// The terminal fact from a blocking helper command.
enum BoundedChildTermination: Equatable, Sendable {
    case exited(Int32)
    case timedOut
}

/// A helper command's bounded combined output and terminal fact.
struct BoundedChildResult: Equatable, Sendable {
    let output: Data
    let outputWasTruncated: Bool
    let termination: BoundedChildTermination
}

/// Which stream a finite helper exposes to its caller. Most model CLIs deliberately merge
/// diagnostics with their JSON-lines envelopes, while probes that parse stdout must keep a
/// warning or shell greeting from becoming input data. In both modes every unreturned stream
/// is sent to `/dev/null`, so it cannot fill a forgotten pipe behind the waiter.
enum BoundedChildOutput: Equatable, Sendable {
    case merged
    case standardOutput
}

/// Runs a finite helper command in its own process group.
///
/// This is for blocking background-queue chores such as source statistics and one-shot model
/// research, not interactive agent sessions. It owns the three rules those chores previously
/// copied imperfectly:
///
/// - stdout and stderr share one pipe that is drained while the child runs, so neither stream
///   can fill behind a waiter;
/// - only the newest `maximumOutputBytes` survive, bounding provider or tool chatter while
///   retaining the final JSON/result and last diagnostic;
/// - the timeout is an explicit state transition, followed by TERM and then KILL for the whole
///   process group. A child that crashes from an unrelated signal is therefore not called a
///   timeout, and one that ignores TERM cannot hold the worker forever.
enum BoundedChildProcess {

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = BoundedChildDefaults.terminationGrace,
        maximumOutputBytes: Int = BoundedChildDefaults.maximumOutputBytes,
        output: BoundedChildOutput = .merged
    ) throws -> BoundedChildResult {
        let outputPipe = try ChildPipe()
        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                descriptors: descriptors(for: output, outputPipe: outputPipe)
            )
        } catch {
            outputPipe.closeBothEnds()
            throw error
        }

        // The child owns its duplicated writer. Keeping the parent's copy would prevent EOF
        // after the group exits and turn every successful run into a timeout.
        outputPipe.closeWriteEnd()
        let output = outputPipe.takeReadHandle()
        let deadline = ChildProcessDeadline(
            child: child,
            timeout: timeout,
            terminationGrace: terminationGrace
        )

        let capture = captureSuffix(from: output, maximumBytes: maximumOutputBytes)
        child.waitUntilExit()
        let timedOut = deadline.complete()
        try? output.close()

        return BoundedChildResult(
            output: capture.data,
            outputWasTruncated: capture.wasTruncated,
            termination: timedOut ? .timedOut : .exited(child.terminationStatus)
        )
    }

    private static func descriptors(
        for output: BoundedChildOutput,
        outputPipe: ChildPipe
    ) -> [Int32: ChildDescriptorSource] {
        return [
            AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
            AgentChildProcessDefaults.standardOutputDescriptor: .inherited(outputPipe.writeEnd),
            AgentChildProcessDefaults.standardErrorDescriptor:
                output == .merged ? .inherited(outputPipe.writeEnd) : .nullDevice
        ]
    }

    static func captureSuffix(
        from handle: FileHandle,
        maximumBytes: Int
    ) -> (data: Data, wasTruncated: Bool) {
        let limit = max(0, maximumBytes)
        var kept = Data()
        var wasTruncated = false

        do {
            while let chunk = try handle.read(upToCount: BoundedChildDefaults.readChunkBytes),
                  !chunk.isEmpty {
                guard limit > 0 else {
                    wasTruncated = true
                    continue
                }
                if chunk.count >= limit {
                    let discardedEarlierBytes = !kept.isEmpty
                    kept = Data(chunk.suffix(limit))
                    wasTruncated = wasTruncated || discardedEarlierBytes || chunk.count > limit
                    continue
                }
                let overflow = kept.count + chunk.count - limit
                if overflow > 0 {
                    kept.removeFirst(overflow)
                    wasTruncated = true
                }
                kept.append(chunk)
            }
        } catch {
            // Closing the reader makes a still-writing child receive SIGPIPE. The exit status
            // remains the caller's diagnostic; partial bytes remain more useful than none.
            ThreadingLogger.agent.error(
                "Could not drain helper child output: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        return (kept, wasTruncated)
    }
}

extension SpawnedChildProcess {
    /// Waits for a finite child under the same process-group deadline as bounded captures.
    /// Callers whose stdio already points at files use this rather than recreating timeout state.
    func waitUntilExit(
        timeout: TimeInterval,
        terminationGrace: TimeInterval = BoundedChildDefaults.terminationGrace
    ) -> BoundedChildTermination {
        let deadline = ChildProcessDeadline(
            child: self,
            timeout: timeout,
            terminationGrace: terminationGrace
        )
        waitUntilExit()
        return deadline.complete() ? .timedOut : .exited(terminationStatus)
    }
}

final class ChildProcessDeadline: @unchecked Sendable {
    private let lifecycle: BoundedChildLifecycle
    private let task: Task<Void, Never>

    init(
        child: SpawnedChildProcess,
        timeout: TimeInterval,
        terminationGrace: TimeInterval
    ) {
        let lifecycle = BoundedChildLifecycle()
        self.lifecycle = lifecycle
        self.task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    nanoseconds: BoundedChildDefaults.nanoseconds(for: timeout)
                )
            } catch {
                return
            }
            guard lifecycle.beginTimeout() else { return }
            child.terminate()
            do {
                try await Task.sleep(
                    nanoseconds: BoundedChildDefaults.nanoseconds(for: terminationGrace)
                )
            } catch {
                return
            }
            // `completed` covers both the leader and, for the bounded runner, its pipe. If the
            // leader exited but a descendant kept that pipe open, the group still needs KILL.
            guard !lifecycle.isCompleted else { return }
            child.kill()
        }
    }

    /// Marks every owned resource settled, cancels the sleeper, and returns whether its deadline
    /// won the race. Idempotence comes from the lifecycle's monotonic flags.
    func complete() -> Bool {
        lifecycle.complete()
        task.cancel()
        return lifecycle.didTimeOut
    }
}

/// TERM followed by KILL for a caller-driven interruption such as an output ceiling. A regular
/// deadline carries the semantic fact "timed out"; this helper deliberately does not, so a size
/// refusal can stop the same process group without later being mislabeled as a timeout.
final class ChildProcessEscalation: @unchecked Sendable {
    private let lifecycle: BoundedChildLifecycle
    private let task: Task<Void, Never>

    init(
        child: SpawnedChildProcess,
        terminationGrace: TimeInterval = BoundedChildDefaults.terminationGrace
    ) {
        let lifecycle = BoundedChildLifecycle()
        self.lifecycle = lifecycle
        child.terminate()
        task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    nanoseconds: BoundedChildDefaults.nanoseconds(for: terminationGrace)
                )
            } catch {
                return
            }
            guard !lifecycle.isCompleted else { return }
            child.kill()
        }
    }

    func complete() {
        lifecycle.complete()
        task.cancel()
    }
}

private final class BoundedChildLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timedOut = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func beginTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        timedOut = true
        return true
    }

    func complete() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

enum BoundedChildDefaults {
    static let maximumOutputBytes = 8 * 1024 * 1024
    static let readChunkBytes = 64 * 1024
    static let terminationGrace: TimeInterval = 1

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let nanoseconds = interval * 1_000_000_000
        return UInt64(min(nanoseconds, Double(UInt64.max)))
    }
}
