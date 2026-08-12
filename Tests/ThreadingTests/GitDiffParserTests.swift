import XCTest
@testable import Threading

final class GitDiffParserTests: XCTestCase {

    func testRawDiffIndexPreservesChangesAndConsumesRenamePaths() {
        let raw = ":100644 100644 aaaaaaa bbbbbbb M\u{00}Sources/Edit.swift\u{00}"
            + ":000000 100644 0000000 ccccccc A\u{00}Sources/New.swift\u{00}"
            + ":100644 000000 ddddddd 0000000 D\u{00}Sources/Old.swift\u{00}"
            + ":100644 100644 eeeeeee fffffff R098\u{00}Old Name.swift\u{00}New Name.swift\u{00}"

        let files = GitDiffParser.files(fromRawDiff: Data(raw.utf8))

        XCTAssertEqual(files.map(\.path), [
            "Sources/Edit.swift", "Sources/New.swift", "Sources/Old.swift", "New Name.swift",
        ])
        XCTAssertEqual(files[0].change, .modified)
        XCTAssertEqual(files[1].change, .added)
        XCTAssertEqual(files[2].change, .deleted)
        XCTAssertEqual(files[3].change, .renamed(from: "Old Name.swift"))
        XCTAssertTrue(files.allSatisfy { $0.hunks.isEmpty && $0.added == 0 && $0.removed == 0 })
    }

    func testNULTerminatedNumstatKeepsLiteralAndRenameDestinationPaths() {
        let raw = "12\t3\tSources/[literal].swift\u{00}"
            + "4\t1\t\u{00}Old Name.swift\u{00}New Name.swift\u{00}"
            + "-\t-\timage.png\u{00}"

        XCTAssertEqual(
            GitDiffParser.fileStats(fromNumstat: Data(raw.utf8)),
            [
                GitFileLineStats(path: "Sources/[literal].swift", added: 12, removed: 3),
                GitFileLineStats(path: "New Name.swift", added: 4, removed: 1),
                GitFileLineStats(path: "image.png", added: 0, removed: 0),
            ]
        )
    }

    // MARK: - Unified Diff

