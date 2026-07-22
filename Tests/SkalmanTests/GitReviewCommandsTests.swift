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
}
