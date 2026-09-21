import XCTest
@testable import Threading

final class AgentSessionCreationTests: XCTestCase {
    func testFreshRecordsPreserveCapabilityAdmissionAndUnnamedPolicy() throws {
        for kind in AgentKind.allCases {
            let id = SessionID()
            let record = try XCTUnwrap(AgentSessionCreation.makeRecord(kind: kind, usesNativeUI: true, id: id))
            XCTAssertEqual(record.id, id)
            XCTAssertEqual(record.title, "")
            XCTAssertEqual(record.usesNativeUI, kind.supportsNativeUI)
            XCTAssertEqual(record.resumeState, .initial(for: kind))
            XCTAssertFalse(record.hasLaunched)
            XCTAssertNil(record.branch)
            XCTAssertEqual(AgentSessionCreation.makeRecord(kind: kind, accountHandle: .named("work")) != nil,
                           kind.supportsAccounts)
            XCTAssertEqual(AgentSessionCreation.makeRecord(kind: kind, permissionMode: .manual) != nil,
                           kind.supportsPermissionModes)
        }
    }

    func testHandoffRefusesWrongIdentityAndRuntimeBeforeRecordPreconditions() throws {
        let id = SessionID()
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(sessionID: SessionID(), kind: .claude, model: nil, title: nil),
            ConversationHandoffEndpoint(sessionID: id, kind: .codex, model: nil, title: nil)
        ]))
        XCTAssertNil(AgentSessionCreation.makeRecord(kind: .codex, handoff: handoff))
        XCTAssertNil(AgentSessionCreation.makeRecord(kind: .grok, handoff: handoff, id: id))
        let record = try XCTUnwrap(AgentSessionCreation.makeRecord(kind: .codex, model: "model",
            reasoningEffort: "high", fastMode: true, permissionMode: .manual,
            title: "User title", handoff: handoff, id: id))
        XCTAssertEqual(record.handoff, handoff)
        XCTAssertEqual(record.title, "User title")
        XCTAssertEqual(record.model, "model")
        XCTAssertEqual(record.reasoningEffort, "high")
        XCTAssertEqual(record.fastMode, true)
        XCTAssertEqual(record.permissionMode, .manual)
    }
}
