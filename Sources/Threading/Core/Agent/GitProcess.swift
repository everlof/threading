import Foundation

// MARK: - Failure

/// What a git invocation can fail with, shared by the reads and the writes so one vocabulary
/// reaches the pane.
enum GitFailure: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case gitFailed(String)
    case timedOut
    case outputTooLarge
    case noCommits
    case noDefaultBranch
    case baselineExpired

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
        case .noCommits: return L10n.string("No commits yet.")
        case .noDefaultBranch: return L10n.string("No default branch found.")
        case .baselineExpired: return L10n.string("The turn baseline has expired.")
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
    static func run(
        _ arguments: [String],
        in root: URL,
        input: Data? = nil,
        environmentOverrides: [String: String] = [:],
        maximumOutput: Int = GitReviewDefaults.maximumDiffBytes,
        acceptedExitCodes: Set<Int32> = [0]
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitDefaults.executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for (name, value) in environmentOverrides {
            environment[name] = value
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin ?? FileHandle.nullDevice

        let started = Date()
        do {
            try process.run()
        } catch {
            throw GitFailure.launchFailed(error.localizedDescription)
        }

        // Written on another queue: a patch larger than the pipe buffer would otherwise block
        // here while git is still waiting for us to read its output.
        if let stdin, let input {
            DispatchQueue.global(qos: .userInitiated).async {
                // The throwing form: a git that rejected the patch and exited early leaves a
                // pipe with no reader, and the non-throwing `write` raises on that rather than
                // returning an error. The exit status is what reports the failure.
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        // One reader per pipe, so neither can fill while the other blocks: stderr drains on a
        // global queue while the caller's queue reads stdout to EOF.
        let errorCapture = GitProcessDataCapture()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCapture.replace(with: stderr.fileHandleForReading.readDataToEndOfFile())
            stderrDrained.leave()
        }

        let interrupted = InterruptFlag()
        let timeoutItem = DispatchWorkItem {
            interrupted.markTimedOut()
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + GitReviewDefaults.timeout, execute: timeoutItem
        )

        var outputData = Data()
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            outputData.append(chunk)
            if outputData.count > maximumOutput {
                interrupted.markOversized()
                process.terminate()
                _ = reader.readDataToEndOfFile()
                break
            }
        }

        process.waitUntilExit()
        timeoutItem.cancel()
        stderrDrained.wait()

        let elapsed = Int(-started.timeIntervalSinceNow * 1000)
        performanceOutputBytes = outputData.count
        ThreadingLogger.git.info(
            "git \(arguments.first ?? "", privacy: .public) finished in \(elapsed)ms, \(outputData.count) bytes"
        )

        if interrupted.timedOut { throw GitFailure.timedOut }
        if interrupted.oversized { throw GitFailure.outputTooLarge }

        guard acceptedExitCodes.contains(process.terminationStatus) else {
            let message = String(data: errorCapture.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ThreadingLogger.git.error(
                "git \(arguments.joined(separator: " "), privacy: .public) failed: \(message ?? "", privacy: .public)"
            )
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

    /// Why a run was cut short, written by the timeout's queue and read after `waitUntilExit`.
    private final class InterruptFlag {
        private let lock = NSLock()
        private var timedOutValue = false
        private var oversizedValue = false

        func markTimedOut() { lock.lock(); timedOutValue = true; lock.unlock() }
        func markOversized() { lock.lock(); oversizedValue = true; lock.unlock() }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutValue }
        var oversized: Bool { lock.lock(); defer { lock.unlock() }; return oversizedValue }
    }
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
