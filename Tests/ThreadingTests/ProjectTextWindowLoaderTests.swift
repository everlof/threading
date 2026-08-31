@testable import Threading
import XCTest

final class ProjectTextWindowLoaderTests: XCTestCase {
    private var directory: URL!
    private let projectID = ProjectID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTextWindowLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testLoadsBoundedLinesAndExactMatch() async throws {
        let lines = (1 ... 20).map { index in
            index == 10 ? "let ultramarine = true" : "line \(index)"
        }
        try Data(lines.joined(separator: "\n").utf8)
            .write(to: directory.appendingPathComponent("Example.swift"))
        let location = SearchFileLocation(
            relativePath: "Example.swift",
            line: 10,
            column: 5,
            matchLength: 11,
            lineFingerprint: SearchSourceFingerprint.text(lines[9])
        )

        let window = try await ProjectTextWindowLoader.load(
            projectID: projectID,
            root: directory,
            location: location
        )

        XCTAssertEqual(window.lines.map(\.number), Array(5 ... 15))
        XCTAssertEqual(window.anchorLine, 10)
        XCTAssertEqual(window.anchorMatch, SearchTextRange(utf16Location: 4, utf16Length: 11))
        XCTAssertTrue(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
    }

    func testRejectsAChangedSourceLine() async throws {
        let file = directory.appendingPathComponent("Example.swift")
        try Data("let needle = true".utf8).write(to: file)
        let location = SearchFileLocation(
            relativePath: "Example.swift",
            line: 1,
            column: 5,
            matchLength: 6,
            lineFingerprint: SearchSourceFingerprint.text("let needle = true")
        )
        try Data("let changed = true".utf8).write(to: file)

        do {
            _ = try await ProjectTextWindowLoader.load(
                projectID: projectID,
                root: directory,
                location: location
            )
            XCTFail("A changed line must not accept a stale search locator")
        } catch let error as ProjectTextWindowLoadError {
            XCTAssertEqual(error, .resultNoLongerAvailable)
        }
    }

    func testRejectsTraversal() async throws {
        let location = SearchFileLocation(
            relativePath: "../outside.txt",
            line: 1,
            column: 1,
            matchLength: 1,
            lineFingerprint: 1
        )

        do {
            _ = try await ProjectTextWindowLoader.load(
                projectID: projectID,
                root: directory,
                location: location
            )
            XCTFail("Traversal must never leave the checkout")
        } catch let error as ProjectTextWindowLoadError {
            XCTAssertEqual(error, .resultNoLongerAvailable)
        }
    }
}
