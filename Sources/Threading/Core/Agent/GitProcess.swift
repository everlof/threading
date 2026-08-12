import Foundation
import os

// MARK: - Failure

/// What a git invocation can fail with, shared by the reads and the writes so one vocabulary
/// reaches the pane.
enum GitFailure: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case gitFailed(String)
    case timedOut
    case outputTooLarge
    /// An internal supersession signal. Review generations consume this rather than presenting
    /// it: the useful compact comparison has won the race, so continuing to generate a complete
    /// patch would spend CPU and I/O on bytes no surface will retain.
    case cancelled
    case noCommits
    case noDefaultBranch
    case baselineExpired
    case checkpointIncomplete(String)
    case checkpointMissing
    case checkpointRepositoryMismatch

    /// Another git — the agent's, usually — holds `index.lock`. Named apart from a general
    /// failure because it is the one error that is worth simply trying again.
    case indexLocked

    case nothingStaged

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        case .gitFailed(let message): return message
        case .timedOut: return L10n.string("git took too long to answer.")
        case .outputTooLarge: return L10n.string("This diff is too large to display.")
        case .cancelled: return L10n.string("The git operation was cancelled.")
        case .noCommits: return L10n.string("No commits yet.")
        case .noDefaultBranch: return L10n.string("No default branch found.")
        case .baselineExpired: return L10n.string("The turn baseline has expired.")
        case .checkpointIncomplete(let detail): return detail
        case .checkpointMissing:
            return L10n.string("This turn’s checkpoint is missing from the repository.")
        case .checkpointRepositoryMismatch:
            return L10n.string("This turn belongs to a different repository.")
        case .indexLocked:
            return L10n.string(
                "The index is in use — the agent is running a git command. Try again."
            )
        case .nothingStaged: return L10n.string("Nothing is staged.")
        }
    }
}

// MARK: - Process

/// Runs `git` and collects its output.
///
/// One runner for the review pane's reads and its index writes: the pipe handling, the
/// timeout and the oversized-output guard are the parts with the traps in them, and having
/// them once is what keeps a second copy from getting them subtly wrong.
///
/// Every call blocks, so callers hop to a queue of their own first.
enum GitProcess {

    // MARK: - Public Methods

