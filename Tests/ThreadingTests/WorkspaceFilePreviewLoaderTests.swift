@testable import Threading
import XCTest

final class WorkspaceFilePreviewLoaderTests: XCTestCase {
    private var directory: URL!
    private let projectID = ProjectID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilePreviewLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testLoadsOnlyTheBoundedHeadAndTruncatesLongUnicodeLinesOnACharacterBoundary()
        async throws
    {
        let longLine = String(repeating: "🧭", count: 700)
        let source = ([longLine] + (2 ... 50).map { "line \($0)" }).joined(separator: "\n")
        try Data(source.utf8).write(to: directory.appendingPathComponent("Notes.swift"))

        let preview = try await WorkspaceFilePreviewLoader.load(
            projectID: projectID,
            root: directory,
            relativePath: "Notes.swift"
        )

        XCTAssertEqual(preview.projectID, projectID)
        XCTAssertEqual(preview.relativePath, "Notes.swift")
        XCTAssertEqual(preview.lines.count, 41)
        XCTAssertEqual(preview.lines.map(\.number), Array(1 ... 41))
        XCTAssertLessThanOrEqual(preview.lines[0].text.utf8.count, 2048)
        XCTAssertTrue(preview.lines[0].text.hasSuffix("…"))
        XCTAssertTrue(preview.hasLater)
    }

    func testRejectsTraversalAndASymlinkLeavingTheProject() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilePreviewOutside-\(UUID().uuidString).txt")
        try Data("private".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("outside.txt"),
            withDestinationURL: outside
        )

        for relativePath in ["../outside.txt", "outside.txt", "/etc/hosts"] {
            do {
                _ = try await WorkspaceFilePreviewLoader.load(
                    projectID: projectID,
                    root: directory,
                    relativePath: relativePath
                )
                XCTFail("\(relativePath) must not escape the project")
            } catch let error as WorkspaceFilePreviewLoadError {
                XCTAssertEqual(error, .resultNoLongerAvailable)
            }
        }
    }

    func testRejectsBinaryAndOversizedSources() async throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: directory.appendingPathComponent("binary.dat"))
        try Data(repeating: 0x61, count: 4 * 1024 * 1024 + 1)
            .write(to: directory.appendingPathComponent("large.txt"))

        for relativePath in ["binary.dat", "large.txt"] {
            do {
                _ = try await WorkspaceFilePreviewLoader.load(
                    projectID: projectID,
                    root: directory,
                    relativePath: relativePath
                )
                XCTFail("\(relativePath) must not be projected")
            } catch let error as WorkspaceFilePreviewLoadError {
                XCTAssertEqual(error, .sourceUnavailable)
            }
        }
    }
}
