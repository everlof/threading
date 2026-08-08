import Foundation
import XCTest
@testable import Threading

/// The batch adoption behind both imports — onboarding's page and the sheet: one save for many
/// conversations, and duplicates skipped whether they repeat something the project already
/// tracks or each other.
@MainActor
final class ProjectStoreImportBatchTests: XCTestCase {

    func testBatchAdoptsResumableSessionsAndSkipsDuplicates() throws {
        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-import-batch-\(UUID().uuidString)")
        )
        defer { store.removeProject(id: project.id) }

        func conversation(_ id: String, daysAgo: Double) -> ImportableSession {
            ImportableSession(
                agentSessionID: TranscriptID(id),
                kind: .claude,
                accountHandle: .standard,
                title: "Chat \(id)",
                lastActiveAt: Date(timeIntervalSinceNow: -daysAgo * 24 * 60 * 60)
            )
        }

        // One already tracked, then a batch that repeats it.
        let existing = try XCTUnwrap(
            store.importSessions([conversation("already", daysAgo: 3)], into: project.id).first
        )

        let adopted = store.importSessions(
            [
                conversation("already", daysAgo: 3),   // duplicate of the tracked one
                conversation("fresh-1", daysAgo: 1),
                conversation("fresh-1", daysAgo: 1),   // duplicate within the batch
                conversation("fresh-2", daysAgo: 0.5)
            ],
            into: project.id
        )

        XCTAssertEqual(
            adopted.map { $0.resumeState.transcriptID?.rawValue },
            ["fresh-1", "fresh-2"]
        )
        for session in adopted {
            XCTAssertTrue(session.hasLaunched, "Adopted resumable, like the single path")
            XCTAssertTrue(session.resumeState.isResumable)
        }

        let stored = try XCTUnwrap(store.project(withID: project.id))
        XCTAssertEqual(stored.sessions.count, 3)
        XCTAssertTrue(stored.sessions.contains { $0.id == existing.id })
    }

    func testEmptyBatchTouchesNothing() {
        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-import-empty-\(UUID().uuidString)")
        )
        defer { store.removeProject(id: project.id) }

        XCTAssertTrue(store.importSessions([], into: project.id).isEmpty)
        XCTAssertEqual(store.project(withID: project.id)?.sessions.count, 0)
    }
}
