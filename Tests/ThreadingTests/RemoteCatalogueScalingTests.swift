import XCTest
@testable import Threading

@MainActor
final class RemoteCatalogueScalingTests: HostedStoreTestCase {
    func testOwnerFanoutReusesOneShortLivedProjectionAndInvalidatesOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-catalogue-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        let firstSession = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            title: "First"
        ))
        XCTAssertNotNil(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            title: "Second"
        ))

        var now = ContinuousClock.now
        var buildCount = 0
        let registry = RemoteSessionMirrorRegistry(
            catalogueCacheNow: { now },
            allSessionsCatalogueDidBuild: { buildCount += 1 }
        )
        let first = registry.meResponse(for: ownerAuthorization(id: "owner-one"))
        let second = registry.meResponse(for: ownerAuthorization(id: "owner-two"))

        XCTAssertEqual(first.sessions.count, 2)
        XCTAssertEqual(second.sessions, first.sessions)
        XCTAssertEqual(first.share.label, "owner-one")
        XCTAssertEqual(second.share.label, "owner-two")
        XCTAssertEqual(buildCount, 1, "owner metadata must not multiply catalogue projection")

        let guest = registry.meResponse(for: RemoteAuthorization(
            shareID: "guest",
            capability: .view,
            scope: .session(firstSession.id),
            principal: .guest
        ))
        XCTAssertEqual(guest.sessions.map(\.id), [firstSession.id.uuidString])
        XCTAssertEqual(buildCount, 1, "an exact-session guest should use indexed lookup")

        now = now.advanced(by: .seconds(2))
        _ = registry.meResponse(for: ownerAuthorization(id: "owner-three"))
        XCTAssertEqual(buildCount, 2, "the shared projection must expire after its freshness bound")

        NotificationCenter.default.post(ProjectsDidChange())
        _ = registry.meResponse(for: ownerAuthorization(id: "owner-four"))
        XCTAssertEqual(buildCount, 3, "a structural change must invalidate the shared projection")
    }

    func testStressOwnerCatalogueFanoutWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_REMOTE_CATALOGUE_STRESS"] == "1",
            "Set THREADING_REMOTE_CATALOGUE_STRESS=1 to measure owner catalogue fan-out."
        )

        let sessionCount = ProcessInfo.processInfo.environment[
            "THREADING_REMOTE_CATALOGUE_STRESS_SESSIONS"
        ].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 1_000
        let clientCount = RemoteAccessDefaults.maximumConnections
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-catalogue-stress-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        for index in 0..<sessionCount {
            XCTAssertNotNil(ProjectStore.shared.addSession(
                to: project.id,
                kind: .claude,
                title: "Conversation \(index)"
            ))
        }

        var buildCount = 0
        let registry = RemoteSessionMirrorRegistry(
            allSessionsCatalogueDidBuild: { buildCount += 1 }
        )
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<clientCount {
            let response = registry.meResponse(for: ownerAuthorization(id: "owner-\(index)"))
            XCTAssertEqual(response.sessions.count, sessionCount)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let elapsedMilliseconds = String(format: "%.3f", Double(elapsed) / 1_000_000)
        XCTAssertEqual(buildCount, 1)
        print(
            "THREADING_PERF remote-catalogue-fanout sessions=\(sessionCount) "
                + "clients=\(clientCount) "
                + "builds=\(buildCount) elapsed_ms=\(elapsedMilliseconds)"
        )
    }

    private func ownerAuthorization(id: String) -> RemoteAuthorization {
        RemoteAuthorization(
            shareID: id,
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice
        )
    }
}
