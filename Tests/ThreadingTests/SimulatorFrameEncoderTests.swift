import CoreVideo
import IOSurface
import ThreadingSimulatorKit
import XCTest

/// The helper keeps one frame inside its encoder and captures the next only after that frame
/// has come back, so an encoder that holds frames for lookahead freezes the whole stream after
/// its first picture. This drives the shipped `SimulatorH264FrameEncoder` exactly the way the
/// helper does: one frame in flight, the next submitted only once the previous one returned.
final class SimulatorFrameEncoderTests: XCTestCase {
    private enum Fixture {
        /// The iPhone 17 Pro framebuffer, so the encoder sees a production-sized surface.
        static let width = 1206
        static let height = 2622
        static let framesPerSecond = 30
        static let frameCount = 4
        static let frameDeadline: TimeInterval = 2
    }

    /// The encoder's completion runs on a VideoToolbox thread; this hands its result back to
    /// the test without mutating a captured variable across that boundary.
    private final class EncodedFrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SimulatorBridgeMediaFrame, Error>?

        func store(_ encoded: Result<SimulatorBridgeMediaFrame, Error>) {
            lock.withLock { result = encoded }
        }

        func take() -> Result<SimulatorBridgeMediaFrame, Error>? {
            lock.withLock { result }
        }
    }

    func testH264EncoderReturnsEveryFrameBeforeTheNextIsCaptured() throws {
        let encoder = try SimulatorH264FrameEncoder(
            width: Fixture.width,
            height: Fixture.height,
            framesPerSecond: Fixture.framesPerSecond
        )
        defer { encoder.finish() }
        let surface = try XCTUnwrap(makeSurface())

        var frames: [SimulatorBridgeMediaFrame] = []
        for sequence in 1...Fixture.frameCount {
            let returned = expectation(description: "frame \(sequence) returned")
            let box = EncodedFrameBox()
            encoder.encode(
                surface: surface,
                sequence: UInt64(sequence),
                presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ) { encoded in
                box.store(encoded)
                returned.fulfill()
            }
            wait(for: [returned], timeout: Fixture.frameDeadline)
            let frame = try XCTUnwrap(
                box.take(),
                "Frame \(sequence) never came back: the encoder is holding it."
            ).get()
            XCTAssertEqual(frame.sequence, UInt64(sequence))
            XCTAssertEqual(frame.codec, .h264)
            XCTAssertEqual(Int(frame.width), Fixture.width)
            XCTAssertEqual(Int(frame.height), Fixture.height)
            XCTAssertFalse(frame.bytes.isEmpty)
            frames.append(frame)
        }

        XCTAssertEqual(frames.first?.isKeyFrame, true)
        XCTAssertEqual(frames.first?.codecConfiguration.isEmpty, false)
        XCTAssertEqual(
            frames.dropFirst().map(\.isKeyFrame),
            Array(repeating: false, count: Fixture.frameCount - 1),
            "Frames inside one key-frame interval should be delta frames."
        )
    }

    func testJPEGEncoderReturnsAKeyFrameSynchronously() throws {
        let encoder = SimulatorJPEGFrameEncoder()
        let surface = try XCTUnwrap(makeSurface())
        let box = EncodedFrameBox()
        encoder.encode(surface: surface, sequence: 7, presentationTimeNanoseconds: 1) { encoded in
            box.store(encoded)
        }
        let frame = try XCTUnwrap(box.take()).get()
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.codec, .jpeg)
        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertFalse(frame.bytes.isEmpty)
    }

    private func makeSurface() -> IOSurface? {
        IOSurface(properties: [
            .width: Fixture.width,
            .height: Fixture.height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ])
    }
}
