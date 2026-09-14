import AVFoundation
import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorStreamRecorderTests: XCTestCase {
    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testEncodesFramesWithAnOverlayIntoAPlayableVideo() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-recorder-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try XCTUnwrap(SimulatorStreamRecorder(url: url, width: 48, height: 64))
        let frame = makeCGImage(width: 48, height: 64)
        let indicators = SimulatorTouchIndicators(
            ripples: [.init(point: CGPoint(x: 0.5, y: 0.5), progress: 0.2)],
            contact: .init(point: CGPoint(x: 0.3, y: 0.3), trail: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)])
        )
        // A few frames, spaced so their presentation times strictly increase.
        for index in 0..<4 {
            recorder.append(image: frame, indicators: index.isMultiple(of: 2) ? indicators : nil)
            try await Task.sleep(for: .milliseconds(40))
        }

        let saved = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        let savedURL = try XCTUnwrap(saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))

        // It is a real, playable video with a non-empty video track.
        let asset = AVURLAsset(url: savedURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "the recording has no video track")
        let size = try await tracks.first?.load(.naturalSize)
        XCTAssertEqual(size?.width, 48)
        XCTAssertEqual(size?.height, 64)
    }

    func testOddDimensionsAreRoundedToEven() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("odd-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // 49x65 should still construct (rounded to 48x64) rather than fail.
        XCTAssertNotNil(SimulatorStreamRecorder(url: url, width: 49, height: 65))
    }
}
