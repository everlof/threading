import XCTest
@testable import ThreadingSimulatorKit

final class SimulatorAccessibilityElementTests: XCTestCase {
    func testElementSurvivesACodableRoundTrip() throws {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            subrole: nil,
            label: "Kronaby",
            value: nil,
            identifier: nil,
            enabled: true,
            frame: .init(x: 0, y: 0, width: 402, height: 874),
            children: [
                SimulatorAccessibilityElement(
                    role: "AXButton",
                    label: "Try notification backend",
                    identifier: "cta",
                    enabled: false,
                    frame: .init(x: 346, y: 66, width: 36, height: 36)
                )
            ]
        )

        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(SimulatorAccessibilityElement.self, from: data)

        XCTAssertEqual(decoded, root)
        XCTAssertEqual(decoded.children.first?.identifier, "cta")
        XCTAssertEqual(decoded.children.first?.enabled, false)
    }

    func testSnapshotWireMessagesRoundTrip() throws {
        let request = UUID()
        let client = SimulatorBridgeClientMessage.accessibilitySnapshot(requestID: request)
        let clientData = try JSONEncoder().encode(client)
        XCTAssertEqual(
            try JSONDecoder().decode(SimulatorBridgeClientMessage.self, from: clientData),
            client
        )

        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 402, height: 874)
        )
        let reply = SimulatorBridgeHelperMessage.accessibilitySnapshotResult(
            requestID: request, root: root, error: nil
        )
        let replyData = try JSONEncoder().encode(reply)
        XCTAssertEqual(
            try JSONDecoder().decode(SimulatorBridgeHelperMessage.self, from: replyData),
            reply
        )

        let failure = SimulatorBridgeHelperMessage.accessibilitySnapshotResult(
            requestID: request, root: nil, error: "automation off"
        )
        let failureData = try JSONEncoder().encode(failure)
        XCTAssertEqual(
            try JSONDecoder().decode(SimulatorBridgeHelperMessage.self, from: failureData),
            failure
        )
    }

    func testFrameCentresAreComputedFromOriginAndSize() {
        let frame = SimulatorAccessibilityElement.Frame(x: 346, y: 66, width: 36, height: 36)
        XCTAssertEqual(frame.midX, 364)
        XCTAssertEqual(frame.midY, 84)
    }
}
