import Foundation

/// Creates git worktrees, so a session can run on its own branch without disturbing the
/// checkout you are working in.
///
/// This is the one place the app mutates a repository, so it shells out to `git` rather than
/// writing git's internal files itself: worktree registration touches several files that must
/// stay consistent, and `git` is the only thing that gets that right.
enum GitWorktree {

    // MARK: - Types

    enum Failure: LocalizedError {
        case notARepository
        case destinationExists(String)
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                return L10n.string("This project is not inside a git repository.")
            case .destinationExists(let path):
                return L10n.format("%@ already exists.", path)
            case .gitFailed(let message):
                return message
            }
        }
    }

    // MARK: - Public Methods

    /// Suggests where a worktree for `branch` should live: beside the repository, named after
    /// it, so sibling worktrees of one repo group together on disk.
    static func suggestedLocation(forBranch branch: String, in project: Project) -> URL? {
        guard let root = GitInfo.repositoryRoot(for: project.folderPath) else { return nil }

        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        return root
            .deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(safeBranch)")
    }

    /// Creates a worktree at `destination` on a new `branch`.
    ///
    /// Returns the created directory, which is a checkout of the same repository and so will
    /// group with its siblings in the sidebar.
    @discardableResult
    static func create(branch: String, at destination: URL, from project: Project) throws -> URL {
        guard let root = GitInfo.repositoryRoot(for: project.folderPath) else {
            throw Failure.notARepository
        }

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.destinationExists(destination.path)
        }

        // -b creates the branch; without it an existing branch already checked out elsewhere
        // would be refused, which is the common case when reusing a name.
        try run(
            ["worktree", "add", "-b", branch, destination.path],
            in: root
        )

        return destination
    }

    /// Branch names already present in the repository, for offering existing branches.
    static func branches(in project: Project) -> [String] {
        guard let root = GitInfo.repositoryRoot(for: project.folderPath),
              let output = try? run(
                  ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
                  in: root
              )
        else { return [] }

        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private Methods

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitDefaults.executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw Failure.gitFailed(error.localizedDescription)
        }

        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.gitFailed(message.flatMap { $0.isEmpty ? nil : $0 } ?? "git failed.")
        }

        return String(data: outData, encoding: .utf8) ?? ""
    }
}
