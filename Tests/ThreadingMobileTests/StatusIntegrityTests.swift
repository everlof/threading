import ThreadingRemoteKit
import XCTest

@testable import ThreadingMobile

@MainActor
final class StatusIntegrityTests: XCTestCase {
    func testSessionSocketDeliversAndReplaysItsCanonicalPostVisitRow() throws {
        let session = summary(id: "session-a", state: .needsAttention)
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: try XCTUnwrap(
                RemoteConnectionLink(string: "https://example.invalid/#status-test")
            ))
        )
        let visit = RemoteSessionVisitedDTO(
            session: summary(id: session.id, state: .idle),
            revision: .init(epoch: "host-a", revision: 8),
            receiptCommitted: true
        )

        connection.receiveServerTextForTesting(try encoded(visit))
        var received: [RemoteSessionVisitedDTO] = []
        connection.onSessionVisited = { received.append($0) }

        XCTAssertEqual(received, [visit], "a warmed socket replays settlement to its late view")

        let anotherSession = RemoteSessionVisitedDTO(
            session: summary(id: "session-b", state: .idle),
            revision: .init(epoch: "host-a", revision: 9),
            receiptCommitted: true
        )
        connection.receiveServerTextForTesting(try encoded(anotherSession))
        XCTAssertEqual(received, [visit], "one session socket cannot settle another row")
    }

    func testOriginatingPhoneAppliesVisitWithoutWaitingForDashboardEvents() throws {
        let model = RemoteAppModel()
        model.startDemo()
        let hostID = try XCTUnwrap(model.activeHostID)
        let original = try XCTUnwrap(model.me?.sessions.first)
        let replacementState: RemoteSessionActivity = original.state == .needsAttention
            ? .idle
            : .needsAttention
        let visit = RemoteSessionVisitedDTO(
            session: summary(id: original.id, state: replacementState),
            revision: .init(epoch: "visit", revision: 1),
            receiptCommitted: true
        )

        model.acceptSessionVisit(visit, from: "another-host")
        XCTAssertEqual(model.dashboardSession(id: original.id)?.state, original.state)

        model.acceptSessionVisit(visit, from: hostID)
        XCTAssertEqual(model.dashboardSession(id: original.id)?.state, replacementState)
    }

    func testVisitEnvelopeDoesNotConsumeEstablishedScalarRevisionFrames() throws {
        let session = summary(id: "session-a", state: .working)
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: try XCTUnwrap(
                RemoteConnectionLink(string: "https://example.invalid/#revision-test")
            ))
        )
        let update = RemoteRunPlanUpdateDTO(
            revision: 4,
            plan: .init(
                activeTitle: "Verify",
                current: 1,
                completed: 0,
                active: 1,
                total: 1
            )
        )

        connection.receiveServerTextForTesting(try encoded(update))

        XCTAssertEqual(connection.runPlan?.activeTitle, "Verify")
    }

    private func summary(
        id: String,
        state: RemoteSessionActivity
    ) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: id,
            title: id,
            agentKind: "codex",
            surface: .conversation,
            state: state,
            attention: .init(
                knowledge: state == .needsAttention ? .unread : .read,
                completionGeneration: 1,
                seenGeneration: state == .needsAttention ? 0 : 1
            ),
            projectName: "Threading"
        )
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
