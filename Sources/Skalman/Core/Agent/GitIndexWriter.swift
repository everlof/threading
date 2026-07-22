import Foundation

/// The review pane's write half: staging, unstaging and committing.
///
/// Deliberately separate from `GitReviewReader`, and deliberately small. The pane's rule was
/// read-only for a reason, and this is the whole of what crosses it — three verbs, no history
/// rewriting, no discarding. **There is no discard**: everything here is reversible with the
/// button beside it, where throwing away a change an agent just made is not reversible by
/// anything.
///
/// Unlike a read, a write *takes* `index.lock`, so it can lose a race with the agent working
/// in the same checkout. That is reported as `indexLocked` — its own case, because the answer
/// is to try again rather than to fix anything.
enum GitIndexWriter {

    // MARK: - Types

    typealias Failure = GitFailure

    // MARK: - Properties

    /// Writes queue behind one another: two `git apply --cached` runs racing for the index is
    /// exactly the contention this reports on.
    private static let queue = DispatchQueue(label: "com.skalman.git-write", qos: .userInitiated)

    // MARK: - Public Methods

    /// Applies one hunk to the index, or takes it back out when `reverse` is set. Completion
    /// arrives on main.
    static func apply(
        patch: String,
        reverse: Bool,
        in root: URL,
        completion: @escaping @MainActor (Result<Void, Failure>) -> Void
    ) {
        perform(completion) {
            SkalmanLogger.git.info("applying \(reverse ? "reverse" : "forward", privacy: .public) hunk patch")
            _ = try GitProcess.run(
                GitWriteCommands.applyToIndex(reverse: reverse),
                in: root,
                input: Data(patch.utf8)
            )
        }
    }

    /// Stages whole files — which is also the right verb for the ones a hunk cannot describe:
    /// an untracked file, a binary, a rename.
    static func stage(
        paths: [String],
        in root: URL,
        completion: @escaping @MainActor (Result<Void, Failure>) -> Void
    ) {
        perform(completion) {
            guard !paths.isEmpty else { return }
            _ = try GitProcess.run(GitWriteCommands.add(paths), in: root)
        }
    }

    /// Takes whole files back out of the index. On an unborn HEAD there is nothing to reset
    /// *to*, so the file is simply removed from the index instead.
    static func unstage(
        paths: [String],
        in root: URL,
        completion: @escaping @MainActor (Result<Void, Failure>) -> Void
    ) {
        perform(completion) {
            guard !paths.isEmpty else { return }
            if hasCommits(in: root) {
                _ = try GitProcess.run(GitWriteCommands.reset(paths), in: root)
            } else {
                _ = try GitProcess.run(GitWriteCommands.removeFromIndex(paths), in: root)
            }
        }
    }

    /// Commits what is staged and answers with the new commit's subject line. Nothing is
    /// staged for the user — `--only` on an empty selection would be a different command, and
    /// what is committed must be what the pane was showing as staged.
    static func commit(
        message: String,
        in root: URL,
        completion: @escaping @MainActor (Result<String, Failure>) -> Void
    ) {
        perform(completion) {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.gitFailed("A commit needs a message.") }

            // Staged emptiness is checked here rather than left to git, whose own message for
            // it is a page of status output.
            let staged = try GitProcess.run(GitWriteCommands.stagedNames(), in: root)
            guard !GitDiffParser.decode(staged).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.nothingStaged
            }

            SkalmanLogger.git.info("committing \(trimmed.count) characters of message")
            _ = try GitProcess.run(GitWriteCommands.commit(message: trimmed), in: root)
            return GitDiffParser.decode(try GitProcess.run(GitWriteCommands.headSubject(), in: root))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Private Methods

    private static func perform<Value>(
        _ completion: @escaping @MainActor (Result<Value, Failure>) -> Void,
        _ work: @escaping () throws -> Value
    ) {
        queue.async {
            let result: Result<Value, Failure>
            do {
                result = .success(try work())
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.gitFailed(error.localizedDescription))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    private static func hasCommits(in root: URL) -> Bool {
        (try? GitProcess.run(GitReviewCommands.common + GitReviewCommands.headHash(), in: root)) != nil
    }
}

// MARK: - Commands

/// The argument lists the writer runs — pure builders, so every one can be pinned by a test
/// without touching a repository.
enum GitWriteCommands {

    /// Literal paths, as the reads use. `--no-optional-locks` is deliberately *not* here: a
    /// write needs the lock it is about to take, and asking git to skip it would be a lie.
    static let common = ["-c", "core.quotepath=false"]

    /// `--cached` touches the index only, never the worktree — which is what makes every
    /// action here reversible by its opposite.
    static func applyToIndex(reverse: Bool) -> [String] {
        common + ["apply", "--cached", "--whitespace=nowarn"]
            + (reverse ? ["--reverse"] : []) + ["-"]
    }

    static func add(_ paths: [String]) -> [String] {
        common + ["add", "--"] + paths
    }

    static func reset(_ paths: [String]) -> [String] {
        common + ["reset", "--quiet", "HEAD", "--"] + paths
    }

    static func removeFromIndex(_ paths: [String]) -> [String] {
        common + ["rm", "--cached", "--quiet", "-r", "--"] + paths
    }

    static func stagedNames() -> [String] {
        common + ["diff", "--cached", "--name-only"]
    }

    static func commit(message: String) -> [String] {
        common + ["commit", "--message", message]
    }

    static func headSubject() -> [String] {
        common + ["log", "-1", "--pretty=format:%s"]
    }
}

// MARK: - Defaults

enum GitWriteDefaults {
    /// git's own words when another process holds the index.
    static let lockErrorMarker = "index.lock"

    /// The note a diff carries about a file whose last line has no newline.
    static let noNewlineMarker = "\\ No newline"
}
