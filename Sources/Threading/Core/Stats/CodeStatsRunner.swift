import Foundation

// MARK: - Code Stats Runner

/// Runs Threading's bundled `scc` over one project folder.
///
/// The helper is part of the signed app, so this path never consults a login shell, Homebrew, or
/// the user's `PATH`. Every call blocks and belongs on a utility queue. Running from the project
/// directory keeps ignore behavior scoped to the folder being described. Git resolves its own
/// standard excludes; scc continues to apply `.ignore` and `.sccignore`.
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
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        guard let executable else {
            ThreadingLogger.agent.error("Bundled scc is missing from Contents/Helpers")
            return nil
        }

        guard let ignoreArguments = CodeStatsIgnoreArguments.make(for: folderURL) else {
            return nil
        }

        let started = Date()
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: executable,
                arguments: CodeStatsDefaults.baseArguments + ignoreArguments + [folderURL.path],
                workingDirectory: folderURL,
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

// MARK: - Git Ignore Boundary

/// Turns Git's exact ignored-path answer into exclusions understood by scc.
///
/// scc's parser reads worktree `.gitignore` files, but not `.git/info/exclude` or the user's
/// global excludes. Asking Git for the resolved roster avoids maintaining a second ignore parser
/// here, and lets tracked files remain countable even when they match an ignore pattern.
/// The roster and the resulting argv both fail closed at fixed byte bounds: a partial exclusion
/// list would make a precise-looking code total wrong.
private enum CodeStatsIgnoreArguments {

    static func make(for folder: URL) -> [String]? {
        var directories = CodeStatsDefaults.alwaysExcludedDirectories
        var files: [String] = []
        let usesGitRoster = GitInfo.worktreeLocation(for: folder.path) != nil

        if usesGitRoster {
            guard let entries = gitIgnoredEntries(in: folder) else { return nil }
            for entry in entries {
                let path = entry.isDirectory
                    ? String(entry.path.dropLast())
                    : entry.path
                guard let absolutePath = absolutePath(for: path, below: folder) else {
                    return nil
                }
                if entry.isDirectory {
                    directories.append(absolutePath)
                } else {
                    files.append(absolutePath)
                }
            }
        }

        directories = stableUnique(directories)
        files = stableUnique(files)

        var arguments = usesGitRoster ? ["--no-gitignore"] : []
        arguments += ["--exclude-dir", csvList(directories)]
        if !files.isEmpty {
            arguments += ["--not-match", exactPathRegex(files)]
        }

        guard argumentBytes(arguments) <= CodeStatsDefaults.maximumExclusionArgumentBytes else {
            ThreadingLogger.agent.error("Git ignore roster is too large to pass safely to scc")
            return nil
        }
        return arguments
    }

    private struct IgnoredEntry {
        let path: String
        let isDirectory: Bool
    }

    private static func gitIgnoredEntries(in folder: URL) -> [IgnoredEntry]? {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: GitDefaults.executablePath,
                arguments: CodeStatsDefaults.gitIgnoredPathArguments,
                workingDirectory: folder,
                timeout: CodeStatsDefaults.gitIgnoreTimeout,
                maximumOutputBytes: CodeStatsDefaults.maximumGitIgnoreOutputBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.agent.error(
                "Could not resolve Git ignores for code stats: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        guard result.termination == .exited(0), !result.outputWasTruncated else {
            ThreadingLogger.agent.error("Git ignore roster was unavailable or exceeded its bound")
            return nil
        }
        guard result.output.isEmpty || result.output.last == 0 else {
            ThreadingLogger.agent.error("Git ignore roster was not NUL terminated")
            return nil
        }

        var entries: [IgnoredEntry] = []
        for bytes in result.output.split(separator: 0) {
            guard let path = String(data: Data(bytes), encoding: .utf8), !path.isEmpty else {
                ThreadingLogger.agent.error("Git ignore roster contained a non-UTF-8 path")
                return nil
            }
            entries.append(IgnoredEntry(path: path, isDirectory: path.hasSuffix("/")))
        }
        return entries
    }

    private static func absolutePath(for relativePath: String, below folder: URL) -> String? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let candidate = folder.appendingPathComponent(relativePath).standardizedFileURL.path
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return candidate.hasPrefix(prefix) ? candidate : nil
    }

    /// pflag's StringSlice parser uses CSV. Quoting here preserves commas, quotes and newlines in
    /// real directory names instead of turning one exact Git path into several broader rules.
    private static func csvList(_ values: [String]) -> String {
        values.map { value in
            guard value.contains(",") || value.contains("\"")
                    || value.contains("\n") || value.contains("\r")
            else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }

    /// scc applies `--not-match` to complete file locations. One anchored alternation keeps file
    /// exclusions path-specific; a basename flag would hide an unrelated file elsewhere.
    private static func exactPathRegex(_ paths: [String]) -> String {
        let alternatives = paths.map(regexQuoted).joined(separator: "|")
        return paths.count == 1 ? "^\(alternatives)$" : "^(\(alternatives))$"
    }

    /// Mirrors Go's regexp.QuoteMeta set, which is the syntax scc compiles.
    private static func regexQuoted(_ value: String) -> String {
        let metacharacters = "\\.+*?()|[]{}^$"
        var quoted = ""
        quoted.reserveCapacity(value.count)
        for character in value {
            if metacharacters.contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func argumentBytes(_ arguments: [String]) -> Int {
        arguments.reduce(0) { $0 + $1.utf8.count + 1 }
    }
}

// MARK: - Code Stats Defaults

enum CodeStatsDefaults {
    static let executableName = "scc"
    static let claudeWorktreesDirectory = ".claude/worktrees"

    /// Supplying `--exclude-dir` replaces scc's defaults rather than appending to them. Keep the
    /// helper's metadata exclusions explicit before adding Threading's nested-worktree rule and
    /// Git's resolved ignored directories. Claude's default worktree root holds complete nested
    /// checkouts rather than more project source, so it remains excluded before a repository adds
    /// Claude's recommended ignore rule.
    static let alwaysExcludedDirectories = [
        ".git", ".hg", ".svn", claudeWorktreesDirectory
    ]

    /// `--no-min-gen` keeps vendored minified bundles and generated files from dominating a
    /// bar that exists to describe what was written here; COCOMO is a number nobody asked for.
    static let baseArguments = ["--format", "json", "--no-cocomo", "--no-min-gen"]

    static let gitIgnoredPathArguments = [
        "--no-optional-locks", "ls-files", "--others", "--ignored", "--exclude-standard",
        "--directory", "--no-empty-directory", "-z", "--", "."
    ]

    static let timeout: TimeInterval = 30
    static let maximumOutputBytes = 32 * 1_024 * 1_024
    static let gitIgnoreTimeout: TimeInterval = 15
    static let maximumGitIgnoreOutputBytes = 128 * 1_024
    static let maximumExclusionArgumentBytes = 128 * 1_024
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
