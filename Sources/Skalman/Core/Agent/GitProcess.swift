import Foundation

// MARK: - Failure

/// What a git invocation can fail with, shared by the reads and the writes so one vocabulary
/// reaches the pane.
enum GitFailure: LocalizedError, Equatable {
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
        case .timedOut: return "git took too long to answer."
        case .outputTooLarge: return "This diff is too large to display."
        case .noCommits: return "No commits yet."
        case .noDefaultBranch: return "No default branch found."
        case .baselineExpired: return "The turn baseline has expired."
        case .indexLocked: return "The index is in use — the agent is running a git command. Try again."
        case .nothingStaged: return "Nothing is staged."
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
    static func run(
        _ arguments: [String],
        in root: URL,
        input: Data? = nil,
        maximumOutput: Int = GitReviewDefaults.maximumDiffBytes
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitDefaults.executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
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
        var errorData = Data()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
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
        SkalmanLogger.git.info(
            "git \(arguments.first ?? "", privacy: .public) finished in \(elapsed)ms, \(outputData.count) bytes"
        )

        if interrupted.timedOut { throw GitFailure.timedOut }
        if interrupted.oversized { throw GitFailure.outputTooLarge }

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            SkalmanLogger.git.error(
                "git \(arguments.joined(separator: " "), privacy: .public) failed: \(message ?? "", privacy: .public)"
            )
            throw failure(fromStandardError: message)
        }

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
