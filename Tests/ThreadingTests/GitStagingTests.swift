import XCTest
@testable import Threading

/// Staging, against a real repository.
///
/// The patch builder is the one piece here that cannot be proven by reading it: a
/// reconstructed hunk either applies to the index or it does not, and only git can say which.
/// So these tests build a scratch repo in the temporary directory and run the real commands —
/// the same "verify against disk rather than by eye" rule the importer's worktree rules follow.
final class GitStagingTests: XCTestCase {

    // MARK: - Fixture

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try git("init", "--quiet")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")

        try write(Self.original, to: "app.swift")
        try git("add", "app.swift")
        try git("commit", "--quiet", "--message", "first")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// Two changes far enough apart to land in separate hunks at three lines of context.
    private static let original = """
    let one = 1
    let two = 2
    let three = 3
    let four = 4
    let five = 5
    let six = 6
    let seven = 7
    let eight = 8
    let nine = 9
    let ten = 10

    """

    private static let edited = """
    let one = 100
    let two = 2
    let three = 3
    let four = 4
    let five = 5
    let six = 6
    let seven = 7
    let eight = 8
    let nine = 9
    let ten = 1000

    """

    // MARK: - Hunk Staging

    func testStagingOneHunkLeavesTheOtherUnstaged() throws {
        try write(Self.edited, to: "app.swift")

        let files = try unstagedDiff()
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.hunks.count, 2, "the edits should be two hunks apart")

        try stage(hunk: 0, of: file)

        let staged = try output("diff", "--cached")
        XCTAssertTrue(staged.contains("let one = 100"), "the first hunk should be staged")
        XCTAssertFalse(staged.contains("let ten = 1000"), "the second hunk should not be")

