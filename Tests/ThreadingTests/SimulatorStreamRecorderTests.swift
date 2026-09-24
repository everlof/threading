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

    func testRecordedPixelsKeepTheDeviceTopAtTheMovieTop() async throws {
        let width = 160
        let height = 240
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-orientation-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // CGImage data is in display row order: red at the device top, blue at the bottom.
        let pixels: [UInt8] = (0..<height).flatMap { y in
            let colour: [UInt8] = y < height / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            return (0..<width).flatMap { _ in colour }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let frame = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let recorder = try XCTUnwrap(SimulatorStreamRecorder(url: url, width: width, height: height))
        let indicators = SimulatorTouchIndicators(
            ripples: [],
            contact: .init(point: CGPoint(x: 0.5, y: 0.25), trail: [])
        )
        for _ in 0..<4 {
            recorder.append(image: frame, indicators: indicators)
            try await Task.sleep(for: .milliseconds(40))
        }
        let saved = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        _ = try XCTUnwrap(saved)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            reader.cancelReading()
        }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func colour(x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
            let pixel = base.advanced(by: y * stride + x * 4)
            return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
        }

        let top = colour(x: 30, y: 60)
        let bottom = colour(x: 30, y: 180)
        XCTAssertGreaterThan(top.red, top.blue + 100)
        XCTAssertGreaterThan(bottom.blue, bottom.red + 100)

        // The contact must stay in the top quarter along with the pixels it annotates.
        let touched = colour(x: 80, y: 60)
        let untouched = colour(x: 30, y: 60)
        XCTAssertGreaterThan(
            abs(touched.red - untouched.red) + abs(touched.green - untouched.green)
                + abs(touched.blue - untouched.blue),
            20
        )
    }
}
