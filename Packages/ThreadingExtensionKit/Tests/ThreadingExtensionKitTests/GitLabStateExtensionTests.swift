import Foundation
import XCTest
@testable import GitLabStateExtensionSupport
import ThreadingExtensionKit

final class GitLabStateExtensionTests: XCTestCase {
    private let repository = ExtensionRepositoryKey(
        host: "gitlab.com",
        path: "group/subgroup/repository"
    )

    func testManifestAndRegistrationUseTheExactSameFactDefinition() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/GitLabStateExtension/threading-extension.json")
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(decoded, GitLabStateExtensionContract.manifest)
        XCTAssertEqual(
            decoded.factDefinitions,
            GitLabStateExtensionContract.registration.factDefinitions
        )
        XCTAssertEqual(decoded.factDefinitions, [ExtensionFactDefinition(
            key: .init(id: "gitlab.mr.state", version: 1),
            displayName: "GitLab merge request state",
            valueType: .string,
            subjectKinds: [.repositoryBranch],
            usages: [.filterable, .sortable, .groupable, .presentable]
        )])
        XCTAssertEqual(decoded.capabilities, [
            .factsProvide,
            .hostProjectsRead,
            .hostRepositoriesRead,
            .hostEvents,
            .networkBrokered
        ])
        XCTAssertEqual(decoded.networkGrants, [ExtensionNetworkGrant(
            host: "gitlab.com",
            methods: ["GET"]
        )])
        XCTAssertTrue(decoded.hasNoUI)
        try decoded.validate()
        try GitLabStateExtensionContract.registration.validate(for: decoded)
    }

    func testNestedAndHostileProjectPathsAreEncodedExactlyOnce() {
        XCTAssertEqual(
            GitLabProjectPathEncoder.encode("group/sub group/repo%2F\u{2603}"),
            "group%2Fsub%20group%2Frepo%252F%E2%98%83"
        )
        XCTAssertEqual(
            GitLabProjectPathEncoder.mergeRequestsURL(
                repositoryPath: "group/sub/repo",
                page: 2
            ),
            "https://gitlab.com/api/v4/projects/group%2Fsub%2Frepo/merge_requests"
                + "?scope=all&state=all&order_by=updated_at&sort=desc&per_page=100&page=2"
        )
    }

    func testForksAreExcludedAndDuplicatesChooseLatestTimestampThenIID() throws {
        let records = [
            mergeRequest(
                iid: 99,
                state: "future-state",
                branch: "fork-only",
                sourceProjectID: 2,
                projectID: 1,
                updatedAt: "2026-08-30T10:00:00Z"
            ),
            mergeRequest(
                iid: 2,
                state: "opened",
                branch: "main",
                updatedAt: "2026-08-30T09:00:00Z"
            ),
            mergeRequest(
                iid: 1,
                state: "merged",
                branch: "main",
                updatedAt: "2026-08-30T12:00:00+02:00"
            ),
            mergeRequest(
                iid: 8,
                state: "closed",
                branch: "release",
                updatedAt: "2026-08-30T10:00:00.125Z"
            ),
            mergeRequest(
                iid: 9,
                state: "locked",
                branch: "release",
                updatedAt: "2026-08-30T10:00:00.125000Z"
            ),
            mergeRequest(
                iid: 10,
                state: "opened",
                branch: "deleted-fork",
                sourceProjectID: nil,
                projectID: 1,
                updatedAt: "2026-08-30T11:00:00Z"
            )
        ]

        XCTAssertEqual(try GitLabMergeRequestReducer.reduce(records), [
            GitLabBranchMergeRequest(
                branch: "main",
                state: .merged,
                updatedAt: "2026-08-30T12:00:00+02:00",
                iid: 1
            ),
            GitLabBranchMergeRequest(
                branch: "release",
                state: .locked,
                updatedAt: "2026-08-30T10:00:00.125000Z",
                iid: 9
            )
        ])
    }

    func testAuthoritativeEmptyClearsWhileUnknownAndTransientResponsesPreserve() async {
        let previous = Set([
            branchSubject(repository: repository, branch: "main"),
            branchSubject(repository: repository, branch: "release")
        ])
        let successful = RefreshScript(steps: [
            .response(response(body: mergeRequestBody([]), nextPage: ""))
        ])
        let emptyOutcome = await refresh(
            previous: previous,
            script: successful,
            now: Date(timeIntervalSinceReferenceDate: 50)
        )
        guard case .replace(let publication) = emptyOutcome else {
            return XCTFail("Expected an authoritative clear, got \(emptyOutcome)")
        }
        XCTAssertTrue(publication.facts.isEmpty)
        XCTAssertEqual(Set(publication.replacingSubjects), previous)

        let unknown = RefreshScript(steps: [
            .response(response(body: mergeRequestBody([
                mergeRequest(state: "new-state", branch: "main")
            ]), nextPage: ""))
        ])
        let unknownOutcome = await refresh(previous: previous, script: unknown)
        XCTAssertEqual(unknownOutcome, .preserve(.unknownState("new-state")))

        let malformed = RefreshScript(steps: [
            .response(response(body: Data("{not-json".utf8), nextPage: ""))
        ])
        let malformedOutcome = await refresh(previous: previous, script: malformed)
        XCTAssertEqual(malformedOutcome, .preserve(.malformed))

        let transient = RefreshScript(steps: [
            .response(response(status: 503)),
            .response(response(status: 503)),
            .response(response(status: 503))
        ])
        let transientOutcome = await refresh(previous: previous, script: transient)
        XCTAssertEqual(transientOutcome, .preserve(.httpStatus(503)))
        let transientSnapshot = await transient.snapshot()
        XCTAssertEqual(transientSnapshot.fetchCount, 3)
        XCTAssertEqual(transientSnapshot.delays, [1, 2])
    }

    func testOnlyRetryableFailuresUseTheOneAndTwoSecondRetryBudget() async {
        let transport = RefreshScript(steps: [.transport, .transport, .transport])
        let transportOutcome = await refresh(previous: [], script: transport)
        XCTAssertEqual(transportOutcome, .preserve(.transport))
        let transportSnapshot = await transport.snapshot()
        XCTAssertEqual(transportSnapshot.fetchCount, 3)
        XCTAssertEqual(transportSnapshot.delays, [1, 2])

        let unauthorized = RefreshScript(steps: [.response(response(status: 401))])
        let unauthorizedOutcome = await refresh(previous: [], script: unauthorized)
        XCTAssertEqual(unauthorizedOutcome, .preserve(.httpStatus(401)))
        let unauthorizedSnapshot = await unauthorized.snapshot()
        XCTAssertEqual(unauthorizedSnapshot.fetchCount, 1)
        XCTAssertTrue(unauthorizedSnapshot.delays.isEmpty)
    }

    func testCompleteRefreshUsesOneCompletionTimestampAndAtomicSubjectUnion() async {
        let previous = Set([branchSubject(repository: repository, branch: "removed")])
        let completion = Date(timeIntervalSinceReferenceDate: 1_234)
        let script = RefreshScript(steps: [
            .response(response(body: mergeRequestBody([
                mergeRequest(state: "opened", branch: "main"),
                mergeRequest(iid: 2, state: "merged", branch: "release")
            ]), nextPage: ""))
        ])

        let outcome = await refresh(previous: previous, script: script, now: completion)
        guard case .replace(let publication) = outcome else {
            return XCTFail("Expected replacement, got \(outcome)")
        }
        XCTAssertEqual(publication.facts.map(\.observedAt), [completion, completion])
        XCTAssertEqual(publication.facts.map(\.value), [.string("opened"), .string("merged")])
        XCTAssertEqual(Set(publication.replacingSubjects), previous.union(
            publication.currentSubjects
        ))
        XCTAssertEqual(publication.replacingSubjects.count, 3)
    }

    func testSecondPageSignalBeyondTheTwoPageBudgetPreservesPriorFacts() async {
        let pageOne = Array(0..<100).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let pageTwo = Array(100..<128).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let script = RefreshScript(steps: [
            .response(response(body: mergeRequestBody(pageOne), nextPage: "2")),
            .response(response(body: mergeRequestBody(pageTwo), nextPage: "3"))
        ])

        let outcome = await refresh(previous: [], script: script)
        XCTAssertEqual(outcome, .preserve(.paginationTruncated))
        let snapshot = await script.snapshot()
        XCTAssertEqual(snapshot.fetchCount, 2)
    }

    func testRepositoryAndFactCapsBoundA5000ProjectRefreshWithFourInFlight() async {
        let projects = (0..<5_000).map { project(path: String(format: "repo-%04d", $0)) }
        let firstPage = Array(0..<100).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let secondPage = Array(100..<128).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let host = ProviderHost(
            projectPages: [.init(cursor: 10, projects: projects)],
            responsesByPage: [
                1: response(body: mergeRequestBody(firstPage), nextPage: "2"),
                2: response(body: mergeRequestBody(secondPage), nextPage: "")
            ],
            fetchDelayNanoseconds: 2_000_000
        )
        let diagnostics = LockedDiagnostics()
        let provider = GitLabStateProvider(
            host: host,
            diagnostic: { diagnostics.append($0) }
        )

        await provider.start()

        let snapshot = await host.snapshot()
        let admitted = await provider.admitted
        XCTAssertEqual(admitted.count, 32)
        XCTAssertEqual(admitted.first?.path, "repo-0000")
        XCTAssertEqual(admitted.last?.path, "repo-0031")
        XCTAssertEqual(snapshot.fetchCount, 64)
        XCTAssertEqual(snapshot.maximumConcurrentFetches, 4)
        XCTAssertEqual(snapshot.publications.count, 32)
        XCTAssertEqual(snapshot.publications.reduce(0) { $0 + $1.facts.count }, 4_096)
        XCTAssertTrue(snapshot.publications.allSatisfy { $0.facts.count == 128 })
        XCTAssertTrue(diagnostics.values.contains { $0.contains("omitted 4968") })
    }

    func testCapTruncationPublishesNothing() async {
        let pageOne = Array(0..<100).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let pageTwo = Array(100..<129).map {
            mergeRequest(iid: Int64($0 + 1), branch: "branch-\($0)")
        }
        let script = RefreshScript(steps: [
            .response(response(body: mergeRequestBody(pageOne), nextPage: "2")),
            .response(response(body: mergeRequestBody(pageTwo), nextPage: ""))
        ])

        let outcome = await refresh(previous: [], script: script)
        XCTAssertEqual(outcome, .preserve(.factLimitExceeded))
    }

    func testEvictionAndRemovalClearPreviouslyPublishedSubjects() async {
        let initialProjects = (0...32).map {
            project(path: String(format: "repo-%03d", $0))
        }
        let withEarlierRepository = [project(path: "aaa")] + initialProjects
        let afterRemoval = withEarlierRepository.filter {
            $0.repository?.repositoryPath != "repo-000"
        }
        let oneFact = response(body: mergeRequestBody([
            mergeRequest(state: "opened", branch: "main")
        ]), nextPage: "")
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 1, projects: initialProjects),
                .init(cursor: 2, projects: withEarlierRepository),
                .init(cursor: 3, projects: afterRemoval)
            ],
            responsesByPage: [1: oneFact]
        )
        let provider = GitLabStateProvider(host: host)

        await provider.start()
        let afterInitial = await host.snapshot().publications.count
        await provider.synchronizeProjects()
        let afterEviction = await host.snapshot().publications
        let evictionClear = afterEviction[afterInitial...].first {
            $0.facts.isEmpty && $0.repositoryPaths == ["repo-031"]
        }
        XCTAssertNotNil(evictionClear)

        let beforeRemoval = afterEviction.count
        await provider.synchronizeProjects()
        let afterRemovalPublications = await host.snapshot().publications
        let removalClear = afterRemovalPublications[beforeRemoval...].first {
            $0.facts.isEmpty && $0.repositoryPaths == ["repo-000"]
        }
        XCTAssertNotNil(removalClear)
    }

    func testAmbiguousInitialPublicationStillLeavesSubjectsAvailableForRemovalClear() async {
        let oneFact = response(body: mergeRequestBody([
            mergeRequest(state: "opened", branch: "main")
        ]), nextPage: "")
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 1, projects: [project(path: "repo")]),
                .init(cursor: 2, projects: [])
            ],
            responsesByPage: [1: oneFact],
            publicationFailures: 1
        )
        let provider = GitLabStateProvider(host: host)

        await provider.start()
        await provider.synchronizeProjects()

        let publications = await host.snapshot().publications
        XCTAssertEqual(publications.count, 2)
        XCTAssertEqual(publications[0].facts.count, 1)
        XCTAssertTrue(publications[1].facts.isEmpty)
        XCTAssertEqual(publications[1].repositoryPaths, ["repo"])
    }

    func testExpiredCursorResnapshotsAndContinuesFromTheNewSnapshotCursor() async {
        let unchangedProjects = [project(path: "repo")]
        let oneFact = response(body: mergeRequestBody([
            mergeRequest(state: "opened", branch: "main")
        ]), nextPage: "")
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 10, projects: unchangedProjects),
                .init(cursor: 50, projects: unchangedProjects)
            ],
            eventSteps: [.expired],
            responsesByPage: [1: oneFact]
        )
        let provider = GitLabStateProvider(host: host)

        await provider.start()
        await provider.pollEventsOnce()

        let snapshot = await host.snapshot()
        let cursor = await provider.eventCursor
        XCTAssertEqual(snapshot.projectCallCount, 2)
        XCTAssertEqual(snapshot.eventCursors, [10])
        XCTAssertEqual(snapshot.fetchCount, 1)
        XCTAssertEqual(snapshot.publications.count, 1)
        XCTAssertEqual(cursor, 50)
    }

    func testProjectEventDoesNotRefreshUnchangedRepositoryOrResetFullCadence() async {
        let unchangedProjects = [project(path: "repo")]
        let changed = ExtensionHostEvent(
            cursor: 11,
            kind: .projectChanged,
            entityID: "project"
        )
        let oneFact = response(body: mergeRequestBody([
            mergeRequest(state: "opened", branch: "main")
        ]), nextPage: "")
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 10, projects: unchangedProjects),
                .init(cursor: 20, projects: unchangedProjects)
            ],
            eventSteps: [
                .page(.init(events: [changed], nextCursor: 11, hasMore: false))
            ],
            responsesByPage: [1: oneFact]
        )
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 0))
        let provider = GitLabStateProvider(host: host, clock: clock)

        await provider.start()
        clock.set(Date(timeIntervalSinceReferenceDate: 299))
        await provider.pollEventsOnce()

        var snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.projectCallCount, 2)
        XCTAssertEqual(snapshot.fetchCount, 1)
        XCTAssertEqual(snapshot.publications.count, 1)

        clock.set(Date(timeIntervalSinceReferenceDate: 301))
        await provider.refreshAllIfDue()

        snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.fetchCount, 2)
        XCTAssertEqual(snapshot.publications.count, 2)
    }

    func testProjectEventRefreshesOnlyNewlyAdmittedRepository() async {
        let changed = ExtensionHostEvent(
            cursor: 11,
            kind: .projectChanged,
            entityID: "project-b"
        )
        let oneFact = response(body: mergeRequestBody([
            mergeRequest(state: "opened", branch: "main")
        ]), nextPage: "")
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 10, projects: [project(path: "repo-a")]),
                .init(cursor: 20, projects: [
                    project(path: "repo-a"),
                    project(path: "repo-b")
                ])
            ],
            eventSteps: [
                .page(.init(events: [changed], nextCursor: 11, hasMore: false))
            ],
            responsesByPage: [1: oneFact]
        )
        let provider = GitLabStateProvider(host: host)

        await provider.start()
        await provider.pollEventsOnce()

        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.fetchCount, 2)
        XCTAssertEqual(snapshot.publications.count, 2)
        XCTAssertEqual(snapshot.publications[0].repositoryPaths, ["repo-a"])
        XCTAssertEqual(snapshot.publications[1].repositoryPaths, ["repo-b"])
    }

    func testEventPagesDrainBeforeOneProjectResnapshot() async {
        let changed = ExtensionHostEvent(
            cursor: 11,
            kind: .projectChanged,
            entityID: "project"
        )
        let host = ProviderHost(
            projectPages: [
                .init(cursor: 10, projects: []),
                .init(cursor: 30, projects: [])
            ],
            eventSteps: [
                .page(.init(events: [changed], nextCursor: 11, hasMore: true)),
                .page(.init(events: [], nextCursor: 12, hasMore: false))
            ]
        )
        let provider = GitLabStateProvider(host: host)

        await provider.start()
        await provider.pollEventsOnce()

        let snapshot = await host.snapshot()
        let cursor = await provider.eventCursor
        XCTAssertEqual(snapshot.eventCursors, [10, 11])
        XCTAssertEqual(snapshot.projectCallCount, 2)
        XCTAssertEqual(cursor, 30)
    }

    private func refresh(
        previous: Set<ExtensionFactSubject>,
        script: RefreshScript,
        now: Date = Date(timeIntervalSinceReferenceDate: 100)
    ) async -> GitLabRepositoryRefreshOutcome {
        await GitLabRepositoryRefresher.refresh(
            repository: repository,
            previousSubjects: previous,
            fetch: { try await script.fetch($0) },
            sleep: { await script.sleep(seconds: $0) },
            now: { now }
        )
    }
}

