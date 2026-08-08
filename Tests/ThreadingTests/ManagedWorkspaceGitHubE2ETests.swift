import XCTest
@testable import Threading

/// Opt-in proof against the private GitHub fixture. The ordinary suite stops at fake HTTP and a
/// local bare remote; this one crosses the real authentication, push, pull-request, and deletion
/// boundaries only when the exact fixture repository is named in the environment.
final class ManagedWorkspaceGitHubE2ETests: XCTestCase {

    @MainActor
    func testPublishedWorkspaceSurvivesOpenReviewThenDisposesAfterClose() async throws {
        guard ProcessInfo.processInfo.environment[GitHubE2EDefaults.repositoryEnvironment]
                == GitHubE2EDefaults.repository else {
            throw XCTSkip(
                "Set \(GitHubE2EDefaults.repositoryEnvironment)=\(GitHubE2EDefaults.repository) "
                    + "to run the live managed-workspace GitHub test."
            )
        }

        let sessionID = SessionID()
        let fixture = try ManagedWorkspaceGitHubFixture(sessionID: sessionID)
        defer { fixture.bestEffortCleanup() }

        let sourceHead = try fixture.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localBranches = try fixture.git("branch", "--format=%(refname:short)")
        let workspace = try ManagedGitWorkspace.provision(
            sessionID: sessionID,
            from: Project(name: GitHubE2EDefaults.projectName, folderURL: fixture.source),
            plan: ManagedWorkspacePlan(publication: .draft),
            rootDirectory: fixture.workspaceParent
        )

        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        let markerName = "managed-\(sessionID.uuidString.lowercased()).txt"
        try GitHubE2EDefaults.markerContents.write(
            to: worktree.appendingPathComponent(markerName),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.run(["add", markerName], in: worktree)
        _ = try GitProcess.run([
            "-c", "commit.gpgsign=false",
            "commit", "--quiet", "--message", GitHubE2EDefaults.commitMessage
        ], in: worktree)

        fixture.headBranch = try XCTUnwrap(workspace.remoteBranch)
        fixture.headRevision = GitDiffParser.decode(try GitProcess.run(
            ["rev-parse", "HEAD"],
            in: worktree
        )).trimmingCharacters(in: .whitespacesAndNewlines)

        let github = GitHubPullRequestClient.live()
        let providers = ChangeRequestProviderRegistry.githubFixture(github)
        let result = try await ManagedWorkspacePublisher(providers: providers).publish(workspace)
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.finalCommit, fixture.headRevision)
        XCTAssertEqual(result.changeRequest.repository, GitHubE2EDefaults.repository)
        XCTAssertEqual(result.changeRequest.branch, fixture.headBranch)
        XCTAssertTrue(result.changeRequest.isDraft)
        XCTAssertNotNil(result.credentialSource)
        fixture.pullNumber = result.changeRequest.number

        var recorded = workspace
        recorded.finalCommit = result.finalCommit
        recorded.changeRequest = result.changeRequest
        recorded.remoteBranchState = .awaitingReviewCompletion
        let completed = try ManagedGitWorkspace.cleanPublished(recorded)

        XCTAssertEqual(completed.state, .published)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreeRoot))
        XCTAssertEqual(
            try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines),
            sourceHead,
            "publishing must not move the source checkout"
        )
        XCTAssertEqual(
            try fixture.git("branch", "--format=%(refname:short)"),
            localBranches,
            "publishing must not create a local feature branch"
        )
        let publishedRevision = try await ChangeRequestGit.remoteRevision(
            of: try XCTUnwrap(fixture.headBranch),
            in: fixture.source
        )
        XCTAssertEqual(publishedRevision, result.finalCommit)

        let cleaner = ManagedWorkspaceRemoteCleaner(providers: providers)
        let openOutcome = await cleaner.reconcile(sessionID: sessionID, workspace: completed)
        XCTAssertEqual(openOutcome, .waiting)
        let openRevision = try await ChangeRequestGit.remoteRevision(
            of: try XCTUnwrap(fixture.headBranch),
            in: fixture.source
        )
        XCTAssertEqual(
            openRevision,
            result.finalCommit,
            "an open review must retain its head branch"
        )

        try fixture.closePullRequest()
        let closedOutcome = await cleaner.reconcile(sessionID: sessionID, workspace: completed)
        XCTAssertEqual(closedOutcome, .disposed(.deleted))
        let closedRevision = try await ChangeRequestGit.remoteRevision(
            of: try XCTUnwrap(fixture.headBranch),
            in: fixture.source
        )
        XCTAssertNil(closedRevision)
        if closedOutcome == .disposed(.deleted), closedRevision == nil {
            fixture.headRevision = nil
        }

        try await ChangeRequestGit.deleteRemoteBranch(
            fixture.baseBranch,
            ifRevisionIs: fixture.baseRevision,
            in: fixture.source
        )
        let remainingBaseRevision = try await ChangeRequestGit.remoteRevision(
            of: fixture.baseBranch,
            in: fixture.source
        )
        XCTAssertNil(remainingBaseRevision)
        fixture.baseWasDeleted = true
    }
}

