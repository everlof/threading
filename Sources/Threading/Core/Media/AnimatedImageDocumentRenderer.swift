import AppKit
import ImageIO
import ThreadingExtensionKit
import UniformTypeIdentifiers

/// Frame timing, read once. Small enough to cross an actor boundary; the pixels never do.
struct AnimatedImagePlan: Sendable {
    let data: Data
    /// Cumulative end time of each frame, seconds. `last` is the document's duration.
    let frameEndTimes: [Double]
    let pixelWidth: Int
    let pixelHeight: Int

    var frameCount: Int { frameEndTimes.count }
    var duration: Double { frameEndTimes.last ?? 0 }
}

/// GIF and APNG, decoded with the platform's own image source.
///
/// The first renderer in the registry on purpose. It fixes a wart that predates the media seam —
/// `BoundedImageDecoder.decodedImage` decodes index 0, so an animated GIF attachment has always
/// shown one frame — and it proves the protocol with a decoder nobody has to audit.
///
/// Frames are decoded **lazily and one at a time**. Decoding every frame up front is the obvious
/// implementation and the wrong one: a 900-frame screen recording at 1,280 × 720 is 3 GB of
/// premultiplied pixels, and the ceilings that would have to reject it would also reject the
/// ordinary documents this exists to play.
struct AnimatedImageDocumentRenderer: MediaDocumentRenderer {

    static let formats: Set<ExtensionMediaFormat> = [.animatedImage]

    /// What a frame with no usable delay is worth. Browsers clamp a zero or missing GIF delay to
    /// 100 ms rather than spinning as fast as they can draw, and a document authored against that
    /// behaviour plays at the wrong speed without it.
    private static let fallbackFrameDelay: Double = 0.1
    private static let minimumFrameDelay: Double = 0.01

    func open(
        _ document: Data,
        limits: MediaDocumentLimits
    ) async throws -> MediaDocumentPlaybackSession {
        let plan = try Self.plan(for: document, limits: limits)
        return await MainActor.run {
            AnimatedImageSession(plan: plan, limits: limits)
        }
    }

    // MARK: - Parsing

    static func plan(
        for document: Data,
        limits: MediaDocumentLimits
    ) throws -> AnimatedImagePlan {
        guard document.count <= limits.maximumDocumentBytes else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The document is larger than the %@ this player accepts.",
                ByteCountFormatter.string(
                    fromByteCount: Int64(limits.maximumDocumentBytes),
                    countStyle: .binary
                )
            ))
        }
        guard let source = CGImageSourceCreateWithData(document as CFData, nil) else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation could not be read as an image.")
            )
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation contains no frames.")
            )
        }
        guard count <= limits.maximumFrameCount else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation has more than the %lld frames this player accepts.",
                Int64(limits.maximumFrameCount)
            ))
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation has no readable size.")
            )
        }
        guard width <= limits.maximumPixelDimension, height <= limits.maximumPixelDimension else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation is larger than the %lld-pixel limit on either axis.",
                Int64(limits.maximumPixelDimension)
            ))
        }

        var elapsed: Double = 0
        var endTimes: [Double] = []
        endTimes.reserveCapacity(count)
        for index in 0..<count {
            elapsed += delay(in: source, at: index)
            endTimes.append(elapsed)
        }
        guard elapsed <= limits.maximumDurationSeconds else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation is longer than the %lld seconds this player accepts.",
                Int64(limits.maximumDurationSeconds)
            ))
        }

        return AnimatedImagePlan(
            data: document,
            frameEndTimes: endTimes,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private static func delay(in source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            index,
            nil
        ) as? [CFString: Any] else {
            return fallbackFrameDelay
        }

        // The unclamped value first, then the clamped one: the clamped property is what a very
        // fast document reports as 0.1, which would play a 60fps GIF at ten frames a second.
        let containers: [CFString] = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary]
        let unclamped: [CFString] = [
            kCGImagePropertyGIFUnclampedDelayTime,
            kCGImagePropertyAPNGUnclampedDelayTime
        ]
        let clamped: [CFString] = [
            kCGImagePropertyGIFDelayTime,
            kCGImagePropertyAPNGDelayTime
        ]

        for (container, keys) in zip(containers, zip(unclamped, clamped)) {
            guard let dictionary = properties[container] as? [CFString: Any] else { continue }
            for key in [keys.0, keys.1] {
                if let value = dictionary[key] as? Double, value > 0 {
                    return max(value, minimumFrameDelay)
                }
            }
        }
        return fallbackFrameDelay
    }
}

