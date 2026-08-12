import XCTest
@testable import Threading

final class GitReviewCommandsTests: XCTestCase {

    func testModeSetAndLiveTurnNameAreExplicit() {
        XCTAssertEqual(
            GitReviewMode.allCases,
            [.uncommitted, .unstaged, .staged, .lastTurn, .branch, .commit]
        )
        XCTAssertEqual(GitReviewMode.lastTurn.title(isTurnInFlight: true), "This Turn")
        XCTAssertEqual(GitReviewMode.lastTurn.title(isTurnInFlight: false), "Last Turn")
        XCTAssertEqual(GitReviewMode.uncommitted.comparisonDescription, "HEAD → Working Tree · staged, unstaged, and untracked")
        XCTAssertEqual(GitReviewMode.unstaged.comparisonDescription, "Index → Working Tree · includes untracked")
        XCTAssertEqual(GitReviewMode.staged.comparisonDescription, "HEAD → Index")
    }

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

    func testRecentSubjectsAskForSubjectsAndNothingElse() {
        // The commit draft's voice sample: no numstat, no hundred-commit page — `log()`
        // pays for both, rightly for the history browser and wastefully here.
        XCTAssertEqual(
            GitReviewCommands.recentSubjects(count: 10),
            ["log", "--no-color", "--pretty=format:%s", "--max-count=10"]
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

    func testRepositoryFilesAreLiteralAndNULTerminated() {
        XCTAssertEqual(
            GitReviewCommands.repositoryFiles(),
            ["ls-files", "-co", "--exclude-standard", "--deduplicate", "-z"]
        )
        XCTAssertEqual(
            GitReviewCommands.repositoryFile("literal[1]\n\u{00E4}.swift"),
            [
                "ls-files", "-co", "--exclude-standard", "--deduplicate", "-z", "--",
                ":(top,literal)literal[1]\n\u{00E4}.swift"
            ]
        )
    }

    func testRepositoryFileDisplayPageKeepsNaturalOrderAndItsBound() {
        let page = GitRepositoryFileList(paths: [
            "Sources/File10.swift", "Sources/File2.swift", "Sources/File1.swift"
        ]).naturalDisplayPage(limit: 2)

        XCTAssertEqual(page.paths, ["Sources/File1.swift", "Sources/File2.swift"])
        XCTAssertTrue(page.isTruncated)
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

    func testTurnSnapshotsUseTwoTreesAndAPrivateIndexVocabulary() {
        XCTAssertEqual(
            GitReviewCommands.diff(from: "old", to: "new"),
            ["diff"] + GitReviewCommands.diffFlags + ["old", "new"]
        )
        XCTAssertEqual(
            GitReviewCommands.verifyTree("abc123"),
            ["rev-parse", "--verify", "--quiet", "abc123^{tree}"]
        )
        XCTAssertEqual(
            GitReviewCommands.indexPath(),
            ["rev-parse", "--path-format=absolute", "--git-path", "index"]
        )
        XCTAssertEqual(GitReviewCommands.readEmptyTree(), ["read-tree", "--empty"])
        XCTAssertEqual(GitReviewCommands.addWorkingTreeToIndex(), ["add", "-A", "--", "."])
        XCTAssertEqual(GitReviewCommands.writeTree(), ["write-tree"])
        XCTAssertEqual(
            GitReviewCommands.writeEmptyTree(),
            ["hash-object", "-w", "-t", "tree", "--stdin"]
        )
    }

    func testTurnTreeDiffKeepsWhitespaceFlagAheadOfBothTrees() {
        XCTAssertEqual(
            GitReviewCommands.diff(from: "old", to: "new", ignoringWhitespace: true),
            ["diff"] + GitReviewCommands.diffFlags + ["-w", "old", "new"]
        )
    }

    func testTurnCheckpointRefCommandsNameOneExactRef() {
        let ref = "refs/threading/turn-checkpoints/v1/session/checkpoint/before"
        XCTAssertEqual(
            GitReviewCommands.updateRef(ref, to: "tree"),
            ["update-ref", ref, "tree", ""]
        )
        XCTAssertEqual(GitReviewCommands.deleteRef(ref), ["update-ref", "-d", ref])
        XCTAssertEqual(
            GitReviewCommands.checkpointRefs(),
            ["for-each-ref", "--format=%(refname)", GitTurnCheckpointRefs.prefix]
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

    /// `--no-index` takes literal paths after `--`, no rename detection, and never the shared
    /// diff flags wholesale — `--find-renames` means nothing to a pair of named files.
    func testCompareFilesPinsItsArgv() {
        XCTAssertEqual(
            GitReviewCommands.compareFiles(oldPath: "/tmp/a.txt", newPath: "/tmp/b txt.txt"),
            [
                "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3",
                "--no-index", "--", "/tmp/a.txt", "/tmp/b txt.txt"
            ]
        )
    }

    /// A blob address is `revision:path` — including `:0:path`, where the empty revision
    /// before the stage number means the index.
    func testShowBlobPinsItsArgv() {
        XCTAssertEqual(
            GitReviewCommands.showBlob(revision: "HEAD", path: "Assets/icon.png"),
            ["show", "HEAD:Assets/icon.png"]
        )
        XCTAssertEqual(
            GitReviewCommands.showBlob(revision: ":0", path: "icon.png"),
            ["show", ":0:icon.png"]
        )
    }
}
