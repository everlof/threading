import Foundation

struct ChangeRequestLocalState: Equatable, Sendable {
    let root: URL
    let branch: String
    let headRevision: String
    let remote: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let hasUncommittedChanges: Bool

    var repository: ChangeRequestRepository? {
        ChangeRequestRepository.github(remote: remote)
    }

    var needsPush: Bool { upstream == nil || ahead > 0 }
}

struct ChangeRequestProposalSeed: Equatable, Sendable {
    var title: String
    var body: String
    var commitSubjects: [String]
    var diff: String
    var template: String?
}

/// The local half of the publish workflow: cheap state reads, explicit pushes, and the bounded
/// context used to propose a title and description. Everything runs off the main thread.
enum ChangeRequestGit {
    private static let queue = DispatchQueue(
        label: "codes.threading.change-request-git",
        qos: .userInitiated
    )

    static func state(in root: URL) async throws -> ChangeRequestLocalState {
        try await perform {
            guard let branch = GitInfo.currentBranch(for: root.path),
                  let head = GitInfo.headRevision(for: root.path) else {
                throw GitFailure.gitFailed(L10n.string("Pull requests need a checked-out branch."))
            }
            guard let remote = GitInfo.remoteOriginURL(for: root.path) else {
                throw GitFailure.gitFailed(L10n.string("This repository has no origin remote."))
            }

            let upstream = try? trimmed(GitProcess.run(
                GitReviewCommands.common + [
                    "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
                ],
                in: root
            ))
            let counts = upstream.flatMap { _ in
                try? trimmed(GitProcess.run(
                    GitReviewCommands.common + [
                        "rev-list", "--left-right", "--count", "@{upstream}...HEAD"
                    ],
                    in: root
                ))
            }
            let fields = counts?.split(whereSeparator: \Character.isWhitespace) ?? []
            let behind = fields.first.flatMap { Int($0) } ?? 0
            let ahead = fields.dropFirst().first.flatMap { Int($0) } ?? 0
            let status = try GitProcess.run(
                GitReviewCommands.common + GitReviewCommands.status(),
                in: root
            )

            return ChangeRequestLocalState(
                root: root,
                branch: branch,
                headRevision: head,
                remote: remote,
                upstream: upstream?.isEmpty == false ? upstream : nil,
                ahead: ahead,
                behind: behind,
                hasUncommittedChanges: !status.isEmpty
            )
        }
    }

    /// Pushes one transition only. A branch without an upstream is published to origin and gains
    /// one; an established branch uses its configured upstream.
    static func push(_ state: ChangeRequestLocalState) async throws {
        try await perform {
            let arguments = state.upstream == nil
                ? ["push", "--set-upstream", "origin", "HEAD"]
                : ["push"]
            _ = try GitProcess.run(
                GitReviewCommands.common + arguments,
                in: state.root,
                maximumOutput: ChangeRequestGitDefaults.pushOutputLimit
            )
        }
    }

    static func proposalSeed(
        in root: URL,
        baseBranch: String
    ) async throws -> ChangeRequestProposalSeed {
        try await perform {
            let base = "origin/\(baseBranch)"
            let subjectsText = trimmed(try GitProcess.run(
                GitReviewCommands.common + [
                    "log", "--pretty=format:%s", "--max-count=50", "\(base)..HEAD"
                ],
                in: root
            ))
            let subjects = subjectsText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            let title: String
            if let first = subjects.first {
                title = first
            } else {
                title = trimmed(try GitProcess.run(
                    GitReviewCommands.common + ["log", "-1", "--pretty=format:%s"],
                    in: root
                ))
            }
            guard !title.isEmpty else {
                throw GitFailure.gitFailed(L10n.string("This branch has no commit to describe."))
            }

            let diffData = try GitProcess.run(
                GitReviewCommands.common + [
                    "diff", "--no-color", "--no-ext-diff", "--no-textconv",
                    "--find-renames", "\(base)...HEAD"
                ],
                in: root
            )
            let diff = String(decoding: diffData, as: UTF8.self)
            let template = pullRequestTemplate(in: root)
            let body = template ?? defaultBody(subjects: subjects)
            return ChangeRequestProposalSeed(
                title: title,
                body: body,
                commitSubjects: subjects,
                diff: diff,
                template: template
            )
        }
    }

    private static func defaultBody(subjects: [String]) -> String {
        guard !subjects.isEmpty else { return "" }
        return "## Summary\n\n" + subjects.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func pullRequestTemplate(in root: URL) -> String? {
        let candidates = [
            ".github/pull_request_template.md",
            "pull_request_template.md",
            "docs/pull_request_template.md"
        ]
        for path in candidates {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let bounded = String(text.prefix(ChangeRequestGitDefaults.templateCharacterLimit))
            if !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return bounded }
        }
        return nil
    }

    private static func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func perform<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum ChangeRequestGitDefaults {
    static let templateCharacterLimit = 30_000
    static let pushOutputLimit = 512 * 1024
}
