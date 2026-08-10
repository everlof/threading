import XCTest
@testable import Threading
import ThreadingExtensionKit

final class ExtensionNetworkBrokerTests: XCTestCase {

    private func resolver(
        app: String? = nil,
        gh: String? = nil,
        git: String? = nil
    ) -> GitHubCredentialResolver {
        GitHubCredentialResolver(
            appConnection: FakeAppTokens(token: app),
            ghSource: FakeTokenSource(token: gh),
            gitSource: FakeTokenSource(token: git)
        )
    }

    /// Scripts responses by the Authorization header the broker attached, so a test states
    /// "the app token sees 404, the gh token sees 200" directly.
    private func transport(
        _ responses: @escaping @Sendable (String?) -> (Int, Data, [String: String])
    ) -> ExtensionNetworkBroker.Transport {
        { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            let (status, body, headers) = responses(token)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (body, http)
        }
    }

    private func request(
        method: String = "GET",
        url: String = "https://api.github.com/repos/o/r/commits/abc/check-runs"
    ) -> ExtensionBrokeredFetchRequest {
        ExtensionBrokeredFetchRequest(method: method, url: url)
    }

    // MARK: - Tier walking

    func testAnAnonymousFetchPassesTheStatusThrough() async {
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: nil,
            transport: transport { token in
                XCTAssertNil(token, "no resolver means no credential")
                return (404, Data("missing".utf8), [:])
            }
        )
        guard case .success(let reading) = result else {
            return XCTFail("a completed exchange is a success, whatever its status")
        }
        XCTAssertEqual(reading.status, 404)
        XCTAssertEqual(reading.credential, .anonymous)
        XCTAssertEqual(reading.body, Data("missing".utf8))
    }

    func testTheWalkFindsTheRepositoryTheAppInstallationCannotSee() async {
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: resolver(app: "app-token", gh: "gh-token"),
            transport: transport { token in
                token == "Bearer gh-token"
                    ? (200, Data("{}".utf8), [:])
                    : (404, Data(), [:])
            }
        )
        guard case .success(let reading) = result else { return XCTFail("expected success") }
        XCTAssertEqual(reading.status, 200)
        XCTAssertEqual(reading.credential, .ghCLI)
    }

    func testA401InvalidatesTheTierAndTheChainMovesOn() async {
        let appTokens = FakeAppTokens(token: "stale-app-token")
        let chain = GitHubCredentialResolver(
            appConnection: appTokens,
            ghSource: FakeTokenSource(token: "gh-token"),
            gitSource: FakeTokenSource(token: nil)
        )
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: chain,
            transport: transport { token in
                token == "Bearer stale-app-token"
                    ? (401, Data(), [:])
                    : (200, Data("{}".utf8), [:])
            }
        )
        guard case .success(let reading) = result else { return XCTFail("expected success") }
        XCTAssertEqual(reading.credential, .ghCLI)
        XCTAssertEqual(
            appTokens.rejections, 1,
            "a 401 is proof the cached token died; it must be dropped"
        )
    }

    func testAllMissesReportTheMostAuthoritativeAnswer() async {
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: resolver(app: "app-token", gh: "gh-token"),
            transport: transport { _ in (404, Data("no".utf8), [:]) }
        )
        guard case .success(let reading) = result else { return XCTFail("expected success") }
        XCTAssertEqual(reading.status, 404)
        XCTAssertEqual(
            reading.credential, .app,
            "the tier the user set up is the answer they should read"
        )
    }

    func testANonWalkableStatusReturnsImmediately() async {
        let counter = TransportCounter()
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: resolver(app: "app-token", gh: "gh-token"),
            transport: transport { _ in
                counter.increment()
                return (500, Data(), [:])
            }
        )
        guard case .success(let reading) = result else { return XCTFail("expected success") }
        XCTAssertEqual(reading.status, 500)
        XCTAssertEqual(reading.credential, .app)
        XCTAssertEqual(counter.count, 1, "a 500 is not a credential problem; do not walk")
    }

    func testTransportFailureStopsTheWalk() async {
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: resolver(app: "app-token"),
            transport: { _ in throw URLError(.timedOut) }
        )
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.message.contains("api.github.com"))
        XCTAssertEqual(failure.credential, .app)
    }

    func testAnOversizedResponseFailsInsteadOfFlooding() async {
        let oversized = Data(
            count: ExtensionBrokeredNetwork.maximumResponseBodyBytes + 1
        )
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: nil,
            transport: transport { _ in (200, oversized, [:]) }
        )
        guard case .failure = result else {
            return XCTFail("an oversized body must not reach the guest")
        }
    }

    func testSetCookieNeverReachesTheGuestAndHeaderNamesLower() async {
        let result = await ExtensionNetworkBroker.perform(
            request: request(),
            resolver: nil,
            transport: transport { _ in
                (200, Data(), [
                    "Set-Cookie": "session=1",
                    "X-RateLimit-Remaining": "0",
                    "Content-Type": "application/json"
                ])
            }
        )
        guard case .success(let reading) = result else { return XCTFail("expected success") }
        XCTAssertNil(reading.headers["set-cookie"])
        XCTAssertEqual(reading.headers["x-ratelimit-remaining"], "0")
        XCTAssertEqual(reading.headers["content-type"], "application/json")
    }
}

