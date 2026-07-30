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

    /// Runs an async writer call and fails the test if it reports an error.
    private func perform(_ work: (@escaping @MainActor (Result<Void, GitFailure>) -> Void) -> Void) throws {
        _ = try performValue(work)
    }

    private func performValue<Value>(
        _ work: (@escaping @MainActor (Result<Value, GitFailure>) -> Void) -> Void
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
        _ work: (@escaping @MainActor (Result<Value, GitFailure>) -> Void) -> Void
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
