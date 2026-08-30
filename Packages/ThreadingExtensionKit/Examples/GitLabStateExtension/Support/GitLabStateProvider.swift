import Foundation
import ThreadingExtensionKit

public protocol GitLabStateHost: Sendable {
    func projects() async throws -> ExtensionProjectSnapshotPage
    func events(after cursor: Int64, limit: Int) async throws -> ExtensionHostEventPage
    func fetch(_ request: ExtensionBrokeredFetchRequest) async throws
        -> ExtensionBrokeredFetchResponse
    func publishFacts(
        _ facts: [ExtensionFact],
        replacing subjects: [ExtensionFactSubject]
    ) async throws
}

public struct GitLabExtensionHostAdapter: GitLabStateHost {
    private let client: ExtensionHostClient

    public init(client: ExtensionHostClient) {
        self.client = client
    }

    public func projects() async throws -> ExtensionProjectSnapshotPage {
        try await client.projects()
    }

    public func events(
        after cursor: Int64,
        limit: Int
    ) async throws -> ExtensionHostEventPage {
        try await client.events(after: cursor, limit: limit)
    }

    public func fetch(
        _ request: ExtensionBrokeredFetchRequest
    ) async throws -> ExtensionBrokeredFetchResponse {
        try await client.brokeredFetch(request)
    }

    public func publishFacts(
        _ facts: [ExtensionFact],
        replacing subjects: [ExtensionFactSubject]
    ) async throws {
        try await client.publishFacts(facts, replacing: subjects)
    }
}

public protocol GitLabStateClock: Sendable {
    func now() -> Date
    func sleep(seconds: UInt64) async throws
}

public struct GitLabSystemClock: GitLabStateClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
}

public enum GitLabRefreshFailure: Equatable, Sendable {
    case transport
    case httpStatus(Int)
    case malformed
    case unknownState(String)
    case paginationTruncated
    case factLimitExceeded
}

public struct GitLabPreparedPublication: Equatable, Sendable {
    public let facts: [ExtensionFact]
    public let replacingSubjects: [ExtensionFactSubject]
    public let currentSubjects: Set<ExtensionFactSubject>

    public init(
        facts: [ExtensionFact],
        replacingSubjects: [ExtensionFactSubject],
        currentSubjects: Set<ExtensionFactSubject>
    ) {
        self.facts = facts
        self.replacingSubjects = replacingSubjects
        self.currentSubjects = currentSubjects
    }
}

public enum GitLabRepositoryRefreshOutcome: Equatable, Sendable {
    case replace(GitLabPreparedPublication)
    case noChange
    case preserve(GitLabRefreshFailure)
}

public enum GitLabRepositoryRefresher {
    public typealias Fetch = @Sendable (ExtensionBrokeredFetchRequest) async throws
        -> ExtensionBrokeredFetchResponse
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    public static func refresh(
        repository: ExtensionRepositoryKey,
        previousSubjects: Set<ExtensionFactSubject>,
        fetch: @escaping Fetch,
        sleep: @escaping Sleep,
        now: @Sendable () -> Date
    ) async -> GitLabRepositoryRefreshOutcome {
        var records: [GitLabMergeRequest] = []
        for page in 1...GitLabStateLimits.maximumPagesPerRepository {
            let request = ExtensionBrokeredFetchRequest(
                method: "GET",
                url: GitLabProjectPathEncoder.mergeRequestsURL(
                    repositoryPath: repository.path,
                    page: page
                ),
                headers: ["Accept": "application/json"]
            )
            let response: ExtensionBrokeredFetchResponse
            switch await fetchWithRetry(request, fetch: fetch, sleep: sleep) {
            case .success(let value):
                response = value
            case .failure(let failure):
                return .preserve(failure)
            }

            guard response.status == 200 else {
                return .preserve(.httpStatus(response.status))
            }
            guard let body = response.body else {
                return .preserve(.malformed)
            }

            let pageRecords: [GitLabMergeRequest]
            do {
                pageRecords = try GitLabMergeRequestReducer.decodePage(body)
            } catch {
                return .preserve(.malformed)
            }
            records.append(contentsOf: pageRecords)

            switch pagination(
                response.headers,
                currentPage: page,
                recordCount: pageRecords.count
            ) {
            case .complete:
                return publication(
                    repository: repository,
                    records: records,
                    previousSubjects: previousSubjects,
                    observedAt: now()
                )
            case .next:
                if page == GitLabStateLimits.maximumPagesPerRepository {
                    return .preserve(.paginationTruncated)
                }
            case .invalid:
                return .preserve(.malformed)
            }
        }
        return .preserve(.paginationTruncated)
    }

