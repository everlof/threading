import Foundation
import XCTest
@testable import Threading

final class SessionMigrationTransactionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-migration-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testCommitPromotesTheCandidateAndRetiresThePreviousTargetCopy() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("new complete transcript", to: source)
        try write("older target transcript", to: destination)
        var commits = 0

        try TranscriptCopyTransaction.install(source: source, destination: destination) {
            commits += 1
            return true
        }

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new complete transcript")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new complete transcript")
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
    }

    func testRefusedCommitRestoresThePreviousTargetCopyExactly() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)
        try write("standing target transcript", to: destination)

        XCTAssertThrowsError(
            try TranscriptCopyTransaction.install(source: source, destination: destination) {
                false
            }
        ) { error in
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .commitRefused)
        }

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "standing target transcript"
        )
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "candidate transcript")
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
    }

    func testRefusedCommitRemovesACandidateWhenNoTargetCopyExisted() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)

        XCTAssertThrowsError(
            try TranscriptCopyTransaction.install(source: source, destination: destination) {
                false
            }
        ) { error in
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .commitRefused)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
    }

    func testContainmentUsesComponentsAndFollowsSymlinks() throws {
        let account = root.appendingPathComponent("config", isDirectory: true)
        let inside = account.appendingPathComponent("sessions/2026/session.jsonl")
        let sibling = root.appendingPathComponent("config-old/session.jsonl")
        let outside = root.appendingPathComponent("outside/session.jsonl")
        try write("inside", to: inside)
        try write("sibling", to: sibling)
        try write("outside", to: outside)

        XCTAssertEqual(
            SessionMigration.relativePathComponents(of: inside, beneath: account),
            ["sessions", "2026", "session.jsonl"]
        )
        XCTAssertNil(SessionMigration.relativePathComponents(of: sibling, beneath: account))

        let link = account.appendingPathComponent("escaped.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(SessionMigration.relativePathComponents(of: link, beneath: account))
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func scratchFiles(beside destination: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".threading-move-") }
    }
}
