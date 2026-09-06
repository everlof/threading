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

    /// The catalogue names its edition, every invalidation advances it, and the encoded body a
    /// worker produces for one edition is served to the next device asking for the same one
    /// without projecting or encoding again. A change empties that shelf, and a body encoded
    /// against an edition that moved while the worker ran is never shelved at all.
    func testTheCatalogueEditionAdvancesOnChangeAndEncodedBodiesAreReusedWithinIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-catalogue-revision-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        XCTAssertNotNil(ProjectStore.shared.addSession(to: project.id, kind: .claude, title: "One"))

        var buildCount = 0
        let registry = RemoteSessionMirrorRegistry(
            allSessionsCatalogueDidBuild: { buildCount += 1 }
        )
        let owner = ownerAuthorization(id: "owner-one")

        let first = registry.meResponseSnapshot(for: owner)
        let payload = try XCTUnwrap(first.payload, "a cold edition hands the worker a payload")
        XCTAssertNil(first.encoded)
        XCTAssertEqual(payload.revision, first.revision)
        XCTAssertEqual(first.revision, registry.catalogueRevision)

        let encoded = try RemoteMeEncodedResponse.encode(payload, revision: first.revision)
        registry.storeMeResponse(encoded, for: owner)

        let second = registry.meResponseSnapshot(for: owner)
        XCTAssertNil(second.payload, "a shelved body needs no projection")
        XCTAssertEqual(second.encoded?.json, encoded.json)
        XCTAssertEqual(buildCount, 1)

        // Another device is another body — its share block differs — but the same projection.
        let other = registry.meResponseSnapshot(for: ownerAuthorization(id: "owner-two"))
        XCTAssertNotNil(other.payload)
        XCTAssertNil(other.encoded)
        XCTAssertEqual(buildCount, 1)

        NotificationCenter.default.post(ProjectsDidChange())
        let moved = registry.meResponseSnapshot(for: owner)
        XCTAssertEqual(moved.revision.epoch, first.revision.epoch)
        XCTAssertEqual(moved.revision.revision, first.revision.revision + 1)
        XCTAssertNil(moved.encoded, "a change empties the shelf")
        XCTAssertNotNil(moved.payload)

        // A body the worker finished against the old edition is dropped, not served as new.
        registry.storeMeResponse(encoded, for: owner)
        XCTAssertNil(registry.meResponseSnapshot(for: owner).encoded)

        XCTAssertFalse(moved.revision.matches(ifNoneMatch: first.revision.entityTag))
        XCTAssertTrue(moved.revision.matches(ifNoneMatch: moved.revision.entityTag))
    }

    /// Reading a finished chat changes only its participant receipt. The receipt event is a
    /// narrow model edge; the broader presentation event must not publish the same row twice.
    /// Runtime snapshots own their own row publication even when their projected activity is
    /// unchanged, because continuation and blocker fields can still have changed.
    func testReadReceiptActivityPublishesOneCatalogueEdition() {
        let registry = RemoteSessionMirrorRegistry()
        let sessionID = SessionID()
        let initial = registry.catalogueRevision

        NotificationCenter.default.post(SessionAttentionDidChange(
            sessionID: sessionID,
            persistence: .committed
        ))
        XCTAssertEqual(registry.catalogueRevision.revision, initial.revision + 1)
        NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
        XCTAssertEqual(
            registry.catalogueRevision.revision,
            initial.revision + 1,
            "presentation notification is not a second remote model edge"
        )

        let idle = SessionRuntimeSnapshot(
            process: .ready,
            turn: .none,
            continuation: .none,
            blocker: .none,
            activity: .idle,
            reportsOwnTurns: true
        )
        let working = SessionRuntimeSnapshot(
            process: .ready,
            turn: .inFlight(.reported),
            continuation: .none,
            blocker: .none,
            activity: .working,
            reportsOwnTurns: true
        )
        NotificationCenter.default.post(SessionRuntimeDidChange(
            sessionID: sessionID,
            transition: SessionRuntimeTransition(previous: idle, current: working),
            cause: .turnStarted
        ))
        XCTAssertEqual(
            registry.catalogueRevision.revision,
            initial.revision + 2,
            "the typed runtime edge owns its remote row"
        )
        NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
        XCTAssertEqual(registry.catalogueRevision.revision, initial.revision + 2)

        let delegated = SessionRuntimeSnapshot(
            process: .ready,
            turn: .none,
            continuation: .delegated,
            blocker: .none,
            activity: .readyWithBackgroundWork,
            reportsOwnTurns: true
        )
        let standing = SessionRuntimeSnapshot(
            process: .ready,
            turn: .none,
            continuation: .standing,
            blocker: .none,
            activity: .readyWithBackgroundWork,
            reportsOwnTurns: true
        )
        NotificationCenter.default.post(SessionRuntimeDidChange(
            sessionID: sessionID,
            transition: SessionRuntimeTransition(previous: delegated, current: standing),
            cause: .turnFinished
        ))
        XCTAssertEqual(
            registry.catalogueRevision.revision,
            initial.revision + 3,
            "a typed runtime-only row change still publishes"
        )
    }

    /// The shelf is bounded by distinct authorizations, and the one served longest ago leaves.
    func testTheEncodedBodyShelfEvictsTheLeastRecentlyServedAuthorization() throws {
        var cache = RemoteMeResponseCache(capacity: 2)
        let revision = RemoteCatalogueRevisionDTO(epoch: "e", revision: 1)
        let body = RemoteMeEncodedResponse(revision: revision, json: Data("{}".utf8), gzip: nil)
        let keys = ["a", "b", "c"].map { RemoteMeResponseKey(ownerAuthorization(id: $0)) }

        cache.store(body, for: keys[0], revision: revision)
        cache.store(body, for: keys[1], revision: revision)
        XCTAssertNotNil(cache.response(for: keys[0], revision: revision))
        cache.store(body, for: keys[2], revision: revision)

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.response(for: keys[0], revision: revision), "served recently, kept")
        XCTAssertNil(cache.response(for: keys[1], revision: revision), "served longest ago, gone")
        XCTAssertNotNil(cache.response(for: keys[2], revision: revision))
        XCTAssertNil(
            cache.response(for: keys[2], revision: RemoteCatalogueRevisionDTO(epoch: "e", revision: 2)),
            "another edition is another catalogue"
        )
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

        // The bytes, separately: what one device's body costs to encode and compress once, and
        // what the next device asking for the same edition pays instead.
        let owner = ownerAuthorization(id: "owner-0")
        let payload = try XCTUnwrap(registry.meResponseSnapshot(for: owner).payload)
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        let encoded = try RemoteMeEncodedResponse.encode(payload, revision: registry.catalogueRevision)
        let encodeElapsed = DispatchTime.now().uptimeNanoseconds - encodeStarted
        registry.storeMeResponse(encoded, for: owner)
        let shelfStarted = DispatchTime.now().uptimeNanoseconds
        let shelved = registry.meResponseSnapshot(for: owner).encoded
        let shelfElapsed = DispatchTime.now().uptimeNanoseconds - shelfStarted
        XCTAssertNotNil(shelved)
        print(
            "THREADING_PERF remote-catalogue-body sessions=\(sessionCount) "
                + "json_bytes=\(encoded.json.count) gzip_bytes=\(encoded.gzip?.count ?? 0) "
                + "encode_ms=\(String(format: "%.3f", Double(encodeElapsed) / 1_000_000)) "
                + "shelf_lookup_ms=\(String(format: "%.3f", Double(shelfElapsed) / 1_000_000))"
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
