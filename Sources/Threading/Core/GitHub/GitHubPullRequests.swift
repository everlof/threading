import Foundation

// MARK: - Provider-neutral change-request model

struct ChangeRequestRepository: Equatable, Sendable {
    let provider: String
    let host: String
    let owner: String
    let name: String

    var slug: String { "\(owner)/\(name)" }

    /// The provider adapters Threading can publish through today. Callers use this entry point
    /// rather than reaching for the GitHub parser, so adding GitLab does not change their model
    /// or their capability check.
    static func supported(remote: String) -> ChangeRequestRepository? {
        github(remote: remote)
    }

    static func github(remote: String) -> ChangeRequestRepository? {
        guard let identity = GitRemoteIdentity(remote: remote),
              identity.host == GitHubDefaults.webHost else { return nil }
        let components = identity.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else { return nil }
        return ChangeRequestRepository(
            provider: "github",
            host: identity.host,
            owner: String(components[0]),
            name: String(components[1])
        )
    }
}

struct ChangeRequestProposal: Equatable, Sendable {
    var title: String
    var body: String
    var baseBranch: String
    var headBranch: String
    var isDraft: Bool
}

struct ChangeRequestChecks: Equatable, Sendable {
    enum State: String, Sendable {
        case unavailable
        case none
        case pending
        case passing
        case failing
    }

    var state: State
    var passed: Int
    var pending: Int
    var failed: Int

    static let unavailable = ChangeRequestChecks(
        state: .unavailable,
        passed: 0,
        pending: 0,
        failed: 0
    )
}

struct ChangeRequestReviews: Equatable, Sendable {
    var approvals: Int
    var changesRequested: Int
    var requested: Int

    static let empty = ChangeRequestReviews(approvals: 0, changesRequested: 0, requested: 0)
}

struct ChangeRequestSummary: Equatable, Sendable {
    let number: Int
    var title: String
    var body: String
    let url: URL
    var isDraft: Bool
    var isMerged: Bool
    var baseBranch: String
    var headBranch: String
    var headRevision: String
    var checks: ChangeRequestChecks
    var reviews: ChangeRequestReviews
}

struct ChangeRequestRepositoryStatus: Equatable, Sendable {
    let repository: ChangeRequestRepository
    let defaultBranch: String
    let branch: String
    let pullRequest: ChangeRequestSummary?
    let checks: ChangeRequestChecks
}

enum ChangeRequestReadOutcome: Equatable, Sendable {
    case loaded(ChangeRequestRepositoryStatus)
    case failed(message: String)
}

enum ChangeRequestLifecycleState: Equatable, Sendable {
    case open
    case closed(merged: Bool)
}

struct ChangeRequestLifecycle: Equatable, Sendable {
    let number: Int
    let state: ChangeRequestLifecycleState
    let headBranch: String
    let headRevision: String
}

enum ChangeRequestLifecycleOutcome: Equatable, Sendable {
    case loaded(ChangeRequestLifecycle)
    case failed(message: String)
}

enum ChangeRequestWriteOutcome: Equatable, Sendable {
    case created(ChangeRequestSummary, tier: GitHubCredential.Tier)
    case webForm(URL, message: String)
    case failed(message: String)
}

// MARK: - GitHub provider

