import Foundation
import XCTest
@testable import Threading
import ThreadingExtensionKit

@MainActor
final class SourceControlProviderConnectionTests: XCTestCase {
    func testConnectionMetadataRoundTripsWhileCredentialStaysInSecretStore() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let connection = forgejoConnection(id: "forgejo-one")

        try fixture.store.upsert(connection, credential: Data("secret-token".utf8))

        let reloaded = SourceControlProviderConnectionStore(
            defaults: fixture.defaults,
            secrets: fixture.secrets
        )
        XCTAssertEqual(reloaded.connections, [connection])
        XCTAssertEqual(try reloaded.credential(for: connection), Data("secret-token".utf8))
        let persisted = try XCTUnwrap(
            fixture.defaults.data(forKey: AppSettingDefinitions
                .sourceControlProviderConnections.persistenceKey)
        )
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("secret-token"))
    }

    func testAHostCanBelongToOnlyOneProviderAndBuiltInHostsStayReserved() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        try fixture.store.upsert(
            forgejoConnection(id: "first"),
            credential: Data("one".utf8)
        )

        XCTAssertThrowsError(try fixture.store.upsert(
            forgejoConnection(id: "second"),
            credential: Data("two".utf8)
        )) { error in
            XCTAssertEqual(
                error as? SourceControlProviderConnectionError,
                .duplicateRemoteHost("forge.example")
            )
        }

        let github = SourceControlProviderConnection(
            id: "github",
            extensionIdentifier: "dev.example.forge",
            providerID: "forgejo",
            remoteHost: "github.com",
            baseOrigin: "https://github.com",
            apiPathPrefix: "/api/v1",
            authenticationKind: .none
        )
        XCTAssertThrowsError(try fixture.store.upsert(github, credential: nil)) { error in
            XCTAssertEqual(
                error as? SourceControlProviderConnectionError,
                .builtInHost("github.com")
            )
        }
    }

    func testOriginMustBeHTTPSAndMatchTheRemoteHostExactly() {
        let mismatched = SourceControlProviderConnection(
            extensionIdentifier: "dev.example.forge",
            providerID: "forgejo",
            remoteHost: "git.example",
            baseOrigin: "https://elsewhere.example",
            apiPathPrefix: "/api/v1",
            authenticationKind: .none
        )
        XCTAssertThrowsError(try mismatched.validate())

        let insecure = SourceControlProviderConnection(
            extensionIdentifier: "dev.example.forge",
            providerID: "forgejo",
            remoteHost: "git.example",
            baseOrigin: "http://git.example",
            apiPathPrefix: "/api/v1",
            authenticationKind: .none
        )
        XCTAssertThrowsError(try insecure.validate())
    }

    func testAuthenticationShapeRejectsAmbientOrMalformedCredentials() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var anonymous = forgejoConnection(id: "anonymous", authenticationKind: .none)
        XCTAssertThrowsError(try fixture.store.upsert(
            anonymous,
            credential: Data("must-not-be-stored".utf8)
        )) { error in
            XCTAssertEqual(error as? SourceControlProviderConnectionError, .credentialNotAllowed)
        }

        XCTAssertThrowsError(try fixture.store.upsert(
            forgejoConnection(id: "whitespace"),
            credential: Data("token with spaces".utf8)
        )) { error in
            XCTAssertEqual(error as? SourceControlProviderConnectionError, .credentialInvalid)
        }

        anonymous = SourceControlProviderConnection(
            id: "anonymous-with-user",
            extensionIdentifier: anonymous.extensionIdentifier,
            providerID: anonymous.providerID,
            remoteHost: anonymous.remoteHost,
            baseOrigin: anonymous.baseOrigin,
            apiPathPrefix: anonymous.apiPathPrefix,
            authenticationKind: .none,
            username: "alice"
        )
        XCTAssertThrowsError(try fixture.store.upsert(anonymous, credential: nil)) { error in
            XCTAssertEqual(error as? SourceControlProviderConnectionError, .usernameNotAllowed)
        }
    }

    func testSecretWriteFailureLeavesNoConnectionMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.secrets.failWrites = true

        XCTAssertThrowsError(try fixture.store.upsert(
            forgejoConnection(id: "failed"),
            credential: Data("token".utf8)
        ))
        XCTAssertTrue(fixture.store.connections.isEmpty)
        XCTAssertNil(fixture.defaults.data(
            forKey: AppSettingDefinitions.sourceControlProviderConnections.persistenceKey
        ))
    }

    func testRemovingConnectionDeletesMetadataAndCredentialTogether() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let connection = forgejoConnection(id: "remove-me")
        try fixture.store.upsert(connection, credential: Data("token".utf8))

        try fixture.store.remove(id: connection.id)

        XCTAssertTrue(fixture.store.connections.isEmpty)
        XCTAssertNil(try fixture.secrets.data(
            extensionIdentifier: SourceControlProviderConnectionStore.credentialNamespace,
            key: connection.id
        ))
    }

    func testBrokerBuildsAuthorityAndCredentialWhileKeepingExtensionBelowAPIPrefix() async throws {
        let recorder = SourceControlRequestRecorder()
        let broker = SourceControlConnectionNetworkBroker { request, _ in
            await recorder.record(request)
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Set-Cookie": "private"]
            )!
            return (Data("{}".utf8), response)
        }
        let request = ExtensionSourceControlFetchRequest(
            connectionID: "forgejo-one",
            path: "/repos/team/project",
            queryItems: [.init(name: "page", value: "2")],
            headers: ["Accept": "application/json"]
        )
        let definition = forgejoDefinition()

        let result = await broker.fetch(
            request,
            connection: forgejoConnection(id: "forgejo-one"),
            definition: definition,
            credential: Data("secret-token".utf8)
        )

        let recorded = await recorder.request
        let sent = try XCTUnwrap(recorded)
        XCTAssertEqual(sent.url?.scheme, "https")
        XCTAssertEqual(sent.url?.host, "forge.example")
        XCTAssertEqual(sent.url?.path, "/api/v1/repos/team/project")
        XCTAssertEqual(sent.url?.query, "page=2")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "token secret-token")
        guard case .success(let response) = result else {
            return XCTFail("broker unexpectedly refused a valid request")
        }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertNil(response.headers["set-cookie"])
        XCTAssertTrue(response.usedCredential)
    }

    func testRedirectGateRefusesAChangedOriginPathOrMethod() throws {
        var original = URLRequest(url: URL(
            string: "https://forge.example/api/v1/repos/team/project"
        )!)
        original.httpMethod = "GET"
        let gate = try XCTUnwrap(SourceControlRedirectGate(
            request: original,
            apiPathPrefix: "/api/v1"
        ))
        XCTAssertTrue(gate.allows(original))

        var otherHost = original
        otherHost.url = URL(string: "https://other.example/api/v1/repos/team/project")
        XCTAssertFalse(gate.allows(otherHost))
        var otherPath = original
        otherPath.url = URL(string: "https://forge.example/private/project")
        XCTAssertFalse(gate.allows(otherPath))
        var otherMethod = original
        otherMethod.httpMethod = "POST"
        XCTAssertFalse(gate.allows(otherMethod))
    }

    func testHostRouteBindsTheOpaqueConnectionToItsOwningExtensionAndProvider() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let connection = forgejoConnection(id: "forgejo-one")
        try fixture.store.upsert(connection, credential: Data("secret-token".utf8))
        let broker = SourceControlRouteBroker()
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            sourceControlConnectionStore: fixture.store,
            sourceControlNetworkBroker: broker
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: connection.extensionIdentifier,
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.sourceControlRead],
            sourceControlProviders: [forgejoDefinition()]
        ))
        let call = ExtensionSourceControlFetchRequest(
            connectionID: connection.id,
            path: "/repos/team/project"
        )

        let response: HTTPResponse = await withCheckedContinuation { continuation in
            service.route(HTTPRequest(
                method: "POST",
                path: "/v1/source-control/fetch",
                headers: [
                    "authorization": "Bearer \(authorization.connection.bearerToken)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(call)
            )) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(response.status, 200)
        let result = try JSONDecoder().decode(
            ExtensionSourceControlFetchResult.self,
            from: response.body
        )
        XCTAssertEqual(result.response?.status, 200)
        let captured = await broker.captured
        XCTAssertEqual(captured?.request, call)
        XCTAssertEqual(captured?.connection, connection)
        XCTAssertEqual(captured?.credential, Data("secret-token".utf8))

        let otherAuthorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "dev.example.other-forge",
            processGeneration: "generation-two",
            order: 1,
            capabilities: [.sourceControlRead],
            sourceControlProviders: [forgejoDefinition()]
        ))
        let refused: HTTPResponse = await withCheckedContinuation { continuation in
            service.route(HTTPRequest(
                method: "POST",
                path: "/v1/source-control/fetch",
                headers: [
                    "authorization": "Bearer \(otherAuthorization.connection.bearerToken)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(call)
            )) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(refused.status, 403)
    }

    private func makeFixture() throws -> (
        store: SourceControlProviderConnectionStore,
        secrets: SourceControlMemorySecrets,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "SourceControlProviderConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let secrets = SourceControlMemorySecrets()
        return (
            SourceControlProviderConnectionStore(defaults: defaults, secrets: secrets),
            secrets,
            defaults,
            suite
        )
    }

    private func forgejoConnection(
        id: String,
        authenticationKind: ExtensionSourceControlAuthenticationKind = .authorizationToken
    ) -> SourceControlProviderConnection {
        SourceControlProviderConnection(
            id: id,
            extensionIdentifier: "dev.example.forge",
            providerID: "forgejo",
            remoteHost: "forge.example",
            baseOrigin: "https://forge.example",
            apiPathPrefix: "/api/v1",
            authenticationKind: authenticationKind
        )
    }

    private func forgejoDefinition() -> ExtensionSourceControlProviderDefinition {
        ExtensionSourceControlProviderDefinition(
            id: "forgejo",
            displayName: "Forgejo",
            changeRequestName: "pull request",
            changeRequestPluralName: "pull requests",
            apiPathPrefix: "/api/v1",
            authenticationKinds: [.authorizationToken, .none]
        )
    }
}

