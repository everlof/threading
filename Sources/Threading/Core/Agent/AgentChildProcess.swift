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
                    AgentChildProcessDefaults.standardInputDescriptor: inputPipe.readEnd,
                    AgentChildProcessDefaults.standardOutputDescriptor: outputPipe.writeEnd,
                    AgentChildProcessDefaults.standardErrorDescriptor: errorPipe.writeEnd
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

        process.enrol(in: ledger, sessionID: sessionID, executable: executable)
        // The pid rather than the child: the supervisor stores this handler, so capturing it
        // here would be a cycle that only the reap could break — including for a child that
        // never exits.
        let pid = child.processIdentifier
        child.observeExit { status in
            ledger.clear(pid: pid)
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
        child.terminate()
    }

    // MARK: - Private Methods

    /// Records the child before anything else can go wrong with it.
    ///
    /// A record without a start time is worse than no record: the sweep would have a pid and no
    /// way to tell our child from whatever the kernel later gives that number to, and its only
    /// safe move would be to skip it anyway. So an unreadable start time refuses the record and
    /// says so, rather than writing an entry that can only ever be ignored.
    private func enrol(in ledger: AgentChildLedger, sessionID: SessionID, executable: String) {
        guard let startTime = ProcessUtility.startTime(forPid: processIdentifier) else {
            ThreadingLogger.agent.error(
                """
                Could not read the start time of agent child \
                \(self.processIdentifier, privacy: .public); it will not be swept if this \
                launch crashes.
                """
            )
            return
        }

        ledger.record(AgentChildRecord(
            pid: processIdentifier,
            startTime: startTime,
            sessionID: sessionID.uuidString,
            executable: URL(fileURLWithPath: executable).lastPathComponent,
            recordedAt: Date()
        ))
    }
}

// MARK: - Child Pipe

/// One `pipe(2)`, before either end has been handed to a `FileHandle`.
///
/// Raw descriptors rather than `Pipe`, because the parent must close the child's ends the
/// instant `posix_spawn` returns and `Pipe` owns both of its handles until it is released.
private final class ChildPipe {
    private(set) var readEnd: Int32
    private(set) var writeEnd: Int32

    /// - Parameter closingOnFailure: pipes already created for this spawn, closed if this one
    ///   cannot be made. A descriptor leak here is permanent for the life of the app.
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
