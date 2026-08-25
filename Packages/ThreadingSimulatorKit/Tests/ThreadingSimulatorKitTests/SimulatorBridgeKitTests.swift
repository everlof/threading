import XCTest
@testable import ThreadingSimulatorKit

final class SimulatorBridgeKitTests: XCTestCase {
    func testCompatibilityIsDirectional() {
        XCTAssertEqual(
            SimulatorBridgeCompatibility.evaluate(peerVersion: 1, peerMinimum: 1),
            .compatible
        )
        XCTAssertEqual(
            SimulatorBridgeCompatibility.evaluate(peerVersion: 0, peerMinimum: 0),
            .peerTooOld
        )
        XCTAssertEqual(
            SimulatorBridgeCompatibility.evaluate(peerVersion: 2, peerMinimum: 2),
            .selfTooOld
        )
    }

    func testControlMessagesRoundTrip() throws {
        let message = SimulatorBridgeClientMessage.input(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            command: .drag(
                fromX: 0.1,
                fromY: 0.2,
                toX: 0.8,
                toY: 0.9,
                durationMilliseconds: 350
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SimulatorBridgeClientMessage.self,
                from: JSONEncoder().encode(message)
            ),
            message
        )
    }

    func testMediaFrameAndH264ConfigurationRoundTrip() throws {
        let configuration = try SimulatorBridgeH264Configuration.encode(
            sequenceParameterSet: Data([1, 2, 3]),
            pictureParameterSet: Data([4, 5])
        )
        let frame = SimulatorBridgeMediaFrame(
            sequence: 42,
            presentationTimeNanoseconds: 1_000_000,
            width: 1206,
            height: 2622,
            codec: .h264,
            isKeyFrame: true,
            codecConfiguration: configuration,
            bytes: Data([9, 8, 7])
        )
        XCTAssertEqual(try SimulatorBridgeMediaFrame.decode(frame.encode()), frame)
        let decoded = try SimulatorBridgeH264Configuration.decode(configuration)
        XCTAssertEqual(decoded.sequence, Data([1, 2, 3]))
        XCTAssertEqual(decoded.picture, Data([4, 5]))
    }

    func testDecoderRefusesOversizeBeforeBufferingPayload() {
        var header = Data([SimulatorBridgeFrameKind.control.rawValue, 0, 0, 0])
        let length = UInt32(SimulatorBridgeFramingDefaults.maximumControlBytes + 1)
        for shift in stride(from: 0, through: 24, by: 8) {
            header.append(UInt8(truncatingIfNeeded: length >> UInt32(shift)))
        }
        var decoder = SimulatorBridgeFrameDecoder()
        XCTAssertEqual(
            decoder.accept(header),
            .refused(.oversized(kind: .control, length: length))
        )
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }
}