/// One opened animated raster document.
///
/// Host-clocked: it owns no timeline, and answers `present(atProgress:)` by mapping the position
/// onto a frame index. Asking for the frame already on screen costs nothing, which is what makes a
/// 3-frame document cheap at 60Hz.
@MainActor
private final class AnimatedImageSession: MediaDocumentPlaybackSession {

    let metadata: ExtensionMediaMetadata
    let drivesItsOwnClock = false
    private(set) var currentProgress: Double = 0

    private let plan: AnimatedImagePlan
    private let limits: MediaDocumentLimits
    private let source: CGImageSource?
    private weak var host: MediaDocumentRenderHost?
    private var presentedFrameIndex: Int?
    private var isPresentationActive = true
    /// The last frame handed to the host, kept only so Copy Frame has something to copy without
    /// decoding again on the main thread.
    private var latestFrame: CGImage?

    init(plan: AnimatedImagePlan, limits: MediaDocumentLimits) {
        self.plan = plan
        self.limits = limits
        source = CGImageSourceCreateWithData(plan.data as CFData, nil)
        let duration = plan.duration
        metadata = ExtensionMediaMetadata(
            duration: duration,
            frameRate: duration > 0 ? Double(plan.frameCount) / duration : 0,
            frameCount: plan.frameCount,
            pixelWidth: plan.pixelWidth,
            pixelHeight: plan.pixelHeight,
            // A raster animation has one layer by construction; saying "0" would read as a
            // document that failed to parse.
            layerCount: 1
        )
    }

    func attach(to host: MediaDocumentRenderHost) {
        self.host = host
        presentedFrameIndex = nil
        present(atProgress: currentProgress)
    }

    func present(atProgress progress: Double) {
        currentProgress = min(max(progress, 0), 1)
        let index = frameIndex(at: currentProgress)
        guard index != presentedFrameIndex, let host else { return }
        guard let frame = decodeFrame(at: index, fitting: host.renderPixelSize) else { return }
        presentedFrameIndex = index
        latestFrame = frame
        host.present(frame: frame)
    }

    func apply(_ playback: MediaPlaybackState) {
        // The whole timeline is the player's; nothing about speed or looping changes how a frame
        // is decoded.
    }

    func setPresentationActive(_ isActive: Bool) {
        isPresentationActive = isActive
        if !isActive {
            // The decoded frame is the only thing worth holding, and the layer already has a copy.
            latestFrame = nil
        }
    }

    func copyCurrentFrame(maximumPixels: Int) throws -> CGImage {
        if let latestFrame { return latestFrame }
        let index = frameIndex(at: currentProgress)
        let side = CGFloat((Double(maximumPixels)).squareRoot())
        guard let frame = decodeFrame(
            at: index,
            fitting: CGSize(width: side, height: side)
        ) else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The current frame could not be decoded.")
            )
        }
        latestFrame = frame
        return frame
    }

    func invalidate() {
        host = nil
        latestFrame = nil
        presentedFrameIndex = nil
    }

    // MARK: - Frames

    private func frameIndex(at progress: Double) -> Int {
        guard let duration = plan.frameEndTimes.last, duration > 0 else { return 0 }
        let time = duration * progress
        // The last frame wins at exactly the end, rather than wrapping to the first: a document
        // held at 1.0 shows its final frame, which is what `.once` means.
        guard let index = plan.frameEndTimes.firstIndex(where: { time < $0 }) else {
            return plan.frameEndTimes.count - 1
        }
        return index
    }

    /// Decodes at most the host's own backing size. `kCGImageSourceThumbnailMaxPixelSize` is what
    /// keeps a 4,000-pixel GIF from allocating a 4,000-pixel frame for a 300-point canvas.
    private func decodeFrame(at index: Int, fitting size: CGSize) -> CGImage? {
        guard let source else { return nil }
        let cap = max(
            1,
            Int(min(
                max(size.width, size.height).rounded(.up),
                CGFloat(limits.maximumPixelDimension)
            ))
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: cap
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options as CFDictionary
        ) {
            return thumbnail
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}
