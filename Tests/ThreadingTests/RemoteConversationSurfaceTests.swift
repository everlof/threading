import XCTest
@testable import Threading

@MainActor
final class RemoteConversationSurfaceTests: XCTestCase {
    func testRemoteTransportConsumesOnlyTheTypedConversationCapability() {
        let snapshot = RemoteConversationSnapshotDTO(rows: [], canSend: true)
        let revision = RemoteConversationRowsRevision(generation: UUID(), value: 7)
        let surface = RecordingSurface(
            projection: RemoteConversationProjection(
                snapshot: snapshot,
                rowsRevision: revision
            )
        )
        let authorization = RemoteAuthorization(
            shareID: "surface-test",
            capability: .interact,
            scope: .allSessions
        )

        let erased: any RemoteConversationSurface = surface
        XCTAssertEqual(erased.remoteSnapshot, snapshot)
        XCTAssertEqual(erased.remoteProjection.rowsRevision, revision)
        XCTAssertTrue(erased.isRunning)
        XCTAssertTrue(erased.sendRemotePrompt(
            "send through the ordinary conversation path",
            context: [],
            authorization: authorization
        ))
        XCTAssertEqual(surface.submissions, [
            .init(
                text: "send through the ordinary conversation path",
                context: [],
                authorization: authorization
            )
        ])
    }

    private final class RecordingSurface: RemoteConversationSurface {
        struct Submission: Equatable {
            let text: String
            let context: [ConversationContextAttachment]
            let authorization: RemoteAuthorization
        }

        let isRunning = true
        let remoteProjection: RemoteConversationProjection
        private(set) var submissions: [Submission] = []

        init(projection: RemoteConversationProjection) {
            remoteProjection = projection
        }

        func sendRemotePrompt(
            _ text: String,
            context: [ConversationContextAttachment],
            authorization: RemoteAuthorization
        ) -> Bool {
            submissions.append(.init(
                text: text,
                context: context,
                authorization: authorization
            ))
            return true
        }
    }
}
