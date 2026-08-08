import XCTest
@testable import Threading

/// The changed-files card's tree derivation — compression, rollups, ordering and the
/// auto-expand rule, checked without a view in sight.
final class ChangedFilesTreeTests: XCTestCase {

    private func makeTree(_ files: [(String, Int, Int)]) -> ChangedFilesTree {
        ChangedFilesTree.build(from: files.map {
            ChangedFilesTree.File(path: $0.0, added: $0.1, removed: $0.2)
        })
    }

    func testDirectoriesComeFirstAndEverythingIsAlphabetical() {
        let tree = makeTree([
            ("package.json", 1, 0),
            ("src/pages/index.astro", 2, 8),
            ("public/robots.txt", 4, 0),
            ("astro.config.mjs", 3, 1)
        ])

        XCTAssertEqual(tree.nodes.map(\.name), [
            "public", "robots.txt",
            "src/pages", "index.astro",
            "astro.config.mjs", "package.json"
        ])
    }

    func testSingleChildChainsCompressIntoOneRow() {
        // A scaffolded project is mostly single-child chains, and a row per component is
        // indentation with no information in it.
        let tree = makeTree([("Sources/Threading/Core/Agent/File.swift", 1, 1)])

        XCTAssertEqual(tree.nodes.count, 2)
        XCTAssertEqual(tree.nodes[0].name, "Sources/Threading/Core/Agent")
        XCTAssertTrue(tree.nodes[0].isDirectory)
        XCTAssertEqual(tree.nodes[1].name, "File.swift")
        XCTAssertEqual(tree.nodes[1].depth, 1)
    }

    func testCompressionStopsWhereADirectoryHasSiblings() {
        let tree = makeTree([
            ("src/layouts/Base.astro", 1, 8),
            ("src/lib/constants.ts", 9, 0)
        ])

        // `src` has two children so it stays its own row; each child chain still compresses.
        XCTAssertEqual(tree.nodes.map(\.name), [
            "src", "layouts", "Base.astro", "lib", "constants.ts"
        ])
        XCTAssertEqual(tree.nodes.map(\.depth), [0, 1, 2, 1, 2])
    }

    func testCountsRollUpThroughAncestors() {
        let tree = makeTree([
            ("src/layouts/Base.astro", 1, 8),
            ("src/lib/constants.ts", 9, 0),
            ("public/robots.txt", 4, 0)
        ])

        let src = tree.nodes.first { $0.name == "src" }
        XCTAssertEqual(src?.added, 10)
        XCTAssertEqual(src?.removed, 8)
        XCTAssertEqual(tree.added, 14)
        XCTAssertEqual(tree.removed, 8)
        XCTAssertEqual(tree.fileCount, 3)
    }

    func testDescendantsAreTheRowsACollapseHides() {
        let tree = makeTree([
            ("src/layouts/Base.astro", 1, 8),
            ("src/lib/constants.ts", 9, 0),
            ("public/robots.txt", 4, 0)
        ])

        // nodes: public, robots.txt, src, layouts, Base.astro, lib, constants.ts
        let src = tree.nodes.firstIndex { $0.name == "src" }!
        XCTAssertEqual(tree.descendantIndices(of: src), 3..<7)

        let layouts = tree.nodes.firstIndex { $0.name == "layouts" }!
        XCTAssertEqual(tree.descendantIndices(of: layouts), 4..<5)
    }

    func testTheAutoExpandRuleIsFilesAndLines() {
        // t3code's thresholds: a small turn opens its tree outright, a wide sweep starts
        // folded so it does not land as forty rows in the transcript.
        XCTAssertTrue(makeTree([("a.swift", 10, 10)]).autoExpands)

        let manyFiles = makeTree((0..<6).map { ("file\($0).swift", 1, 0) })
        XCTAssertFalse(manyFiles.autoExpands)

        let manyLines = makeTree([("a.swift", 150, 60)])
        XCTAssertFalse(manyLines.autoExpands)
    }

    func testARootOnlyChangeSetHasNoDirectories() {
        let tree = makeTree([("README.md", 1, 0)])
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertFalse(tree.nodes[0].isDirectory)
        XCTAssertEqual(tree.nodes[0].depth, 0)
    }

    // MARK: - Hover Preview

    private func makeFile(
        path: String,
        hunks: [Int],
        added: Int = 1,
        removed: Int = 0
    ) -> GitFileDiff {
        GitFileDiff(
            path: path,
            change: .modified,
            hunks: hunks.enumerated().map { index, lines in
                GitHunk(
                    header: "@@ hunk \(index) @@",
                    lines: (0..<lines).map {
                        GitDiffLine(kind: .added, text: "line \($0)", newNumber: $0 + 1)
                    }
                )
            },
            added: added,
            removed: removed
        )
    }

    func testAShortFileIsKeptWhole() {
        let preview = ChangedFileDiffPreview.preview(
            of: makeFile(path: "a.swift", hunks: [3, 4]),
            lineCap: 400
        )

        XCTAssertEqual(preview.hunks.map(\.lines.count), [3, 4])
        XCTAssertEqual(preview.omittedLines, 0)
        XCTAssertFalse(preview.isEmpty)
    }

    func testTheCapIsSpentInHunkOrderAndWhatItMissesIsCounted() {
        // The card outlives its turn, so the diff it keeps is bounded when it is captured.
        // A hunk the cap runs out inside is kept as far as it reaches — a preview that stops
        // mid-file still shows the change it started on.
        let preview = ChangedFileDiffPreview.preview(
            of: makeFile(path: "generated.swift", hunks: [4, 10, 6]),
            lineCap: 8
        )

        XCTAssertEqual(preview.hunks.map(\.lines.count), [4, 4])
        XCTAssertEqual(preview.omittedLines, 12)
    }

    func testAFileWithNothingToDrawHasNoPreview() {
        // A binary file, or one git reported without hunks: the row raises nothing.
        let preview = ChangedFileDiffPreview.preview(
            of: GitFileDiff(path: "icon.png", change: .binary, hunks: [], added: 0, removed: 0)
        )

        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(preview.omittedLines, 0)
    }

    func testPreviewsAreKeyedByPath() {
        let previews = ChangedFileDiffPreview.previews(from: [
            makeFile(path: "src/a.swift", hunks: [2], added: 2),
            makeFile(path: "src/b.swift", hunks: [3], added: 3)
        ])

        XCTAssertEqual(Set(previews.keys), ["src/a.swift", "src/b.swift"])
        XCTAssertEqual(previews["src/b.swift"]?.added, 3)
    }
}
