import XCTest
@testable import Threading

final class AgentSessionRowPresentationTests: XCTestCase {
    func testUserRenameWinsWhenAgentTitlesAreEnabledOrDisabled() {
        var session = AgentSession(kind: .claude, title: "Prompt title")
        session.agentTitle = "Agent title"
        session.customTitle = "My title — 日本語 👩🏽‍💻"
        for enabled in [true, false] {
            XCTAssertEqual(row(session, agentTitles: enabled).title, session.customTitle)
        }
    }

    func testAgentTitlePreferenceAndEmptySourcesFallThroughInOrder() {
        var session = AgentSession(kind: .claude, title: "Prompt title")
        session.agentTitle = "Agent title"
        session.customTitle = ""
        XCTAssertEqual(row(session).title, "Agent title")
        XCTAssertEqual(row(session, agentTitles: false).title, "Prompt title")
        session.agentTitle = ""
        XCTAssertEqual(row(session).title, "Prompt title")
        session.title = ""
        XCTAssertEqual(row(session).title, "Host fallback")
        session.agentTitle = "Agent title"
        XCTAssertEqual(row(session, agentTitles: false).title, "Host fallback")
    }

    func testProjectionPreservesIdentityAndLeavesBoundsAndWhitespaceToRenderer() {
        var session = AgentSession(kind: .codex, title: "Prompt title",
                                   accountHandle: .named("codex-work"))
        session.customTitle = "  " + String(repeating: "日本語e\u{301}👩🏽‍💻", count: 80) + "\n"
        let presentation = row(session)
        XCTAssertEqual(presentation.id, session.id)
        XCTAssertEqual(presentation.kind, session.kind)
        XCTAssertEqual(presentation.accountHandle, session.accountHandle)
        XCTAssertEqual(presentation.title, session.customTitle)
        session.customTitle = " "
        XCTAssertEqual(row(session).title, " ")
    }

    func testNewlyAdmittedProjectionMatchesFreshStoredRecord() throws {
        for kind in AgentKind.allCases {
            let session = try XCTUnwrap(AgentSessionCreation.makeRecord(kind: kind))
            XCTAssertEqual(
                AgentSessionRowPresentation.unnamed(id: session.id, kind: kind,
                    accountHandle: session.accountHandle, untitledTitle: "Host fallback"),
                row(session)
            )
        }
    }

    private func row(_ session: AgentSession, agentTitles: Bool = true) -> AgentSessionRowPresentation {
        AgentSessionRowPresentation(session: session, usesAgentTitle: agentTitles,
                                    untitledTitle: "Host fallback")
    }
}