        // And the worktree still has both, because `--cached` never touches it.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("app.swift")), Self.edited)
    }

    func testUnstagingIsTheSamePatchBackwards() throws {
        try write(Self.edited, to: "app.swift")
        try git("add", "app.swift")

        let files = try stagedDiff()
        let file = try XCTUnwrap(files.first)
        try unstage(hunk: 0, of: file)

        let staged = try output("diff", "--cached")
        XCTAssertFalse(staged.contains("let one = 100"), "the first hunk should be back out of the index")
        XCTAssertTrue(staged.contains("let ten = 1000"), "the second should still be staged")
    }

    func testStagingAFileWithNoTrailingNewline() throws {
        // The `\\ No newline at end of file` note is a comment about the line before it, and a
        // patch that drops it silently re-adds a newline the file never had.
        try write("alpha\nbeta", to: "app.swift")
        try git("add", "app.swift")
        try git("commit", "--quiet", "--message", "no newline")

        try write("alpha\ngamma", to: "app.swift")
        let file = try XCTUnwrap(try unstagedDiff().first)
        try stage(hunk: 0, of: file)

        let staged = try output("show", ":app.swift")
        XCTAssertEqual(staged, "alpha\ngamma", "the staged blob keeps its missing newline")
    }

    // MARK: - Untracked and Whole Files

    func testUntrackedFilesStageWholeAndAreNotHunkStageable() throws {
        try write("new file\n", to: "added.txt")

        let file = try XCTUnwrap(try unstagedDiff().first { $0.path == "added.txt" })
        XCTAssertEqual(file.change, .untracked)
        XCTAssertFalse(GitPatch.supportsHunkStaging(file), "an untracked file is staged whole or not at all")

        try perform { GitIndexWriter.stage(paths: [file.path], in: self.root, completion: $0) }
        XCTAssertTrue(try output("diff", "--cached", "--name-only").contains("added.txt"))
    }

    // MARK: - Added and Deleted Files

    /// A rebuilt one-hunk patch has no `new file mode` header and no `/dev/null` side, and git
    /// does not treat that as cosmetic: reverse-applying one for an added file used to stage an
    /// *empty blob* rather than unstage the file, silently. Nothing is lost by refusing — a new
    /// file's diff is one hunk, which is the whole file, which Stage File already handles.
    func testAddedFilesAreNotHunkStageable() throws {
        try write("one\ntwo\nthree\n", to: "new.swift")
        try git("add", "new.swift")

        let file = try XCTUnwrap(try stagedDiff().first { $0.path == "new.swift" })
        XCTAssertEqual(file.change, .added)
        XCTAssertEqual(file.hunks.count, 1, "a new file is always exactly one hunk")
        XCTAssertFalse(GitPatch.supportsHunkStaging(file))
    }

    func testDeletedFilesAreNotHunkStageable() throws {
        try git("rm", "--quiet", "app.swift")

        let file = try XCTUnwrap(try stagedDiff().first)
        XCTAssertEqual(file.change, .deleted)
        XCTAssertFalse(GitPatch.supportsHunkStaging(file))
    }

    /// …and the whole-file path does what the hunk path could not.
    func testUnstagingAnAddedFileRemovesItFromTheIndex() throws {
        try write("one\ntwo\n", to: "new.swift")
        try git("add", "new.swift")

        try perform { GitIndexWriter.unstage(paths: ["new.swift"], in: self.root, completion: $0) }
        XCTAssertFalse(try output("diff", "--cached", "--name-only").contains("new.swift"))
    }

    // MARK: - Commit

    func testCommitWritesWhatIsStaged() throws {
        try write(Self.edited, to: "app.swift")
        try git("add", "app.swift")

        let subject = try performValue { GitIndexWriter.commit(message: "second", in: self.root, completion: $0) }
        XCTAssertEqual(subject, "second")
        XCTAssertEqual(try output("log", "--oneline").split(separator: "\n").count, 2)
        XCTAssertTrue(try output("diff", "--cached").isEmpty, "the index is clean after committing it")
    }

    func testCommittingNothingIsRefusedBeforeGitSeesIt() throws {
        let failure = try performFailure { GitIndexWriter.commit(message: "empty", in: self.root, completion: $0) }
        XCTAssertEqual(failure, .nothingStaged)
    }

    func testCommitNeedsAMessage() throws {
        try write(Self.edited, to: "app.swift")
        try git("add", "app.swift")

        let failure = try performFailure { GitIndexWriter.commit(message: "   ", in: self.root, completion: $0) }
        XCTAssertEqual(failure, .gitFailed("A commit needs a message."))
    }

    // MARK: - Modes

    func testOnlyIndexBasedModesOfferStaging() {
        XCTAssertEqual(GitStaging.capability(for: .unstaged)?.action, .stage)
        XCTAssertEqual(GitStaging.capability(for: .unstaged)?.allowsHunks, true)
        XCTAssertEqual(GitStaging.capability(for: .staged)?.action, .unstage)
        XCTAssertEqual(GitStaging.capability(for: .staged)?.allowsHunks, true)

        // Uncommitted is measured from HEAD, so its hunks cannot be handed to the index.
        XCTAssertEqual(GitStaging.capability(for: .uncommitted)?.allowsHunks, false)

        for mode in [GitReviewMode.branch, .lastTurn, .commit] {
            XCTAssertNil(GitStaging.capability(for: mode), "\(mode) compares things that are not the index")
        }
    }

    // MARK: - Turn Snapshots

    func testTurnSnapshotPreservesAndThenDiffsPreexistingUntrackedBytes() throws {
        try write("before\n", to: "notes.txt")
        let baseline = try snapshot()

        // A path-only baseline used to exclude this completely because it was already
        // untracked. The tree baseline must report the bytes the turn actually changed.
        try write("after\n", to: "notes.txt")
        let file = try XCTUnwrap(try turnDiff(from: baseline).first { $0.path == "notes.txt" })
        XCTAssertEqual(file.change, .modified)
        XCTAssertEqual(file.added, 1)
        XCTAssertEqual(file.removed, 1)
    }

    func testTurnSnapshotDoesNotAttributeAnUnchangedUntrackedFileToTheTurn() throws {
        try write("already here\n", to: "notes.txt")
        let baseline = try snapshot()

        XCTAssertFalse(try turnDiff(from: baseline).contains { $0.path == "notes.txt" })
    }

    func testTurnSnapshotIncludesFilesCreatedAndDeletedDuringTheTurn() throws {
        try write("delete me\n", to: "removed.txt")
        let baseline = try snapshot()

        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        try write("created\n", to: "created.txt")

        let files = try turnDiff(from: baseline)
        XCTAssertEqual(files.first { $0.path == "removed.txt" }?.change, .deleted)
        XCTAssertEqual(files.first { $0.path == "created.txt" }?.change, .added)
    }

    func testTurnSnapshotLeavesTheRealIndexUntouched() throws {
        try write(Self.edited, to: "app.swift")
        try git("add", "app.swift")
        try write("worktree after staging\n", to: "app.swift")
        let stagedBefore = try output("diff", "--cached")

        _ = try snapshot()

        XCTAssertEqual(try output("diff", "--cached"), stagedBefore)
        XCTAssertEqual(try output("show", ":app.swift"), Self.edited.trimmingCharacters(in: .newlines))
    }

    func testTurnSnapshotWorksBeforeTheFirstCommit() throws {
        let unborn = root.appendingPathComponent("Unborn", isDirectory: true)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        _ = try GitProcess.run(["init", "--quiet"], in: unborn)
        try "before\n".write(
            to: unborn.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )

        let baseline = try performValue {
            GitReviewReader.createSnapshot(in: unborn, completion: $0)
        }
        try "after\n".write(
            to: unborn.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )
        let files = try performValue {
            GitReviewReader.diff(.lastTurn(baseline), in: unborn, completion: $0)
        }

        XCTAssertEqual(files.first?.path, "first.txt")
        XCTAssertEqual(files.first?.change, .modified)
    }

    func testUncommittedUsesLatestWorktreeBytesBeforeTheFirstCommit() throws {
        let unborn = root.appendingPathComponent("Unborn-Uncommitted", isDirectory: true)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        _ = try GitProcess.run(["init", "--quiet"], in: unborn)
        let file = unborn.appendingPathComponent("first.txt")
        try "staged one\nstaged two\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try GitProcess.run(["add", "first.txt"], in: unborn)
        try "working version\n".write(to: file, atomically: true, encoding: .utf8)

        let files = try performValue {
            GitReviewReader.diff(.uncommitted, in: unborn, completion: $0)
        }
        let changed = try XCTUnwrap(files.first { $0.path == "first.txt" })

        XCTAssertEqual(changed.change, .added)
        var addedTexts: [String] = []
        for hunk in changed.hunks {
            for line in hunk.lines where line.kind == .added {
                addedTexts.append(line.text)
            }
        }
        XCTAssertTrue(addedTexts.contains("working version"))
        XCTAssertFalse(addedTexts.contains("staged one"))

        let summary = try performValue {
            GitReviewReader.uncommittedSummary(in: unborn, completion: $0)
        }
        XCTAssertEqual(summary.files, 1)
        XCTAssertEqual(summary.added, 1)
    }

    // MARK: - Managed Workspaces

    func testGitChildrenUseTheLoginShellPathForHooksFiltersAndLFS() {
        let environment = GitChildEnvironment.make(
            inherited: [
                EnvironmentKeys.path: "/usr/bin:/bin",
                EnvironmentKeys.home: "/Users/fixture"
            ],
            loginPath: "/opt/homebrew/bin:/Users/fixture/.local/bin:/usr/bin:/bin"
        )

        XCTAssertEqual(
            environment[EnvironmentKeys.path],
            "/opt/homebrew/bin:/Users/fixture/.local/bin:/usr/bin:/bin"
        )
        XCTAssertEqual(environment[EnvironmentKeys.home], "/Users/fixture")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
    }

    func testGitChildExplicitEnvironmentOverridesRemainFinal() {
        let environment = GitChildEnvironment.make(
            inherited: [EnvironmentKeys.path: "/usr/bin:/bin"],
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin",
            overrides: [
                EnvironmentKeys.path: "/fixture/bin",
                "GIT_INDEX_FILE": "/fixture/index"
            ]
        )

        XCTAssertEqual(environment[EnvironmentKeys.path], "/fixture/bin")
        XCTAssertEqual(environment["GIT_INDEX_FILE"], "/fixture/index")
    }

    func testLoginShellPathIgnoresStartupGreeting() {
        XCTAssertEqual(
            GitChildEnvironment.path(
                fromShellOutput: "Welcome to the fixture shell\n\n/opt/homebrew/bin:/usr/bin:/bin\n"
            ),
            "/opt/homebrew/bin:/usr/bin:/bin"
        )
        XCTAssertNil(GitChildEnvironment.path(fromShellOutput: "\n \n"))
    }

    func testManagedWorkspacePlanWrittenBeforePublicationKeepsLocalDefaults() throws {
        let data = try XCTUnwrap(#"{"delivery":"mergeAndCleanUp"}"#.data(using: .utf8))
        let plan = try JSONDecoder().decode(ManagedWorkspacePlan.self, from: data)

        XCTAssertEqual(plan.delivery, .mergeAndCleanUp)
        XCTAssertNil(plan.publication)
    }

    func testManagedWorkspaceUsesNoFeatureBranchThenFastForwardsAndDisposesItself() throws {
        let workspaceParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingManaged-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceParent) }

        let project = Project(name: "Fixture", folderURL: root)
        try FileManager.default.createDirectory(
            at: workspaceParent,
            withIntermediateDirectories: true
        )
        let hooks = workspaceParent.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let observedPath = workspaceParent.appendingPathComponent("post-checkout-path.txt")
        let postCheckout = hooks.appendingPathComponent("post-checkout")
        try """
        #!/bin/sh
        /usr/bin/printenv PATH > '\(observedPath.path)'

        """.write(to: postCheckout, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: postCheckout.path
        )
        try git("config", "core.hooksPath", hooks.path)
        let branchesBefore = try output("branch", "--format=%(refname:short)")
        let workspace = try ManagedGitWorkspace.provision(
            sessionID: SessionID(),
            from: project,
            plan: ManagedWorkspacePlan(),
            rootDirectory: workspaceParent
        )

        let hookPath = try String(contentsOf: observedPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPath = try XCTUnwrap(GitChildEnvironment.make()[EnvironmentKeys.path])
        XCTAssertTrue(
            hookPath == loginPath || hookPath.hasSuffix(":" + loginPath),
            "Git may prepend git-core, but the hook must retain the complete login-shell PATH"
        )

        XCTAssertEqual(
            try GitDiffParser.decode(
                GitProcess.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(
                    fileURLWithPath: workspace.worktreeRoot
                ))
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "HEAD",
            "the generated checkout is detached; no feature-branch name is invented"
        )

        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        try "isolated\n".write(
            to: worktree.appendingPathComponent("managed.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.run(["add", "managed.txt"], in: worktree)
        _ = try GitProcess.run(["commit", "--quiet", "--message", "managed work"], in: worktree)

        let completed = try ManagedGitWorkspace.integrateAndClean(workspace)
        XCTAssertEqual(completed.state, .integrated)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("managed.txt")), "isolated\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreeRoot))
        XCTAssertEqual(
            try output("branch", "--format=%(refname:short)"),
            branchesBefore,
            "local delivery leaves neither a generated branch nor a worktree behind"
        )
    }

    func testManagedWorkspacePublishesOnlyAnOpaqueRemoteBranchThenDisposesLocally() async throws {
        let workspaceParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingManaged-\(UUID().uuidString)", isDirectory: true)
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRemote-\(UUID().uuidString).git", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceParent)
            try? FileManager.default.removeItem(at: remote)
        }

        _ = try GitProcess.run(
            ["init", "--quiet", "--bare", remote.path],
            in: remote.deletingLastPathComponent()
        )
        let emptyHooks = root.appendingPathComponent(".test-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true)
        try git("config", "core.hooksPath", emptyHooks.path)
        try git("remote", "add", "origin", "git@github.com:team/app.git")

        let project = Project(name: "Fixture", folderURL: root)
        let sessionID = SessionID()
        let sourceHead = try output("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branchesBefore = try output("branch", "--format=%(refname:short)")
        let workspace = try ManagedGitWorkspace.provision(
            sessionID: sessionID,
            from: project,
            plan: ManagedWorkspacePlan(publication: .draft),
            rootDirectory: workspaceParent
        )

        let worktree = URL(fileURLWithPath: workspace.worktreeRoot, isDirectory: true)
        try "remote review\n".write(
            to: worktree.appendingPathComponent("review.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.run(["add", "review.txt"], in: worktree)
        _ = try GitProcess.run(
            ["commit", "--quiet", "--message", "managed review"],
            in: worktree
        )

        let snapshot = try ManagedGitWorkspace.publicationSnapshot(for: workspace)
        XCTAssertEqual(snapshot.branch, ManagedGitWorkspace.publicationBranch(for: sessionID))
        XCTAssertEqual(snapshot.repository.slug, "team/app")

        // The production path pushes to the GitHub origin above. Point the same named remote at
        // a local bare repository only for the process-level assertion.
        try git("remote", "set-url", "origin", remote.path)
        try await ChangeRequestGit.pushDetached(
            commit: snapshot.finalCommit,
            to: snapshot.branch,
            in: worktree
        )

        let remoteBranches = GitDiffParser.decode(try GitProcess.run(
            ["--git-dir", remote.path, "branch", "--format=%(refname:short)"],
            in: remote.deletingLastPathComponent()
        ))
        XCTAssertEqual(
            remoteBranches.trimmingCharacters(in: .whitespacesAndNewlines),
            snapshot.branch
        )
        let publishedRemoteRevision = try await ChangeRequestGit.remoteRevision(
            of: snapshot.branch,
            in: worktree
        )
        XCTAssertEqual(publishedRemoteRevision, snapshot.finalCommit)

        var recorded = workspace
        recorded.finalCommit = snapshot.finalCommit
        recorded.changeRequest = ManagedWorkspaceChangeRequest(
            provider: "github",
            repository: "team/app",
            remote: "origin",
            branch: snapshot.branch,
            number: 42,
            url: try XCTUnwrap(URL(string: "https://github.com/team/app/pull/42")),
            isDraft: true
        )
        let completed = try ManagedGitWorkspace.cleanPublished(recorded)

        XCTAssertEqual(completed.state, .published)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreeRoot))
        XCTAssertEqual(
            try output("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines),
            sourceHead,
            "publication leaves the selected checkout untouched"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review.txt").path))
        XCTAssertEqual(
            try output("branch", "--format=%(refname:short)"),
            branchesBefore,
            "publication creates no local branch to clean up"
        )

        try await ChangeRequestGit.deleteRemoteBranch(
            snapshot.branch,
            ifRevisionIs: snapshot.finalCommit,
            in: root
        )
        let removedRemoteRevision = try await ChangeRequestGit.remoteRevision(
            of: snapshot.branch,
            in: root
        )
        XCTAssertNil(
            removedRemoteRevision,
            "a closed review can dispose its exact generated remote ref without a worktree"
        )

        // The ref is app-owned only while it is still the commit in the receipt. Simulate a
        // remote actor advancing it between publication and cleanup; the deletion lease must
        // refuse even though the name still has Threading's prefix.
        try await ChangeRequestGit.pushDetached(
            commit: snapshot.finalCommit,
            to: snapshot.branch,
            in: root
        )
        let tree = try output("rev-parse", "\(snapshot.finalCommit)^{tree}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let advanced = GitDiffParser.decode(try GitProcess.run(
            ["commit-tree", tree, "-p", snapshot.finalCommit, "-m", "remote advancement"],
            in: root
        )).trimmingCharacters(in: .whitespacesAndNewlines)
        try await ChangeRequestGit.pushDetached(
            commit: advanced,
            to: snapshot.branch,
            in: root
        )
        do {
            try await ChangeRequestGit.deleteRemoteBranch(
                snapshot.branch,
                ifRevisionIs: snapshot.finalCommit,
                in: root
            )
            XCTFail("a moved generated ref must survive cleanup")
        } catch {
            let retainedRemoteRevision = try await ChangeRequestGit.remoteRevision(
                of: snapshot.branch,
                in: root
            )
            XCTAssertEqual(retainedRemoteRevision, advanced)
        }
    }

    // MARK: - Helpers

    private func stage(hunk index: Int, of file: GitFileDiff) throws {
        try perform {
            GitIndexWriter.apply(
                patch: GitPatch.patch(for: file.hunks[index], path: file.path),
                reverse: false,
                in: self.root,
                completion: $0
            )
        }
    }

    private func unstage(hunk index: Int, of file: GitFileDiff) throws {
        try perform {
            GitIndexWriter.apply(
                patch: GitPatch.patch(for: file.hunks[index], path: file.path),
                reverse: true,
                in: self.root,
                completion: $0
            )
        }
    }

    private func unstagedDiff() throws -> [GitFileDiff] {
        try performValue { GitReviewReader.diff(.unstaged, in: self.root, completion: $0) }
    }

    private func stagedDiff() throws -> [GitFileDiff] {
        try performValue { GitReviewReader.diff(.staged, in: self.root, completion: $0) }
    }

    private func snapshot() throws -> GitTurnBaseline {
        try performValue { GitReviewReader.createSnapshot(in: self.root, completion: $0) }
    }

    private func turnDiff(from baseline: GitTurnBaseline) throws -> [GitFileDiff] {
        try performValue {
            GitReviewReader.diff(.lastTurn(baseline), in: self.root, completion: $0)
        }
    }

    /// Runs an async writer call and fails the test if it reports an error.
    private func perform(
        _ work: (@escaping @MainActor @Sendable (Result<Void, GitFailure>) -> Void) -> Void
    ) throws {
        _ = try performValue(work)
    }

    private func performValue<Value>(
        _ work: (@escaping @MainActor @Sendable (Result<Value, GitFailure>) -> Void) -> Void
    ) throws -> Value {
        let finished = expectation(description: "git")
        var outcome: Result<Value, GitFailure>?
        work { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)

        switch try XCTUnwrap(outcome) {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }

    private func performFailure<Value>(
        _ work: (@escaping @MainActor @Sendable (Result<Value, GitFailure>) -> Void) -> Void
    ) throws -> GitFailure {
        do {
            _ = try performValue(work)
            XCTFail("expected a failure")
            return .gitFailed("")
        } catch let failure as GitFailure {
            return failure
        }
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        try output(arguments)
    }

    private func output(_ arguments: String...) throws -> String {
        try output(arguments)
    }

    private func output(_ arguments: [String]) throws -> String {
        let data = try GitProcess.run(arguments, in: root)
        return GitDiffParser.decode(data).trimmingCharacters(in: .newlines)
    }
}
