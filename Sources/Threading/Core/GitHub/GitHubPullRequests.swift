import Foundation

// MARK: - GitHub provider

/// Native GitHub pull-request discovery and creation.
///
/// Reads may walk the credential chain because they are idempotent. A write never retries after
/// a transport failure: GitHub may have received it, and duplicating a pull request is worse than
/// asking the user to inspect the repository. Credential refusals may still walk to the next
/// tier, exactly like issue submission.
struct GitHubPullRequestClient: ChangeRequestProviderClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let tierWalkStatuses: Set<Int> = [401, 403, 404]

    private let resolver: GitHubCredentialResolver?
    private let transport: Transport

    let provider = SourceControlProvider.github

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

    func automaticCreationReadiness(
        repository: ChangeRequestRepository
    ) async -> ChangeRequestProviderReadiness {
        let credentials = await resolver?.orderedCredentials() ?? [.anonymous]
        guard let credential = credentials.first(where: { $0.token != nil }) else {
            return .unavailable(message: L10n.string(
                "Automatic review publishing requires a GitHub sign-in in Threading, gh, or Git."
            ))
        }
        return .ready(credential: ChangeRequestCredentialSource(credential.tier))
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
                "GitHub repository response could not be decoded: \(error.localizedDescription, privacy: .private(mask: .hash))"
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
                "GitHub pull-request response could not be decoded: \(error.localizedDescription, privacy: .private(mask: .hash))"
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
            changeRequest: summary,
            checks: resolvedChecks,
            cloneURLs: ChangeRequestCloneURLs(
                https: metadata.cloneURL.flatMap(URL.init(string:)),
                ssh: metadata.sshURL
            )
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
                "GitHub pull-request lifecycle response could not be decoded: \(error.localizedDescription, privacy: .private(mask: .hash))"
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
            title: String(proposal.title.prefix(ChangeRequestDefaults.titleLimit)),
            body: String(proposal.body.prefix(ChangeRequestDefaults.bodyLimit)),
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
                return .created(summary, credential: ChangeRequestCredentialSource(credential.tier))

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
        async let checkRuns = checkRunSummary(
            repository: repository,
            revision: revision,
            credentials: credentials
        )
        async let commitStatuses = commitStatusSummary(
            repository: repository,
            revision: revision,
            credentials: credentials
        )
        return await checkRuns.merging(commitStatuses)
    }

    private func checkRunSummary(
        repository: ChangeRequestRepository,
        revision: String,
        credentials: [GitHubCredential]
    ) async -> ChangeRequestChecks {
        var outcomes: [ChangeRequestCheckOutcome: Int] = [:]
        var loaded = 0

        for page in 1...ChangeRequestCheckDefaults.maximumPages {
            let result = await read(
                endpoint: endpoint(
                    repository,
                    suffix: "/commits/\(revision)/check-runs",
                    query: [
                        URLQueryItem(name: "filter", value: "latest"),
                        URLQueryItem(
                            name: "per_page",
                            value: String(ChangeRequestCheckDefaults.pageSize)
                        ),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                ),
                credentials: credentials
            )
            guard case .success(let data) = result,
                  let response = try? JSONDecoder().decode(CheckRunsResponse.self, from: data)
            else {
                return loaded == 0
                    ? .unavailable
                    : ChangeRequestChecks(outcomes: outcomes, coverage: .partial)
            }

            for run in response.checkRuns {
                outcomes[checkRunOutcome(run), default: 0] += 1
            }
            loaded += response.checkRuns.count
            if loaded >= response.totalCount
                || response.checkRuns.count < ChangeRequestCheckDefaults.pageSize {
                return ChangeRequestChecks(outcomes: outcomes)
            }
            if page == ChangeRequestCheckDefaults.maximumPages {
                return ChangeRequestChecks(
                    outcomes: outcomes,
                    coverage: .capped(additionalCount: max(0, response.totalCount - loaded))
                )
            }
        }
        return ChangeRequestChecks(outcomes: outcomes)
    }

    private func commitStatusSummary(
        repository: ChangeRequestRepository,
        revision: String,
        credentials: [GitHubCredential]
    ) async -> ChangeRequestChecks {
        var outcomes: [ChangeRequestCheckOutcome: Int] = [:]
        var loaded = 0

        for page in 1...ChangeRequestCheckDefaults.maximumPages {
            let result = await read(
                endpoint: endpoint(
                    repository,
                    suffix: "/commits/\(revision)/status",
                    query: [
                        URLQueryItem(
                            name: "per_page",
                            value: String(ChangeRequestCheckDefaults.pageSize)
                        ),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                ),
                credentials: credentials
            )
            guard case .success(let data) = result,
                  let response = try? JSONDecoder().decode(CombinedStatusResponse.self, from: data)
            else {
                return loaded == 0
                    ? .unavailable
                    : ChangeRequestChecks(outcomes: outcomes, coverage: .partial)
            }

            for status in response.statuses {
                outcomes[commitStatusOutcome(status.state), default: 0] += 1
            }
            loaded += response.statuses.count
            if loaded >= response.totalCount
                || response.statuses.count < ChangeRequestCheckDefaults.pageSize {
                return ChangeRequestChecks(outcomes: outcomes)
            }
            if page == ChangeRequestCheckDefaults.maximumPages {
                return ChangeRequestChecks(
                    outcomes: outcomes,
                    coverage: .capped(additionalCount: max(0, response.totalCount - loaded))
                )
            }
        }
        return ChangeRequestChecks(outcomes: outcomes)
    }

    private func checkRunOutcome(
        _ run: CheckRunsResponse.CheckRun
    ) -> ChangeRequestCheckOutcome {
        let status = run.status.lowercased()
        guard status == "completed" else {
            switch status {
            case "requested": return .requested
            case "queued": return .queued
            case "waiting": return .waiting
            case "pending": return .pending
            case "in_progress": return .inProgress
            default:
                return .unknownActive(ChangeRequestCheckOutcome.boundedProviderValue(status))
            }
        }

        let conclusion = run.conclusion?.lowercased() ?? "no conclusion"
        switch conclusion {
        case "success": return .passed
        case "neutral": return .neutral
        case "skipped": return .skipped
        case "failure": return .failed
        case "cancelled": return .cancelled
        case "timed_out": return .timedOut
        case "action_required": return .actionRequired
        case "startup_failure": return .startupFailure
        case "stale": return .stale
        default:
            return .unknownTerminal(ChangeRequestCheckOutcome.boundedProviderValue(conclusion))
        }
    }

    private func commitStatusOutcome(_ value: String) -> ChangeRequestCheckOutcome {
        switch value.lowercased() {
        case "success": return .passed
        case "pending": return .pending
        case "failure": return .failed
        case "error": return .error
        default:
            return .unknownTerminal(ChangeRequestCheckOutcome.boundedProviderValue(value))
        }
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
        components.path = "/repos/\(repository.namespace)/\(repository.name)\(suffix)"
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
        let cloneURL: String?
        let sshURL: String?
        enum CodingKeys: String, CodingKey {
            case defaultBranch = "default_branch"
            case cloneURL = "clone_url"
            case sshURL = "ssh_url"
        }
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
        let totalCount: Int
        let checkRuns: [CheckRun]
        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case checkRuns = "check_runs"
        }
    }

    private struct CombinedStatusResponse: Decodable {
        struct Status: Decodable { let state: String }
        let totalCount: Int
        let statuses: [Status]
        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case statuses
        }
    }

    private struct ReviewResponse: Decodable {
        struct User: Decodable { let login: String }
        let state: String
        let user: User
    }

    private struct ErrorResponse: Decodable { let message: String }
}

enum GitHubPullRequestDefaults {
    static let webBodyLimit = 6_000
}
