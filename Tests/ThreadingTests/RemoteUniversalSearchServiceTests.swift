import ThreadingRemoteKit
import XCTest

@testable import Threading

@MainActor
final class RemoteUniversalSearchServiceTests: HostedStoreTestCase {
    func testTokenIsDeviceBoundOneTimeAndSupersededByANewerGeneration() async throws {
        let fixture = try makeFixture(name: "SearchAuthority")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try await projectHit(
            from: fixture.service,
            projectName: fixture.project.name,
            generation: 1,
            deviceID: "phone-a"
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.resolve(token: first.token, deviceID: "phone-b")
        }

        let resolution = try await fixture.service.resolve(
            token: first.token,
            deviceID: "phone-a"
        )
        XCTAssertEqual(resolution.kind, .project)
        XCTAssertEqual(resolution.projectName, fixture.project.name)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.resolve(token: first.token, deviceID: "phone-a")
        }

        let superseded = try await projectHit(
            from: fixture.service,
            projectName: fixture.project.name,
            generation: 2,
            deviceID: "phone-a"
        )
        _ = try await fixture.service.search(RemoteSearchRequestDTO(
            query: "",
            generation: 3
        ), deviceID: "phone-a")
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.resolve(token: superseded.token, deviceID: "phone-a")
        }
    }

    func testLateGenerationCannotInvalidateCompletedResults() async throws {
        let fixture = try makeFixture(name: "SearchLateGeneration")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let current = try await projectHit(
            from: fixture.service,
            projectName: fixture.project.name,
            generation: 5,
            deviceID: "phone-a"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.search(RemoteSearchRequestDTO(
                query: fixture.project.name,
                generation: 3
            ), deviceID: "phone-a")
        }

        let resolution = try await fixture.service.resolve(
            token: current.token,
            deviceID: "phone-a"
        )
        XCTAssertEqual(resolution.projectID, fixture.project.id.uuidString)

        // A completed empty query has no token to keep the generation alive. It must still
        // reject an older delivery during the replay window.
        _ = try await fixture.service.search(RemoteSearchRequestDTO(
            query: "definitely-no-search-result-9d61f9cf",
            generation: 6
        ), deviceID: "phone-a")
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.search(RemoteSearchRequestDTO(
                query: fixture.project.name,
                generation: 5
            ), deviceID: "phone-a")
        }
    }

    func testTokenCapacityEvictsOldestEntriesWithoutClearingOtherLiveDevices() async throws {
        let fixture = try makeFixture(
            name: "SearchTokenCapacity",
            maximumRetainedTokens: 2
        ) { project, sessionID in
            [WorkspaceMetadataSearchRecord(
                destination: .attachment(SearchAttachmentID(rawValue: "capacity-attachment")),
                projectID: project.id,
                projectName: project.name,
                sessionID: sessionID,
                sessionTitle: "Incident review",
                providerName: "Codex",
                title: "unique-capacity-marker",
                detail: "attachment",
                isArchived: false,
                updatedAt: Date(timeIntervalSince1970: 1)
            )]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let oldest = try await searchHit(
            from: fixture.service,
            query: "unique-capacity-marker",
            kind: .attachment,
            generation: 1,
            deviceID: "phone-a"
        )
        let retained = try await searchHit(
            from: fixture.service,
            query: "unique-capacity-marker",
            kind: .attachment,
            generation: 1,
            deviceID: "phone-b"
        )
        _ = try await searchHit(
            from: fixture.service,
            query: "unique-capacity-marker",
            kind: .attachment,
            generation: 1,
            deviceID: "phone-c"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.resolve(token: oldest.token, deviceID: "phone-a")
        }
        let resolution = try await fixture.service.resolve(
            token: retained.token,
            deviceID: "phone-b"
        )
        XCTAssertEqual(resolution.attachmentID, "capacity-attachment")
    }

    func testRemoteCompositionIncludesBoundedWorkspaceMetadata() async throws {
        let fixture = try makeFixture(name: "SearchMetadata") { project, sessionID in
            [WorkspaceMetadataSearchRecord(
                destination: .attachment(SearchAttachmentID(rawValue: "attachment-1")),
                projectID: project.id,
                projectName: project.name,
                sessionID: sessionID,
                sessionTitle: "Incident review",
                providerName: "Codex",
                title: "evidence.pdf",
                detail: "artifacts/evidence.pdf",
                isArchived: false,
                updatedAt: Date(timeIntervalSince1970: 1)
            )]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try await fixture.service.search(RemoteSearchRequestDTO(
            query: "evidence",
            generation: 1
        ), deviceID: "phone-a")

        XCTAssertEqual(response.groups.flatMap(\.hits).map(\.kind), [.attachment])
        XCTAssertEqual(response.groups.flatMap(\.hits).first?.title, "evidence.pdf")
        let hit = try XCTUnwrap(response.groups.flatMap(\.hits).first)
        let resolution = try await fixture.service.resolve(
            token: hit.token,
            deviceID: "phone-a"
        )
        XCTAssertEqual(resolution.kind, .attachment)
        XCTAssertEqual(resolution.attachmentID, "attachment-1")
    }

    func testAmbiguousProjectPresentationNameCannotSelectAuthority() async throws {
        let parentA = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-scope-a-\(UUID().uuidString)", isDirectory: true)
        let parentB = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-scope-b-\(UUID().uuidString)", isDirectory: true)
        let first = parentA.appendingPathComponent("Duplicate", isDirectory: true)
        let second = parentB.appendingPathComponent("Duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: parentA)
            try? FileManager.default.removeItem(at: parentB)
        }
        XCTAssertNotNil(ProjectStore.shared.addProject(folderURL: first))
        XCTAssertNotNil(ProjectStore.shared.addProject(folderURL: second))
        let fixture = try serviceFixture(root: parentA)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.search(RemoteSearchRequestDTO(
                query: "",
                scope: .project,
                projectName: "Duplicate",
                generation: 1
            ), deviceID: "phone-a")
        }
    }

    func testProjectResolutionCarriesStableIdentityWhenNamesAreDuplicated() async throws {
        let parentA = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-route-a-\(UUID().uuidString)", isDirectory: true)
        let parentB = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-route-b-\(UUID().uuidString)", isDirectory: true)
        let first = parentA.appendingPathComponent("Duplicate", isDirectory: true)
        let second = parentB.appendingPathComponent("Duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: parentA)
            try? FileManager.default.removeItem(at: parentB)
        }
        let projectA = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: first))
        let projectB = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: second))
        let fixture = try serviceFixture(root: parentA)

        var resolvedIDs = Set<String>()
        for _ in 0 ..< 50 where resolvedIDs.count < 2 {
            let response = try await fixture.service.search(RemoteSearchRequestDTO(
                query: "Duplicate",
                generation: UInt64(resolvedIDs.count + 1)
            ), deviceID: "phone-a")
            for hit in response.groups.flatMap(\.hits).filter({ $0.kind == .project }) {
                let resolution = try await fixture.service.resolve(
                    token: hit.token,
                    deviceID: "phone-a"
                )
                if let id = resolution.projectID { resolvedIDs.insert(id) }
            }
            if resolvedIDs.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(resolvedIDs, Set([projectA.id.uuidString, projectB.id.uuidString]))
    }

    private struct Fixture {
        let service: RemoteUniversalSearchService
        let project: Project
        let root: URL
    }

    private func makeFixture(
        name: String,
        maximumRetainedTokens: Int = RemoteSearchWireLimits.maximumVisibleHits * 32,
        metadata: @escaping @MainActor (Project, SessionID) -> [WorkspaceMetadataSearchRecord] = {
            _, _ in []
        }
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            title: "Incident review"
        ))
        let metadataRecords = metadata(project, session.id)
        let service = try serviceFixture(
            root: root,
            metadata: { metadataRecords },
            maximumRetainedTokens: maximumRetainedTokens
        ).service
        return Fixture(service: service, project: project, root: root)
    }

    private func serviceFixture(
        root: URL,
        metadata: @escaping @MainActor () -> [WorkspaceMetadataSearchRecord] = { [] },
        maximumRetainedTokens: Int = RemoteSearchWireLimits.maximumVisibleHits * 32
    ) throws -> Fixture {
        let center = NotificationCenter()
        let navigation = NavigationSearchIndexStore(
            projectStore: .shared,
            notificationCenter: center
        )
        let transcript = TranscriptSearchIndexStore(
            projectStore: .shared,
            databaseURL: root.appendingPathComponent("search-index.sqlite"),
            notificationCenter: center
        )
        let service = RemoteUniversalSearchService(
            navigationIndex: navigation,
            transcriptIndex: transcript,
            projectStore: .shared,
            workspaceMetadata: metadata,
            maximumRetainedTokens: maximumRetainedTokens
        )
        return Fixture(
            service: service,
            project: ProjectStore.shared.projects.first ?? Project(name: "", folderURL: root),
            root: root
        )
    }

    private func projectHit(
        from service: RemoteUniversalSearchService,
        projectName: String,
        generation: UInt64,
        deviceID: String
    ) async throws -> RemoteSearchHitDTO {
        try await searchHit(
            from: service,
            query: projectName,
            kind: .project,
            generation: generation,
            deviceID: deviceID
        )
    }

    private func searchHit(
        from service: RemoteUniversalSearchService,
        query: String,
        kind: RemoteSearchHitKindDTO,
        generation: UInt64,
        deviceID: String
    ) async throws -> RemoteSearchHitDTO {
        for _ in 0 ..< 50 {
            let response = try await service.search(RemoteSearchRequestDTO(
                query: query,
                generation: generation
            ), deviceID: deviceID)
            if let hit = response.groups.flatMap(\.hits).first(where: { $0.kind == kind }) {
                return hit
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search never published the expected \(kind.rawValue) hit")
        throw RemoteUniversalSearchError.unavailable
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @MainActor () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
