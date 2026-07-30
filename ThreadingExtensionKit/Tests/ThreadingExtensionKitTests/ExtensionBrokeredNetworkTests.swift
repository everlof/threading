import XCTest
@testable import ThreadingExtensionKit

final class ExtensionBrokeredNetworkTests: XCTestCase {

    // MARK: - Capability

    func testTheCapabilityIsSafeForWebAssembly() {
        XCTAssertTrue(
            ThreadingExtensionAPI.safeCapabilities.contains(.networkBrokered),
            "a wasm manifest declaring network.brokered must pass bundle inspection"
        )
        XCTAssertEqual(ExtensionCapability.networkBrokered.rawValue, "network.brokered")
        XCTAssertFalse(
            ThreadingExtensionAPI.safeCapabilities.contains(.networkClient),
            "raw sockets stay out of the safe vocabulary"
        )
    }

    // MARK: - Manifest grants

    private func manifest(
        capabilities: Set<ExtensionCapability>,
        grants: [ExtensionNetworkGrant],
        companions: [ExtensionCompanion] = []
    ) -> ExtensionManifest {
        ExtensionManifest(
            identifier: "com.example.fetcher",
            name: "Fetcher",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/fetcher.wasm",
            capabilities: capabilities,
            companions: companions,
            networkGrants: grants
        )
    }