    func testModifiedFileNumbersLinesAcrossHunks() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        index 1111111..2222222 100644
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,4 +1,5 @@
         line one
        -line two
        +line 2
        +line 2.5
         line three
        @@ -10,3 +11,2 @@ func tail()
         alpha
        -beta
         gamma
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)

        let file = files[0]
        XCTAssertEqual(file.path, "Sources/Foo.swift")
        XCTAssertEqual(file.change, .modified)
        XCTAssertEqual(file.added, 2)
        XCTAssertEqual(file.removed, 2)
        XCTAssertEqual(file.hunks.count, 2)
        XCTAssertEqual(file.hunks[1].header, "@@ -10,3 +11,2 @@ func tail()")

        let first = file.hunks[0].lines
        XCTAssertEqual(first[0].oldNumber, 1)
        XCTAssertEqual(first[0].newNumber, 1)
        XCTAssertEqual(first[1].kind, .removed)
        XCTAssertEqual(first[1].oldNumber, 2)
        XCTAssertNil(first[1].newNumber)
        XCTAssertEqual(first[2].kind, .added)
        XCTAssertNil(first[2].oldNumber)
        XCTAssertEqual(first[2].newNumber, 2)
        XCTAssertEqual(first[4].oldNumber, 3)
        XCTAssertEqual(first[4].newNumber, 4)

        let second = file.hunks[1].lines
        XCTAssertEqual(second[0].oldNumber, 10)
        XCTAssertEqual(second[0].newNumber, 11)
        XCTAssertEqual(second[2].oldNumber, 12)
        XCTAssertEqual(second[2].newNumber, 12)
    }

    func testRenameWithEdit() {
        let diff = """
        diff --git a/old/name.txt b/new/name.txt
        similarity index 90%
        rename from old/name.txt
        rename to new/name.txt
        index 1111111..2222222 100644
        --- a/old/name.txt
        +++ b/new/name.txt
        @@ -1,2 +1,2 @@
        -foo
        +bar
         baz
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "new/name.txt")
        XCTAssertEqual(files[0].change, .renamed(from: "old/name.txt"))
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[0].removed, 1)
    }

    func testPureRenameHasNoHunks() {
        let diff = """
        diff --git a/before.txt b/after.txt
        similarity index 100%
        rename from before.txt
        rename to after.txt
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "after.txt")
        XCTAssertEqual(files[0].change, .renamed(from: "before.txt"))
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testBinaryFile() {
        let diff = """
        diff --git a/img.png b/img.png
        index 1111111..2222222 100644
        Binary files a/img.png and b/img.png differ
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "img.png")
        XCTAssertEqual(files[0].change, .binary)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testNewAndDeletedFiles() {
        let diff = """
        diff --git a/added.txt b/added.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 2)

        XCTAssertEqual(files[0].path, "added.txt")
        XCTAssertEqual(files[0].change, .added)
        XCTAssertEqual(files[0].added, 2)
        XCTAssertEqual(files[0].hunks[0].lines[0].newNumber, 1)
        XCTAssertEqual(files[0].hunks[0].lines[1].newNumber, 2)

        XCTAssertEqual(files[1].path, "gone.txt")
        XCTAssertEqual(files[1].change, .deleted)
        XCTAssertEqual(files[1].removed, 2)
    }

    func testNoNewlineMarkerIsNoteNotLine() {
        let diff = """
        diff --git a/x.txt b/x.txt
        index 1111111..2222222 100644
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[0].removed, 1)

        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].text, "\\ No newline at end of file")
        XCTAssertNil(lines[1].oldNumber)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].kind, .added)
        XCTAssertEqual(lines[2].newNumber, 1)
    }

    func testQuotedPathWithSpacesAndQuotes() {
        let diff = #"""
        diff --git "a/sp ace \"q\".txt" "b/sp ace \"q\".txt"
        index 1111111..2222222 100644
        --- "a/sp ace \"q\".txt"
        +++ "b/sp ace \"q\".txt"
        @@ -1 +1 @@
        -a
        +b
        """#

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "sp ace \"q\".txt")
    }

    func testUnquotedPathWithSpacesTrimsTrailingTab() {
        let diff = "diff --git a/sp ace.txt b/sp ace.txt\n"
            + "index 1111111..2222222 100644\n"
            + "--- a/sp ace.txt\t\n"
            + "+++ b/sp ace.txt\t\n"
            + "@@ -1 +1 @@\n"
            + "-a\n"
            + "+b"

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "sp ace.txt")
    }

    func testSubmoduleBumpParsesAsOrdinaryHunk() {
        let diff = """
        diff --git a/SwiftTerm b/SwiftTerm
        index 1111111..2222222 160000
        --- a/SwiftTerm
        +++ b/SwiftTerm
        @@ -1 +1 @@
        -Subproject commit aaaa
        +Subproject commit bbbb
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "SwiftTerm")
        XCTAssertEqual(files[0].change, .modified)
        XCTAssertEqual(files[0].hunks[0].lines.count, 2)
    }

    func testMultipleFilesKeepOrder() {
        let diff = """
        diff --git a/first.txt b/first.txt
        index 1111111..2222222 100644
        --- a/first.txt
        +++ b/first.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/second.txt b/second.txt
        index 1111111..2222222 100644
        --- a/second.txt
        +++ b/second.txt
        @@ -1 +1 @@
        -c
        +d
        """

        let files = GitDiffParser.files(fromUnifiedDiff: diff)
        XCTAssertEqual(files.map(\.path), ["first.txt", "second.txt"])
    }

    func testEmptyInputYieldsNoFiles() {
        XCTAssertTrue(GitDiffParser.files(fromUnifiedDiff: "").isEmpty)
    }

    // MARK: - Numstat Summary

    func testNumstatSummarySumsFilesAndLines() {
        let numstat = "12\t3\tSources/Foo.swift\n0\t20\tREADME.md\n5\t0\tnew file.txt\n"

        let summary = GitDiffParser.summary(fromNumstat: Data(numstat.utf8))

        XCTAssertEqual(summary.files, 3)
        XCTAssertEqual(summary.added, 17)
        XCTAssertEqual(summary.removed, 23)
        XCTAssertFalse(summary.isClean)
    }

    func testNumstatSummaryCountsBinaryAsFileWithoutLines() {
        let numstat = "-\t-\tImage.png\n4\t1\tSources/Foo.swift\n"

        let summary = GitDiffParser.summary(fromNumstat: Data(numstat.utf8))

        XCTAssertEqual(summary.files, 2)
        XCTAssertEqual(summary.added, 4)
        XCTAssertEqual(summary.removed, 1)
    }

    func testNumstatSummaryOfEmptyOutputIsClean() {
        XCTAssertEqual(GitDiffParser.summary(fromNumstat: Data()), .clean)
        XCTAssertTrue(GitChangeSummary.clean.isClean)
    }

    // MARK: - Unquote

    func testUnquoteOctalEscapes() {
        XCTAssertEqual(GitDiffParser.unquote(#""\303\244.txt""#), "ä.txt")
        XCTAssertEqual(GitDiffParser.unquote(#""tab\there""#), "tab\there")
        XCTAssertEqual(GitDiffParser.unquote("plain.txt"), "plain.txt")
    }
}
