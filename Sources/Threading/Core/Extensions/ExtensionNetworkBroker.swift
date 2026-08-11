import Foundation
import ThreadingExtensionKit

/// The outcome of one brokered exchange: a real HTTP answer, whatever its status.
struct BrokeredFetchReading: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let credential: GitHubCredential.Tier
}

/// The transport itself failed — nothing came back to interpret.
struct BrokeredFetchFailure: Error, Equatable, Sendable {
    let message: String
    let credential: GitHubCredential.Tier
}

/// Host-side boundary the extension host calls, separated for tests.
@MainActor
protocol ExtensionNetworkBrokering: AnyObject {
    func fetch(
        request: ExtensionBrokeredFetchRequest,
        credentialProvider: String?,
        completion: @escaping @MainActor (Result<BrokeredFetchReading, BrokeredFetchFailure>) -> Void
    )
}

/// Performs brokered fetches, attaching the named provider's best credential.
///
/// Credential providers are a host-side registry — today `"github"`, resolved through the
/// same chain the rest of the app uses (app connection → `gh` → git credential helper →
/// anonymous). For a credentialed GET the tiers are walked on 401, 403, and 404, because a
/// miss under one tier says nothing about the next: a GitHub App sees only the repositories
/// it was installed on, while a `gh` token sees everything the user sees. A 401 additionally
/// invalidates that tier's cache — proof the cached token died. When every tier misses, the
/// *most authoritative* answer is returned: that is the credential the user actually set up,
/// so it is the answer they should read.
@MainActor
final class ExtensionNetworkBroker: ExtensionNetworkBrokering {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Statuses worth retrying under the next credential tier, GET/HEAD only.
    private static let tierWalkStatuses: Set<Int> = [401, 403, 404]

    private let credentialResolvers: [String: GitHubCredentialResolver]
    private let transport: Transport

    init(
        credentialResolvers: [String: GitHubCredentialResolver],
        transport: @escaping Transport = GitHubAppConnection.liveTransport
    ) {
        self.credentialResolvers = credentialResolvers
        self.transport = transport
    }

    static func live() -> ExtensionNetworkBroker {
        ExtensionNetworkBroker(credentialResolvers: ["github": .live()])
    }

    func fetch(
        request: ExtensionBrokeredFetchRequest,
        credentialProvider: String?,
        completion: @escaping @MainActor (Result<BrokeredFetchReading, BrokeredFetchFailure>) -> Void
    ) {
        let resolver = credentialProvider.flatMap { credentialResolvers[$0] }
        let transport = transport
        Task {
            let result = await Self.perform(
                request: request,
                resolver: resolver,
                transport: transport
            )
            await MainActor.run { completion(result) }
        }
    }

    static func perform(
        request: ExtensionBrokeredFetchRequest,
        resolver: GitHubCredentialResolver?,
        transport: Transport
    ) async -> Result<BrokeredFetchReading, BrokeredFetchFailure> {
        guard let url = URL(string: request.url) else {
            ThreadingLogger.extensions.warning(
                "Extension brokered request rejected stage=url_parse url=\(request.url, privacy: .private(mask: .hash))"
            )
            return .failure(BrokeredFetchFailure(
                message: L10n.string("The brokered URL could not be parsed."),
                credential: .anonymous
            ))
        }

        let credentials = await resolver?.orderedCredentials() ?? [.anonymous]
        var mostAuthoritative: BrokeredFetchReading?
        for credential in credentials {
            var urlRequest = URLRequest(
                url: url,
                timeoutInterval: GitHubDefaults.requestTimeout
            )
            urlRequest.httpMethod = request.method
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            urlRequest.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")
            if let token = credential.token {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let bodyBase64 = request.bodyBase64 {
                urlRequest.httpBody = Data(base64Encoded: bodyBase64)
            }

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await transport(urlRequest)
            } catch {
                // Transport trouble is environmental, not credential-dependent; retrying the
                // same network under another token would only repeat the wait.
                ThreadingLogger.extensions.error(
                    "Extension brokered request transport failed host=\(url.host ?? request.url, privacy: .private(mask: .hash)) credential_tier=\(credential.tier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                return .failure(BrokeredFetchFailure(
                    message: L10n.format(
                        "The host could not reach %@: %@",
                        url.host ?? request.url,
                        error.localizedDescription
                    ),
                    credential: credential.tier
                ))
            }

            guard data.count <= ExtensionBrokeredNetwork.maximumResponseBodyBytes else {
                ThreadingLogger.extensions.warning(
                    "Extension brokered response refused reason=oversized status=\(http.statusCode, privacy: .public) response_bytes=\(data.count, privacy: .public) credential_tier=\(credential.tier.rawValue, privacy: .public)"
                )
                return .failure(BrokeredFetchFailure(
                    message: L10n.string("The response exceeds the brokered size limit."),
                    credential: credential.tier
                ))
            }

            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String else {
                    continue
                }
                let lowered = name.lowercased()
                guard !ExtensionBrokeredNetwork.deniedResponseHeaders.contains(lowered) else {
                    continue
                }
                headers[lowered] = String(
                    value.prefix(ExtensionBrokeredNetwork.maximumHeaderValueLength)
                )
            }
            let reading = BrokeredFetchReading(
                status: http.statusCode,
                headers: headers,
                body: data,
                credential: credential.tier
            )

            let isWalkable = (request.method == "GET" || request.method == "HEAD")
                && Self.tierWalkStatuses.contains(http.statusCode)
                && credential.tier != credentials.last?.tier
            guard isWalkable else {
                return .success(mostAuthoritative.map { best in
                    Self.tierWalkStatuses.contains(reading.status) ? best : reading
                } ?? reading)
            }
            if http.statusCode == 401, credential.token != nil {
                await resolver?.invalidate(credential.tier)
            } else {
                mostAuthoritative = mostAuthoritative ?? reading
            }
        }
        // Unreachable: the last tier always returns above. Kept for the compiler.
        ThreadingLogger.extensions.fault(
            "Extension brokered request exhausted credentials without a result credential_count=\(credentials.count, privacy: .public)"
        )
        return .failure(BrokeredFetchFailure(
            message: L10n.string("Every GitHub credential Threading holds was refused."),
            credential: .anonymous
        ))
    }
}
