import XCTest
@testable import Threading

@MainActor
final class RemoteSessionRecencyTests: HostedStoreTestCase {
    /// A long-lived process can host today's newest turn while a relaunched old chat has the
    /// newest process timestamp. Exercise the catalogue clients actually sort and display.
    func testCatalogueUsesConversationRecencyWithPinningAndLegacyFallback() throws {
        let project = try makeProject()
        let resumed = try addSession("Recent turn", to: project.id, active: 100, turn: 900)
        let relaunched = try addSession("Old turn, new process", to: project.id, active: 1_000, turn: 200)
        let legacy = try addSession("Legacy", to: project.id, active: 500)
        let pinned = try addSession("Pinned", to: project.id, active: 50, turn: 50)
        ProjectStore.shared.update(sessionID: pinned.id) { $0.isPinned = true }

        let registry = RemoteSessionMirrorRegistry()
        let catalogue = registry.meResponse(for: owner)
        XCTAssertEqual(
            catalogue.sessions.map(\.id),
            [pinned, resumed, legacy, relaunched].map { $0.id.uuidString }
        )
        XCTAssertEqual(catalogue.sessions.map(\.lastActiveAt), [50, 900, 500, 200])

        let guest = RemoteAuthorization(
            shareID: "recency-guest",
            capability: .view,
            scope: .session(resumed.id),
            principal: .guest
        )
        XCTAssertEqual(registry.meResponse(for: guest).sessions.first?.lastActiveAt, 900)
        XCTAssertEqual(
            registry.sessionSummary(for: resumed.id, authorization: owner)?.lastActiveAt,
            900,
            "snapshots and the single-row live update projection must agree"
        )
    }

    func testTurnStartInvalidatesCachedCatalogueAndPromotesTheConversation() throws {
        let project = try makeProject()
        let resumed = try addSession("Resumed", to: project.id, active: 100, turn: 100)
        let other = try addSession("Other", to: project.id, active: 500, turn: 500)
        let registry = RemoteSessionMirrorRegistry()
        let before = registry.meResponseSnapshot(for: owner)
        let payload = try XCTUnwrap(before.payload)
        XCTAssertEqual(payload.sessions.map(\.id), [other.id.uuidString, resumed.id.uuidString])
        registry.storeMeResponse(
            try RemoteMeEncodedResponse.encode(payload, revision: before.revision),
            for: owner
        )
        XCTAssertNotNil(registry.meResponseSnapshot(for: owner).encoded)

        // The terminal renderer stamps the turn before publishing the typed runtime edge. The
        // stamp itself is coalesced persistence, not a second catalogue notification.
        ProjectStore.shared.noteTurnStarted(sessionID: resumed.id)
        XCTAssertEqual(registry.catalogueRevision, before.revision)
        let idle = SessionRuntimeSnapshot(
            process: .ready, turn: .none, continuation: .none, blocker: .none,
            activity: .idle, reportsOwnTurns: true
        )
        let working = SessionRuntimeSnapshot(
            process: .ready, turn: .inFlight(.reported), continuation: .none, blocker: .none,
            activity: .working, reportsOwnTurns: true
        )
        NotificationCenter.default.post(SessionRuntimeDidChange(
            sessionID: resumed.id,
            transition: SessionRuntimeTransition(previous: idle, current: working),
            cause: .turnStarted
        ))

        let after = registry.meResponseSnapshot(for: owner)
        XCTAssertEqual(after.revision.revision, before.revision.revision + 1)
        XCTAssertNil(after.encoded)
        let refreshed = try XCTUnwrap(after.payload)
        XCTAssertEqual(refreshed.sessions.map(\.id), [resumed.id.uuidString, other.id.uuidString])
        let stored = try XCTUnwrap(ProjectStore.shared.session(withID: resumed.id))
        let turnAt = try XCTUnwrap(stored.lastTurnAt).timeIntervalSince1970
        XCTAssertEqual(stored.lastActiveAt.timeIntervalSince1970, 100)
        XCTAssertEqual(refreshed.sessions.first?.lastActiveAt, turnAt)
        XCTAssertEqual(
            registry.sessionSummary(for: resumed.id, authorization: owner)?.lastActiveAt,
            turnAt
        )
    }

    func testAcceptedSteeringPublishesOneRowWithoutChangingTurnStart() throws {
        let project = try makeProject()
        let resumed = try addSession("Steered", to: project.id, active: 100, turn: 100)
        let other = try addSession("Other", to: project.id, active: 500, turn: 500)
        let registry = RemoteSessionMirrorRegistry()
        let before = registry.meResponseSnapshot(for: owner)
        XCTAssertEqual(before.payload?.sessions.map(\.id), [other.id.uuidString, resumed.id.uuidString])
        ProjectStore.shared.noteInputAccepted(
            sessionID: resumed.id, at: Date(timeIntervalSince1970: 700)
        )
        let after = registry.meResponseSnapshot(for: owner)
        XCTAssertEqual(after.revision.revision, before.revision.revision + 1)
        XCTAssertEqual(after.payload?.sessions.first?.id, resumed.id.uuidString)
        XCTAssertEqual(after.payload?.sessions.first?.lastActiveAt, 700)
        XCTAssertEqual(ProjectStore.shared.session(withID: resumed.id)?.lastTurnAt?.timeIntervalSince1970, 100)
    }

    private var owner: RemoteAuthorization {
        RemoteAuthorization(
            shareID: "recency-owner", capability: .interact,
            scope: .allSessions, principal: .ownerDevice
        )
    }

    private func makeProject() throws -> Project {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-recency-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
    }

    private func addSession(
        _ title: String, to projectID: ProjectID, active: TimeInterval, turn: TimeInterval? = nil
    ) throws -> AgentSession {
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: projectID, kind: .claude, title: title
        ))
        ProjectStore.shared.update(sessionID: session.id) {
            $0.lastActiveAt = Date(timeIntervalSince1970: active)
            $0.lastTurnAt = turn.map { Date(timeIntervalSince1970: $0) }
        }
        return session
    }
}
