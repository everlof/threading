import Foundation
import XCTest
@testable import ThreadingRemoteKit

final class RemoteNotificationLocalizationTests: XCTestCase {

    func testLocalizedNotificationMetadataRoundTrips() throws {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .permissionRequest,
            hostID: "mac-1",
            sessionID: "session-1",
            title: "Build needs permission",
            body: "Bash is waiting. Open the chat to review the request.",
            titleLocalization: .init(
                key: "%@ needs permission",
                arguments: ["Build"]
            ),
            bodyLocalization: .init(
                key: "%@ is waiting. Open the chat to review the request.",
                arguments: ["Bash"]
            ),
            createdAt: 123
        )

        let decoded = try JSONDecoder().decode(
            RemoteNotificationEventDTO.self,
            from: JSONEncoder().encode(event)
        )

        XCTAssertEqual(decoded, event)
    }

    func testLegacyNotificationWithoutLocalizationMetadataStillDecodes() throws {
        let data = Data(
            """
            {
              "type": "notification",
              "id": "event-1",
              "kind": "sharedSession",
              "hostID": "mac-1",
              "sessionID": "session-1",
              "title": "Chat shared with you",
              "body": "Build",
              "createdAt": 123
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(RemoteNotificationEventDTO.self, from: data)

        XCTAssertNil(event.titleLocalization)
        XCTAssertNil(event.bodyLocalization)
        XCTAssertEqual(event.title, "Chat shared with you")
    }
}
