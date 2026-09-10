import Foundation
import ThreadingExtensionKit

public protocol ForgejoSourceControlHost: Sendable {
    func fetch(_ request: ExtensionSourceControlFetchRequest) async throws
        -> ExtensionSourceControlFetchResponse
}

public struct ForgejoSourceControlHostAdapter: ForgejoSourceControlHost {
    private let client: ExtensionHostClient

    public init(client: ExtensionHostClient) { self.client = client }

    public func fetch(
        _ request: ExtensionSourceControlFetchRequest
    ) async throws -> ExtensionSourceControlFetchResponse {
        try await client.sourceControlFetch(request)
    }
}

public struct ForgejoSourceControlProvider: Sendable {
    private let host: any ForgejoSourceControlHost

    public init(host: any ForgejoSourceControlHost) { self.host = host }

    public func handle(_ request: ExtensionSourceControlRequest) async
        -> ExtensionSourceControlResponse
    {
        do {
            try request.validate()
            guard request.providerID == ForgejoSourceControlExtensionContract.provider.id else {
                return failure(request, code: .unavailable, message: "Unknown Forgejo provider.")
            }
            switch request.operation {
            case .probe:
                let version: ForgejoVersion = try await fetch(
                    connectionID: request.connectionID,
                    path: "/version"
                )
                return ExtensionSourceControlResponse(
                    requestID: request.requestID,
                    providerID: request.providerID,
                    serverVersion: String(version.version.prefix(80))
                )
            case .discover:
                guard let repository = request.repository else {
                    return failure(request, code: .malformedResponse, message: "Missing repository.")
                }
                return try await discover(request, repository: repository)
            case .lifecycle:
                guard let repository = request.repository,
                      let number = request.changeRequestNumber else {
                    return failure(request, code: .malformedResponse, message: "Missing pull request.")
                }
                return try await lifecycle(request, repository: repository, number: number)
            }
        } catch let error as ForgejoProviderFailure {
            return failure(request, code: error.code, message: error.message)
        } catch {
            return failure(request, code: .transport, message: "Forgejo could not be reached.")
        }
    }

    private func discover(
        _ request: ExtensionSourceControlRequest,
        repository: ExtensionSourceControlRepository
    ) async throws -> ExtensionSourceControlResponse {
        let path = try repositoryPath(repository)
        async let repositoryReading: ForgejoRepository = fetch(
            connectionID: request.connectionID,
            path: path
        )
        async let pullReading: [ForgejoPullRequest?] = fetch(
            connectionID: request.connectionID,
            path: path + "/pulls",
            queryItems: [
                .init(name: "state", value: "all"),
                .init(name: "sort", value: "recentupdate"),
                .init(name: "head", value: repository.branch),
                .init(name: "page", value: "1"),
                .init(name: "limit", value: String(ForgejoSourceControlLimits.maximumPageItems))
            ]
        )
        let (metadata, pulls) = try await (repositoryReading, pullReading)
        guard !metadata.defaultBranch.isEmpty else {
            throw ForgejoProviderFailure(.malformedResponse, "Forgejo returned no default branch.")
        }
        let selected = pulls.compactMap { $0 }.filter {
            matches($0, branch: repository.branch, headRevision: repository.headRevision)
        }.sorted(by: newestPullFirst).first
        let summary: ExtensionChangeRequestSummary?
        if let selected {
            summary = try await makeSummary(selected, request: request, repositoryPath: path)
        } else {
            summary = nil
        }
        return ExtensionSourceControlResponse(
            requestID: request.requestID,
            providerID: request.providerID,
            defaultBranch: metadata.defaultBranch,
            changeRequest: summary
        )
    }

    private func lifecycle(
        _ request: ExtensionSourceControlRequest,
        repository: ExtensionSourceControlRepository,
        number: Int
    ) async throws -> ExtensionSourceControlResponse {
        let path = try repositoryPath(repository)
        let pull: ForgejoPullRequest = try await fetch(
            connectionID: request.connectionID,
            path: path + "/pulls/\(number)"
        )
        guard pull.number == number else {
            throw ForgejoProviderFailure(.malformedResponse, "Forgejo returned another pull request.")
        }
        return ExtensionSourceControlResponse(
            requestID: request.requestID,
            providerID: request.providerID,
            changeRequest: try await makeSummary(pull, request: request, repositoryPath: path)
        )
    }

