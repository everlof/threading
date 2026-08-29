import XCTest
@testable import Threading

@MainActor
final class ComposerAttachmentHandoverTests: XCTestCase {
    func testStagedHandoverReturnsOnlySessionOwnedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-handover-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("project", isDirectory: true)
        let custody = root.appendingPathComponent("custody", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = staging.appendingPathComponent(
            "\(ComposerAttachmentDefaults.generatedPrefix)report.jpeg"
        )
        let bytes = Data([0xff, 0xd8, 0xff, 0x01])
        try bytes.write(to: source)
        let store = SessionAttachmentStore(
            copiesDirectory: { custody },
            referenceRoot: { _ in project },
            allowsFilesOutsideProject: { false }
        )

        let handed = try XCTUnwrap(ComposerAttachmentHandover.handOverStaged(
            paths: [source.path],
            sessionID: SessionID(),
            projectRoot: project,
            store: store
        ))

        XCTAssertEqual(handed.count, 1)
        XCTAssertNotEqual(handed[0], source.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: handed[0])), bytes)
    }

    func testStagedHandoverRefusesCallerPathFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-handover-refusal-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staged.jpeg")
        try Data([0xff, 0xd8, 0xff]).write(to: source)
        let store = SessionAttachmentStore(
            referenceRoot: { _ in project },
            allowsFilesOutsideProject: { false }
        )

        XCTAssertNil(ComposerAttachmentHandover.handOverStaged(
            paths: [source.path],
            sessionID: SessionID(),
            projectRoot: project,
            store: store
        ))
    }
}
