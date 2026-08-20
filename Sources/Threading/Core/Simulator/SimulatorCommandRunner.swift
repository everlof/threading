import Foundation

enum SimulatorCommandCapture: Equatable, Sendable {
    case combined
    case standardOutput
}

struct SimulatorCommandResult: Equatable, Sendable {
    let output: Data
    let outputWasTruncated: Bool
    let termination: BoundedChildTermination
}

protocol SimulatorCommandRunning: Sendable {
    func run(
        _ arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        capture: SimulatorCommandCapture,
        cancellation: SimulatorCommandCancellation
    ) throws -> SimulatorCommandResult
}

/// Runs finite `simctl` operations in their own process group. `executable` and
/// `prefixArguments` are injectable so cancellation and capture can be tested without depending
/// on whichever Xcode happens to be selected on the test machine.
struct XcrunSimulatorCommandRunner: SimulatorCommandRunning {
    private let executable: String
    private let prefixArguments: [String]

    init(
        executable: String = "/usr/bin/xcrun",
        prefixArguments: [String] = ["simctl"]
    ) {
        self.executable = executable
        self.prefixArguments = prefixArguments
    }

    func run(
        _ arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        capture: SimulatorCommandCapture,
        cancellation: SimulatorCommandCancellation
    ) throws -> SimulatorCommandResult {
        let outputPipe = try ChildPipe()
        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: executable),
                arguments: prefixArguments + arguments,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor:
                        .inherited(outputPipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor:
                        capture == .combined ? .inherited(outputPipe.writeEnd) : .nullDevice
                ]
            )
        } catch {
            outputPipe.closeBothEnds()
            throw error
        }
        cancellation.attach(child)

        outputPipe.closeWriteEnd()
        let output = outputPipe.takeReadHandle()
        let deadline = ChildProcessDeadline(
            child: child,
            timeout: timeout,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )
        let capture = BoundedChildProcess.captureSuffix(
            from: output,
            maximumBytes: maximumOutputBytes
        )
        child.waitUntilExit()
        let timedOut = deadline.complete()
        cancellation.complete()
        try? output.close()

        return SimulatorCommandResult(
            output: capture.data,
            outputWasTruncated: capture.wasTruncated,
            termination: timedOut ? .timedOut : .exited(child.terminationStatus)
        )
    }
}

/// Caller-owned cancellation for one simulator command. Mutable state is protected by `lock`;
/// the escalation owns the spawned process group until its TERM/KILL sequence has settled.
final class SimulatorCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var child: SpawnedChildProcess?
    private var escalation: ChildProcessEscalation?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        if let child {
            escalation = ChildProcessEscalation(child: child)
        }
        lock.unlock()
    }

    fileprivate func attach(_ child: SpawnedChildProcess) {
        lock.lock()
        self.child = child
        if cancelled {
            escalation = ChildProcessEscalation(child: child)
        }
        lock.unlock()
    }

    fileprivate func complete() {
        lock.lock()
        child = nil
        let escalation = escalation
        self.escalation = nil
        lock.unlock()
        escalation?.complete()
    }
}

/// One serial owner for simctl's process lifecycle. The queue is the only executor touching no
/// mutable state of its own; it sequences commands so prepare/install/release cannot race each
/// other while values and completions cross as `Sendable`.
final class SimulatorCommandQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
