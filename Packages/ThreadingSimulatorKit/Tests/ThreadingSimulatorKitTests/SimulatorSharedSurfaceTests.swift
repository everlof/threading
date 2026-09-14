import XCTest
@testable import ThreadingSimulatorKit

final class SimulatorSharedSurfaceTests: XCTestCase {
    func testProtocolAdvertisesSharedMemoryVersion() {
        // Shared memory arrived in v2; the protocol only moves forward, so assert the capability
        // floor rather than the exact current version — that keeps this test from rotting every
        // time a later, unrelated capability (v3's accessibility snapshot, …) bumps `current`.
        XCTAssertGreaterThanOrEqual(SimulatorBridgeProtocol.current, 2)
        XCTAssertEqual(SimulatorBridgeProtocol.minimumSupported, 1)
        // A v1 peer and a v2 peer still negotiate: neither is below the other's minimum.
        XCTAssertEqual(SimulatorBridgeCompatibility.evaluate(peerVersion: 1, peerMinimum: 1), .compatible)
    }

    func testSharedTransportControlMessagesRoundTrip() throws {
        let release = SimulatorBridgeClientMessage.releaseSharedFrame(2)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SimulatorBridgeClientMessage.self, from: JSONEncoder().encode(release)
            ),
            release
        )

        let ready = SimulatorBridgeHelperMessage.sharedFrameReady(
            bufferIndex: 1, sequence: 42, presentationTimeNanoseconds: 123_456_789
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SimulatorBridgeHelperMessage.self, from: JSONEncoder().encode(ready)
            ),
            ready
        )
    }

    func testHelloReplyCarriesSharedSurfaceDescriptor() throws {
        let descriptor = SimulatorSharedSurfaceDescriptor(
            namePrefix: "/tsim-0123456789abcdef-",
            bufferCount: 3,
            width: 1206,
            height: 2622,
            bytesPerRow: 1206 * 4,
            pixelFormat: 0x42_47_52_41, // 'BGRA'
            bufferByteLength: 1206 * 4 * 2622
        )
        let reply = SimulatorBridgeHelloReply(
            selectedCodec: nil,
            sharedSurface: descriptor,
            capabilities: nil,
            refusal: nil,
            coreSimulatorVersion: "1051.54",
            simulatorKitVersion: "955.7"
        )
        let decoded = try JSONDecoder().decode(
            SimulatorBridgeHelloReply.self, from: JSONEncoder().encode(reply)
        )
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded.sharedSurface?.name(forBuffer: 2), "/tsim-0123456789abcdef-2")
        XCTAssertNil(decoded.selectedCodec)
    }

    /// A v1-shaped payload (no `supportsSharedMemory`, no `sharedSurface`) still decodes, so the
    /// codec path keeps working across the version boundary.
    func testLegacyPayloadsDecodeWithoutTheNewFields() throws {
        // Codecs are UInt8-raw enums on the wire (h264 == 1, jpeg == 2), not strings.
        let helloJSON = """
        {"protocolVersion":1,"minimumSupported":1,
         "deviceID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
         "developerDirectory":"/dev","preferredCodecs":[1,2],
         "requestedFramesPerSecond":30}
        """.data(using: .utf8)!
        let hello = try JSONDecoder().decode(SimulatorBridgeHello.self, from: helloJSON)
        XCTAssertFalse(hello.supportsSharedMemory)

        let replyJSON = """
        {"protocolVersion":1,"minimumSupported":1,"selectedCodec":1}
        """.data(using: .utf8)!
        let reply = try JSONDecoder().decode(SimulatorBridgeHelloReply.self, from: replyJSON)
        XCTAssertEqual(reply.selectedCodec, .h264)
        XCTAssertNil(reply.sharedSurface)
    }

    func testHelloAdvertisingSharedMemoryRoundTrips() throws {
        let hello = SimulatorBridgeHello(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            developerDirectory: "/dev",
            supportsSharedMemory: true
        )
        let decoded = try JSONDecoder().decode(
            SimulatorBridgeHello.self, from: JSONEncoder().encode(hello)
        )
        XCTAssertTrue(decoded.supportsSharedMemory)
    }

    func testEveryHardwareButtonRoundTrips() throws {
        XCTAssertTrue(SimulatorBridgeButton.allCases.contains(.volumeUp))
        XCTAssertTrue(SimulatorBridgeButton.allCases.contains(.volumeDown))
        for button in SimulatorBridgeButton.allCases {
            let input = SimulatorBridgeInput.button(button)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SimulatorBridgeInput.self, from: JSONEncoder().encode(input)
                ),
                input
            )
        }
    }

    func testContinuousTouchInputRoundTrips() throws {
        for phase in SimulatorBridgeTouchPhase.allCases {
            let input = SimulatorBridgeInput.touch(phase: phase, x: 0.4, y: 0.6)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SimulatorBridgeInput.self, from: JSONEncoder().encode(input)
                ),
                input
            )
        }
    }

    func testFrameRingClaimsFreeBuffersAndDropsWhenFull() {
        var ring = SimulatorSharedFrameRing(bufferCount: 3)
        XCTAssertEqual(ring.freeCount, 3)

        let a = ring.claim(); let b = ring.claim(); let c = ring.claim()
        XCTAssertEqual([a, b, c], [0, 1, 2])
        XCTAssertFalse(ring.hasFreeBuffer)
        XCTAssertNil(ring.claim()) // app holds every buffer -> drop this capture

        ring.release(1)
        XCTAssertTrue(ring.hasFreeBuffer)
        XCTAssertEqual(ring.claim(), 1) // the freed one is reused
        XCTAssertNil(ring.claim())

        // A duplicate/stale release cannot corrupt the set.
        ring.release(1); ring.release(1)
        XCTAssertEqual(ring.freeCount, 1)
    }

    func testRandomNamePrefixIsShortAndUnique() {
        let a = SimulatorSharedSurfaceNaming.randomNamePrefix()
        let b = SimulatorSharedSurfaceNaming.randomNamePrefix()
        XCTAssertNotEqual(a, b)
        // Darwin caps shm names near 31 bytes; leave room for the buffer index.
        XCTAssertLessThanOrEqual((a + "9").utf8.count, 31)
        XCTAssertTrue(a.hasPrefix("/tsim-"))
    }
}
