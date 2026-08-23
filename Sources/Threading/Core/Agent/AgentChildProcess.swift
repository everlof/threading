import Darwin
import Foundation
import ThreadingPTYHostKit

// MARK: - Agent Child Process

/// One native agent CLI: pipe stdio, its own process group, and a record on disk while it runs.
///
/// This is what the three native transports launch instead of `Process`, and the two things it
/// adds are the two `Process` cannot do. **Its own process group** means teardown reaches the
/// shells and subagents the CLI started rather than only the CLI — Stop is pressed for a fleet
/// that has run away, so the parent-only version does least exactly when it matters most.
/// **A ledger entry** means an app that is killed rather than quit leaves behind a record of
/// what it was running, which the next launch sweeps; before this, those children reparented to
/// launchd and stayed there.
///
/// The three streams stay three. Merging stderr into stdout would corrupt the JSON line stream
/// the transports parse, which is why every one of them reads diagnostics separately and only
/// surfaces them when the child dies unexpectedly.
final class AgentChildProcess {

    // MARK: - Properties

    let processIdentifier: pid_t

    /// The parent's ends. Ownership is here rather than in the caller so that closing them is
    /// one thing that happens when this object goes, not three things a transport remembers.
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    /// A child of this process, or nil for one the PTY host holds.
    private let child: SpawnedChildProcess?

    /// The link to `threading-ptyd`, or nil for a child of this process.
    ///
    /// Exactly one of these two is set. They are separate stored properties rather than an
    /// abstraction over both because the two things a caller does with a child — end it, ask
    /// whether it is running — are the *only* members they have in common, and every other
    /// question this file asks (the ledger's start time, the escalation, the hand-over) is
    /// answered differently enough that a shared protocol would be a name for a coincidence.
    private let host: PTYHostPipeLink?

    /// Whether the child lives in `threading-ptyd` and can outlive this process.
    var isHostBacked: Bool { host != nil }

    /// True once the child has been handed to the host, after which this object ends nothing.
    ///
    /// The quit path detaches every host-backed conversation and *then* tears every session down,
    /// and the second step must not undo the first. Guarded here as well as at the call site
    /// because tearing every session down must never be a way to kill a child nobody asked to
    /// stop — the same rule `AgentRuntime.terminateAll` already states for terminals.
    private let detached = AgentChildLifecycleFlag()

    /// True once somebody has asked for this child to end, after which it is never handed over.
    ///
    /// The other direction of the same rule, and it needs its own flag because "is it running"
    /// cannot answer it: a `kill` reaches the daemon immediately while `isRunning` stays true
    /// until the `exited` frame comes back.
    private let stopped = AgentChildLifecycleFlag()

    var isRunning: Bool {
        if let host { return host.isRunning && !detached.isSet }
        return child?.isRunning ?? false
    }

    // MARK: - Initialization

    private init(
        child: SpawnedChildProcess?,
        host: PTYHostPipeLink?,
        processIdentifier: pid_t,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.child = child
        self.host = host
        self.processIdentifier = processIdentifier
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    // MARK: - Public Methods

    /// Starts the CLI, or throws. Nothing here is asynchronous: `posix_spawn` reports a missing
    /// executable synchronously, exactly as `Process.run()` did, so the transports keep their
    /// "spawn failure is delivered async on main" contract by hopping in their own `catch`.
    ///
    /// - Parameter onExit: delivered exactly once, on the child's own reap queue, with the
    ///   status a shell would report. Installed after the spawn because the pid is what it
    ///   watches; a child that exits in between still delivers, because the supervisor keeps
    ///   the status for a late observer.
    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        sessionID: SessionID,
        ledger: AgentChildLedger = .shared,
        host: PTYHostChildPlan? = nil,
        eventLog: EventLog = .shared,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> AgentChildProcess {
        if let host, let hosted = launchInHost(
            host,
            executable: executable,
            arguments: arguments,
            environment: environment,
            sessionID: sessionID,
            ledger: ledger,
            eventLog: eventLog,
            onExit: onExit
        ) {
            return hosted
        }

        let inputPipe = try ChildPipe()
        // The child may exit after `posix_spawn` but before a transport's first initialization
        // write, or between any two later writes. This descriptor is the shared ownership
        // boundary for ACP, Codex and Claude, so make a closed reader an ordinary EPIPE error
        // here rather than letting any one transport terminate Threading with SIGPIPE.
        guard fcntl(inputPipe.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            let code = errno
            inputPipe.closeBothEnds()
            throw AgentChildInputError.noSignalProtectionFailed(code: code)
        }
        let outputPipe = try ChildPipe(closingOnFailure: [inputPipe])
        let errorPipe = try ChildPipe(closingOnFailure: [inputPipe, outputPipe])

        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor:
                        .inherited(inputPipe.readEnd),
                    AgentChildProcessDefaults.standardOutputDescriptor:
                        .inherited(outputPipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor:
                        .inherited(errorPipe.writeEnd)
                ]
            )
        } catch {
            [inputPipe, outputPipe, errorPipe].forEach { $0.closeBothEnds() }
            throw error
        }

