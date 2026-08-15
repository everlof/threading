import Foundation
import XCTest
@testable import ThreadingDomain

final class IdentifiersTests: XCTestCase {
    func testTypedUUIDsPreserveTheirSingleValueEncoding() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try encoder.encode(ProjectID(uuid)), try encoder.encode(uuid))
        XCTAssertEqual(try encoder.encode(SessionID(uuid)), try encoder.encode(uuid))
        XCTAssertEqual(try encoder.encode(TerminalID(uuid)), try encoder.encode(uuid))
        XCTAssertEqual(try decoder.decode(ProjectID.self, from: encoder.encode(uuid)), ProjectID(uuid))
        XCTAssertEqual(try decoder.decode(SessionID.self, from: encoder.encode(uuid)), SessionID(uuid))
        XCTAssertEqual(try decoder.decode(TerminalID.self, from: encoder.encode(uuid)), TerminalID(uuid))
    }

    func testProviderIdentityPreservesItsLegacyStringAndPathSafety() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let safe = TranscriptID("provider-thread")

        XCTAssertEqual(try encoder.encode(safe), try encoder.encode("provider-thread"))
        XCTAssertEqual(
            try decoder.decode(TranscriptID.self, from: encoder.encode("provider-thread")),
            safe
        )
        XCTAssertTrue(safe.isSafePathComponent)
        XCTAssertFalse(TranscriptID("../outside").isSafePathComponent)
        XCTAssertFalse(TranscriptID(String(repeating: "a", count: 256)).isSafePathComponent)
    }

    func testTerminalIdentityNamespacesNonSessionHistory() {
        let uuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sessionID = SessionID(uuid)
        let terminalID = TerminalID(uuid)

        XCTAssertEqual(TerminalInstanceIdentity.agentSession(sessionID).historyFileStem, uuid.uuidString)
        XCTAssertEqual(
            TerminalInstanceIdentity.projectTerminal(terminalID).historyFileStem,
            "terminal-\(uuid.uuidString)"
        )
        XCTAssertEqual(
            TerminalInstanceIdentity.sessionShell(sessionID).ownerSessionID,
            sessionID
        )
        XCTAssertTrue(TerminalInstanceIdentity.recognizesHistoryFileStem("shell-\(uuid.uuidString)"))
        XCTAssertFalse(TerminalInstanceIdentity.recognizesHistoryFileStem("shell-not-a-uuid"))
    }

    func testAccountHandleDistinguishesStandardFromNamedAccounts() {
        XCTAssertEqual(AccountHandle(storedName: nil), .standard)
        XCTAssertEqual(AccountHandle(storedName: "default"), .standard)
        XCTAssertNil(AccountHandle.standard.persistedSessionName)
        XCTAssertEqual(AccountHandle(storedName: "work"), .named("work"))
        XCTAssertEqual(AccountHandle.named("work").persistedSessionName, "work")
    }
}
