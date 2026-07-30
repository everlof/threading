import XCTest
@testable import Threading

/// The watcher's filter, which is where its correctness lives: FSEvents reports every write git
/// makes, and nearly all of them are git talking to itself.
final class GitCheckoutWatcherTests: XCTestCase {

    private let root = "/Users/x/repo/app"
    private let gitDirectories = ["/Users/x/repo/app/.git"]

    // MARK: - Worktree Content

    func testWorktreeFileIsRelevant() {
        XCTAssertTrue(GitWatchFilter.isRelevant("\(root)/Sources/App.swift", gitDirectories: gitDirectories))
    }

    func testUntrackedFileIsRelevant() {
        // Nothing here knows what `.gitignore` says; the diff read that follows decides.
        XCTAssertTrue(GitWatchFilter.isRelevant("\(root)/build/output.o", gitDirectories: gitDirectories))
    }

    // MARK: - Git Directory Noise

    func testObjectWritesAreIgnored() {
        XCTAssertFalse(GitWatchFilter.isRelevant(
            "\(root)/.git/objects/ab/cdef0123456789", gitDirectories: gitDirectories
        ))
    }

    func testLogsAndCachesAreIgnored() {
        for path in ["\(root)/.git/logs/HEAD", "\(root)/.git/COMMIT_EDITMSG", "\(root)/.git/FETCH_HEAD"] {
            XCTAssertFalse(GitWatchFilter.isRelevant(path, gitDirectories: gitDirectories), path)
        }
    }

    func testLockFilesAreIgnored() {
        // A lock is git announcing it is about to write; the write itself is the event.
        XCTAssertFalse(GitWatchFilter.isRelevant("\(root)/.git/index.lock", gitDirectories: gitDirectories))
        XCTAssertFalse(GitWatchFilter.isRelevant(
            "\(root)/.git/refs/heads/main.lock", gitDirectories: gitDirectories
        ))
    }

    func testGitDirectoryItselfIsIgnored() {
        XCTAssertFalse(GitWatchFilter.isRelevant("\(root)/.git", gitDirectories: gitDirectories))
    }

    // MARK: - Git Directory Signal

    func testIndexAndHeadAreRelevant() {
        for path in ["\(root)/.git/index", "\(root)/.git/HEAD", "\(root)/.git/MERGE_HEAD"] {
            XCTAssertTrue(GitWatchFilter.isRelevant(path, gitDirectories: gitDirectories), path)
        }
    }

    func testRefUpdatesAreRelevant() {
        XCTAssertTrue(GitWatchFilter.isRelevant("\(root)/.git/refs/heads/main", gitDirectories: gitDirectories))
        XCTAssertTrue(GitWatchFilter.isRelevant("\(root)/.git/packed-refs", gitDirectories: gitDirectories))
    }

    // MARK: - Linked Worktrees

    func testLinkedWorktreeIndexIsRelevant() {
        // A linked worktree's index lives in the shared git directory, not under the checkout.
        let directories = ["/Users/x/repo/main/.git", "/Users/x/repo/main/.git/worktrees/feature"]
        XCTAssertTrue(GitWatchFilter.isRelevant(
            "/Users/x/repo/main/.git/worktrees/feature/index", gitDirectories: directories
        ))
        XCTAssertFalse(GitWatchFilter.isRelevant(
            "/Users/x/repo/main/.git/objects/ff/00", gitDirectories: directories
        ))
    }

    // MARK: - Branch Scope

    func testOnlyTheWorktreesOwnHeadIsBranchRelevant() {
        XCTAssertTrue(GitWatchFilter.isBranchRelevant("\(root)/.git/HEAD", gitDirectories: gitDirectories))

        // Everything else — ref writes, the index, git's logs, a lock, worktree content —
        // changes what a diff says, never which branch is checked out.
        for path in [
            "\(root)/.git/index", "\(root)/.git/HEAD.lock", "\(root)/.git/ORIG_HEAD",
            "\(root)/.git/logs/HEAD", "\(root)/.git/refs/heads/main", "\(root)/Sources/App.swift"
        ] {
            XCTAssertFalse(GitWatchFilter.isBranchRelevant(path, gitDirectories: gitDirectories), path)
        }
    }

    func testLinkedWorktreeHeadIsBranchRelevant() {
        // A branch-scoped watcher watches the worktree's *own* git directory, where its HEAD
        // lives; the shared repository's HEAD belongs to a different checkout.
        let directories = ["/Users/x/repo/main/.git/worktrees/feature"]
        XCTAssertTrue(GitWatchFilter.isBranchRelevant(
            "/Users/x/repo/main/.git/worktrees/feature/HEAD", gitDirectories: directories
        ))
        XCTAssertFalse(GitWatchFilter.isBranchRelevant(
            "/Users/x/repo/main/.git/worktrees/feature/index", gitDirectories: directories
        ))
    }

    // MARK: - Watched Paths

    func testContainedPathsArePruned() {
        let paths = GitWatchFilter.pruningContained([
            "/Users/x/repo/app", "/Users/x/repo/app/.git", "/Users/x/repo/app/.git/worktrees/a"
        ])
        XCTAssertEqual(paths, ["/Users/x/repo/app"])
    }

    func testSeparateGitDirectoryIsKept() {
        let paths = GitWatchFilter.pruningContained([
            "/Users/x/worktrees/feature", "/Users/x/repo/main/.git", "/Users/x/repo/main/.git/worktrees/feature"
        ]).sorted()
        XCTAssertEqual(paths, ["/Users/x/repo/main/.git", "/Users/x/worktrees/feature"])
    }

    func testPrefixMatchDoesNotSpanSiblings() {
        // `app-tests` is not inside `app`, however much its path looks like it.
        let paths = GitWatchFilter.pruningContained(["/Users/x/app", "/Users/x/app-tests"]).sorted()
        XCTAssertEqual(paths, ["/Users/x/app", "/Users/x/app-tests"])
    }
}
