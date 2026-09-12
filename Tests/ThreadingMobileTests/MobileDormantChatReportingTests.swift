import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// What the phone says about a chat whose agent is no longer running on the Mac.
///
/// Filed from a shake report on 12 Sep 2026: "This chat opened now, but last time it said 'this
/// chat closed on the Mac' or smth, which obviously isn't true." The diagnostics showed a parked
/// socket being pushed back into a chat, the Mac answering `ended` 72 ms later, and the same chat
/// opening normally 8 seconds afterwards. The chat had never closed — its agent had stopped, and
/// the host had one word for both.
@MainActor
final class MobileDormantChatReportingTests: XCTestCase {

    func testADormantChatIsNotReportedAsClosed() throws {
        let connection = makeConnection()

        connection.receiveServerTextForTesting(#"{"type":"ended","reason":"sessionDormant"}"#)

        let status = try XCTUnwrap(endedStatus(connection))
        XCTAssertEqual(status, MobileL10n.string("Reopen to resume on your Mac"))
        XCTAssertNotEqual(
            status,
            MobileL10n.string("Session closed on Mac"),
            "a chat the next tap reopens has not closed"
        )
    }

    func testAChatThatReallyWentStillSaysSo() throws {
        let connection = makeConnection()

        connection.receiveServerTextForTesting(#"{"type":"ended","reason":"sessionClosed"}"#)

        XCTAssertEqual(endedStatus(connection), MobileL10n.string("Session closed on Mac"))
    }

    /// An older Mac knows only `sessionClosed`, and a newer one may learn further reasons. Either
    /// way the phone must land on a phrase rather than on an empty status line.
    func testAnUnknownReasonStillEndsWithSomethingToRead() throws {
        let connection = makeConnection()

        connection.receiveServerTextForTesting(#"{"type":"ended","reason":"somethingLater"}"#)

        XCTAssertEqual(endedStatus(connection), MobileL10n.string("Session ended"))
    }

    private func endedStatus(_ connection: RemoteSessionConnection) -> String? {
        guard case let .ended(status) = connection.phase else { return nil }
        return status
    }

    private func makeConnection() -> RemoteSessionConnection {
        RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: UUID().uuidString.lowercased(),
                title: "Fixture",
                agentKind: "claude",
                surface: .terminal,
                state: .idle,
                projectName: "Fixture"
            ),
            client: RemoteClient(link: RemoteConnectionLink(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                token: "dormant-chat-reporting-token"
            )!)
        )
    }
}