    private func makeSummary(
        _ pull: ForgejoPullRequest,
        request: ExtensionSourceControlRequest,
        repositoryPath: String
    ) async throws -> ExtensionChangeRequestSummary {
        guard pull.number > 0, !pull.title.isEmpty, !pull.htmlURL.isEmpty,
              !pull.base.ref.isEmpty, !pull.head.ref.isEmpty, !pull.head.sha.isEmpty else {
            throw ForgejoProviderFailure(.malformedResponse, "Forgejo returned an incomplete pull request.")
        }
        async let statusReading = fetchResponse(
            connectionID: request.connectionID,
            path: repositoryPath + "/commits/\(ForgejoPath.component(pull.head.sha))/statuses",
            queryItems: [
                .init(name: "page", value: "1"),
                .init(name: "limit", value: String(ForgejoSourceControlLimits.maximumPageItems))
            ]
        )
        async let reviewReading = fetchResponse(
            connectionID: request.connectionID,
            path: repositoryPath + "/pulls/\(pull.number)/reviews",
            queryItems: [
                .init(name: "page", value: "1"),
                .init(name: "limit", value: String(ForgejoSourceControlLimits.maximumPageItems))
            ]
        )
        let (statusResponse, reviewResponse) = try await (statusReading, reviewReading)
        let statuses: [ForgejoCommitStatus] = try decode(statusResponse)
        let reviews: [ForgejoPullReview] = try decode(reviewResponse)
        return ExtensionChangeRequestSummary(
            number: pull.number,
            title: String(pull.title.prefix(256)),
            webURL: pull.htmlURL,
            lifecycle: try lifecycle(for: pull),
            baseBranch: pull.base.ref,
            headBranch: pull.head.ref,
            headRevision: pull.head.sha,
            checks: checks(statuses, incomplete: hasNextPage(statusResponse.headers)),
            reviews: reviewSummary(reviews, requested: pull.requestedReviewers?.count ?? 0)
        )
    }

    private func fetch<Value: Decodable>(
        connectionID: String,
        path: String,
        queryItems: [ExtensionSourceControlQueryItem] = []
    ) async throws -> Value {
        try decode(try await fetchResponse(
            connectionID: connectionID,
            path: path,
            queryItems: queryItems
        ))
    }

    private func fetchResponse(
        connectionID: String,
        path: String,
        queryItems: [ExtensionSourceControlQueryItem] = []
    ) async throws -> ExtensionSourceControlFetchResponse {
        let response = try await host.fetch(.init(
            connectionID: connectionID,
            path: path,
            queryItems: queryItems,
            headers: ["Accept": "application/json"]
        ))
        switch response.status {
        case 200: return response
        case 401: throw ForgejoProviderFailure(.authenticationRequired, "Forgejo requires authentication.")
        case 403: throw ForgejoProviderFailure(.forbidden, "Forgejo refused this read.")
        case 404: throw ForgejoProviderFailure(.notFound, "Forgejo could not find this repository or pull request.")
        case 429: throw ForgejoProviderFailure(.rateLimited, "Forgejo rate-limited this connection.")
        default:
            throw ForgejoProviderFailure(.transport, "Forgejo returned HTTP \(response.status).")
        }
    }

    private func decode<Value: Decodable>(
        _ response: ExtensionSourceControlFetchResponse
    ) throws -> Value {
        guard let body = response.body else {
            throw ForgejoProviderFailure(.malformedResponse, "Forgejo returned malformed JSON.")
        }
        do { return try JSONDecoder().decode(Value.self, from: body) }
        catch { throw ForgejoProviderFailure(.malformedResponse, "Forgejo returned malformed JSON.") }
    }

    private func repositoryPath(_ repository: ExtensionSourceControlRepository) throws -> String {
        guard !repository.namespace.contains("/") else {
            throw ForgejoProviderFailure(.unavailable, "Forgejo requires a single repository owner.")
        }
        return "/repos/\(ForgejoPath.component(repository.namespace))/\(ForgejoPath.component(repository.name))"
    }

    private func matches(
        _ pull: ForgejoPullRequest,
        branch: String,
        headRevision: String
    ) -> Bool {
        guard pull.head.ref == branch else { return false }
        if pull.merged || pull.state.lowercased() == "closed" {
            return pull.head.sha == headRevision
        }
        return pull.state.lowercased() == "open"
    }

