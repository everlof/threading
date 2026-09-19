import Foundation

/// What a remote checkout's uncommitted changes came to.
enum RemoteGitReviewOutcome: Equatable, Sendable {
    /// The changes against `HEAD`, untracked files included. `truncated` when the diff reached its
    /// bound, so the pane can say it shows the first part rather than claim it is everything.
    case diffs(branch: String?, files: [GitFileDiff], truncated: Bool)
    /// The host has no `git` on its login shell's `PATH`.
    case noGit
    case notRepository
    /// The project's folder does not exist on the host.
    case missingDirectory
    case failed(String)
}

/// Reads a remote checkout's uncommitted changes in one `ssh` round trip.
///
/// **Read-only, and on git's own terms.** The command is built from the same flag lists the local
/// review uses (`GitReviewCommands.common` and `.diffFlags`), so a remote read never takes
/// `index.lock` and cannot drift from a local one. Untracked files are synthesized the way the local
/// pane does — git's diff never lists them — each one capped at the same 256 KB and never by writing
/// the index: `git diff --no-index /dev/null <file>` per file, in the same round trip.
///
/// **One round trip.** A `git status` over a fresh `ssh` measured 150–280 ms on the spike's VM, so the
/// branch, the tracked diff and every untracked file come back from one command, bounded on the host
/// with `head -c` so the capture here is the whole answer rather than a suffix of a larger one.
struct RemoteGitReviewReader: Sendable {

    static let shared = RemoteGitReviewReader()

    /// Reads off the main actor and answers on it.
    func uncommitted(
        destination: RemoteHostDestination,
        remoteDirectory: String,
        completion: @escaping @MainActor @Sendable (RemoteGitReviewOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.read(destination: destination, remoteDirectory: remoteDirectory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome) }
            }
        }
    }

    // MARK: - The host's half

    /// The command the host's login shell runs. POSIX only, like every remote command here: a remote
    /// launch already refuses a login shell that is not.
    static func command(remoteDirectory: String) -> String {
        let git: String = (["git"] + GitReviewCommands.common).map(quoted).joined(separator: " ")
        let diff: String = GitReviewCommands.diffFlags.map(quoted).joined(separator: " ")
        let marker = RemoteGitReviewDefaults.marker
        // The untracked half runs inside `sh -c '…'`, so its own single quotes are closed, escaped
        // and reopened — the one POSIX spelling of a quote inside a quoted word.
        let innerGit = git.replacingOccurrences(of: "'", with: "'\\''")
        let innerDiff = diff.replacingOccurrences(of: "'", with: "'\\''")
        let untrackedFile: String = "f=$1; [ -f \"$f\" ] && "
            + "[ \"$(wc -c < \"$f\")\" -le \(RemoteGitReviewDefaults.untrackedFileBytes) ] && "
            + "\(innerGit) diff \(innerDiff) --no-index -- /dev/null \"$f\"; exit 0"
        let untracked: String = "\(git) ls-files --others --exclude-standard -z "
            + "| head -c \(RemoteGitReviewDefaults.untrackedListBytes) "
            + "| xargs -0 -n 1 sh -c '\(untrackedFile)' sh"
        let tracked: String = "\(git) diff \(diff) \"$base\" --"
        let lines: [String] = [
            "cd \(quoted(remoteDirectory)) 2>/dev/null || { printf '\(marker) missing-directory\\n'; exit 0; }",
            "command -v git >/dev/null 2>&1 || { printf '\(marker) no-git\\n'; exit 0; }",
            "git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '\(marker) not-repository\\n'; exit 0; }",
            "printf '\(marker) branch %s\\n' \"$(git symbolic-ref --short -q HEAD)\"",
            // A repository with no commit yet compares against the empty tree.
            "base=HEAD; git rev-parse -q --verify HEAD >/dev/null 2>&1 || base=\(RemoteGitReviewDefaults.emptyTree)",
            "{ \(tracked); \(untracked); } | head -c \(RemoteGitReviewDefaults.diffBytes)"
        ]
        return lines.joined(separator: "\n")
    }

    /// Reads the answer: one marker line, then the unified diff.
    static func parse(_ output: Data) -> RemoteGitReviewOutcome {
        guard let newline = output.firstIndex(of: UInt8(ascii: "\n")) else {
            return .failed("The host's answer about its checkout could not be read.")
        }
        let header = String(decoding: output[output.startIndex..<newline], as: UTF8.self)
        let prefix = RemoteGitReviewDefaults.marker + " "
        guard header.hasPrefix(prefix) else {
            return .failed("The host's answer about its checkout could not be read.")
        }
        let status = header.dropFirst(prefix.count)
        switch status {
        case "missing-directory": return .missingDirectory
        case "no-git": return .noGit
        case "not-repository": return .notRepository
        default: break
        }
        guard status.hasPrefix("branch") else {
            return .failed("The host's answer about its checkout could not be read.")
        }
        let branchName = status.dropFirst("branch".count).trimmingCharacters(in: .whitespaces)
        let body = output[output.index(after: newline)...]
        let truncated = body.count >= RemoteGitReviewDefaults.diffBytes
        return .diffs(
            branch: branchName.isEmpty ? nil : branchName,
            files: GitDiffParser.files(fromUnifiedDiff: String(decoding: body, as: UTF8.self)),
            truncated: truncated
        )
    }

    // MARK: - Private Methods

    private static func read(destination: RemoteHostDestination, remoteDirectory: String) -> RemoteGitReviewOutcome {
        do {
            let result = try BoundedChildProcess.run(
                executable: RemoteHostDefaults.sshExecutable,
                arguments: destination.sshArguments(extraOptions: RemoteHostDefaults.compressionOptions)
                    + [command(remoteDirectory: remoteDirectory)],
                timeout: RemoteGitReviewDefaults.timeout,
                maximumOutputBytes: RemoteGitReviewDefaults.diffBytes + RemoteGitReviewDefaults.headerBytes,
                output: .standardOutput
            )
            guard result.termination == .exited(0) else {
                return .failed(L10n.string("Threading couldn’t reach this machine with ssh."))
            }
            return parse(result.output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func quoted(_ word: String) -> String {
        ShellCommand(word: word).source
    }
}

enum RemoteGitReviewDefaults {
    static let marker = "THREADING-GIT"
    /// The local pane's own stdout ceiling for one git read.
    static let diffBytes = 8 * 1024 * 1024
    static let headerBytes = 4_096
    /// The local pane's cap on one untracked file's synthesized diff.
    static let untrackedFileBytes = 256 * 1024
    /// How much of the untracked list is read. A name cut short at this edge is not a file, and the
    /// host's own `[ -f ]` drops it.
    static let untrackedListBytes = 256 * 1024
    static let timeout: TimeInterval = 30
    /// Git's well-known empty tree, for a repository with no commit yet.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}
