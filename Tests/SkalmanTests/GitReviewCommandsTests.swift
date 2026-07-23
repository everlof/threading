import XCTest
@testable import Skalman

final class GitReviewCommandsTests: XCTestCase {

    func testDiffFlagsAreHygienic() {
        XCTAssertEqual(
            GitReviewCommands.diffFlags,
            ["--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "-U3"]
        )
    }

    func testWorkingTreeDiffArguments() {
        XCTAssertEqual(
            GitReviewCommands.diff(against: nil),
            ["diff"] + GitReviewCommands.diffFlags
        )
        XCTAssertEqual(
            GitReviewCommands.diff(against: "HEAD"),
            ["diff"] + GitReviewCommands.diffFlags + ["HEAD"]
        )
        XCTAssertEqual(
            GitReviewCommands.diffStaged(),
            ["diff", "--cached"] + GitReviewCommands.diffFlags
        )
    }

    func testShowSuppressesCommitHeader() {
        let arguments = GitReviewCommands.show("abc123")
        XCTAssertEqual(arguments.prefix(3), ["show", "abc123", "--format="])
    }

    func testStatusListsUntrackedFilesIndividually() {
        XCTAssertEqual(
            GitReviewCommands.status(),
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
        )
    }

    func testLogPagesWithControlCharacterFormat() {
        let arguments = GitReviewCommands.log(skip: 200)
        XCTAssertTrue(arguments.contains("--skip=200"))
        XCTAssertTrue(arguments.contains("--max-count=\(GitReviewDefaults.logPageSize)"))
        XCTAssertTrue(arguments.contains("--numstat"))
        // Parents and decorations trail the original fields, which is what the graph reads.
        XCTAssertTrue(arguments.contains("--pretty=format:%x01%H%x00%h%x00%s%x00%an%x00%at%x00%P%x00%D%x02"))
    }

    func testVerifyCommitPinsObjectType() {
        XCTAssertEqual(
            GitReviewCommands.verifyCommit("origin/main"),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]
        )
    }

    func testCommonFlagsNeverTakeLocks() {
        XCTAssertEqual(
            GitReviewCommands.common,
            ["-c", "core.quotepath=false", "--no-optional-locks"]
        )
    }

    // MARK: - Hide Whitespace

    /// The toggle is off by default, so every read the pane already made is argv-identical to
    /// what it was — the flag is opt-in, never a quiet change to what a diff reports.
    func testWhitespaceIsNotIgnoredByDefault() {
        XCTAssertFalse(GitReviewCommands.diff(against: nil).contains("-w"))
        XCTAssertFalse(GitReviewCommands.diff(against: "HEAD").contains("-w"))
        XCTAssertFalse(GitReviewCommands.diffStaged().contains("-w"))
        XCTAssertFalse(GitReviewCommands.show("abc123").contains("-w"))
    }

    func testIgnoringWhitespaceAddsTheFlagToEveryDiffShape() {
        XCTAssertEqual(
            GitReviewCommands.diff(against: nil, ignoringWhitespace: true),
            ["diff"] + GitReviewCommands.diffFlags + ["-w"]
        )
        XCTAssertEqual(
            GitReviewCommands.diffStaged(ignoringWhitespace: true),
            ["diff", "--cached"] + GitReviewCommands.diffFlags + ["-w"]
        )
        XCTAssertEqual(
            GitReviewCommands.show("abc123", ignoringWhitespace: true),
            ["show", "abc123", "--format="] + GitReviewCommands.diffFlags + ["-w"]
        )
    }

    /// The ref stays the last argument. A flag appended after it reads as the start of the
    /// pathspec list, which would silently scope the diff to a file named `-w`.
    func testIgnoringWhitespaceKeepsTheRefLast() {
        let arguments = GitReviewCommands.diff(against: "HEAD", ignoringWhitespace: true)
        XCTAssertEqual(arguments.last, "HEAD")
        XCTAssertEqual(arguments, ["diff"] + GitReviewCommands.diffFlags + ["-w", "HEAD"])
    }
}
