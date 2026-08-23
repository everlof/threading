import XCTest
@testable import Threading

@MainActor
final class PermissionRequestViewTests: XCTestCase {

    private final class LifetimeToken {}

    func testResolveReleasesDecisionHandlerAndCallsItOnce() {
        var card: PermissionRequestView!
        weak var handlerLifetime: LifetimeToken?
        var decisionCount = 0

        autoreleasepool {
            let lifetime = LifetimeToken()
            handlerLifetime = lifetime
            card = PermissionRequestView(request: makeRequest()) { [lifetime] _ in
                _ = lifetime
                decisionCount += 1
            }
        }

        XCTAssertNotNil(handlerLifetime)

        card.resolve(.deny(reason: "Test decision"))
        card.resolve(.deny(reason: "Duplicate decision"))

        XCTAssertEqual(decisionCount, 1)
        XCTAssertNil(handlerLifetime)
    }

    func testResolvedCardDoesNotRetainItselfThroughControllerStyleClosure() {
        weak var cardReference: PermissionRequestView?

        autoreleasepool {
            var card: PermissionRequestView?
            card = PermissionRequestView(request: makeRequest()) { _ in
                // Matches ConversationViewController's closure, which compares its local card.
                _ = card
            }
            cardReference = card
            card?.resolve(.deny(reason: "Test decision"))
        }

        XCTAssertNil(cardReference)
    }

    func testRemoteRequestIncludesTheEditDiffNeededForAnInformedDecision() {
        let request = PermissionRequest(
            sessionID: SessionID(),
            toolName: "Edit",
            input: [
                "file_path": "/tmp/App.swift",
                "old_string": "let old = true",
                "new_string": "let fixed = true",
            ]
        )
        let card = PermissionRequestView(request: request) { _ in }

        XCTAssertEqual(card.remoteRequest.toolName, "Edit")
        XCTAssertEqual(card.remoteRequest.filePath, "/tmp/App.swift")
        XCTAssertEqual(card.remoteRequest.diff.map(\.kind), [.removal, .addition])
    }

    func testRemoteDecisionMustMatchTheActiveCardAndSettlesOnlyOnce() {
        var decisions: [String] = []
        let card = PermissionRequestView(request: makeRequest()) { decision in
            switch decision {
            case .allow: decisions.append("allow")
            case .deny: decisions.append("deny")
            }
        }
        let id = card.remoteRequest.id

        XCTAssertFalse(card.resolveRemote(id: "stale-id", decision: .allow))
        XCTAssertTrue(card.resolveRemote(id: id, decision: .allow))
        XCTAssertFalse(card.resolveRemote(id: id, decision: .deny))
        XCTAssertEqual(decisions, ["allow"])
    }

    func testManagerDecisionMustMatchTheCardIsOneShotAndCarriesManagerAttribution() {
        var decisions: [PermissionDecision] = []
        let card = PermissionRequestView(request: makeRequest()) { decisions.append($0) }
        let id = card.remoteRequest.id

        XCTAssertFalse(card.resolveManager(id: "stale-id", decision: .allow))
        XCTAssertTrue(card.resolveManager(id: id, decision: .deny))
        XCTAssertFalse(card.resolveManager(id: id, decision: .allow))
        XCTAssertEqual(decisions.count, 1)
        guard case .deny(let reason) = decisions[0] else {
            return XCTFail("Expected a manager denial")
        }
        XCTAssertEqual(reason, "Declined by a user-appointed Threading manager.")
    }

    func testOversizedRemoteDiffRequiresReviewOnTheMac() {
        let request = PermissionRequest(
            sessionID: SessionID(),
            toolName: "Write",
            input: [
                "file_path": "/tmp/generated.swift",
                "content": .string(String(
                    repeating: "let generated = true // remote review evidence\n",
                    count: 4_000
                )),
            ]
        )
        var decisionCount = 0
        let card = PermissionRequestView(request: request) { _ in decisionCount += 1 }
        let remote = card.remoteRequest

        XCTAssertFalse(remote.canDecide)
        XCTAssertEqual(remote.unavailableReason, RemoteConversationWirePolicy.localReviewReason)
        XCTAssertTrue(remote.diff.isEmpty)
        XCTAssertFalse(card.resolveRemote(id: remote.id, decision: .allow))
        XCTAssertFalse(card.resolveManager(id: remote.id, decision: .allow))
        XCTAssertEqual(decisionCount, 0)
    }

    func testToolIdentityPreservesNamesItDoesNotKnow() {
        let tool = ToolIdentity("FutureProviderTool")

        XCTAssertEqual(tool, .unknown("FutureProviderTool"))
        XCTAssertEqual(tool.rawName, "FutureProviderTool")
    }

    func testPermissionPolicyAllowsOnlyKnownReadOnlyAndOwnedMCPTools() {
        XCTAssertTrue(PermissionPolicy.isAutoAllowed(.read))
        XCTAssertTrue(PermissionPolicy.isAutoAllowed(.mcp("mcp__threading__show_image")))
        XCTAssertFalse(PermissionPolicy.isAutoAllowed(.bash))
        XCTAssertFalse(PermissionPolicy.isAutoAllowed(.mcp("mcp__external__delete")))
        XCTAssertFalse(PermissionPolicy.isAutoAllowed(.unknown("FutureProviderTool")))
    }

    func testToolGlyphKeepsUnknownAndMCPNamesUseful() {
        let unknown = ToolGlyph.forTool(.unknown("FutureProviderTool"))
        let mcp = ToolGlyph.forTool(.mcp("mcp__web__query"))

        XCTAssertEqual(unknown.symbol, "•")
        XCTAssertEqual(unknown.label, "FutureProviderTool")
        XCTAssertEqual(mcp.symbol, "◇")
        XCTAssertEqual(mcp.label, "query")
    }

    private func makeRequest() -> PermissionRequest {
        PermissionRequest(sessionID: SessionID(), toolName: "Bash", input: ["command": "pwd"])
    }
}