private extension ExtensionManifest {
    var hasNoUI: Bool {
        !capabilities.contains(.panels)
            && !capabilities.contains(.componentCustomization)
            && !capabilities.contains(.workspaceNavigation)
    }
}

private func project(
    path: String,
    host: String = "gitlab.com"
) -> ExtensionProjectSnapshot {
    ExtensionProjectSnapshot(
        id: "project-\(host)-\(path)",
        displayName: path,
        repository: .init(remoteHost: host, repositoryPath: path)
    )
}

private func mergeRequest(
    iid: Int64 = 1,
    state: String = "opened",
    branch: String,
    sourceProjectID: Int64? = 1,
    projectID: Int64 = 1,
    updatedAt: String = "2026-08-30T10:00:00Z"
) -> GitLabMergeRequest {
    GitLabMergeRequest(
        iid: iid,
        state: state,
        sourceBranch: branch,
        sourceProjectID: sourceProjectID,
        projectID: projectID,
        updatedAt: updatedAt
    )
}

private func mergeRequestBody(_ requests: [GitLabMergeRequest]) -> Data {
    let objects: [[String: Any]] = requests.map { request in
        var object: [String: Any] = [
            "iid": request.iid,
            "state": request.state,
            "source_branch": request.sourceBranch,
            "project_id": request.projectID,
            "updated_at": request.updatedAt
        ]
        object["source_project_id"] = request.sourceProjectID ?? NSNull()
        return object
    }
    return try! JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
}