        // The child holds its own copies now. Until the parent drops these, the read ends never
        // reach end-of-file and closing stdin never reads as end-of-input to the CLI — which is
        // the graceful shutdown every one of these transports depends on.
        inputPipe.closeReadEnd()
        outputPipe.closeWriteEnd()
        errorPipe.closeWriteEnd()

        let process = AgentChildProcess(
            child: child,
            host: nil,
            processIdentifier: child.processIdentifier,
            standardInput: FileHandle(fileDescriptor: inputPipe.writeEnd, closeOnDealloc: true),
            standardOutput: FileHandle(fileDescriptor: outputPipe.readEnd, closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errorPipe.readEnd, closeOnDealloc: true)
        )

        do {
            try process.enrol(child, in: ledger, sessionID: sessionID, executable: executable)
        } catch {
            // A native child without a durable ownership record is not a partially available
            // conversation. End its whole group before throwing so a launch failure cannot be
            // the mechanism that creates the orphan this wrapper exists to prevent.
            let escalation = ChildProcessEscalation(child: child)
            child.observeExit { _ in escalation.complete() }
            try? process.standardInput.close()
            try? process.standardOutput.close()
            try? process.standardError.close()
            throw error
        }
        let executableIdentity = URL(fileURLWithPath: executable).lastPathComponent
        ThreadingLogger.agent.info(
            "Agent child launched pid=\(child.processIdentifier, privacy: .public) session=\(sessionID.uuidString, privacy: .public) executable=\(executableIdentity, privacy: .private(mask: .hash))"
        )
        // The pid rather than the child: the supervisor stores this handler, so capturing it
        // here would be a cycle that only the reap could break — including for a child that
        // never exits.
        let pid = child.processIdentifier
        child.observeExit { status in
            ledger.clear(pid: pid)
            ThreadingLogger.agent.info(
                "Agent child exited pid=\(pid, privacy: .public) session=\(sessionID.uuidString, privacy: .public) status=\(status, privacy: .public)"
            )
            onExit(status)
        }

