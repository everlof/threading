import AVFoundation
import CoreVideo

/// A short movie a test can hand a decoder, written on demand.
///
/// A fixture that is genuinely decodable is the only kind worth having: every claim made about a
/// movie in this suite — the size, the length, the poster frame, the refusal of a file that only
/// *looks* like one — is a claim about what a decoder says, and a stub would prove none of them.
/// Written rather than checked in for the same reason the Lottie fixtures are: the bytes are
/// small, and a fixture whose recipe is in the diff is a fixture whose point is in the diff.
///
/// The picture is a grey ramp, dark at the start and light at the end, so a test can tell the
/// first frame from the last by its brightness alone.
enum MovieFixture {

    static let size = CGSize(width: 160, height: 120)
    static let seconds: Double = 1
    static let frameRate: Int32 = 10

    enum Failure: Error {
        case writer(String)
        case pixelBuffer
    }

    /// Writes a QuickTime movie at `url`, `seconds` long at `frameRate`, and returns when the
    /// file is complete on disk.
    ///
    /// Frames are supplied on the writer's own queue and the call blocks on a semaphore rather
    /// than spinning the run loop: nothing the writer does needs the main thread, and a fixture
    /// that depended on the run loop could not be written from a nonisolated helper.
    static func write(
        to url: URL,
        size: CGSize = size,
        seconds: Double = seconds,
        frameRate: Int32 = frameRate
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? "startWriting refused")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(Double(frameRate) * seconds)
        let progress = Progress()
        let finished = DispatchSemaphore(value: 0)
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "MovieFixture")) {
            while input.isReadyForMoreMediaData {
                guard progress.index < frames else {
                    input.markAsFinished()
                    writer.endSession(atSourceTime: CMTime(
                        value: CMTimeValue(frames),
                        timescale: frameRate
                    ))
                    writer.finishWriting { finished.signal() }
                    return
                }
                do {
                    let buffer = try pixelBuffer(
                        gray: Double(progress.index) / Double(max(frames - 1, 1)),
                        size: size,
                        pool: adaptor.pixelBufferPool
                    )
                    adaptor.append(
                        buffer,
                        withPresentationTime: CMTime(
                            value: CMTimeValue(progress.index),
                            timescale: frameRate
                        )
                    )
                    progress.index += 1
                } catch {
                    progress.failure = error
                    input.markAsFinished()
                    writer.cancelWriting()
                    finished.signal()
                    return
                }
            }
        }
        finished.wait()

        if let failure = progress.failure { throw failure }
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "\(writer.status)")
        }
    }

    /// The writer's queue and the caller's thread share this one box: the queue advances it, the
    /// caller reads it once the semaphore says the queue is done with it.
    private final class Progress: @unchecked Sendable {
        var index = 0
        var failure: Error?
    }

    private static func pixelBuffer(
        gray: Double,
        size: CGSize,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32ARGB,
                nil,
                &buffer
            )
        }
        guard let pixels = buffer else { throw Failure.pixelBuffer }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(
                base,
                Int32(min(max(gray, 0), 1) * 255),
                CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels)
            )
        }
        return pixels
    }
}
