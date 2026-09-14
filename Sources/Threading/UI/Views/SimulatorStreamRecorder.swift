import AVFoundation
import AppKit

/// Records the pane's own live frames to an H.264 .mov, compositing the touch overlay onto each
/// frame — the engine that puts what you see (including taps and swipes) into the movie.
///
/// Fidelity equals the live stream: it encodes the frames we already decode. Each frame is drawn
/// upright with its overlay into a bitmap (the same path the live view uses), then blitted into the
/// writer's pixel buffer with the standard vertical flip.
@MainActor
final class SimulatorStreamRecorder {
    let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private var startedAt: TimeInterval?
    private var finished = false

    init?(url: URL, width: Int, height: Int) {
        // H.264 wants even dimensions.
        let evenWidth = width - (width % 2)
        let evenHeight = height - (height % 2)
        guard evenWidth > 0, evenHeight > 0,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenWidth,
                kCVPixelBufferHeightKey as String: evenHeight,
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        self.outputURL = url
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.width = evenWidth
        self.height = evenHeight
    }

    func append(image: CGImage, indicators: SimulatorTouchIndicators?) {
        guard !finished, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool,
              let composited = Self.composite(
                frame: image, indicators: indicators, width: width, height: height
              ) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if startedAt == nil { startedAt = now }
        let elapsed = now - (startedAt ?? now)

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        // CVPixelBuffer row 0 is the top; CGContext is bottom-left — flip so the upright composite
        // lands upright in the buffer.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(composited, in: CGRect(x: 0, y: 0, width: width, height: height))

        adaptor.append(buffer, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 600))
    }

    func finish(completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !finished else {
            completion(nil)
            return
        }
        finished = true
        input.markAsFinished()
        let url = outputURL
        // The completion runs on AVFoundation's queue and captures only Sendable values (the URL and
        // the handler). finishWriting completing after real appends means the file is written.
        writer.finishWriting {
            Task { @MainActor in completion(url) }
        }
    }

    /// Draw the frame upright with its overlay, the same way the live view does, into a bitmap.
    private static func composite(
        frame: CGImage,
        indicators: SimulatorTouchIndicators?,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: frame, size: rect.size).draw(in: rect)
        if let indicators { SimulatorTouchMarks.draw(indicators, in: rect) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
