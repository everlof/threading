import Foundation
import XCTest

final class FilesystemSynchronizedTestTargetTests: XCTestCase {
    func testThisUnregisteredFileIsCompiledByTheSynchronizedTarget() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFile = repositoryRoot
            .appendingPathComponent("Threading.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)

        XCTAssertTrue(project.contains("isa = PBXFileSystemSynchronizedRootGroup;"))
        XCTAssertTrue(project.contains("path = Tests/ThreadingTests;"))
        XCTAssertFalse(project.contains("FilesystemSynchronizedTestTargetTests.swift"))
    }
}