/// Native GitHub pull-request discovery and creation.
///
/// Reads may walk the credential chain because they are idempotent. A write never retries after
/// a transport failure: GitHub may have received it, and duplicating a pull request is worse than
/// asking the user to inspect the repository. Credential refusals may still walk to the next
/// tier, exactly like issue submission.
struct GitHubPullRequestClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let tierWalkStatuses: Set<Int> = [401, 403, 404]

    private let resolver: GitHubCredentialResolver?
    private let transport: Transport

    init(
        resolver: GitHubCredentialResolver?,
        transport: @escaping Transport = GitHubAppConnection.liveTransport
    ) {
        self.resolver = resolver
        self.transport = transport
    }

    @MainActor
    static func live() -> GitHubPullRequestClient {
        GitHubPullRequestClient(resolver: .live())
    }

    /// Automatic workflows cannot spend the browser fallback. Check before pushing their
    /// generated branch so a signed-out Mac does not gain remote state it cannot turn into the
    /// review object the user opted into.
    func supportsAutomaticCreation() async -> Bool {
        let credentials = await resolver?.orderedCredentials() ?? [.anonymous]
        return credentials.contains { $0.token != nil }
    }

    func discover(
        repository: ChangeRequestRepository,
        branch: String,
        headRevision: String
    ) async -> ChangeRequestReadOutcome {
        let credentials = await resolver?.orderedCredentials() ?? [.anonymous]

        let repositoryResult = await read(
            endpoint: endpoint(repository, suffix: ""),
            credentials: credentials
        )
        guard case .success(let repositoryData) = repositoryResult else {
            return .failed(message: readFailureMessage(repositoryResult))
        }
        let metadata: RepositoryResponse
        do {
            metadata = try JSONDecoder().decode(RepositoryResponse.self, from: repositoryData)
        } catch {
            ThreadingLogger.github.error(
                "GitHub repository response could not be decoded: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(message: L10n.string("GitHub returned a response Threading could not read."))
        }

        let pullsResult = await read(
            endpoint: endpoint(
                repository,
                suffix: "/pulls",
                query: [
                    URLQueryItem(name: "state", value: "open"),
                    URLQueryItem(name: "per_page", value: "100")
                ]
            ),
            credentials: credentials
        )
        guard case .success(let pullsData) = pullsResult else {
            return .failed(message: readFailureMessage(pullsResult))
        }
        let pulls: [PullResponse]
        do {
            pulls = try JSONDecoder().decode([PullResponse].self, from: pullsData)
        } catch {
            ThreadingLogger.github.error(
                "GitHub pull-request response could not be decoded: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(message: L10n.string("GitHub returned a response Threading could not read."))
        }

        let pull = pulls.first { $0.head.ref == branch }
        let checkRevision = pull?.head.sha ?? headRevision
        async let checks = checkSummary(
            repository: repository,
            revision: checkRevision,
            credentials: credentials
        )

        let summary: ChangeRequestSummary?
        if let pull {
            async let reviews = reviewSummary(
                repository: repository,
                number: pull.number,
                requested: pull.requestedReviewers?.count ?? 0,
                credentials: credentials
            )
            summary = pull.summary(checks: await checks, reviews: await reviews)
        } else {
            summary = nil
        }

        let loadedChecks = await checks
        let resolvedChecks = summary?.checks ?? loadedChecks
        return .loaded(ChangeRequestRepositoryStatus(
            repository: repository,
            defaultBranch: metadata.defaultBranch,
            branch: branch,
            pullRequest: summary,
            checks: resolvedChecks
        ))
    }

    /// Reads one review by its durable number, including closed reviews that ordinary branch
    /// discovery intentionally omits. Managed-workspace cleanup uses this only as permission to
    /// inspect its generated ref; a failed or unreadable response can never authorize deletion.
    func lifecycle(
        repository: ChangeRequestRepository,
        number: Int
    ) async -> ChangeRequestLifecycleOutcome {
        let credentials = await resolver?.orderedCredentials() ?? [.anonymous]
        let result = await read(
            endpoint: endpoint(repository, suffix: "/pulls/\(number)"),
            credentials: credentials,
            // GitHub serves this endpoint with `Cache-Control: private, max-age=60`. A cached
            // closed response could authorize deletion after a review was reopened, so this
            // safety decision must always cross the network.
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        guard case .success(let data) = result else {
            return .failed(message: readFailureMessage(result))
        }
        let pull: PullResponse
        do {
            pull = try JSONDecoder().decode(PullResponse.self, from: data)
        } catch {
            ThreadingLogger.github.error(
                "GitHub pull-request lifecycle response could not be decoded: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(message: L10n.string(
                "GitHub returned a response Threading could not read."
            ))
        }

        let state: ChangeRequestLifecycleState
        switch pull.state {
        case "open": state = .open
        case "closed": state = .closed(merged: pull.mergedAt != nil)
        default:
            return .failed(message: L10n.string(
                "GitHub returned a pull-request state Threading does not understand."
            ))
        }
        return .loaded(ChangeRequestLifecycle(
            number: pull.number,
            state: state,
            headBranch: pull.head.ref,
            headRevision: pull.head.sha
        ))
    }

    func create(
        repository: ChangeRequestRepository,
        proposal: ChangeRequestProposal
    ) async -> ChangeRequestWriteOutcome {
        guard let endpoint = endpoint(repository, suffix: "/pulls") else {
            return .failed(message: L10n.string("Threading could not build the GitHub address."))
        }

        let resolved = await resolver?.orderedCredentials() ?? [.anonymous]
        let credentials = resolved.filter { $0.token != nil }
        guard !credentials.isEmpty else {
            return webForm(
                repository: repository,
                proposal: proposal,
                message: L10n.string("Threading has no GitHub sign-in, so this opens the pull request form in your browser.")
            )
        }

        guard let body = try? JSONEncoder().encode(CreateRequest(
            title: String(proposal.title.prefix(GitHubPullRequestDefaults.titleLimit)),
            body: String(proposal.body.prefix(GitHubPullRequestDefaults.bodyLimit)),
            head: proposal.headBranch,
            base: proposal.baseBranch,
            draft: proposal.isDraft
        )) else {
            return .failed(message: L10n.string("Threading could not prepare the pull request."))
        }

        for credential in credentials {
            switch await write(endpoint: endpoint, body: body, credential: credential) {
            case .created(let data):
                guard let response = try? JSONDecoder().decode(PullResponse.self, from: data),
                      let summary = response.summary(
                        checks: .unavailable,
                        reviews: .empty
                      ) else {
                    // A 2xx means the write happened. Do not invite a duplicate because the
                    // response was newer than the decoder.
                    return .webForm(
                        repositoryWebURL(repository),
                        message: L10n.string("GitHub created the pull request, but Threading could not read its response.")
                    )
                }
                return .created(summary, tier: credential.tier)

            case .refused(let status, let data):
                if status == 401 { await resolver?.invalidate(credential.tier) }
                guard Self.tierWalkStatuses.contains(status) else {
                    return .failed(message: refusalMessage(status: status, body: data))
                }

            case .transportFailed(let message):
                return .failed(message: message)
            }
        }

        return webForm(
            repository: repository,
            proposal: proposal,
            message: L10n.string("GitHub would not accept this Mac's sign-in, so this opens the pull request form in your browser.")
        )
    }

    // MARK: Reads

    private enum ReadResult {
        case success(Data)
        case failure(String)
    }

    private func read(
        endpoint: URL?,
        credentials: [GitHubCredential],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async -> ReadResult {
        guard let endpoint else {
            return .failure(L10n.string("Threading could not build the GitHub address."))
        }

        for credential in credentials {
            var request = request(endpoint, method: "GET", credential: credential)
            request.cachePolicy = cachePolicy
            request.httpBody = nil
            do {
                let (data, response) = try await transport(request)
                if (200..<300).contains(response.statusCode) { return .success(data) }
                if response.statusCode == 401 { await resolver?.invalidate(credential.tier) }
                guard Self.tierWalkStatuses.contains(response.statusCode) else {
                    return .failure(refusalMessage(status: response.statusCode, body: data))
                }
            } catch {
                return .failure(L10n.format(
                    "Threading could not reach GitHub: %@",
                    error.localizedDescription
                ))
            }
        }
        return .failure(L10n.string("GitHub could not find this repository for any available sign-in."))
    }

    private func checkSummary(
        repository: ChangeRequestRepository,
        revision: String,
        credentials: [GitHubCredential]
    ) async -> ChangeRequestChecks {
        let result = await read(
            endpoint: endpoint(repository, suffix: "/commits/\(revision)/check-runs"),
            credentials: credentials
        )
        guard case .success(let data) = result,
              let response = try? JSONDecoder().decode(CheckRunsResponse.self, from: data)
        else { return .unavailable }

        var passed = 0
        var pending = 0
        var failed = 0
        for run in response.checkRuns {
            guard run.status == "completed" else {
                pending += 1
                continue
            }
            switch run.conclusion {
            case "success", "neutral", "skipped": passed += 1
            case "failure", "timed_out", "cancelled", "action_required", "startup_failure":
                failed += 1
            default: pending += 1
            }
        }
        let state: ChangeRequestChecks.State
        if failed > 0 { state = .failing }
        else if pending > 0 { state = .pending }
        else if passed > 0 { state = .passing }
        else { state = .none }
        return ChangeRequestChecks(state: state, passed: passed, pending: pending, failed: failed)
    }

    private func reviewSummary(
        repository: ChangeRequestRepository,
        number: Int,
        requested: Int,
        credentials: [GitHubCredential]
    ) async -> ChangeRequestReviews {
        let result = await read(
            endpoint: endpoint(repository, suffix: "/pulls/\(number)/reviews"),
            credentials: credentials
        )
        guard case .success(let data) = result,
              let reviews = try? JSONDecoder().decode([ReviewResponse].self, from: data)
        else { return ChangeRequestReviews(approvals: 0, changesRequested: 0, requested: requested) }

        var latest: [String: String] = [:]
        for review in reviews where review.state != "COMMENTED" {
            latest[review.user.login] = review.state
        }
        return ChangeRequestReviews(
            approvals: latest.values.filter { $0 == "APPROVED" }.count,
            changesRequested: latest.values.filter { $0 == "CHANGES_REQUESTED" }.count,
            requested: requested
        )
    }

    // MARK: Writes

    private enum WriteAttempt {
        case created(Data)
        case refused(Int, Data)
        case transportFailed(String)
    }

    private func write(
        endpoint: URL,
        body: Data,
        credential: GitHubCredential
    ) async -> WriteAttempt {
        var request = request(endpoint, method: "POST", credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await transport(request)
            guard (200..<300).contains(response.statusCode) else {
                return .refused(response.statusCode, data)
            }
            return .created(data)
        } catch {
            return .transportFailed(L10n.format(
                "Threading could not reach GitHub: %@",
                error.localizedDescription
            ))
        }
    }

    private func request(
        _ url: URL,
        method: String,
        credential: GitHubCredential
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: GitHubDefaults.requestTimeout)
        request.httpMethod = method
        request.setValue(GitHubDefaults.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GitHubDefaults.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = credential.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: URLs and wire format

    private func endpoint(
        _ repository: ChangeRequestRepository,
        suffix: String,
        query: [URLQueryItem] = []
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = GitHubDefaults.apiHost
        components.path = "/repos/\(repository.owner)/\(repository.name)\(suffix)"
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private func repositoryWebURL(_ repository: ChangeRequestRepository) -> URL {
        URL(string: "https://\(GitHubDefaults.webHost)/\(repository.slug)/pulls")!
    }

    private func webForm(
        repository: ChangeRequestRepository,
        proposal: ChangeRequestProposal,
        message: String
    ) -> ChangeRequestWriteOutcome {
        var components = URLComponents()
        components.scheme = "https"
        components.host = GitHubDefaults.webHost
        components.path = "/\(repository.slug)/compare/\(proposal.baseBranch)...\(proposal.headBranch)"
        components.queryItems = [
            URLQueryItem(name: "expand", value: "1"),
            URLQueryItem(name: "title", value: proposal.title),
            URLQueryItem(name: "body", value: String(proposal.body.prefix(GitHubPullRequestDefaults.webBodyLimit)))
        ]
        guard let url = components.url else {
            return .failed(message: L10n.string("Threading could not build the GitHub address."))
        }
        return .webForm(url, message: message)
    }

    private func readFailureMessage(_ result: ReadResult) -> String {
        if case .failure(let message) = result { return message }
        return L10n.string("GitHub returned a response Threading could not read.")
    }

    private func refusalMessage(status: Int, body: Data) -> String {
        let response = try? JSONDecoder().decode(ErrorResponse.self, from: body)
        guard let detail = response?.message, !detail.isEmpty else {
            return L10n.format("GitHub refused the pull request (%lld).", Int64(status))
        }
        return L10n.format(
            "GitHub refused the pull request (%lld): %@",
            Int64(status),
            detail
        )
    }

    private struct RepositoryResponse: Decodable {
        let defaultBranch: String
        enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
    }

    private struct CreateRequest: Encodable {
        let title: String
        let body: String
        let head: String
        let base: String
        let draft: Bool
    }

    private struct PullResponse: Decodable {
        struct Branch: Decodable { let ref: String; let sha: String }
        struct User: Decodable { let login: String }

        let number: Int
        let title: String
        let body: String?
        let htmlURL: String
        let state: String?
        let draft: Bool?
        let mergedAt: String?
        let base: Branch
        let head: Branch
        let requestedReviewers: [User]?

        enum CodingKeys: String, CodingKey {
            case number, title, body, state, draft, base, head
            case htmlURL = "html_url"
            case mergedAt = "merged_at"
            case requestedReviewers = "requested_reviewers"
        }

        func summary(
            checks: ChangeRequestChecks,
            reviews: ChangeRequestReviews
        ) -> ChangeRequestSummary? {
            guard let url = URL(string: htmlURL), url.scheme == "https", url.host != nil else {
                return nil
            }
            return ChangeRequestSummary(
                number: number,
                title: title,
                body: body ?? "",
                url: url,
                isDraft: draft ?? false,
                isMerged: mergedAt != nil,
                baseBranch: base.ref,
                headBranch: head.ref,
                headRevision: head.sha,
                checks: checks,
                reviews: reviews
            )
        }
    }

    private struct CheckRunsResponse: Decodable {
        struct CheckRun: Decodable {
            let status: String
            let conclusion: String?
        }
        let checkRuns: [CheckRun]
        enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
    }

    private struct ReviewResponse: Decodable {
        struct User: Decodable { let login: String }
        let state: String
        let user: User
    }

    private struct ErrorResponse: Decodable { let message: String }
}

enum GitHubPullRequestDefaults {
    static let titleLimit = 256
    static let bodyLimit = 60_000
    static let webBodyLimit = 6_000
}
