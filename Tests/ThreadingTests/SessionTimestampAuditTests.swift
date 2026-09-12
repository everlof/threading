import AppKit
import XCTest
@testable import Threading

/// Opposing process/work timestamps reproduce the original cross-surface recency defects.
@MainActor
final class SessionTimestampAuditTests: XCTestCase {
    func testMacRecentOrderUsesWorkTime() {
        let (worked, relaunched) = sessions()
        var project = Project(name: "Audit", folderURL: URL(fileURLWithPath: "/tmp/recency-audit"))
        project.sessions = [relaunched, worked]
        let options = NativeSidebarPipelineOptionValues(
            sessionOrder: .recentActivity, sessionOrderReversed: false,
            branchGrouping: false, loneBranchHeadings: false, compactTree: false,
            groupByFact: nil, sortByFact: nil
        )
        let roots = SidebarTreeBuilder.rootNodes(from: [project], optionValues: options)
        XCTAssertEqual(sessionIDs(in: roots), [worked.id, relaunched.id])
    }

    func testRunningAtLastQuitPrioritizesRecentlyWorkedConversation() {
        let (worked, relaunched) = sessions()
        let result = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit, recorded: [relaunched.id, worked.id],
            sessions: [relaunched, worked]
        )
        XCTAssertEqual(result.sessionIDs, [worked.id, relaunched.id])
    }

    private func sessions() -> (AgentSession, AgentSession) {
        var worked = AgentSession(kind: .claude, title: "Recent work")
        worked.lastActiveAt = Date(timeIntervalSince1970: 100)
        worked.lastTurnAt = Date(timeIntervalSince1970: 150)
        worked.lastWorkAt = Date(timeIntervalSince1970: 900)
        var relaunched = AgentSession(kind: .claude, title: "Old work, recent launch")
        relaunched.lastActiveAt = Date(timeIntervalSince1970: 1_000)
        relaunched.lastTurnAt = Date(timeIntervalSince1970: 200)
        return (worked, relaunched)
    }

    private func sessionIDs(in nodes: [NSObject]) -> [SessionID] {
        nodes.flatMap { node in
            let own = (node as? SessionNode).map { [$0.sessionID] } ?? []
            return own + sessionIDs(in: SidebarTreeBuilder.children(of: node))
        }
    }
}
