import XCTest
@testable import Threading

final class FileActivityMapTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Universe

    func testUniverseIsSortedDedupedAndTrimmed() {
        let map = FileActivityMap(files: [
            "./b.swift", "a/two.swift", "a/one.swift", "b.swift", "  ", "a/two.swift"
        ])

        XCTAssertEqual(map.entries.map(\.path), ["a/one.swift", "a/two.swift", "b.swift"])
        XCTAssertFalse(map.entries.contains(where: \.isNew))
    }

    func testRunOrdinalsFollowParentDirectories() {
        let map = FileActivityMap(files: [
            "Sources/UI/a.swift", "Sources/UI/b.swift", "Sources/Core/c.swift", "README.md"
        ])

        // Sorted: README.md, Sources/Core/c, Sources/UI/a, Sources/UI/b — root files are one
        // run, and each leaf directory is its own, so regions are directories rather than
        // the giant single run everything under `Sources/` would make.
        XCTAssertEqual(map.entries.map(\.runOrdinal), [0, 1, 2, 2])
    }

    // MARK: - Recording

    func testAbsolutePathsRelativizeAgainstTheRoot() {
        var map = FileActivityMap(files: ["Sources/a.swift"], root: "/repo/project/")

        let index = map.record(.read, path: "/repo/project/Sources/a.swift", at: now)
        XCTAssertEqual(index, 0)
        XCTAssertNotNil(map.entries[0].lastRead)
    }

    func testPathsOutsideTheRootAreIgnoredNotForceFitted() {
        var map = FileActivityMap(files: ["Sources/a.swift"], root: "/repo/project")

        XCTAssertNil(map.record(.read, path: "/etc/hosts", at: now))
        XCTAssertNil(map.record(.edit, path: "/repo/project-other/b.swift", at: now))
        XCTAssertEqual(map.entries.count, 1)
    }

    func testUnknownPathInsertsSortedAndMarkedNew() {
        var map = FileActivityMap(files: ["a.swift", "c.swift"])

        let index = map.record(.edit, path: "b.swift", at: now)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(map.entries.map(\.path), ["a.swift", "b.swift", "c.swift"])
        XCTAssertTrue(map.entries[1].isNew)

        // The index table must follow the shift, or every later mark lights the wrong file.
        XCTAssertEqual(map.record(.read, path: "c.swift", at: now), 2)
    }

    // MARK: - Heat

    func testHeatFadesToTheResidualAndHoldsThere() {
        XCTAssertEqual(FileActivityMap.heat(since: nil, now: now), 0)
        XCTAssertEqual(FileActivityMap.heat(since: now, now: now), 1)

        let atDuration = FileActivityMap.heat(
            since: now.addingTimeInterval(-FileActivityMap.Metrics.glowDuration),
            now: now
        )
        XCTAssertEqual(atDuration, FileActivityMap.Metrics.residualHeat, accuracy: 0.001)

        let longAfter = FileActivityMap.heat(since: now.addingTimeInterval(-9999), now: now)
        XCTAssertEqual(longAfter, FileActivityMap.Metrics.residualHeat, accuracy: 0.001)

        // A touch stamped ahead of the clock reads as fresh rather than as negative age.
        XCTAssertEqual(FileActivityMap.heat(since: now.addingTimeInterval(60), now: now), 1)
    }

    func testActiveGlowEndsWithTheFadeNotWithTheResidual() {
        var map = FileActivityMap(files: ["a.swift"])
        map.record(.read, path: "a.swift", at: now.addingTimeInterval(-10))

        XCTAssertTrue(map.hasActiveGlow(now: now))
        XCTAssertFalse(map.hasActiveGlow(
            now: now.addingTimeInterval(FileActivityMap.Metrics.glowDuration + 10)
        ))
    }

    // MARK: - Classification

    func testClaudeVocabularyClassifies() {
        let read = FileActivityMap.touches(tool: .read, input: ["file_path": "/p/a.swift"])
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.kind, .read)
        XCTAssertEqual(read.first?.path, "/p/a.swift")

        for tool in [ToolIdentity.edit, .multiEdit, .write] {
            let touches = FileActivityMap.touches(tool: tool, input: ["file_path": "/p/a.swift"])
            XCTAssertEqual(touches.first?.kind, .edit, "\(tool) should classify as an edit")
        }

        let notebook = FileActivityMap.touches(
            tool: .notebookEdit, input: ["notebook_path": "/p/n.ipynb"]
        )
        XCTAssertEqual(notebook.first?.path, "/p/n.ipynb")
    }

    func testCodexPatchYieldsEveryFileItTouches() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/a.swift
        @@
        -old
        +new
        *** Add File: Sources/b.swift
        +created
        *** End Patch
        """
        let touches = FileActivityMap.touches(tool: .edit, input: ["patch": patch])

        XCTAssertEqual(touches.map(\.path), ["Sources/a.swift", "Sources/b.swift"])
        XCTAssertTrue(touches.allSatisfy { $0.kind == .edit })
    }

    func testDirectoryLevelAndUnparsedToolsStaySilent() {
        // A Grep names a directory, not the files read inside it; a Bash command would need
        // the shell parsed. Guessing marks poisons the true ones.
        XCTAssertTrue(FileActivityMap.touches(tool: .grep, input: ["path": "/p"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .glob, input: ["path": "/p"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .bash, input: ["command": "cat a"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .read, input: [:]).isEmpty)
    }

    // MARK: - Layout

    func testLayoutHoldsEveryMarkInsideEveryPane() {
        let counts = [1, 50, 438, 4966]
        let sizes = [CGSize(width: 56, height: 900),
                     CGSize(width: 300, height: 1000),
                     CGSize(width: 120, height: 600)]

        for count in counts {
            for size in sizes {
                guard let layout = FileActivityMap.Layout.compute(count: count, size: size) else {
                    XCTFail("No layout for \(count) files at \(size)")
                    continue
                }

                XCTAssertLessThanOrEqual(layout.contentWidth, size.width + 0.5)
                XCTAssertGreaterThanOrEqual(
                    layout.columnCount * layout.rowsPerColumn, count,
                    "\(count) files at \(size): grid too small"
                )

                let last = layout.rect(at: count - 1)
                XCTAssertLessThanOrEqual(last.maxX, size.width + 0.5)
                XCTAssertLessThanOrEqual(last.maxY, size.height + 0.5)
                XCTAssertGreaterThan(layout.markHeight, 0)
            }
        }
    }

    func testLayoutPrefersRoomyPitchesWhenTheyFit() {
        // 438 files in 300×1000: pitch 4 gives 250 rows a column, two columns fit easily.
        let layout = FileActivityMap.Layout.compute(
            count: 438, size: CGSize(width: 300, height: 1000)
        )
        XCTAssertEqual(layout?.rowPitch, 4)
        XCTAssertEqual(layout?.columnCount, 2)
    }

    func testLayoutRefusesTheUndrawable() {
        XCTAssertNil(FileActivityMap.Layout.compute(count: 0, size: CGSize(width: 300, height: 1000)))
        XCTAssertNil(FileActivityMap.Layout.compute(count: 10, size: CGSize(width: 4, height: 1000)))
    }
}