    /// Runs git and returns stdout. `input`, when given, is written to stdin and the pipe
    /// closed — which is how a patch reaches `git apply -`.
    ///
    /// `acceptedExitCodes` exists for the commands whose non-zero exit is an answer rather
    /// than a failure: `diff --no-index` exits 1 to say "the files differ".
    /// `reportsRejectedExit` is false only for probes whose rejected status is an ordinary
    /// negative answer that the caller deliberately converts to nil/false.
    static func run(
        _ arguments: [String],
        in root: URL,
        input: Data? = nil,
        environmentOverrides: [String: String] = [:],
        maximumOutput: Int = GitReviewDefaults.maximumDiffBytes,
        acceptedExitCodes: Set<Int32> = [0],
        reportsRejectedExit: Bool = true,
        cancellation: GitProcessCancellation? = nil
    ) throws -> Data {
        let command = arguments.first(where: { !$0.hasPrefix("-") }) ?? "unknown"
        let performanceSpan = PerformanceRecorder.shared.begin(
            "git.process",
            category: "git.process",
            metadata: ["command": command]
        )
        var performanceResult = "failure"
        var performanceOutputBytes = 0
        defer {
            performanceSpan.end(metadata: [
                "result": performanceResult,
                "output_bytes": String(performanceOutputBytes)
            ])
        }

        let stdout = try ChildPipe()
        let stderr = try ChildPipe(closingOnFailure: [stdout])
        let stdin: ChildPipe?
        if input == nil {
            stdin = nil
        } else {
            stdin = try ChildPipe(closingOnFailure: [stdout, stderr])
        }

        let child: SpawnedChildProcess
        let started = Date()
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: GitDefaults.executablePath),
                arguments: arguments,
                environment: GitChildEnvironment.make(overrides: environmentOverrides),
                workingDirectory: root,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor:
                        stdin.map { .inherited($0.readEnd) } ?? .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor:
                        .inherited(stdout.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor:
                        .inherited(stderr.writeEnd)
                ]
            )
        } catch {
            stdout.closeBothEnds()
            stderr.closeBothEnds()
            stdin?.closeBothEnds()
            throw GitFailure.launchFailed(error.localizedDescription)
        }
        cancellation?.attach(child)

        stdout.closeWriteEnd()
        stderr.closeWriteEnd()
        stdin?.closeReadEnd()
        let outputReader = stdout.takeReadHandle()
        let errorReader = stderr.takeReadHandle()
        let inputWriter = stdin?.takeWriteHandle()
        let deadline = ChildProcessDeadline(
            child: child,
            timeout: GitReviewDefaults.timeout,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )

        // Written on another queue: a patch larger than the pipe buffer would otherwise block
        // here while git is still waiting for us to read its output.
        let inputWritten = DispatchGroup()
        if let inputWriter, let input {
            inputWritten.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { inputWritten.leave() }
                // The throwing form: a git that rejected the patch and exited early leaves a
                // pipe with no reader, and the non-throwing `write` raises on that rather than
                // returning an error. The exit status is what reports the failure.
                try? inputWriter.write(contentsOf: input)
                try? inputWriter.close()
            }
        }

        // One reader per pipe, so neither can fill while the other blocks: stderr drains on a
        // global queue while the caller's queue reads stdout to EOF.
        let errorCapture = GitProcessDataCapture()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCapture.replace(with: BoundedChildProcess.captureSuffix(
                from: errorReader,
                maximumBytes: GitProcessDefaults.maximumErrorBytes
            ).data)
            try? errorReader.close()
            stderrDrained.leave()
        }

        var outputData = Data()
        var outputWasOversized = false
        var outputReadError: Error?
        var outputEscalation: ChildProcessEscalation?
        let outputLimit = max(0, maximumOutput)
        do {
            while let chunk = try outputReader.read(
                upToCount: BoundedChildDefaults.readChunkBytes
            ), !chunk.isEmpty {
                guard !outputWasOversized else { continue }
                if outputData.count + chunk.count > outputLimit {
                    outputWasOversized = true
                    outputEscalation = ChildProcessEscalation(child: child)
                } else {
                    outputData.append(chunk)
                }
            }
        } catch {
            outputReadError = error
        }
        try? outputReader.close()

        child.waitUntilExit()
        let timedOut = deadline.complete()
        outputEscalation?.complete()
        cancellation?.complete()
        inputWritten.wait()
        stderrDrained.wait()

        let elapsed = Int(-started.timeIntervalSinceNow * 1000)
        performanceOutputBytes = outputData.count
        ThreadingLogger.git.debug(
            "git \(arguments.first ?? "", privacy: .private(mask: .hash)) finished in \(elapsed, privacy: .public)ms, \(outputData.count, privacy: .public) bytes"
        )

        if timedOut { throw GitFailure.timedOut }
        if cancellation?.isCancelled == true { throw GitFailure.cancelled }
        if outputWasOversized { throw GitFailure.outputTooLarge }
        if let outputReadError { throw GitFailure.gitFailed(outputReadError.localizedDescription) }

        guard acceptedExitCodes.contains(child.terminationStatus) else {
            let message = String(data: errorCapture.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if reportsRejectedExit {
                ThreadingLogger.git.error(
                    "git \(arguments.joined(separator: " "), privacy: .private(mask: .hash)) failed: \(message ?? "", privacy: .private(mask: .hash))"
                )
            }
            throw failure(fromStandardError: message)
        }

        performanceResult = "success"
        return outputData
    }

    // MARK: - Private Methods

    /// git says an index it cannot lock is a file that already exists; that is worth telling
    /// apart from a real failure, since the answer is to wait rather than to fix anything.
    private static func failure(fromStandardError message: String?) -> GitFailure {
        guard let message, !message.isEmpty else { return .gitFailed("git failed.") }
        if message.contains(GitWriteDefaults.lockErrorMarker) { return .indexLocked }
        return .gitFailed(message)
    }

}