private func response(
    status: Int = 200,
    body: Data = Data("[]".utf8),
    nextPage: String? = nil
) -> ExtensionBrokeredFetchResponse {
    ExtensionBrokeredFetchResponse(
        status: status,
        headers: nextPage.map { ["X-Next-Page": $0] } ?? [:],
        bodyBase64: body.base64EncodedString(),
        credential: "anonymous"
    )
}

private func branchSubject(
    repository: ExtensionRepositoryKey,
    branch: String
) -> ExtensionFactSubject {
    .repositoryBranch(repository: repository, branch: branch)
}

private actor RefreshScript {
    enum Step: Sendable {
        case response(ExtensionBrokeredFetchResponse)
        case transport
    }

    struct Snapshot: Sendable {
        let fetchCount: Int
        let delays: [UInt64]
    }

    private var steps: [Step]
    private var fetchCount = 0
    private var delays: [UInt64] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetch(_ request: ExtensionBrokeredFetchRequest) throws
        -> ExtensionBrokeredFetchResponse {
        _ = request
        fetchCount += 1
        let step = steps.isEmpty ? .transport : steps.removeFirst()
        switch step {
        case .response(let response): return response
        case .transport:
            throw ExtensionBrokeredFetchFailure(message: "offline", credential: "anonymous")
        }
    }

    func sleep(seconds: UInt64) {
        delays.append(seconds)
    }

    func snapshot() -> Snapshot {
        Snapshot(fetchCount: fetchCount, delays: delays)
    }
}

