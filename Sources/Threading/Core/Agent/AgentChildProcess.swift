import Darwin
import Foundation

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

    private let child: SpawnedChildProcess

    var isRunning: Bool { child.isRunning }

    // MARK: - Initialization

    private init(
        child: SpawnedChildProcess,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.child = child
        self.processIdentifier = child.processIdentifier
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
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> AgentChildProcess {
        let inputPipe = try ChildPipe()
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
            standardInput: FileHandle(fileDescriptor: inputPipe.writeEnd, closeOnDealloc: true),
            standardOutput: FileHandle(fileDescriptor: outputPipe.readEnd, closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errorPipe.readEnd, closeOnDealloc: true)
        )

        do {
            try process.enrol(in: ledger, sessionID: sessionID, executable: executable)
        } catch {
            // A native child without a durable ownership record is not a partially available
            // conversation. End its whole group before throwing so a launch failure cannot be
            // the mechanism that creates the orphan this wrapper exists to prevent.
            let escalation = ChildProcessEscalation(child: process.child)
            process.child.observeExit { _ in escalation.complete() }
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
        ThreadingLogger.agent.notice(
            "Agent child termination requested pid=\(self.processIdentifier, privacy: .public)"
        )
        child.terminate()
    }

    // MARK: - Private Methods

    /// Records the child before anything else can go wrong with it.
    ///
    /// A record without a start time is worse than no record: the sweep would have a pid and no
    /// way to tell our child from whatever the kernel later gives that number to, and its only
    /// safe move would be to skip it anyway. So an unreadable start time refuses the record and
    /// says so, rather than writing an entry that can only ever be ignored.
    private func enrol(
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