final class TransportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

// MARK: - Route

@MainActor
final class ExtensionHostBrokeredFetchRouteTests: XCTestCase {

    private final class FakeBroker: ExtensionNetworkBrokering {
        var lastCredentialProvider: String??
        var result: Result<BrokeredFetchReading, BrokeredFetchFailure> = .success(
            BrokeredFetchReading(
                status: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8),
                credential: .ghCLI
            )
        )

        func fetch(
            request: ExtensionBrokeredFetchRequest,
            credentialProvider: String?,
            completion: @escaping @MainActor (Result<BrokeredFetchReading, BrokeredFetchFailure>) -> Void
        ) {
            lastCredentialProvider = credentialProvider
            completion(result)
        }
    }

    private func makeService(
        broker: ExtensionNetworkBrokering
    ) throws -> ExtensionHostService {
        ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            networkBroker: broker
        )
    }

    private func authorize(
        _ service: ExtensionHostService,
        capabilities: Set<ExtensionCapability> = [.networkBrokered],
        grants: [ExtensionNetworkGrant] = [
            ExtensionNetworkGrant(host: "api.github.com", methods: ["GET"], credential: "github")
        ]
    ) throws -> String {
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.fetcher",
            processGeneration: "generation-one",
            order: 0,
            capabilities: capabilities,
            networkGrants: grants
        ))
        return authorization.connection.bearerToken
    }

    func testAuthorizationFailsClosedWhenSecureTokenEntropyIsUnavailable() throws {
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            entropySource: { _ in nil }
        )

        XCTAssertThrowsError(try service.authorize(
            extensionIdentifier: "com.example.no-entropy",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.networkBrokered]
        )) { error in
            guard case ExtensionHostServiceError.secureTokenUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(ExtensionHostService.randomToken(using: { _ in [0] }))
    }

    private func post(
        _ call: ExtensionBrokeredFetchRequest,
        token: String,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        var result: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/network/fetch",
                headers: [
                    "authorization": "Bearer \(token)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(call)
            )
        ) {
            result = $0
        }
        return result!
    }

    func testAGrantedFetchReturnsTheEnvelopeAndNamesTheProvider() throws {
        let broker = FakeBroker()
        let service = try makeService(broker: broker)
        let token = try authorize(service)

        let response = post(
            ExtensionBrokeredFetchRequest(
                method: "GET",
                url: "https://api.github.com/repos/o/r/commits/abc/check-runs"
            ),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 200)
        let result = try JSONDecoder().decode(
            ExtensionBrokeredFetchResult.self,
            from: response.body
        )
        XCTAssertEqual(result.response?.status, 200)
        XCTAssertEqual(result.response?.credentialTier, .ghCLI)
        XCTAssertEqual(broker.lastCredentialProvider, "github")
    }

    func testAFailureTravelsAsDataNotAsARejection() throws {
        let broker = FakeBroker()
        broker.result = .failure(BrokeredFetchFailure(
            message: "The host could not reach api.github.com: timed out",
            credential: .anonymous
        ))
        let service = try makeService(broker: broker)
        let token = try authorize(service)

        let response = post(
            ExtensionBrokeredFetchRequest(
                method: "GET",
                url: "https://api.github.com/x"
            ),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 200)
        let result = try JSONDecoder().decode(
            ExtensionBrokeredFetchResult.self,
            from: response.body
        )
        XCTAssertNil(result.response)
        XCTAssertEqual(result.failure?.credentialTier, .anonymous)
    }

    func testAnUndeclaredHostIsForbidden() throws {
        let service = try makeService(broker: FakeBroker())
        let token = try authorize(service)
        let response = post(
            ExtensionBrokeredFetchRequest(method: "GET", url: "https://example.com/data"),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 403)
    }

    func testAnUndeclaredMethodIsForbidden() throws {
        let service = try makeService(broker: FakeBroker())
        let token = try authorize(service)
        let response = post(
            ExtensionBrokeredFetchRequest(method: "HEAD", url: "https://api.github.com/x"),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 403, "the grant declared GET, not HEAD")
    }

    func testTheCapabilityIsRequired() throws {
        let service = try makeService(broker: FakeBroker())
        // Authorized for other host work, but without network.brokered.
        let token = try authorize(
            service,
            capabilities: [.componentCustomization],
            grants: []
        )
        let response = post(
            ExtensionBrokeredFetchRequest(method: "GET", url: "https://api.github.com/x"),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 403)
    }

    func testABrokerOwnedHeaderIsRefusedBeforeTheBroker() throws {
        let broker = FakeBroker()
        let service = try makeService(broker: broker)
        let token = try authorize(service)
        let response = post(
            ExtensionBrokeredFetchRequest(
                method: "GET",
                url: "https://api.github.com/x",
                headers: ["Authorization": "Bearer smuggled"]
            ),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 422)
        XCTAssertNil(broker.lastCredentialProvider, "the broker must never see the request")
    }
}