private struct RecordedPublication: Sendable {
    let facts: [ExtensionFact]
    let replacingSubjects: [ExtensionFactSubject]

    var repositoryPaths: [String] {
        Array(Set(replacingSubjects.compactMap { subject in
            if case .repositoryBranch(let repository, _) = subject {
                return repository.path
            }
            return nil
        })).sorted()
    }
}

private enum ProviderEventStep: Sendable {
    case page(ExtensionHostEventPage)
    case expired
}

private actor ProviderHost: GitLabStateHost {
    struct Snapshot: Sendable {
        let projectCallCount: Int
        let eventCursors: [Int64]
        let fetchCount: Int
        let maximumConcurrentFetches: Int
        let publications: [RecordedPublication]
    }

    private var projectPages: [ExtensionProjectSnapshotPage]
    private var eventSteps: [ProviderEventStep]
    private let responsesByPage: [Int: ExtensionBrokeredFetchResponse]
    private let fetchDelayNanoseconds: UInt64
    private var publicationFailures: Int
    private var projectCallCount = 0
    private var eventCursors: [Int64] = []
    private var fetchCount = 0
    private var currentFetches = 0
    private var maximumConcurrentFetches = 0
    private var publications: [RecordedPublication] = []

    init(
        projectPages: [ExtensionProjectSnapshotPage],
        eventSteps: [ProviderEventStep] = [],
        responsesByPage: [Int: ExtensionBrokeredFetchResponse] = [
            1: response(nextPage: "")
        ],
        fetchDelayNanoseconds: UInt64 = 0,
        publicationFailures: Int = 0
    ) {
        self.projectPages = projectPages
        self.eventSteps = eventSteps
        self.responsesByPage = responsesByPage
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
        self.publicationFailures = publicationFailures
    }

    func projects() throws -> ExtensionProjectSnapshotPage {
        projectCallCount += 1
        guard !projectPages.isEmpty else {
            throw ExtensionHostClientError.invalidResponse
        }
        if projectPages.count == 1 { return projectPages[0] }
        return projectPages.removeFirst()
    }

    func events(after cursor: Int64, limit: Int) throws -> ExtensionHostEventPage {
        _ = limit
        eventCursors.append(cursor)
        guard !eventSteps.isEmpty else {
            return .init(events: [], nextCursor: cursor, hasMore: false)
        }
        switch eventSteps.removeFirst() {
        case .page(let page): return page
        case .expired:
            throw ExtensionHostClientError.rejected(status: 410, message: "expired")
        }
    }

    func fetch(
        _ request: ExtensionBrokeredFetchRequest
    ) async throws -> ExtensionBrokeredFetchResponse {
        fetchCount += 1
        currentFetches += 1
        maximumConcurrentFetches = max(maximumConcurrentFetches, currentFetches)
        if fetchDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        currentFetches -= 1
        let page = request.url.hasSuffix("page=2") ? 2 : 1
        guard let response = responsesByPage[page] else {
            throw ExtensionBrokeredFetchFailure(message: "missing fixture", credential: "anonymous")
        }
        return response
    }

    func publishFacts(
        _ facts: [ExtensionFact],
        replacing subjects: [ExtensionFactSubject]
    ) throws {
        publications.append(.init(facts: facts, replacingSubjects: subjects))
        if publicationFailures > 0 {
            publicationFailures -= 1
            throw ExtensionHostClientError.invalidResponse
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            projectCallCount: projectCallCount,
            eventCursors: eventCursors,
            fetchCount: fetchCount,
            maximumConcurrentFetches: maximumConcurrentFetches,
            publications: publications
        )
    }
}

private final class LockedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ManualClock: GitLabStateClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func sleep(seconds: UInt64) async throws {
        _ = seconds
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