    private enum FetchAttempt {
        case success(ExtensionBrokeredFetchResponse)
        case failure(GitLabRefreshFailure)
    }

    private static func fetchWithRetry(
        _ request: ExtensionBrokeredFetchRequest,
        fetch: @escaping Fetch,
        sleep: @escaping Sleep
    ) async -> FetchAttempt {
        for attempt in 0..<GitLabStateLimits.maximumAttempts {
            do {
                let response = try await fetch(request)
                if isRetryable(status: response.status),
                   attempt + 1 < GitLabStateLimits.maximumAttempts {
                    do {
                        try await sleep(secondsBeforeRetry(attempt: attempt))
                    } catch {
                        return .failure(.transport)
                    }
                    continue
                }
                return .success(response)
            } catch is ExtensionBrokeredFetchFailure {
                if attempt + 1 < GitLabStateLimits.maximumAttempts {
                    do {
                        try await sleep(secondsBeforeRetry(attempt: attempt))
                    } catch {
                        return .failure(.transport)
                    }
                    continue
                }
                return .failure(.transport)
            } catch {
                return .failure(.transport)
            }
        }
        return .failure(.transport)
    }

    private static func secondsBeforeRetry(attempt: Int) -> UInt64 {
        GitLabStateLimits.retryDelays[min(attempt, GitLabStateLimits.retryDelays.count - 1)]
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private enum Pagination {
        case complete
        case next
        case invalid
    }

    private static func pagination(
        _ headers: [String: String],
        currentPage: Int,
        recordCount: Int
    ) -> Pagination {
        let nextValue = headers.first {
            $0.key.caseInsensitiveCompare("x-next-page") == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let nextValue {
            if nextValue.isEmpty { return .complete }
            guard let nextPage = Int(nextValue), nextPage == currentPage + 1 else {
                return .invalid
            }
            return .next
        }
        return recordCount < GitLabStateLimits.maximumMergeRequestsPerPage
            ? .complete
            : .next
    }

    private static func publication(
        repository: ExtensionRepositoryKey,
        records: [GitLabMergeRequest],
        previousSubjects: Set<ExtensionFactSubject>,
        observedAt: Date
    ) -> GitLabRepositoryRefreshOutcome {
        let reduced: [GitLabBranchMergeRequest]
        do {
            reduced = try GitLabMergeRequestReducer.reduce(records)
        } catch GitLabMergeRequestReductionError.unknownState(let state) {
            return .preserve(.unknownState(state))
        } catch GitLabMergeRequestReductionError.factLimitExceeded {
            return .preserve(.factLimitExceeded)
        } catch {
            return .preserve(.malformed)
        }

        let facts = reduced.map { request -> ExtensionFact in
            let subject = ExtensionFactSubject.repositoryBranch(
                repository: repository,
                branch: request.branch
            )
            return ExtensionFact(
                key: GitLabStateExtensionContract.factKey,
                subject: subject,
                value: .string(request.state.rawValue),
                label: request.state.label,
                status: request.state.status,
                observedAt: observedAt
            )
        }
        let currentSubjects = Set(facts.map(\.subject))
        let replacementSet = previousSubjects.union(currentSubjects)
        guard !replacementSet.isEmpty else { return .noChange }
        let replacingSubjects = replacementSet.sorted(by: subjectOrder)
        return .replace(.init(
            facts: facts,
            replacingSubjects: replacingSubjects,
            currentSubjects: currentSubjects
        ))
    }

    private static func subjectOrder(
        _ lhs: ExtensionFactSubject,
        _ rhs: ExtensionFactSubject
    ) -> Bool {
        subjectBranch(lhs) < subjectBranch(rhs)
    }

    private static func subjectBranch(_ subject: ExtensionFactSubject) -> String {
        if case .repositoryBranch(_, let branch) = subject { return branch }
        return ""
    }
}

public actor GitLabStateProvider {
    private let host: any GitLabStateHost
    private let clock: any GitLabStateClock
    private let diagnostic: @Sendable (String) -> Void
    private var admittedRepositories: [ExtensionRepositoryKey] = []
    private var subjectsByRepository: [ExtensionRepositoryKey: Set<ExtensionFactSubject>] = [:]
    private var cursor: Int64?
    private var lastFullRefreshAt: Date?
    private var needsSnapshotRetry = false

    public init(
        host: any GitLabStateHost,
        clock: any GitLabStateClock = GitLabSystemClock(),
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.host = host
        self.clock = clock
        self.diagnostic = diagnostic
    }

    public var eventCursor: Int64? { cursor }
    public var admitted: [ExtensionRepositoryKey] { admittedRepositories }

    public func start() async {
        await synchronizeProjects()
    }

    public func synchronizeProjects() async {
        let page: ExtensionProjectSnapshotPage
        do {
            page = try await host.projects()
        } catch {
            needsSnapshotRetry = true
            diagnostic("GitLab State could not read projects: \(error.localizedDescription)")
            return
        }

        cursor = page.cursor
        let admission = GitLabRepositoryAdmissionPolicy.admit(projects: page.projects)
        if admission.omittedCount > 0 {
            diagnostic(
                "GitLab State omitted \(admission.omittedCount) repositories beyond its "
                    + "\(GitLabStateLimits.maximumRepositories)-repository generation cap."
            )
        }

        let previouslyAdmitted = Set(admittedRepositories)
        let target = Set(admission.admitted)
        let stale = subjectsByRepository.keys
            .filter { !target.contains($0) }
            .sorted(by: GitLabRepositoryAdmissionPolicy.repositoryOrder)
        for repository in stale {
            guard let subjects = subjectsByRepository[repository], !subjects.isEmpty else {
                subjectsByRepository.removeValue(forKey: repository)
                continue
            }
            do {
                try await host.publishFacts(
                    [],
                    replacing: subjects.sorted(by: factSubjectOrder)
                )
                subjectsByRepository.removeValue(forKey: repository)
            } catch {
                needsSnapshotRetry = true
                diagnostic(
                    "GitLab State could not clear \(repository.host)/\(repository.path): "
                        + error.localizedDescription
                )
                return
            }
        }

        admittedRepositories = admission.admitted
        needsSnapshotRetry = false
        if lastFullRefreshAt == nil {
            await performFullRefresh()
        } else {
            let newlyAdmitted = admission.admitted.filter {
                !previouslyAdmitted.contains($0)
            }
            await refresh(repositories: newlyAdmitted)
        }
    }

    public func pollEventsOnce() async {
        guard var nextCursor = cursor else {
            await synchronizeProjects()
            return
        }

        var projectsChanged = false
        do {
            while true {
                let requestedCursor = nextCursor
                let page = try await host.events(after: nextCursor, limit: 100)
                guard page.nextCursor >= requestedCursor,
                      !page.hasMore || page.nextCursor > requestedCursor else {
                    diagnostic("GitLab State received a non-advancing host event page.")
                    return
                }
                nextCursor = page.nextCursor
                cursor = nextCursor
                projectsChanged = projectsChanged || page.events.contains {
                    $0.kind == .projectChanged || $0.kind == .projectRemoved
                }
                if !page.hasMore { break }
            }
        } catch ExtensionHostClientError.rejected(let status, _) where status == 410 {
            await synchronizeProjects()
            return
        } catch {
            diagnostic("GitLab State could not read host events: \(error.localizedDescription)")
            return
        }

        if projectsChanged || needsSnapshotRetry {
            await synchronizeProjects()
        }
    }

    public func refreshAdmittedRepositories() async {
        await refresh(repositories: admittedRepositories)
    }

    func refreshAllIfDue() async {
        guard let lastFullRefreshAt,
              clock.now().timeIntervalSince(lastFullRefreshAt)
                >= GitLabStateLimits.fullRefreshSeconds else {
            return
        }
        await performFullRefresh()
    }

    private func performFullRefresh() async {
        await refresh(repositories: admittedRepositories)
        lastFullRefreshAt = clock.now()
    }

    private func refresh(repositories: [ExtensionRepositoryKey]) async {
        let previous = subjectsByRepository
        let host = self.host
        let clock = self.clock
        var outcomes: [(ExtensionRepositoryKey, GitLabRepositoryRefreshOutcome)] = []
        outcomes.reserveCapacity(repositories.count)

        for start in stride(
            from: 0,
            to: repositories.count,
            by: GitLabStateLimits.maximumConcurrentRefreshes
        ) {
            let end = min(
                start + GitLabStateLimits.maximumConcurrentRefreshes,
                repositories.count
            )
            let batch = Array(repositories[start..<end])
            let batchOutcomes = await withTaskGroup(
                of: (ExtensionRepositoryKey, GitLabRepositoryRefreshOutcome).self,
                returning: [(ExtensionRepositoryKey, GitLabRepositoryRefreshOutcome)].self
            ) { group in
                for repository in batch {
                    let prior = previous[repository] ?? []
                    group.addTask {
                        let outcome = await GitLabRepositoryRefresher.refresh(
                            repository: repository,
                            previousSubjects: prior,
                            fetch: { try await host.fetch($0) },
                            sleep: { try await clock.sleep(seconds: $0) },
                            now: { clock.now() }
                        )
                        return (repository, outcome)
                    }
                }
                var result: [(ExtensionRepositoryKey, GitLabRepositoryRefreshOutcome)] = []
                for await outcome in group { result.append(outcome) }
                return result
            }
            outcomes.append(contentsOf: batchOutcomes)
        }

        outcomes.sort {
            GitLabRepositoryAdmissionPolicy.repositoryOrder($0.0, $1.0)
        }
        for (repository, outcome) in outcomes {
            switch outcome {
            case .replace(let publication):
                do {
                    try await host.publishFacts(
                        publication.facts,
                        replacing: publication.replacingSubjects
                    )
                    if publication.currentSubjects.isEmpty {
                        subjectsByRepository.removeValue(forKey: repository)
                    } else {
                        subjectsByRepository[repository] = publication.currentSubjects
                    }
                } catch {
                    let uncertainSubjects = (subjectsByRepository[repository] ?? [])
                        .union(publication.currentSubjects)
                    if !uncertainSubjects.isEmpty {
                        subjectsByRepository[repository] = uncertainSubjects
                    }
                    diagnostic(
                        "GitLab State could not publish \(repository.host)/\(repository.path): "
                            + error.localizedDescription
                    )
                }
            case .noChange:
                subjectsByRepository.removeValue(forKey: repository)
            case .preserve(let failure):
                diagnostic(
                    "GitLab State preserved \(repository.host)/\(repository.path) after "
                        + "\(description(of: failure))."
                )
            }
        }
    }

    public func run() async {
        await start()
        while !Task.isCancelled {
            await pollEventsOnce()
            await refreshAllIfDue()
            do {
                try await clock.sleep(seconds: GitLabStateLimits.eventPollSeconds)
            } catch {
                return
            }
        }
    }

    private func factSubjectOrder(
        _ lhs: ExtensionFactSubject,
        _ rhs: ExtensionFactSubject
    ) -> Bool {
        branch(of: lhs) < branch(of: rhs)
    }

    private func branch(of subject: ExtensionFactSubject) -> String {
        if case .repositoryBranch(_, let branch) = subject { return branch }
        return ""
    }

    private func description(of failure: GitLabRefreshFailure) -> String {
        switch failure {
        case .transport: "a transport failure"
        case .httpStatus(let status): "HTTP \(status)"
        case .malformed: "a malformed response"
        case .unknownState(let state): "unknown state \(state)"
        case .paginationTruncated: "pagination truncation"
        case .factLimitExceeded: "the per-repository fact cap"
        }
    }
}
