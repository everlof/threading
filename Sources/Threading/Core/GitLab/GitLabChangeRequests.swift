import Foundation
import Darwin

enum GitLabDefaults {
    static let webHost = "gitlab.com"
    static let timeout: TimeInterval = 45
    static let maximumOutputBytes = 2 * 1_024 * 1_024
    static let maximumDiagnosticBytes = 4 * 1_024
}

struct GitLabCLIInvocation: Equatable, Sendable {
    let arguments: [String]
    var input: Data? = nil
}

struct GitLabCLIResult: Equatable, Sendable {
    let status: Int32
    let output: Data
    let diagnostic: String

    var succeeded: Bool { status == 0 }
}

/// GitLab's forge adapter. It delegates authentication and host policy to `glab`, so Threading
/// never reads, stores, or exports a GitLab token. Only GitLab.com repositories reach this client;
/// remote detection makes self-hosted support an explicit future capability rather than a guess.
struct GitLabChangeRequestClient: ChangeRequestProviderClient {
    typealias Runner = @Sendable (GitLabCLIInvocation) async -> GitLabCLIResult

    let provider = SourceControlProvider.gitlab
    private let runner: Runner

    init(runner: @escaping Runner) {
        self.runner = runner
    }

    static func live() -> GitLabChangeRequestClient {
        GitLabChangeRequestClient { invocation in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: GitLabCLIProcess.run(invocation))
                }
            }
        }
    }

    func automaticCreationReadiness(
        repository: ChangeRequestRepository
    ) async -> ChangeRequestProviderReadiness {
        guard repository.provider == .gitlab, repository.host == GitLabDefaults.webHost else {
            return .unavailable(message: L10n.string(
                "Automatic review publishing supports GitLab.com repositories, not this GitLab host."
            ))
        }
        let result = await runner(GitLabCLIInvocation(arguments: [
            "auth", "status", "--hostname", repository.host
        ]))
        guard result.succeeded else {
            return .unavailable(message: L10n.string(
                "GitLab publishing requires glab to be installed and signed in to GitLab.com."
            ))
        }
        return .ready(credential: .glabCLI)
    }

    func discover(
        repository: ChangeRequestRepository,
        branch: String,
        headRevision: String
    ) async -> ChangeRequestReadOutcome {
        guard let projectPath = projectPath(repository) else {
            return .failed(message: unsupportedHostMessage)
        }

        async let metadataResult = api(
            repository: repository,
            method: "GET",
            endpoint: "projects/\(projectPath)"
        )
        async let requestsResult = api(
            repository: repository,
            method: "GET",
            endpoint: "projects/\(projectPath)/merge_requests",
            fields: ["state=opened", "source_branch=\(branch)", "per_page=100"]
        )

        let metadataResponse = await metadataResult
        guard metadataResponse.succeeded else {
            return .failed(message: apiFailure(metadataResponse))
        }
        let requestsResponse = await requestsResult
        guard requestsResponse.succeeded else {
            return .failed(message: apiFailure(requestsResponse))
        }

        let metadata: ProjectResponse
        let requests: [MergeRequestResponse]
        do {
            metadata = try JSONDecoder().decode(ProjectResponse.self, from: metadataResponse.output)
            requests = try JSONDecoder().decode([MergeRequestResponse].self, from: requestsResponse.output)
        } catch {
            return .failed(message: unreadableResponseMessage)
        }
        guard !metadata.defaultBranch.isEmpty else {
            return .failed(message: unreadableResponseMessage)
        }

        let request = requests.first { $0.sourceBranch == branch }
        let revision = request?.headRevision ?? headRevision
        async let checks = checkSummary(
            repository: repository,
            projectPath: projectPath,
            revision: revision
        )

        let summary: ChangeRequestSummary?
        if let request {
            async let reviews = reviewSummary(
                repository: repository,
                projectPath: projectPath,
                request: request
            )
            guard let loadedSummary = request.summary(
                host: repository.host,
                checks: await checks,
                reviews: await reviews
            ) else {
                return .failed(message: unreadableResponseMessage)
            }
            summary = loadedSummary
        } else {
            summary = nil
        }

        let loadedChecks = await checks
        return .loaded(ChangeRequestRepositoryStatus(
            repository: repository,
            defaultBranch: metadata.defaultBranch,
            branch: branch,
            changeRequest: summary,
            checks: summary?.checks ?? loadedChecks,
            cloneURLs: ChangeRequestCloneURLs(
                https: validatedHTTPSURL(metadata.httpURLToRepo, host: repository.host),
                ssh: metadata.sshURLToRepo
            )
        ))
    }

    func lifecycle(
        repository: ChangeRequestRepository,
        number: Int
    ) async -> ChangeRequestLifecycleOutcome {
        guard let projectPath = projectPath(repository) else {
            return .failed(message: unsupportedHostMessage)
        }
        let result = await api(
            repository: repository,
            method: "GET",
            endpoint: "projects/\(projectPath)/merge_requests/\(number)"
        )
        guard result.succeeded else { return .failed(message: apiFailure(result)) }
        guard let request = try? JSONDecoder().decode(MergeRequestResponse.self, from: result.output)
        else { return .failed(message: unreadableResponseMessage) }
        guard !request.sourceBranch.isEmpty, !request.headRevision.isEmpty else {
            return .failed(message: unreadableResponseMessage)
        }

        let state: ChangeRequestLifecycleState
        switch request.state {
        case "opened": state = .open
        case "closed": state = .closed(merged: false)
        case "merged": state = .closed(merged: true)
        default:
            return .failed(message: L10n.string(
                "GitLab returned a merge-request state Threading does not understand."
            ))
        }
        return .loaded(ChangeRequestLifecycle(
            number: request.iid,
            state: state,
            headBranch: request.sourceBranch,
            headRevision: request.headRevision
        ))
    }

    func create(
        repository: ChangeRequestRepository,
        proposal: ChangeRequestProposal
    ) async -> ChangeRequestWriteOutcome {
        guard let projectPath = projectPath(repository) else {
            return .failed(message: unsupportedHostMessage)
        }
        guard case .ready = await automaticCreationReadiness(repository: repository) else {
            return .failed(message: L10n.string(
                "GitLab merge-request creation requires glab to be installed and signed in to GitLab.com."
            ))
        }

        let title = draftTitle(
            String(proposal.title.prefix(ChangeRequestDefaults.titleLimit)),
            isDraft: proposal.isDraft
        )
        let body = CreateRequest(
            sourceBranch: proposal.headBranch,
            targetBranch: proposal.baseBranch,
            title: title,
            description: String(proposal.body.prefix(ChangeRequestDefaults.bodyLimit))
        )
        guard let input = try? JSONEncoder().encode(body) else {
            return .failed(message: L10n.string("Threading could not prepare the merge request."))
        }

        // Exactly one POST is attempted. A transport failure is ambiguous because GitLab may
        // have accepted it; the caller must discover again before any explicit retry.
        let result = await api(
            repository: repository,
            method: "POST",
            endpoint: "projects/\(projectPath)/merge_requests",
            input: input
        )
        guard result.succeeded else { return .failed(message: apiFailure(result)) }
        guard let response = try? JSONDecoder().decode(MergeRequestResponse.self, from: result.output),
              let summary = response.summary(
                host: repository.host,
                checks: .unavailable,
                reviews: .empty
              ) else {
            return .failed(message: L10n.string(
                "GitLab created the merge request, but Threading could not read its response. Discover it before retrying."
            ))
        }
        return .created(summary, credential: .glabCLI)
    }

    private func checkSummary(
        repository: ChangeRequestRepository,
        projectPath: String,
        revision: String
    ) async -> ChangeRequestChecks {
        let result = await api(
            repository: repository,
            method: "GET",
            endpoint: "projects/\(projectPath)/repository/commits/\(revision)/statuses",
            fields: ["per_page=100"]
        )
        guard result.succeeded,
              let statuses = try? JSONDecoder().decode([CommitStatusResponse].self, from: result.output)
        else { return .unavailable }

        var passed = 0
        var pending = 0
        var failed = 0
        for status in statuses {
            switch status.status {
            case "success", "skipped": passed += 1
            case "failed", "canceled", "canceling": failed += 1
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
        projectPath: String,
        request: MergeRequestResponse
    ) async -> ChangeRequestReviews {
        let result = await api(
            repository: repository,
            method: "GET",
            endpoint: "projects/\(projectPath)/merge_requests/\(request.iid)/approvals"
        )
        let approvals: Int
        if result.succeeded,
           let response = try? JSONDecoder().decode(ApprovalsResponse.self, from: result.output) {
            approvals = response.approvedBy.count
        } else {
            approvals = 0
        }
        return ChangeRequestReviews(
            approvals: approvals,
            changesRequested: 0,
            requested: request.reviewers?.count ?? 0
        )
    }

    private func api(
        repository: ChangeRequestRepository,
        method: String,
        endpoint: String,
        fields: [String] = [],
        input: Data? = nil
    ) async -> GitLabCLIResult {
        var arguments = [
            "api", "--hostname", repository.host, "--method", method
        ]
        for field in fields {
            arguments.append(contentsOf: ["--raw-field", field])
        }
        if input != nil {
            arguments.append(contentsOf: ["--input", "-"])
        }
        arguments.append(endpoint)
        return await runner(GitLabCLIInvocation(arguments: arguments, input: input))
    }

    private func projectPath(_ repository: ChangeRequestRepository) -> String? {
        guard repository.provider == .gitlab, repository.host == GitLabDefaults.webHost else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return repository.slug.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func draftTitle(_ title: String, isDraft: Bool) -> String {
        guard isDraft else { return title }
        let lowered = title.lowercased()
        if lowered.hasPrefix("draft:") || lowered.hasPrefix("[draft]") || lowered.hasPrefix("(draft)") {
            return title
        }
        return "Draft: \(title)"
    }

    private func validatedHTTPSURL(_ value: String?, host: String) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host == host
        else { return nil }
        return url
    }

    private func apiFailure(_ result: GitLabCLIResult) -> String {
        guard !result.diagnostic.isEmpty else {
            return L10n.string("GitLab did not accept the request.")
        }
        return L10n.format("GitLab did not accept the request: %@", result.diagnostic)
    }

    private var unsupportedHostMessage: String {
        L10n.string("Threading supports GitLab change requests on GitLab.com only.")
    }

    private var unreadableResponseMessage: String {
        L10n.string("GitLab returned a response Threading could not read.")
    }

    private struct ProjectResponse: Decodable {
        let defaultBranch: String
        let httpURLToRepo: String?
        let sshURLToRepo: String?

        enum CodingKeys: String, CodingKey {
            case defaultBranch = "default_branch"
            case httpURLToRepo = "http_url_to_repo"
            case sshURLToRepo = "ssh_url_to_repo"
        }
    }

    private struct MergeRequestResponse: Decodable {
        struct User: Decodable { let id: Int? }
        struct DiffRefs: Decodable {
            let headSHA: String?
            enum CodingKeys: String, CodingKey { case headSHA = "head_sha" }
        }

        let iid: Int
        let title: String
        let description: String?
        let webURL: String
        let state: String
        let draft: Bool?
        let sourceBranch: String
        let targetBranch: String
        let sha: String?
        let diffRefs: DiffRefs?
        let mergedAt: String?
        let reviewers: [User]?

        var headRevision: String { sha ?? diffRefs?.headSHA ?? "" }

        enum CodingKeys: String, CodingKey {
            case iid, title, description, state, draft, sha, reviewers
            case webURL = "web_url"
            case sourceBranch = "source_branch"
            case targetBranch = "target_branch"
            case diffRefs = "diff_refs"
            case mergedAt = "merged_at"
        }

        func summary(
            host: String,
            checks: ChangeRequestChecks,
            reviews: ChangeRequestReviews
        ) -> ChangeRequestSummary? {
            guard !sourceBranch.isEmpty, !targetBranch.isEmpty, !headRevision.isEmpty,
                  let url = URL(string: webURL), url.scheme == "https", url.host == host else {
                return nil
            }
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let inferredDraft = normalizedTitle.hasPrefix("draft:")
                || normalizedTitle.hasPrefix("[draft]")
                || normalizedTitle.hasPrefix("(draft)")
            return ChangeRequestSummary(
                number: iid,
                title: title,
                body: description ?? "",
                url: url,
                isDraft: draft ?? inferredDraft,
                isMerged: state == "merged" || mergedAt != nil,
                baseBranch: targetBranch,
                headBranch: sourceBranch,
                headRevision: headRevision,
                checks: checks,
                reviews: reviews
            )
        }
    }

    private struct CreateRequest: Encodable {
        let sourceBranch: String
        let targetBranch: String
        let title: String
        let description: String

        enum CodingKeys: String, CodingKey {
            case sourceBranch = "source_branch"
            case targetBranch = "target_branch"
            case title, description
        }
    }

    private struct CommitStatusResponse: Decodable { let status: String }

    private struct ApprovalsResponse: Decodable {
        struct Approval: Decodable { let user: MergeRequestResponse.User }
        let approvedBy: [Approval]
        enum CodingKeys: String, CodingKey { case approvedBy = "approved_by" }
    }
}

private enum GitLabCLIProcess {
    static func run(_ invocation: GitLabCLIInvocation) -> GitLabCLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["glab"] + invocation.arguments
        process.environment = GitChildEnvironment.make(overrides: ["GLAB_NO_PROMPT": "1"])

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = invocation.input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitLabCLIResult(
                status: -1,
                output: Data(),
                diagnostic: L10n.string("glab is not installed or could not be launched.")
            )
        }

        if let stdin, let input = invocation.input {
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        let diagnosticCapture = GitLabDataCapture()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            diagnosticCapture.replace(with: Data(data.prefix(GitLabDefaults.maximumDiagnosticBytes)))
            stderrDrained.leave()
        }

        let interrupted = GitLabProcessFlag()
        let timeout = DispatchWorkItem {
            interrupted.markTimedOut()
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + GitLabDefaults.timeout,
            execute: timeout
        )

        var output = Data()
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > GitLabDefaults.maximumOutputBytes {
                interrupted.markOversized()
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = reader.readDataToEndOfFile()
                break
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        stderrDrained.wait()

        let diagnostic: String
        if interrupted.timedOut {
            diagnostic = L10n.string("glab took too long to answer.")
        } else if interrupted.oversized {
            diagnostic = L10n.string("GitLab returned too much data.")
        } else {
            diagnostic = boundedDiagnostic(diagnosticCapture.value)
        }
        return GitLabCLIResult(
            status: interrupted.timedOut || interrupted.oversized ? -1 : process.terminationStatus,
            output: output,
            diagnostic: diagnostic
        )
    }

    private static func boundedDiagnostic(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
            }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class GitLabDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func replace(with data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}

private final class GitLabProcessFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var timeoutValue = false
    private var oversizedValue = false

    var timedOut: Bool { lock.withLock { timeoutValue } }
    var oversized: Bool { lock.withLock { oversizedValue } }
    func markTimedOut() { lock.withLock { timeoutValue = true } }
    func markOversized() { lock.withLock { oversizedValue = true } }
}
