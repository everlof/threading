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
    func testCommitPromotesTheCandidateAndRetiresThePreviousTargetCopy() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("new complete transcript", to: source)
        try write("older target transcript", to: destination)
        let copiedByteCount = try await TranscriptMigrationWorker.shared.install(
            source: source,
            destination: destination,
            includesSubagents: false,
            journalURL: recoveryJournal
        ) {
            true
        }

        XCTAssertEqual(copiedByteCount, Data("new complete transcript".utf8).count)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new complete transcript")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new complete transcript")
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testRefusedCommitRestoresThePreviousTargetCopyExactly() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)
        try write("standing target transcript", to: destination)

        do {
            _ = try await TranscriptMigrationWorker.shared.install(
                source: source,
                destination: destination,
                includesSubagents: false,
            journalURL: recoveryJournal
            ) {
                false
            }
            XCTFail("A refused store commit must roll back the transcript")
        } catch {
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
    func testRefusedCommitRemovesACandidateWhenNoTargetCopyExisted() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("candidate transcript", to: source)

        do {
            _ = try await TranscriptMigrationWorker.shared.install(
                source: source,
                destination: destination,
                includesSubagents: false,
            journalURL: recoveryJournal
            ) {
                false
            }
            XCTFail("A refused store commit must roll back the transcript")
        } catch {
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .commitRefused)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testAccountBundleCopiesSubagentsBeforeCommitAndKeepsTheSource() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        let sourceChildren = ClaudeTranscript.subagentsDirectory(forRoot: source)
        let targetChildren = ClaudeTranscript.subagentsDirectory(forRoot: destination)
        try write("parent history", to: source)
        try write("panel history", to: sourceChildren.appendingPathComponent("agent-panel.jsonl"))
        try write("old parent", to: destination)
        try write("stale panel", to: targetChildren.appendingPathComponent("agent-stale.jsonl"))

        let bytes = try await TranscriptMigrationWorker.shared.install(
            source: source, destination: destination, includesSubagents: true,
            journalURL: recoveryJournal
        ) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? String(contentsOf: destination, encoding: .utf8), "parent history")
            XCTAssertEqual(try? String(contentsOf: targetChildren.appendingPathComponent("agent-panel.jsonl"),
                                      encoding: .utf8), "panel history")
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetChildren.appendingPathComponent("agent-stale.jsonl").path))
            return true
        }
        XCTAssertEqual(bytes, Data("parent history".utf8).count)
        XCTAssertEqual(try String(contentsOf: sourceChildren.appendingPathComponent("agent-panel.jsonl"),
                                  encoding: .utf8), "panel history")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testRefusedBundleCommitRestoresParentAndChildrenTogether() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        let sourceChildren = ClaudeTranscript.subagentsDirectory(forRoot: source)
        let targetChildren = ClaudeTranscript.subagentsDirectory(forRoot: destination)
        try write("new parent", to: source)
        try write("new child", to: sourceChildren.appendingPathComponent("agent-new.jsonl"))
        try write("old parent", to: destination)
        try write("old child", to: targetChildren.appendingPathComponent("agent-old.jsonl"))
        do {
            _ = try await TranscriptMigrationWorker.shared.install(
                source: source, destination: destination, includesSubagents: true,
                journalURL: recoveryJournal
            ) { false }
            XCTFail("A refused account change must roll back the entire bundle")
        } catch {
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .commitRefused)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old parent")
        XCTAssertEqual(try String(contentsOf: targetChildren.appendingPathComponent("agent-old.jsonl"),
                                  encoding: .utf8), "old child")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetChildren.appendingPathComponent("agent-new.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testInvalidSubagentBundleCannotReplaceTheParent() async throws {
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("new parent", to: source)
        try write("old parent", to: destination)
        try write("not a directory", to: ClaudeTranscript.subagentsDirectory(forRoot: source))
        do {
            _ = try await TranscriptMigrationWorker.shared.install(
                source: source, destination: destination, includesSubagents: true,
                journalURL: recoveryJournal
            ) { XCTFail("Invalid child storage must refuse before the store commit"); return true }
            XCTFail("Invalid child storage was accepted")
        } catch {
            XCTAssertEqual(error as? TranscriptCopyTransactionError, .sourceNotRegular)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old parent")
        XCTAssertTrue(try scratchFiles(beside: destination).isEmpty)
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
    func testLaunchRecoveryRestoresAParentPromotedBeforeItsChildren() throws {
        let destination = root.appendingPathComponent("target/session.jsonl")
        let children = ClaudeTranscript.subagentsDirectory(forRoot: destination)
        let rootNonce = UUID().uuidString.lowercased()
        let childNonce = UUID().uuidString.lowercased()
        let candidate = scratchURL(nonce: rootNonce, suffix: "candidate", beside: destination)
        let backup = scratchURL(nonce: rootNonce, suffix: "previous", beside: destination)
        let childCandidate = scratchURL(nonce: childNonce, suffix: "candidate", beside: children)
        let childBackup = scratchURL(nonce: childNonce, suffix: "previous", beside: children)
        try write("old parent", to: destination)
        try write("new parent", to: candidate)
        try write("old child", to: children.appendingPathComponent("agent.jsonl"))
        try write("new child", to: childCandidate.appendingPathComponent("agent.jsonl"))
        try TranscriptCopyRecovery.begin(destination: destination, candidate: candidate, backup: backup,
            nonce: rootNonce, companions: [.init(version: 1, nonce: childNonce,
                destinationPath: children.path, candidatePath: childCandidate.path,
                backupPath: childBackup.path, hadDestination: true)],
            journalURL: recoveryJournal, fileManager: .default)
        try FileManager.default.moveItem(at: destination, to: backup)
        try FileManager.default.moveItem(at: candidate, to: destination)

        guard case .restoredPrevious = TranscriptCopyRecovery.recoverPending(journalURL: recoveryJournal)
        else { return XCTFail("A partially promoted bundle must restore its previous generation") }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old parent")
        XCTAssertEqual(try String(contentsOf: children.appendingPathComponent("agent.jsonl"), encoding: .utf8), "old child")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJournal.path))
    }

    @MainActor
    func testLargeBundleCopiesWithoutBlockingTheMainActor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_TRANSCRIPT_MIGRATION_STRESS"] == "1")
        let source = root.appendingPathComponent("source/session.jsonl")
        let destination = root.appendingPathComponent("target/session.jsonl")
        try write("parent history", to: source)
        let children = ClaudeTranscript.subagentsDirectory(forRoot: source)
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        let childData = Data(repeating: 65, count: 256 * 1_024)
        for index in 0..<64 {
            try childData.write(to: children.appendingPathComponent("agent-\(index).jsonl"))
        }
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let started = Date()
        _ = try await TranscriptMigrationWorker.shared.install(source: source, destination: destination,
            includesSubagents: true, journalURL: recoveryJournal) {
                XCTAssertTrue(heartbeat)
                return true
            }
        let targetChildren = ClaudeTranscript.subagentsDirectory(forRoot: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: targetChildren.path).count, 64)
        print("transcript-migration-stress bytes=16777216 children=64 seconds=\(Date().timeIntervalSince(started))")
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