private enum GitHubE2EDefaults {
    static let repository = "everlof/threading-managed-workspace-e2e"
    static let repositoryEnvironment = "THREADING_GITHUB_E2E_REPOSITORY"
    static let projectName = "Managed Workspace GitHub E2E"
    static let commitMessage = "Exercise managed workspace publication"
    static let markerContents = "Threading managed-workspace GitHub fixture\n"
    static let remote = "git@github.com:\(repository).git"
}

private final class ManagedWorkspaceGitHubFixture {
    enum Failure: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message): message
            }
        }
    }

    let container: URL
    let source: URL
    let workspaceParent: URL
    let baseBranch: String
    let baseRevision: String
    var headBranch: String?
    var headRevision: String?
    var pullNumber: Int?
    var baseWasDeleted = false

    init(sessionID: SessionID) throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingGitHubE2E-\(sessionID.uuidString.lowercased())",
            isDirectory: true
        )
        source = container.appendingPathComponent("source", isDirectory: true)
        workspaceParent = container.appendingPathComponent("workspaces", isDirectory: true)
        baseBranch = "e2e/base/\(sessionID.uuidString.lowercased())"

        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let emptyHooks = container.appendingPathComponent("empty-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true)
        _ = try GitProcess.run([
            "-c", "submodule.recurse=false",
            "-c", "core.hooksPath=\(emptyHooks.path)",
            "clone", "--quiet", GitHubE2EDefaults.remote, source.path
        ], in: container)
        _ = try GitProcess.run(["config", "core.hooksPath", emptyHooks.path], in: source)
        _ = try GitProcess.run(["config", "user.email", "threading-e2e@invalid.example"], in: source)
        _ = try GitProcess.run(["config", "user.name", "Threading E2E"], in: source)
        _ = try GitProcess.run(["config", "commit.gpgsign", "false"], in: source)
        _ = try GitProcess.run(["switch", "--quiet", "--create", baseBranch], in: source)
        baseRevision = GitDiffParser.decode(try GitProcess.run(
            ["rev-parse", "HEAD"],
            in: source
        )).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try GitProcess.run([
            "push", "origin", "HEAD:refs/heads/\(baseBranch)"
        ], in: source)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        GitDiffParser.decode(try GitProcess.run(arguments, in: source))
    }

    @MainActor
    func closePullRequest() throws {
        let number = try XCTUnwrap(pullNumber)
        _ = try Self.gh([
            "api",
            "repos/\(GitHubE2EDefaults.repository)/pulls/\(number)",
            "-X", "PATCH",
            "-f", "state=closed",
            "--silent"
        ], in: source)
    }

    @MainActor
    func bestEffortCleanup() {
        if pullNumber == nil, let headBranch {
            let output = try? Self.gh([
                "pr", "list",
                "--repo", GitHubE2EDefaults.repository,
                "--state", "open",
                "--head", headBranch,
                "--json", "number",
                "--jq", ".[0].number"
            ], in: source)
            if let rawNumber = output?.trimmingCharacters(in: .whitespacesAndNewlines),
               let number = Int(rawNumber) {
                pullNumber = number
            }
        }
        if let pullNumber {
            _ = try? Self.gh([
                "api",
                "repos/\(GitHubE2EDefaults.repository)/pulls/\(pullNumber)",
                "-X", "PATCH",
                "-f", "state=closed",
                "--silent"
            ], in: source)
        }
        if let headBranch, let headRevision {
            try? leasedDelete(branch: headBranch, revision: headRevision)
        }
        if !baseWasDeleted {
            try? leasedDelete(branch: baseBranch, revision: baseRevision)
        }
        try? FileManager.default.removeItem(at: container)
    }

    private func leasedDelete(branch: String, revision: String) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        _ = try GitProcess.run([
            "push",
            "--force-with-lease=refs/heads/\(branch):\(revision)",
            "origin",
            "--delete",
            branch
        ], in: source)
    }

    @MainActor
    private static func gh(_ arguments: [String], in directory: URL) throws -> String {
        var command = ShellCommand(word: "gh")
        for argument in arguments {
            command.append(word: argument)
        }
        let source = ShellCommand.executing(command, in: directory.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentLauncher.loginShellPath)
        process.arguments = ["-l", "-c", source.source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(message)
        }
        return message
    }
}
