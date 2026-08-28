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

    @MainActor
    func testCommitPromotesTheCandidateAndRetiresThePreviousTargetCopy() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("new complete transcript", to: source)
        try write("older target transcript", to: destination)
        var commits = 0

        let copiedByteCount = try TranscriptCopyTransaction.install(
            source: source,
            destination: destination,
            recoveryJournalURL: recoveryJournal
        ) {
            commits += 1
            return true
        }

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(copiedByteCount, Data("new complete transcript".utf8).count)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new complete transcript")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new complete transcript")
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testRefusedCommitRestoresThePreviousTargetCopyExactly() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)
        try write("standing target transcript", to: destination)

        XCTAssertThrowsError(
            try TranscriptCopyTransaction.install(
                source: source,
                destination: destination,
                recoveryJournalURL: recoveryJournal
            ) {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testRefusedCommitRemovesACandidateWhenNoTargetCopyExisted() throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)

        XCTAssertThrowsError(
            try TranscriptCopyTransaction.install(
                source: source,
                destination: destination,
                recoveryJournalURL: recoveryJournal
            ) {
                false
            }
        ) { error in
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .commitRefused)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testLaunchRecoveryRestoresAHiddenPreviousCopy() throws {
        let destination = root.appendingPathComponent("target/session.jsonl")
        let nonce = UUID().uuidString.lowercased()
        let candidate = scratchURL(nonce: nonce, suffix: "candidate", beside: destination)
        let backup = scratchURL(nonce: nonce, suffix: "previous", beside: destination)
        try write("standing target transcript", to: destination)
        try write("candidate transcript", to: candidate)
        try TranscriptCopyRecovery.begin(
            destination: destination,
            candidate: candidate,
            backup: backup,
            nonce: nonce,
            journalURL: recoveryJournal,
            fileManager: .default
        )
        try FileManager.default.moveItem(at: destination, to: backup)

        let outcome = TranscriptCopyRecovery.recoverPending(journalURL: recoveryJournal)

        guard case .restoredPrevious(let restored) = outcome else {
            return XCTFail("expected the previous target to be restored, got \(outcome)")
        }
        XCTAssertEqual(restored, destination)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "standing target transcript"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testLaunchRecoveryClearsARecordWrittenBeforeTheFirstRename() throws {
        let destination = root.appendingPathComponent("target/session.jsonl")
        let nonce = UUID().uuidString.lowercased()
        let candidate = scratchURL(nonce: nonce, suffix: "candidate", beside: destination)
        let backup = scratchURL(nonce: nonce, suffix: "previous", beside: destination)
        try write("standing target transcript", to: destination)
        try write("candidate transcript", to: candidate)
        try TranscriptCopyRecovery.begin(
            destination: destination,
            candidate: candidate,
            backup: backup,
            nonce: nonce,
            journalURL: recoveryJournal,
            fileManager: .default
        )

        let outcome = TranscriptCopyRecovery.recoverPending(journalURL: recoveryJournal)

        guard case .clearedPrepared(let preserved) = outcome else {
            return XCTFail("expected prepared scratch to be cleared, got \(outcome)")
        }
        XCTAssertEqual(preserved, destination)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "standing target transcript"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testLaunchRecoveryReportsAnAmbiguousPromotedCopyWithoutGuessing() throws {
        let destination = root.appendingPathComponent("target/session.jsonl")
        let nonce = UUID().uuidString.lowercased()
        let candidate = scratchURL(nonce: nonce, suffix: "candidate", beside: destination)
        let backup = scratchURL(nonce: nonce, suffix: "previous", beside: destination)
        try write("standing target transcript", to: destination)
        try write("candidate transcript", to: candidate)
        try TranscriptCopyRecovery.begin(
            destination: destination,
            candidate: candidate,
            backup: backup,
            nonce: nonce,
            journalURL: recoveryJournal,
            fileManager: .default
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try FileManager.default.moveItem(at: candidate, to: destination)

        let outcome = TranscriptCopyRecovery.recoverPending(journalURL: recoveryJournal)

        guard case .needsAttention(let reported, _) = outcome else {
            return XCTFail("expected an ambiguous promotion to be reported, got \(outcome)")
        }
        XCTAssertEqual(reported, destination)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "candidate transcript"
        )
        XCTAssertEqual(
            try String(contentsOf: backup, encoding: .utf8),
            "standing target transcript"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryJournal.path))
        XCTAssertThrowsError(
            try TranscriptCopyRecovery.begin(
                destination: destination,
                candidate: candidate,
                backup: backup,
                nonce: nonce,
                journalURL: recoveryJournal,
                fileManager: .default
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptCopyRecovery.RecoveryError,
                .pendingRecovery
            )
        }
    }

    @MainActor
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

    private var recoveryJournal: URL {
        root.appendingPathComponent("recovery/PendingTranscriptCopy.json")
    }

    private func scratchURL(nonce: String, suffix: String, beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".threading-move-\(nonce).\(suffix)")
    }
}
