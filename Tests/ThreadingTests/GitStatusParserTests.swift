import XCTest
@testable import Threading

final class GitStatusParserTests: XCTestCase {

    private func data(_ records: [String]) -> Data {
        Data((records.joined(separator: "\u{00}") + "\u{00}").utf8)
    }

    func testChangedEntriesReadStagedAndUnstaged() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "# branch.oid 1234",
            "# branch.head main",
            "1 .M N... 100644 100644 100644 1111111 1111111 Sources/Modified.swift",
            "1 A. N... 000000 100644 100644 0000000 1111111 Sources/Staged.swift",
            "1 MM N... 100644 100644 100644 1111111 2222222 Sources/Both.swift"
        ]))

        XCTAssertEqual(status.entries.count, 3)

        XCTAssertEqual(status.entries[0].path, "Sources/Modified.swift")
        XCTAssertFalse(status.entries[0].staged)
        XCTAssertTrue(status.entries[0].unstaged)

        XCTAssertEqual(status.entries[1].path, "Sources/Staged.swift")
        XCTAssertTrue(status.entries[1].staged)
        XCTAssertFalse(status.entries[1].unstaged)

        XCTAssertTrue(status.entries[2].staged)
        XCTAssertTrue(status.entries[2].unstaged)
    }

    func testRenameEntryConsumesOriginalPathRecord() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "2 R. N... 100644 100644 100644 1111111 1111111 R100 new name.txt",
            "old name.txt",
            "? untracked.txt"
        ]))

        XCTAssertEqual(status.entries.count, 1)
        XCTAssertEqual(status.entries[0].path, "new name.txt")
        XCTAssertEqual(status.entries[0].renamedFrom, "old name.txt")
        XCTAssertEqual(status.untracked, ["untracked.txt"])
    }

    func testUntrackedAndIgnoredEntries() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "? new file with spaces.txt",
            "? another.txt",
            "! build/ignored.o"
        ]))

        XCTAssertTrue(status.entries.isEmpty)
        XCTAssertEqual(status.untracked, ["new file with spaces.txt", "another.txt"])
    }

    func testUnmergedEntryIsTolerated() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflicted.txt"
        ]))

        XCTAssertEqual(status.entries.count, 1)
        XCTAssertEqual(status.entries[0].path, "conflicted.txt")
        XCTAssertTrue(status.entries[0].unstaged)
    }

    // MARK: - Malformed and truncated status

    /// A rename's original path arrives as the *next* record, so the cursor must advance past it
    /// whether or not the rename record itself parsed. Guarding first and consuming second is the
    /// natural way to write this and the wrong one: the orphaned path record is then read as a
    /// status record, and every entry after it shifts.
    func testAMalformedRenameStillConsumesItsOriginalPathRecord() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "2 R. N... too few fields",
            "old name.txt",
            "1 .M N... 100644 100644 100644 1111111 1111111 Sources/After.swift"
        ]))

        XCTAssertEqual(status.entries.count, 1)
        XCTAssertEqual(
            status.entries[0].path, "Sources/After.swift",
            "the orphaned original-path record was read as a status record"
        )
        XCTAssertTrue(status.untracked.isEmpty)
    }

    /// Output cut off mid-rename: the entry keeps its new path and simply knows no origin.
    func testARenameAtTheEndOfTruncatedOutputDoesNotRunOffTheEnd() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "2 R. N... 100644 100644 100644 1111111 1111111 R100 new name.txt"
        ]))

        XCTAssertEqual(status.entries.count, 1)
        XCTAssertEqual(status.entries[0].path, "new name.txt")
        XCTAssertNil(status.entries[0].renamedFrom)
    }

    /// `-z` does not quote, so a newline inside a path arrives literally — which is the whole
    /// reason records are split on NUL. A line-based reader silently invents a second file here.
    func testPathsContainingNewlinesAndTabsSurviveIntact() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "1 .M N... 100644 100644 100644 1111111 1111111 Sources/two\nlines.swift",
            "? untracked\twith tab.txt"
        ]))

        XCTAssertEqual(status.entries.map(\.path), ["Sources/two\nlines.swift"])
        XCTAssertEqual(status.untracked, ["untracked\twith tab.txt"])
    }

    /// Short and unrecognised records are skipped, not guessed at.
    func testTruncatedAndUnknownRecordsAreSkipped() {
        let status = GitDiffParser.status(fromPorcelainV2: data([
            "1 .M N... 100644",
            "1",
            "u UU N... too short",
            "?",
            "x whatever",
            "1 .M N... 100644 100644 100644 1111111 1111111 Sources/Good.swift"
        ]))

        XCTAssertEqual(status.entries.map(\.path), ["Sources/Good.swift"])
        XCTAssertTrue(status.untracked.isEmpty, "a `? ` record naming no file became a row")
    }

    func testEmptyStatus() {
        let status = GitDiffParser.status(fromPorcelainV2: Data())
        XCTAssertTrue(status.entries.isEmpty)
        XCTAssertTrue(status.untracked.isEmpty)
    }

    // MARK: - Log

    func testLogRecordsParseFieldsAndNumstat() {
        let record1 = "\u{01}aaaa1111\u{00}aaaa\u{00}Fix the thing\u{00}David\u{00}1750000000\u{02}\n"
            + "10\t2\tSources/Foo.swift\n"
            + "-\t-\tResources/icon.png\n"
        let record2 = "\u{01}bbbb2222\u{00}bbbb\u{00}Subject with \t tab\u{00}Someone Else\u{00}1750001000\u{02}\n"
            + "3\t0\tREADME.md\n"

        let commits = GitDiffParser.commits(fromLog: Data((record1 + record2).utf8))

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaaa1111")
        XCTAssertEqual(commits[0].shortHash, "aaaa")
        XCTAssertEqual(commits[0].subject, "Fix the thing")
        XCTAssertEqual(commits[0].author, "David")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(commits[0].added, 10)
        XCTAssertEqual(commits[0].removed, 2)

        XCTAssertEqual(commits[1].added, 3)
        XCTAssertEqual(commits[1].removed, 0)
    }

    func testLogRecordWithoutNumstatCountsZero() {
        let commits = GitDiffParser.commits(
            fromLog: Data("\u{01}cccc3333\u{00}cccc\u{00}Empty commit\u{00}David\u{00}1750002000".utf8)
        )

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].added, 0)
        XCTAssertEqual(commits[0].removed, 0)
    }
}
