import Foundation
import ThreadingController

// MARK: - Workroom Git Context

/// The checkout a workroom question is asked against, read by the host from the asking session's
/// working directory: never typed by the model, so an answer is paired with the code it was
/// actually about. Agents and the owner read it back; the domain expert's page never shows it.
///
/// Bounded at every step. Each git call runs through `GitProcess` with its own output cap and
/// deadline, the changed-path list stops at `WorkroomLimits.changedPaths` (with a total beside
/// it) and the commit list at `WorkroomLimits.commits`. It blocks, so callers run it off the main
/// actor (`capture`).
enum WorkroomGitContextReader {

    enum Failure: Error, Equatable {
        case notARepository
        case unknownBase(String)
    }

    /// Off the main actor; nil when the directory is not a git checkout.
    static func capture(directory: URL, base: String?) async -> Result<WorkroomGitContext, Failure> {
        await Task.detached(priority: .utility) { read(directory: directory, base: base) }.value
    }

    static func read(directory: URL, base: String?) -> Result<WorkroomGitContext, Failure> {
        guard let head = text(GitReviewCommands.headHash(), in: directory), isHash(head) else {
            return .failure(.notARepository)
        }
        let baseRef: String
        if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            guard isSafeRef(base), commitExists(base, in: directory) else { return .failure(.unknownBase(base)) }
            baseRef = base
        } else {
            guard let resolved = defaultBranch(in: directory) else { return .failure(.unknownBase("default branch")) }
            baseRef = resolved
        }
        guard let baseCommit = text(["rev-parse", "--verify", "--quiet", baseRef + "^{commit}"], in: directory),
              isHash(baseCommit) else { return .failure(.unknownBase(baseRef)) }
        let mergeBase = text(GitReviewCommands.mergeBase(baseRef), in: directory).flatMap { isHash($0) ? $0 : nil }
        let from = mergeBase ?? baseCommit
        let paths = (output(GitReviewCommands.diffNames(from: from, to: head), in: directory,
                            maximum: WorkroomGitDefaults.pathListBytes) ?? Data())
            .split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
        let commits = (text(["log", "--no-color", "--pretty=format:%H%x09%s",
                             "--max-count=\(WorkroomLimits.commits)", "\(from)..\(head)"], in: directory) ?? "")
            .split(separator: "\n").compactMap { line -> WorkroomCommit? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let hash = parts.first.map(String.init), isHash(hash) else { return nil }
                return WorkroomCommit(hash: hash, subject: clipped(parts.count > 1 ? String(parts[1]) : "",
                                                                   to: WorkroomLimits.subjectBytes))
            }
        let dirty = !(text(["status", "--porcelain", "--untracked-files=no"], in: directory) ?? "").isEmpty
        let repository = GitInfo.remoteOriginURL(for: directory.path)
            .flatMap(GitRemoteIdentity.init(remote:)).map { "\($0.host)/\($0.path)" }
        return .success(WorkroomGitContext(
            repository: repository.map { clipped($0, to: WorkroomLimits.refBytes) },
            baseRef: baseRef, baseCommit: baseCommit,
            headRef: GitInfo.currentBranch(for: directory.path).map { clipped($0, to: WorkroomLimits.refBytes) },
            headCommit: head, mergeBase: mergeBase,
            changedPaths: paths.prefix(WorkroomLimits.changedPaths).map { clipped($0, to: WorkroomLimits.pathBytes) },
            changedPathCount: paths.count, commits: commits, dirty: dirty,
            capturedAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    // MARK: - Helpers

    /// origin's HEAD when known, else the first conventional name that resolves — the same
    /// order the Git Review pane's Branch mode measures from.
    private static func defaultBranch(in directory: URL) -> String? {
        if let symbolic = text(GitReviewCommands.originHead(), in: directory), !symbolic.isEmpty { return symbolic }
        return GitReviewDefaults.defaultBranchCandidates.first { commitExists($0, in: directory) }
    }

    private static func commitExists(_ ref: String, in directory: URL) -> Bool {
        text(GitReviewCommands.verifyCommit(ref), in: directory) != nil
    }

    private static func output(_ arguments: [String], in directory: URL,
                               maximum: Int = WorkroomGitDefaults.commandBytes) -> Data? {
        try? GitProcess.run(GitReviewCommands.common + arguments, in: directory, maximumOutput: maximum,
                            reportsRejectedExit: false, timeout: WorkroomGitDefaults.timeout)
    }

    private static func text(_ arguments: [String], in directory: URL) -> String? {
        output(arguments, in: directory).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func isHash(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    /// A ref the agent names is passed to git as an argument; it may not look like an option.
    static func isSafeRef(_ value: String) -> Bool {
        !value.hasPrefix("-") && value.utf8.count <= WorkroomLimits.refBytes
            && !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" })
    }

    private static func clipped(_ text: String, to bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}

enum WorkroomGitDefaults {
    /// Each git call in a capture; a question waits on at most a handful of these.
    static let timeout: TimeInterval = 10
    static let commandBytes = 256 * 1024
    /// Enough for thousands of paths; the record keeps the first fifty and the total.
    static let pathListBytes = 2 * 1024 * 1024
}