        return process
    }

    /// Ends the conversation's CLI **and everything it started**, cooperatively.
    ///
    /// The signal goes to the group, not the pid. A CLI that has backgrounded a shell or a
    /// subagent would otherwise leave it behind, reparented to launchd, with the ledger entry
    /// already cleared by the leader's own reap.
    func terminate() {
        // Handed to the host on the way out. Ending it here is exactly the bug the hand-over
        // exists to prevent, so this is a no-op rather than a signal.
        guard !detached.isSet else { return }
        stopped.set()
        ThreadingLogger.agent.notice(
            "Agent child termination requested pid=\(self.processIdentifier, privacy: .public)"
        )
        if let host {
            host.terminate()
            return
        }
        child?.terminate()
    }

    /// Hands a host-backed child to `threading-ptyd` instead of ending it.
    ///
    /// Answers false for a child of this process, which is what the quit path reads as "this one
    /// closes the ordinary way". **Blocking, bounded by `deadline`**, which the caller shares
    /// across every conversation so forty of them cost the same wait as one.
    ///
    /// The ledger record goes with it: the child is still running and still `.ptyHost`-owned, but
    /// this launch is over, and the record's only remaining reader would be the *next* launch's
    /// sweep — which the owner field already tells to leave it alone. Clearing it keeps the file
    /// a description of what this process is responsible for.
    @discardableResult
    func detachFromBackgroundHost(
        by deadline: Date,
        ledger: AgentChildLedger = .shared
    ) -> Bool {
        // A stop that has already been asked for is not a hand-over waiting to happen. The quit
        // question's third answer stops every host-backed child and *then* detaches whatever is
        // left, and the two steps compose only if the second can see that the first happened:
        // a transport's own `isRunning` does not clear until the exit is observed, which is a
        // frame away, so a `kill` would otherwise be followed by a `detach` for the same session.
        guard let host, !detached.isSet, !stopped.isSet else { return false }
        guard host.detach(by: deadline) else { return false }
        detached.set()
        ledger.clear(pid: processIdentifier)
        ThreadingLogger.agent.notice(
            "Agent child handed to the PTY host pid=\(self.processIdentifier, privacy: .public)"
        )
        return true
    }

    // MARK: - Private Methods — the host-backed launch

    /// Starts the CLI in `threading-ptyd`, or answers nil having said why.
    ///
    /// **Nil is always "run it here instead".** Every way this can fail — no daemon, a version
    /// gate that refused, a `spawnRefused`, a silence — is a degradation to exactly the launch
    /// this app performed before the daemon existed, and every one of them is journalled with a
    /// structural cause, because a feature that quietly stopped working cannot be explained from
    /// a support report without that line. It never throws: a throw here would be a launch
    /// failure on a conversation that has a perfectly good way to start.
    ///
    /// **The three pipes are the same three pipes.** The transport is handed the identical ends
    /// it would have been handed by the local path — same `FileHandle`s, same
    /// `F_SETNOSIGPIPE` on standard input, same end-of-file semantics — and the link owns the
    /// other three and pumps them across the wire. That is what makes "the adapters see the same
    /// bytes" a property of the construction rather than a claim.
    private static func launchInHost(
        _ plan: PTYHostChildPlan,
        executable: String,
        arguments: [String],
        environment: [String: String],
        sessionID: SessionID,
        ledger: AgentChildLedger,
        eventLog: EventLog,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> AgentChildProcess? {
        guard let pipes = HostPipes() else {
            journal(.descriptorsUnavailable(errno), sessionID: sessionID, eventLog: eventLog)
            return nil
        }

        let link = PTYHostPipeLink(identity: plan.identity)
        let transport: any PTYHostSessionTransport
        do {
            transport = try plan.factory(link.events())
        } catch {
            pipes.closeAll()
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            journal(.linkUnavailable(cause), sessionID: sessionID, eventLog: eventLog)
            return nil
        }
        link.adopt(transport)

        // Adopted before the spawn, so no output frame can arrive with nowhere to go.
        link.adoptDescriptors(
            input: pipes.input.takeReadDescriptor(),
            output: pipes.output.takeWriteDescriptor(),
            error: pipes.errors.takeWriteDescriptor()
        )

        do {
            try link.spawn(PTYHostSpawnRequest(
                id: plan.identity,
                channel: .pipes,
                executable: executable,
                arguments: arguments,
                // Sorted for the reason `ChildProcessSpawn` sorts: an environment whose order
                // depends on a dictionary's hash seed is a launch that cannot be compared with
                // the one before it.
                environment: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
                cwd: plan.workingDirectory
            ))
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            link.close()
            pipes.closeAll()
            journal(.linkUnavailable(cause), sessionID: sessionID, eventLog: eventLog)
            return nil
        }

        let spawned: PTYHostSpawned
        switch link.awaitSpawn() {
        case .success(let value):
            spawned = value
        case .failure(let refusal):
            link.close()
            pipes.closeAll()
            journal(refusal, sessionID: sessionID, eventLog: eventLog)
            return nil
        }

        let process = AgentChildProcess(
            child: nil,
            host: link,
            processIdentifier: spawned.pid,
            standardInput: pipes.input.takeWriteHandle(),
            standardOutput: pipes.output.takeReadHandle(),
            standardError: pipes.errors.takeReadHandle()
        )

        // The daemon's own reading of the child's identity, not a second one taken here: the pid
        // is the daemon's child, and a start time read a moment later races the very reuse the
        // pair exists to rule out.
        let enrolment = ledger.recordHostBackedChild(
            pid: spawned.pid,
            startTime: ProcessStartTime(
                seconds: spawned.startTime.seconds,
                microseconds: spawned.startTime.microseconds
            ),
            sessionID: sessionID.uuidString,
            executable: executable
        )
        guard enrolment == .recorded else {
            // The same discipline the local path applies, with the one difference the host
            // makes: the child is not ours to signal directly, so the kill goes through the
            // link. A hosted child with no record is a child a launch cannot even name.
            ThreadingLogger.agent.error(
                """
                Could not record host-backed agent child \
                \(spawned.pid, privacy: .public); ending it rather than running a child crash \
                recovery cannot see.
                """
            )
            link.terminate()
            link.close()
            return nil
        }

        let executableIdentity = URL(fileURLWithPath: executable).lastPathComponent
        ThreadingLogger.agent.info(
            "Agent child launched in the PTY host pid=\(spawned.pid, privacy: .public) session=\(sessionID.uuidString, privacy: .public) executable=\(executableIdentity, privacy: .private(mask: .hash))"
        )
        eventLog.record(.session, "Conversation runs its CLI in the PTY host", [
            "session": sessionID.uuidString,
            "pid": String(spawned.pid)
        ])

        let pid = spawned.pid
        link.delivery = PTYHostPipeLink.Delivery(ended: { status in
            ledger.clear(pid: pid)
            ThreadingLogger.agent.info(
                "Agent child exited pid=\(pid, privacy: .public) session=\(sessionID.uuidString, privacy: .public) status=\(status, privacy: .public)"
            )
            onExit(status)
        })
        return process
    }

    /// Why this launch is running in this process after all. One line, one structural cause.
    private static func journal(
        _ refusal: PTYHostChildRefusal,
        sessionID: SessionID,
        eventLog: EventLog
    ) {
        eventLog.record(.session, "Conversation runs its CLI in-process", [
            "session": sessionID.uuidString,
            "cause": refusal.token
        ])
    }

    // MARK: - Private Methods

    /// Records the child before anything else can go wrong with it.
    ///
    /// A record without a start time is worse than no record: the sweep would have a pid and no
    /// way to tell our child from whatever the kernel later gives that number to, and its only
    /// safe move would be to skip it anyway. So an unreadable start time refuses the record and
    /// says so, rather than writing an entry that can only ever be ignored.
    private func enrol(
        _ child: SpawnedChildProcess,
        in ledger: AgentChildLedger,
        sessionID: SessionID,
        executable: String
    ) throws {
        switch ledger.recordSpawnedChild(
            child,
            sessionID: sessionID.uuidString,
            executable: executable
        ) {
        case .recorded:
            return
        case .identityUnavailable:
            ThreadingLogger.agent.error(
                """
                Could not read the start time of agent child \
                \(self.processIdentifier, privacy: .public); it will not be swept if this \
                launch crashes.
                """
            )
            throw AgentChildLaunchError.identityUnavailable(processIdentifier)
        case .persistenceRefused:
            ThreadingLogger.agent.error(
                """
                Could not record agent child \(self.processIdentifier, privacy: .public); \
                refusing to run a child that crash recovery cannot own.
                """
            )
            throw AgentChildLaunchError.ledgerWriteFailed(processIdentifier)
        }
    }
}

