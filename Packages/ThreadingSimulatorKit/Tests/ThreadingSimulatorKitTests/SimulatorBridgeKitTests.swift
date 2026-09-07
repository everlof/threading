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
            // A peer that requires a version newer than ours is out of reach. (Our `current` is
            // now 2, so the too-new peer must ask for at least 3.)
            SimulatorBridgeCompatibility.evaluate(peerVersion: 3, peerMinimum: 3),
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

    func testSixtyFPSStressKeepsOnlyOutstandingAndLatestPendingFrame() {
        var window = SimulatorLatestFrameWindow<Int>()
        var lastSent = 0
        var replaced = 0
        var maximumPending = 0

        for sequence in 1...3_600 {
            switch window.offer(sequence, sequence: UInt64(sequence)) {
            case .send(let frame):
                lastSent = frame
            case .held(let didReplace):
                if didReplace { replaced += 1 }
            }
            XCTAssertLessThanOrEqual(window.pendingFrameCount, 1)
            maximumPending = max(maximumPending, window.pendingFrameCount)

            if sequence.isMultiple(of: 12),
               let next = window.acknowledge(sequence: UInt64(lastSent)) {
                lastSent = next
            }
        }

        XCTAssertTrue(window.hasOutstandingFrame)
        XCTAssertEqual(maximumPending, 1)
        XCTAssertEqual(window.pendingFrameCount, 0)
        XCTAssertGreaterThan(replaced, 3_000)
    }

    func testKeyboardVocabularyMatchesBoundedUSKeyboardTransport() {
        XCTAssertTrue(SimulatorBridgeText.isSupported(
            "AZaz09 !@#$%^&*()_+-=[]{}\\|;:'\",.<>/?`~\t\n\u{8}"
        ))
        XCTAssertFalse(SimulatorBridgeText.isSupported("nul\u{0}"))
        XCTAssertFalse(SimulatorBridgeText.isSupported("Hej 👋"))
        XCTAssertFalse(SimulatorBridgeText.isSupported(
            String(repeating: "a", count: SimulatorBridgeText.maximumCharacterCount + 1)
        ))
    }
}