private actor SourceControlRequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private actor SourceControlRouteBroker: SourceControlConnectionFetching {
    struct Captured: Sendable {
        let request: ExtensionSourceControlFetchRequest
        let connection: SourceControlProviderConnection
        let credential: Data?
    }

    private(set) var captured: Captured?

    func fetch(
        _ request: ExtensionSourceControlFetchRequest,
        connection: SourceControlProviderConnection,
        definition: ExtensionSourceControlProviderDefinition,
        credential: Data?
    ) async -> Result<SourceControlConnectionFetchReading, SourceControlConnectionFetchFailure> {
        captured = Captured(
            request: request,
            connection: connection,
            credential: credential
        )
        return .success(SourceControlConnectionFetchReading(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data("{}".utf8),
            finalURL: "https://forge.example/api/v1/repos/team/project",
            usedCredential: true
        ))
    }
}

private final class SourceControlMemorySecrets: ExtensionSecretStoring, @unchecked Sendable {
    enum Failure: Error { case requested }

    private let lock = NSLock()
    private var values: [String: [String: Data]] = [:]
    var failWrites = false

    func data(extensionIdentifier: String, key: String) throws -> Data? {
        lock.withLock { values[extensionIdentifier]?[key] }
    }

    func setData(_ data: Data, extensionIdentifier: String, key: String) throws {
        try lock.withLock {
            if failWrites { throw Failure.requested }
            values[extensionIdentifier, default: [:]][key] = data
        }
    }

    func remove(extensionIdentifier: String, key: String) throws {
        lock.withLock { values[extensionIdentifier]?[key] = nil }
    }

    func keys(extensionIdentifier: String) throws -> [String] {
        lock.withLock { values[extensionIdentifier]?.keys.sorted() ?? [] }
    }
}