// MARK: - Host launch support

/// The three pipes a host-backed launch makes, so a failure closes six descriptors rather than
/// remembering which four it had opened.
private final class HostPipes {

    let input: ChildPipe
    let output: ChildPipe
    let errors: ChildPipe

    init?() {
        guard let input = try? ChildPipe() else { return nil }
        // The same `F_SETNOSIGPIPE` the local path sets, and for the same reason from the other
        // end: the child may exit between any two of a transport's writes, and once it has, the
        // link closes its read end so a write is an ordinary `EPIPE` error rather than a signal
        // that ends Threading.
        guard fcntl(input.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            input.closeBothEnds()
            return nil
        }
        guard let output = try? ChildPipe(closingOnFailure: [input]),
              let errors = try? ChildPipe(closingOnFailure: [input, output]) else { return nil }
        self.input = input
        self.output = output
        self.errors = errors
    }

    func closeAll() {
        input.closeBothEnds()
        output.closeBothEnds()
        errors.closeBothEnds()
    }
}

/// One latching flag, readable from any thread.
///
/// A tiny type rather than an `NSLock` beside a `Bool` in `AgentChildProcess`, because the flags
/// are read from the transport's queue and set on the main actor, and `AgentChildProcess` itself
/// is not `Sendable` — the compiler would otherwise be right to complain about the pair rather
/// than about the class. Two of them exist, and they are the two ends of one rule: a child that
/// was handed over is never signalled, and a child that was signalled is never handed over.
final class AgentChildLifecycleFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum AgentChildInputError: LocalizedError {
    case noSignalProtectionFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .noSignalProtectionFailed(let code):
            return "The agent input pipe could not be made signal-safe (errno \(code))."
        }
    }
}

enum AgentChildLaunchError: LocalizedError {
    case identityUnavailable(pid_t)
    case ledgerWriteFailed(pid_t)

    var processIdentifier: pid_t {
        switch self {
        case .identityUnavailable(let pid), .ledgerWriteFailed(let pid): return pid
        }
    }

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            return "The agent process started, but its process identity could not be verified."
        case .ledgerWriteFailed:
            return "The agent process started, but its crash-recovery record could not be saved."
        }
    }
}

// MARK: - Agent Child Process Defaults

enum AgentChildProcessDefaults {
    static let standardInputDescriptor: Int32 = 0
    static let standardOutputDescriptor: Int32 = 1
    static let standardErrorDescriptor: Int32 = 2

    /// What a transport reports when the CLI never started. Not a status any child can exit
    /// with, so a caller can tell "it refused to launch" from "it ran and failed".
    static let spawnFailureStatus: Int32 = -1
}