    private func newestPullFirst(_ lhs: ForgejoPullRequest, _ rhs: ForgejoPullRequest) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.number > rhs.number
    }

    private func lifecycle(
        for pull: ForgejoPullRequest
    ) throws -> ExtensionChangeRequestLifecycle {
        if pull.merged { return .init(.merged, providerValue: pull.state) }
        switch pull.state.lowercased() {
        case "open": return .init(pull.draft ? .draft : .open, providerValue: pull.state)
        case "closed": return .init(.closed, providerValue: pull.state)
        default:
            throw ForgejoProviderFailure(
                .malformedResponse,
                "Forgejo returned an unknown pull-request state."
            )
        }
    }

    private func checks(
        _ values: [ForgejoCommitStatus],
        incomplete: Bool
    ) -> ExtensionChangeRequestChecks {
        var latest: [String: ForgejoCommitStatus] = [:]
        for value in values where !value.context.isEmpty {
            if let current = latest[value.context], current.updatedAt >= value.updatedAt { continue }
            latest[value.context] = value
        }
        var counts = (successful: 0, nonBlocking: 0, active: 0, attention: 0, unknown: 0)
        for value in latest.values {
            switch value.status.lowercased() {
            case "success": counts.successful += 1
            case "warning", "skipped": counts.nonBlocking += 1
            case "pending": counts.active += 1
            case "error", "failure": counts.attention += 1
            default: counts.unknown += 1
            }
        }
        return .init(
            successful: counts.successful,
            nonBlocking: counts.nonBlocking,
            active: counts.active,
            needsAttention: counts.attention,
            unknown: counts.unknown,
            isIncomplete: incomplete
        )
    }

    private func reviewSummary(
        _ values: [ForgejoPullReview],
        requested: Int
    ) -> ExtensionChangeRequestReviews {
        var latest: [String: ForgejoPullReview] = [:]
        for value in values {
            guard !value.dismissed, !value.stale,
                  let login = value.user?.login, !login.isEmpty else { continue }
            if let current = latest[login], current.timestamp >= value.timestamp { continue }
            latest[login] = value
        }
        var approvals = 0
        var changesRequested = 0
        for value in latest.values {
            switch value.state.lowercased() {
            case "approved": approvals += 1
            case "request_changes", "request changes", "changes_requested": changesRequested += 1
            default: break
            }
        }
        return .init(
            approvals: approvals,
            changesRequested: changesRequested,
            requested: min(max(requested, 0), 100_000)
        )
    }

    private func hasNextPage(_ headers: [String: String]) -> Bool {
        headers.first { $0.key.lowercased() == "link" }?.value.contains("rel=\"next\"") == true
    }

    private func failure(
        _ request: ExtensionSourceControlRequest,
        code: ExtensionSourceControlErrorCode,
        message: String
    ) -> ExtensionSourceControlResponse {
        .init(
            requestID: request.requestID,
            providerID: request.providerID,
            error: .init(code: code, message: String(message.prefix(500)))
        )
    }
}

private struct ForgejoProviderFailure: Error {
    let code: ExtensionSourceControlErrorCode
    let message: String

    init(_ code: ExtensionSourceControlErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

private struct ForgejoVersion: Decodable { let version: String }
private struct ForgejoRepository: Decodable {
    let defaultBranch: String
    private enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
}
private struct ForgejoPullRequest: Decodable {
    let number: Int
    let title: String
    let htmlURL: String
    let state: String
    let draft: Bool
    let merged: Bool
    let updatedAt: String
    let base: ForgejoBranch
    let head: ForgejoBranch
    let requestedReviewers: [ForgejoUser]?
    private enum CodingKeys: String, CodingKey {
        case number, title, state, draft, merged, base, head
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case requestedReviewers = "requested_reviewers"
    }
}
private struct ForgejoBranch: Decodable { let ref: String; let sha: String }
private struct ForgejoUser: Decodable { let login: String }
private struct ForgejoCommitStatus: Decodable {
    let context: String
    let status: String
    let updatedAt: String
    private enum CodingKeys: String, CodingKey {
        case context, status
        case updatedAt = "updated_at"
    }
}
private struct ForgejoPullReview: Decodable {
    let state: String
    let dismissed: Bool
    let stale: Bool
    let submittedAt: String?
    let updatedAt: String?
    let user: ForgejoUser?
    var timestamp: String { updatedAt ?? submittedAt ?? "" }
    private enum CodingKeys: String, CodingKey {
        case state, dismissed, stale, user
        case submittedAt = "submitted_at"
        case updatedAt = "updated_at"
    }
}

public enum ForgejoPath {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    public static func component(_ value: String) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                result.append(byte)
            } else {
                result.append(UInt8(ascii: "%"))
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "~")
    }
}
