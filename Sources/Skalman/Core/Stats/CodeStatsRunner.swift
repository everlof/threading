import Foundation

// MARK: - Code Stats Runner

/// Runs `scc` over a folder and returns what it counted.
///
/// scc is a tool the user installed, not a dependency of ours: when it is not on the machine
/// the feature stays quiet rather than fail — `locate` answers nil once and nothing downstream
/// runs. Every call here blocks, so callers hop to a queue of their own first (the same
/// contract as `GitProcess`).
enum CodeStatsRunner {

    // MARK: - Locating

    /// Finds the scc binary, or nil when the machine has none.
    ///
    /// Known install paths are tried first because they are a `stat` each; the login shell is
    /// the fallback that knows whatever `PATH` the user actually builds — a GUI app inherits
    /// neither Homebrew's prefix nor a Go bin directory (see `AgentLauncher.loginShellPath`).
    static func locate(shell: String, fileManager: FileManager = .default) -> String? {
        for candidate in CodeStatsDefaults.executableCandidates
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", CodeStatsDefaults.locateCommand]

        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded rather than piped: a pipe nobody drains can fill and deadlock the child.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer with nobody draining it deadlocks the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // The last non-empty line, not the whole output: a login shell is free to print a
        // greeting or a version-manager warning before the answer.
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .split(separator: "\n")
                  .map({ $0.trimmingCharacters(in: .whitespaces) })
                  .last(where: { !$0.isEmpty }),
              fileManager.isExecutableFile(atPath: path)
        else { return nil }

        return path
    }

    // MARK: - Measuring

    /// Counts one folder. Blocking; nil when scc failed or the folder is gone.
    static func measure(folder: String, executable: String) -> CodeStats? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = CodeStatsDefaults.arguments + [folder]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let started = Date()
        do {
            try process.run()
        } catch {
            SkalmanLogger.agent.error(
                "Could not run scc: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // scc answers a whole repository in tens of milliseconds, so the timeout is not a
        // budget but a leak guard: a wedged child on an unreadable mount must not outlive
        // the scan that spawned it.
        let timeoutItem = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + CodeStatsDefaults.timeout, execute: timeoutItem
        )

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let elapsed = Int(-started.timeIntervalSinceNow * 1000)
        SkalmanLogger.agent.debug(
            "scc measured \(folder, privacy: .public) in \(elapsed)ms, \(data.count) bytes"
        )

        return try? CodeStats.parse(sccJSON: data)
    }
}

// MARK: - Code Stats Defaults

enum CodeStatsDefaults {
    /// Where package managers put scc: Homebrew on Apple silicon and Intel, `go install`,
    /// and the user-local bin both CLIs already live in.
    static let executableCandidates: [String] = [
        "/opt/homebrew/bin/scc",
        "/usr/local/bin/scc",
        NSHomeDirectory() + "/go/bin/scc",
        NSHomeDirectory() + "/.local/bin/scc"
    ]

    static let locateCommand = "command -v scc"

    /// `--no-min-gen` keeps vendored minified bundles and generated files from dominating a
    /// bar that exists to describe what was *written* here; COCOMO is a number nobody asked.
    static let arguments = ["--format", "json", "--no-cocomo", "--no-min-gen"]

    static let timeout: TimeInterval = 30

    static let fileName = "code-stats.json"

    /// The first pass can start soon after launch: unlike the storage walk, a count is tens
    /// of milliseconds per project, so there is no launch contention worth dodging.
    static let firstPassDelay: TimeInterval = 5

    /// How often the passive pass looks for something stale — code the user edits outside
    /// any agent still changes, just not urgently.
    static let passiveInterval: TimeInterval = 10 * 60
    static let passiveTolerance: TimeInterval = 60

    static let staleAfter: TimeInterval = 30 * 60

    /// How fresh a reading must be for a hover to skip recounting: crossing rows on the way
    /// somewhere else must not launch a process per project.
    static let hoverRefreshAfter: TimeInterval = 60

    /// How long a "not installed" answer stands before the next refresh re-probes. Short,
    /// because the popover just told the user the install command.
    static let missingReprobeAfter: TimeInterval = 60
}
