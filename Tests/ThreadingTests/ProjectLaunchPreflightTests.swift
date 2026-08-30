import Foundation
import XCTest
@testable import Threading

final class ProjectLaunchPreflightTests: XCTestCase {

    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-launch-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        try super.tearDownWithError()
    }

    func testExistingDirectoryIsUsable() {
        XCTAssertNil(ProjectLaunchPreflight.failure(forFolderPath: fixtureRoot.path))
    }

    func testMissingDirectoryIsRefusedWithItsPath() {
        let missing = fixtureRoot.appendingPathComponent("removed-worktree", isDirectory: true)

        XCTAssertEqual(
            ProjectLaunchPreflight.failure(forFolderPath: missing.path),
            .missing(path: missing.path)
        )
    }

    func testFileAtProjectPathIsNotAcceptedAsDirectory() throws {
        let file = fixtureRoot.appendingPathComponent("checkout")
        try Data("not a directory".utf8).write(to: file)

        XCTAssertEqual(
            ProjectLaunchPreflight.failure(forFolderPath: file.path),
            .notDirectory(path: file.path)
        )
    }

    func testMissingProjectProducesDurablePreflightFailure() throws {
        let missing = fixtureRoot.appendingPathComponent("removed-worktree", isDirectory: true)
        let project = Project(name: "Removed", folderURL: missing)

        let refusal = try XCTUnwrap(ProjectLaunchPreflight.launchFailure(for: project))

        XCTAssertEqual(refusal.origin, .preflight)
        XCTAssertNil(refusal.exitCode)
        XCTAssertEqual(refusal.knownCause, "project-folder-missing")
        XCTAssertTrue(refusal.summary.contains(missing.path))
    }
}