/// One caller-owned cancellation for one bounded Git process. Cancellation terminates the whole
/// spawned process group and escalates to KILL after the ordinary bounded-child grace period, so a
/// filter or descendant keeping stdout open cannot strand the synchronous reader. The token is
/// deliberately narrower than Swift task cancellation: `GitProcess.run` blocks a queue thread.
final class GitProcessCancellation: @unchecked Sendable {
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
        let escalation = self.escalation
        self.escalation = nil
        lock.unlock()
        escalation?.complete()
    }
}

private enum GitProcessDefaults {
    /// Git diagnostics are useful at the end (the failed ref or hook), not as an unbounded log.
    static let maximumErrorBytes = 64 * 1024
}

// MARK: - Environment

/// The environment inherited by app-owned Git processes.
///
/// `/usr/bin/git` itself is absolute, but programs Git launches are not: hooks, credential
/// helpers, clean/smudge filters and Git LFS all resolve on `PATH`. A Finder-launched app gets
/// launchd's small environment rather than the PATH the user's login shell gives an agent.
/// Resolve that PATH once per shell and pass it to Git without running Git itself through shell
/// source text.
enum GitChildEnvironment {
    private enum CachedLoginPath: Sendable {
        case found(String)
        case unavailable

        var value: String? {
            switch self {
            case .found(let path): path
            case .unavailable: nil
            }
        }
    }

    private static let loginPaths = OSAllocatedUnfairLock(
        initialState: [String: CachedLoginPath]()
    )

    static func make(overrides: [String: String] = [:]) -> [String: String] {
        make(
            inherited: ProcessInfo.processInfo.environment,
            loginPath: loginPath(for: loginShell),
            overrides: overrides
        )
    }

    /// Background Git work cannot read the main-actor terminal profile. The account's SHELL is
    /// the login shell whose startup files define PATH; the terminal profile is a separate UI
    /// choice that normally agrees but must not pull Git back onto the main actor.
    private static var loginShell: String {
        ProcessInfo.processInfo.environment[EnvironmentKeys.shell] ?? "/bin/zsh"
    }

    /// Pure merge policy kept visible to tests: the login shell replaces only PATH, while an
    /// operation's explicit environment remains the final authority (alternate indexes rely on
    /// this same ordering).
    static func make(
        inherited: [String: String],
        loginPath: String?,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited
        if let loginPath {
            environment[EnvironmentKeys.path] = loginPath
        }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for (name, value) in overrides {
            environment[name] = value
        }
        return environment
    }

    /// Login files sometimes print a greeting. `exec` prevents logout output after `printenv`,
    /// so the final non-empty line is the one answer rather than shell decoration before it.
    static func path(fromShellOutput output: String) -> String? {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }

    private static func loginPath(for shell: String) -> String? {
        if let cached = loginPaths.withLock({ $0[shell] }) {
            return cached.value
        }

        let resolved = resolveLoginPath(shell: shell)
        loginPaths.withLock {
            $0[shell] = resolved.map(CachedLoginPath.found) ?? .unavailable
        }
        return resolved
    }

    private static func resolveLoginPath(shell: String) -> String? {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: shell,
                arguments: ["-l", "-c", "exec /usr/bin/printenv PATH"],
                timeout: GitChildEnvironmentDefaults.loginPathTimeout,
                maximumOutputBytes: GitChildEnvironmentDefaults.maximumLoginPathBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.git.error(
                "Could not resolve login-shell PATH: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
        guard result.termination == .exited(0), !result.outputWasTruncated else { return nil }
        return path(fromShellOutput: String(decoding: result.output, as: UTF8.self))
    }
}

private enum GitChildEnvironmentDefaults {
    static let loginPathTimeout: TimeInterval = 5
    static let maximumLoginPathBytes = 64 * 1024
}

/// One cross-queue stderr handoff. The dispatch group establishes ordering for the caller;
/// the lock makes the ownership legible to Swift's concurrency checker as well.
private final class GitProcessDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func replace(with data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}
