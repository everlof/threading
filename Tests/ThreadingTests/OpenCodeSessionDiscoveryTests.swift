import XCTest
@testable import Threading

final class OpenCodeSessionDiscoveryTests: XCTestCase {

    func testSelectsNewestSessionCreatedForThisCheckout() throws {
        let launchedAt = Date(timeIntervalSince1970: 2_000)
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "id": "ses_old",
                "created": 1_000_000,
                "directory": "/tmp/project"
            ],
            [
                "id": "ses_other_checkout",
                "created": 2_001_000,
                "directory": "/tmp/other"
            ],
            [
                "id": "ses_newer",
                "created": 2_002_000,
                "directory": "/tmp/project"
            ],
            [
                "id": "ses_newest",
                "created": 2_003_000,
                "directory": "/tmp/project"
            ]
        ])

        XCTAssertEqual(
            OpenCodeSessionDiscovery.sessionID(
                in: data,
                projectPath: "/tmp/project/.",
                launchedAt: launchedAt
            ),
            TranscriptID("ses_newest")
        )
    }

    func testRejectsMalformedOldAndNonSessionRecords() throws {
        let launchedAt = Date(timeIntervalSince1970: 2_000)
        let records: [[[String: Any]]] = [
            [["id": "ses_old", "created": 1_000_000, "directory": "/tmp/project"]],
            [["id": "not-a-session", "created": 2_001_000, "directory": "/tmp/project"]],
            [["id": "ses_missing_directory", "created": 2_001_000]]
        ]

        for record in records {
            let data = try JSONSerialization.data(withJSONObject: record)
            XCTAssertNil(OpenCodeSessionDiscovery.sessionID(
                in: data,
                projectPath: "/tmp/project",
                launchedAt: launchedAt
            ))
        }
        XCTAssertNil(OpenCodeSessionDiscovery.sessionID(
            in: Data("not json".utf8),
            projectPath: "/tmp/project",
            launchedAt: launchedAt
        ))
    }

    func testOpenCodeSessionRoundTripsAsTerminalOnly() throws {
        var session = AgentSession(kind: .openCode, title: "OpenRouter")
        session.model = "openrouter/x-ai/grok-4"
        session.resumeState = .resumable(TranscriptID("ses_round_trip"))

        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(restored.kind, .openCode)
        XCTAssertEqual(restored.model, "openrouter/x-ai/grok-4")
        XCTAssertEqual(restored.resumeState, .resumable(TranscriptID("ses_round_trip")))
        XCTAssertFalse(restored.usesNativeUI)
        XCTAssertFalse(restored.kind.supportsAccounts)
        XCTAssertFalse(restored.kind.supportsPermissionModes)
        XCTAssertFalse(restored.kind.supportsThreadingBridge)
    }
}
