import Foundation

// MARK: - Code Stats Runner

/// Runs Threading's bundled `scc` over one project folder.
///
/// The helper is part of the signed app, so this path never consults a login shell, Homebrew, or
/// the user's `PATH`. Every call blocks and belongs on a utility queue. Running from the project
/// directory keeps scc's ordinary `.gitignore`, `.ignore`, and `.sccignore` behavior scoped to the
/// folder being described.
enum CodeStatsRunner {

    /// Returns the helper embedded in the macOS app, failing closed when packaging is broken.
    static func bundledExecutable(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        let path = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(CodeStatsDefaults.executableName)
            .path
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    /// Counts one folder. Blocking; nil when scc failed, its bundled copy is absent, or the
    /// folder disappeared.
    static func measure(
        folder: String,
        executable: String? = bundledExecutable()
    ) -> CodeStats? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        guard let executable else {
            ThreadingLogger.agent.error("Bundled scc is missing from Contents/Helpers")
            return nil
        }

        let started = Date()
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: executable,
                arguments: CodeStatsDefaults.arguments + ["."],
                workingDirectory: URL(fileURLWithPath: folder, isDirectory: true),
                timeout: CodeStatsDefaults.timeout,
                maximumOutputBytes: CodeStatsDefaults.maximumOutputBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.agent.error(
                "Could not run bundled scc: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        guard result.termination == .exited(0), !result.outputWasTruncated else { return nil }

        let elapsed = Int(-started.timeIntervalSinceNow * 1_000)
        ThreadingLogger.agent.debug(
            "scc measured \(folder, privacy: .private(mask: .hash)) in \(elapsed, privacy: .public)ms, \(result.output.count, privacy: .public) bytes"
        )

        return try? CodeStats.parse(sccJSON: result.output)
    }
}

// MARK: - Code Stats Defaults

enum CodeStatsDefaults {
    static let executableName = "scc"

    /// `--no-min-gen` keeps vendored minified bundles and generated files from dominating a
    /// bar that exists to describe what was written here; COCOMO is a number nobody asked for.
    static let arguments = ["--format", "json", "--no-cocomo", "--no-min-gen"]

    static let timeout: TimeInterval = 30
    static let maximumOutputBytes = 32 * 1_024 * 1_024
    static let fileName = "code-stats.json"

    /// Readings are rebuildable and arrive in bursts during passive scans. Keep publication
    /// immediate, but cap verified whole-cache rewrites to one per two-second window.
    static let persistenceCoalescingInterval: TimeInterval = 2

    static let firstPassDelay: TimeInterval = 5
    static let passiveInterval: TimeInterval = 10 * 60
    static let passiveTolerance: TimeInterval = 60
    static let staleAfter: TimeInterval = 30 * 60

    /// A hover reuses a reading for at least a minute, so pointer travel cannot launch one
    /// process per row.
    static let hoverRefreshAfter: TimeInterval = 60
}
