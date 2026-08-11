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
        locate(
            shell: shell,
            fileManager: fileManager,
            shellOutput: runLocateCommand
        )
    }

    /// The locating policy with its process boundary supplied by the caller.
    ///
    /// Keeping output parsing outside `Process` makes the important rule — ignore login-shell
    /// greetings and use the last non-empty line — deterministic to test. The production entry
    /// point above still performs the real shell probe.
    static func locate(
        shell: String,
        fileManager: FileManager,
        shellOutput: (String) -> String?
    ) -> String? {
        for candidate in CodeStatsDefaults.executableCandidates
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        guard let output = shellOutput(shell),
              let path = output
                  .split(separator: "\n")
                  .map({ $0.trimmingCharacters(in: .whitespaces) })
                  .last(where: { !$0.isEmpty }),
              fileManager.isExecutableFile(atPath: path)
        else { return nil }

        return path
    }

    private static func runLocateCommand(shell: String) -> String? {
        guard let result = try? BoundedChildProcess.run(
            executable: shell,
            arguments: ["-l", "-c", CodeStatsDefaults.locateCommand],
            timeout: CodeStatsDefaults.locateTimeout,
            maximumOutputBytes: CodeStatsDefaults.maximumLocateOutputBytes
        ), result.termination == .exited(0) else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    // MARK: - Measuring

    /// Counts one folder. Blocking; nil when scc failed or the folder is gone.
    static func measure(folder: String, executable: String) -> CodeStats? {
        let started = Date()
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: executable,
                arguments: CodeStatsDefaults.arguments + [folder],
                timeout: CodeStatsDefaults.timeout,
                maximumOutputBytes: CodeStatsDefaults.maximumOutputBytes
            )
        } catch {
            ThreadingLogger.agent.error(
                "Could not run scc: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        guard result.termination == .exited(0), !result.outputWasTruncated else { return nil }

        let elapsed = Int(-started.timeIntervalSinceNow * 1000)
        ThreadingLogger.agent.debug(
            "scc measured \(folder, privacy: .private(mask: .hash)) in \(elapsed, privacy: .public)ms, \(result.output.count, privacy: .public) bytes"
        )

        return try? CodeStats.parse(sccJSON: result.output)
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
    static let locateTimeout: TimeInterval = 5
    static let maximumLocateOutputBytes = 64 * 1024
    static let maximumOutputBytes = 32 * 1024 * 1024

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
