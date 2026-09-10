import Foundation
@testable import ForgejoSourceControlExtensionSupport
import ThreadingExtensionKit
import XCTest

final class ForgejoSourceControlExtensionTests: XCTestCase {
    func testManifestPinsAReadOnlyProviderWithoutStaticNetworkAuthority() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Examples/ForgejoSourceControlExtension/threading-extension.json"
            )
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(decoded, ForgejoSourceControlExtensionContract.manifest)
        XCTAssertEqual(decoded.capabilities, [.sourceControlRead])
        XCTAssertEqual(decoded.networkGrants, [])
        XCTAssertEqual(
            decoded.sourceControlProviders,
            ForgejoSourceControlExtensionContract.registration.sourceControlProviders
        )
        XCTAssertFalse(decoded.capabilities.contains(.panels))
        XCTAssertFalse(decoded.capabilities.contains(.componentCustomization))
        try decoded.validate()
        try ForgejoSourceControlExtensionContract.registration.validate(for: decoded)
    }

    func testPathComponentsAreEncodedExactlyOnce() {
        XCTAssertEqual(
            ForgejoPath.component("space/%2F/☃"),
            "space%2F%252F%2F%E2%98%83"
        )
    }

    func testDiscoveryNormalizesLifecycleChecksAndLatestReviewPerUser() async throws {
        let host = ForgejoTestHost(responses: [
            "/repos/team/repo": response(json: [
                "default_branch": "main"
            ]),
            "/repos/team/repo/pulls": response(json: [[
                "number": 42,
                "title": "A typed provider boundary",
                "html_url": "https://forge.example/team/repo/pulls/42",
                "state": "open",
                "draft": true,
                "merged": false,
                "updated_at": "2026-09-10T10:00:00Z",
                "base": ["ref": "main", "sha": "base"],
                "head": ["ref": "feature/providers", "sha": "abc123"],
                "requested_reviewers": [["login": "carol"]]
            ]]),
            "/repos/team/repo/commits/abc123/statuses": response(
                json: [
                    ["context": "ci", "status": "failure", "updated_at": "2026-09-10T08:00:00Z"],
                    ["context": "ci", "status": "success", "updated_at": "2026-09-10T09:00:00Z"],
                    ["context": "lint", "status": "warning", "updated_at": "2026-09-10T09:00:00Z"],
                    ["context": "deploy", "status": "pending", "updated_at": "2026-09-10T09:00:00Z"],
                    ["context": "future", "status": "queued", "updated_at": "2026-09-10T09:00:00Z"]
                ],
                headers: ["link": "<https://forge.example/next>; rel=\"next\""]
            ),
            "/repos/team/repo/pulls/42/reviews": response(json: [
                review("alice", state: "APPROVED", at: "2026-09-10T08:00:00Z"),
                review("alice", state: "REQUEST_CHANGES", at: "2026-09-10T09:00:00Z"),
                review("bob", state: "APPROVED", at: "2026-09-10T09:00:00Z")
            ])
        ])
        let provider = ForgejoSourceControlProvider(host: host)
        let result = await provider.handle(.init(
            requestID: "request-1",
            providerID: "forgejo",
            connectionID: "connection-1",
            operation: .discover,
            repository: .init(
                host: "forge.example",
                namespace: "team",
                name: "repo",
                branch: "feature/providers",
                headRevision: "abc123"
            )
        ))

        try result.validate()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.defaultBranch, "main")
        XCTAssertEqual(result.changeRequest?.number, 42)
        XCTAssertEqual(result.changeRequest?.lifecycle.normalized, .draft)
        XCTAssertEqual(result.changeRequest?.checks, .init(
            successful: 1,
            nonBlocking: 1,
            active: 1,
            needsAttention: 0,
            unknown: 1,
            isIncomplete: true
        ))
        XCTAssertEqual(result.changeRequest?.reviews, .init(
            approvals: 1,
            changesRequested: 1,
            requested: 1
        ))

        let requests = await host.requests()
        XCTAssertEqual(Set(requests.map(\.connectionID)), ["connection-1"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["Accept"] == "application/json" })
        XCTAssertEqual(Set(requests.map(\.path)), [
            "/repos/team/repo",
            "/repos/team/repo/pulls",
            "/repos/team/repo/commits/abc123/statuses",
            "/repos/team/repo/pulls/42/reviews"
        ])
    }

    func testClosedPullMustMatchTheExactHeadRevision() async {
        let host = ForgejoTestHost(responses: [
            "/repos/team/repo": response(json: ["default_branch": "main"]),
            "/repos/team/repo/pulls": response(json: [[
                "number": 12,
                "title": "Old branch review",
                "html_url": "https://forge.example/team/repo/pulls/12",
                "state": "closed",
                "draft": false,
                "merged": false,
                "updated_at": "2026-09-09T10:00:00Z",
                "base": ["ref": "main", "sha": "base"],
                "head": ["ref": "feature/providers", "sha": "old-head"]
            ]])
        ])
        let result = await ForgejoSourceControlProvider(host: host).handle(.init(
            requestID: "request-2",
            providerID: "forgejo",
            connectionID: "connection-1",
            operation: .discover,
            repository: .init(
                host: "forge.example",
                namespace: "team",
                name: "repo",
                branch: "feature/providers",
                headRevision: "new-head"
            )
        ))

        XCTAssertNil(result.error)
        XCTAssertNil(result.changeRequest)
        XCTAssertEqual(result.defaultBranch, "main")
        let requests = await host.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testSourceControlWireRejectsAuthorityAndAmbiguousPaths() {
        XCTAssertThrowsError(try ExtensionSourceControlFetchRequest(
            connectionID: "connection-1",
            path: "https://attacker.example/api/v1/repos"
        ).validate())
        XCTAssertThrowsError(try ExtensionSourceControlFetchRequest(
            connectionID: "connection-1",
            path: "/repos/team/%2Fadmin"
        ).validate())
        XCTAssertThrowsError(try ExtensionSourceControlFetchRequest(
            connectionID: "connection-1",
            path: "/repos/team/repo",
            headers: ["Authorization": "stolen"]
        ).validate())
        XCTAssertThrowsError(try ExtensionSourceControlFetchRequest(
            connectionID: "connection-1",
            path: "/repos/team/repo",
            headers: ["X-Bad\r\nHeader": "value"]
        ).validate())
        XCTAssertThrowsError(try ExtensionSourceControlFetchRequest(
            connectionID: "connection-1",
            path: "/repos/team/repo",
            headers: ["Accept": "application/json\r\nAuthorization: stolen"]
        ).validate())
    }
}

private actor ForgejoTestHost: ForgejoSourceControlHost {
    private let responses: [String: ExtensionSourceControlFetchResponse]
    private var captured: [ExtensionSourceControlFetchRequest] = []

    init(responses: [String: ExtensionSourceControlFetchResponse]) {
        self.responses = responses
    }

    func fetch(
        _ request: ExtensionSourceControlFetchRequest
    ) async throws -> ExtensionSourceControlFetchResponse {
        captured.append(request)
        guard let response = responses[request.path] else {
            return response(status: 404, json: [:])
        }
        return response
    }

    func requests() -> [ExtensionSourceControlFetchRequest] { captured }
}

private func response(
    status: Int = 200,
    json: Any,
    headers: [String: String] = [:]
) -> ExtensionSourceControlFetchResponse {
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    return .init(
        status: status,
        headers: headers,
        bodyBase64: data.base64EncodedString(),
        credential: "host-attached",
        finalURL: "https://forge.example/api/v1"
    )
}

private func review(_ login: String, state: String, at: String) -> [String: Any] {
    [
        "state": state,
        "dismissed": false,
        "stale": false,
        "submitted_at": at,
        "updated_at": at,
        "user": ["login": login]
    ]
}