    func testAGrantedManifestValidatesAndRoundTrips() throws {
        let subject = manifest(
            capabilities: [.panels, .networkBrokered],
            grants: [
                ExtensionNetworkGrant(
                    host: "api.github.com",
                    methods: ["GET"],
                    credential: "github"
                )
            ]
        )
        try subject.validate()
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: JSONEncoder().encode(subject)
        )
        XCTAssertEqual(decoded, subject)
        XCTAssertEqual(decoded.networkGrants.first?.credential, "github")
    }

    func testAManifestWithoutGrantsStillDecodes() throws {
        let json = """
        {"formatVersion":1,"identifier":"com.example.plain","name":"Plain",\
        "version":"1.0.0","runtime":"webAssembly","executable":"bin/plain.wasm",\
        "capabilities":["panels"]}
        """
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.networkGrants, [])
        XCTAssertNoThrow(try decoded.validate())
    }

    func testGrantsRequireTheCapabilityAndViceVersa() {
        let grantsOnly = manifest(
            capabilities: [.panels],
            grants: [ExtensionNetworkGrant(host: "api.github.com", methods: ["GET"])]
        )
        XCTAssertThrowsError(try grantsOnly.validate())

        let capabilityOnly = manifest(capabilities: [.panels, .networkBrokered], grants: [])
        XCTAssertThrowsError(try capabilityOnly.validate())
    }

    func testHostileGrantsAreRefused() {
        let hostile: [ExtensionNetworkGrant] = [
            .init(host: "", methods: ["GET"]),
            .init(host: "API.github.com", methods: ["GET"]),
            .init(host: "api.github.com:8443", methods: ["GET"]),
            .init(host: "api.github.com/path", methods: ["GET"]),
            .init(host: "api..github.com", methods: ["GET"]),
            .init(host: "api.github.com", methods: []),
            .init(host: "api.github.com", methods: ["POST"]),
            .init(host: "api.github.com", methods: ["GET"], credential: "gitlab")
        ]
        for grant in hostile {
            let subject = manifest(capabilities: [.networkBrokered], grants: [grant])
            XCTAssertThrowsError(
                try subject.validate(),
                "\(grant) should not validate"
            )
        }
    }

    func testDuplicateGrantHostsAreRefused() {
        let subject = manifest(
            capabilities: [.networkBrokered],
            grants: [
                ExtensionNetworkGrant(host: "api.github.com", methods: ["GET"]),
                ExtensionNetworkGrant(host: "api.github.com", methods: ["HEAD"])
            ]
        )
        XCTAssertThrowsError(try subject.validate())
    }

    func testACredentialedGrantBesideANetworkCompanionIsRefused() {
        let companion = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            activation: .onDemand,
            capabilities: [.networkClient]
        )
        let credentialed = manifest(
            capabilities: [.networkBrokered, .companionOperations],
            grants: [
                ExtensionNetworkGrant(
                    host: "api.github.com",
                    methods: ["GET"],
                    credential: "github"
                )
            ],
            companions: [companion]
        )
        XCTAssertThrowsError(
            try credentialed.validate(),
            "a raw socket beside a credentialed grant is the exfiltration pairing"
        )

        let anonymous = manifest(
            capabilities: [.networkBrokered, .companionOperations],
            grants: [ExtensionNetworkGrant(host: "api.github.com", methods: ["GET"])],
            companions: [companion]
        )
        XCTAssertNoThrow(
            try anonymous.validate(),
            "without a credential there is nothing brokered worth exfiltrating"
        )
    }

    // MARK: - Fetch request validation

    func testAWellFormedFetchRequestValidates() {
        let request = ExtensionBrokeredFetchRequest(
            method: "GET",
            url: "https://api.github.com/repos/everlof/threading/commits/abc/check-runs?per_page=100",
            headers: ["Accept": "application/vnd.github+json"]
        )
        XCTAssertNoThrow(try request.validate())
    }

    func testHostileFetchRequestsAreRefused() {
        let hostile: [ExtensionBrokeredFetchRequest] = [
            .init(method: "POST", url: "https://api.github.com/x"),
            .init(method: "GET", url: "http://api.github.com/x"),
            .init(method: "GET", url: "https://api.github.com:8443/x"),
            .init(method: "GET", url: "https://user:pw@api.github.com/x"),
            .init(method: "GET", url: "not a url at all ://"),
            .init(
                method: "GET",
                url: "https://api.github.com/x",
                headers: ["Authorization": "Bearer stolen"]
            ),
            .init(
                method: "GET",
                url: "https://api.github.com/x",
                headers: ["Cookie": "session=1"]
            ),
            .init(
                method: "GET",
                url: "https://api.github.com/x",
                bodyBase64: "not-base64!!"
            )
        ]
        for request in hostile {
            XCTAssertThrowsError(
                try request.validate(),
                "\(request.method) \(request.url) \(request.headers) should not validate"
            )
        }
    }

    // MARK: - Result envelope

    func testAResponseRoundTripsWithBodyAndTier() throws {
        let body = Data("{\"total_count\":1}".utf8)
        let result = ExtensionBrokeredFetchResult(
            response: ExtensionBrokeredFetchResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                bodyBase64: body.base64EncodedString(),
                credential: "gh-cli"
            )
        )
        let decoded = try JSONDecoder().decode(
            ExtensionBrokeredFetchResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.response?.body, body)
        XCTAssertEqual(decoded.response?.credentialTier, .ghCLI)
        XCTAssertNil(decoded.failure)
    }

    func testAFailureCarriesAPresentableMessageAndTier() throws {
        let result = ExtensionBrokeredFetchResult(
            failure: ExtensionBrokeredFetchFailure(
                message: "The host could not reach api.github.com: timed out",
                credential: "anonymous"
            )
        )
        let decoded = try JSONDecoder().decode(
            ExtensionBrokeredFetchResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded.failure?.credentialTier, .anonymous)
        XCTAssertEqual(
            decoded.failure?.errorDescription,
            "The host could not reach api.github.com: timed out"
        )
        XCTAssertNil(decoded.response)
    }

    func testAnUnknownFutureTierStaysDecodableAndReportsNoTier() throws {
        let json = """
        {"protocolVersion":1,"response":{"status":200,"headers":{},\
        "bodyBase64":"","credential":"quantum-vault"}}
        """
        let decoded = try JSONDecoder().decode(
            ExtensionBrokeredFetchResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.response?.credential, "quantum-vault")
        XCTAssertNil(decoded.response?.credentialTier)
    }
}
