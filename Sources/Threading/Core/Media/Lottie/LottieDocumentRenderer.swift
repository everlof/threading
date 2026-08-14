import CoreGraphics
import Foundation
import ThreadingExtensionKit

/// Lottie and `.lottie`, drawn by the host's own bounded engine.
///
/// Host-clocked: the player owns the timeline and asks for a position, and this answers with one
/// bounded frame. The rasterization itself happens **off** the main actor and the result is
/// committed as a single image — a frame that missed its deadline is superseded by the next
/// request rather than queued behind it, which is the difference between a player that drops
/// frames under load and one that falls further behind the longer it runs.
struct LottieDocumentRenderer: MediaDocumentRenderer {

    static let formats: Set<ExtensionMediaFormat> = [.lottie, .dotLottie]

    func open(
        _ document: Data,
        limits: MediaDocumentLimits
    ) async throws -> MediaDocumentPlaybackSession {
        let parsed = try Self.parse(document, limits: limits)
        return await MainActor.run {
            LottieSession(document: parsed, limits: limits)
        }
    }

    /// Reads either shape the format ships in. The container is recognized by its own bytes
    /// rather than by the extension it arrived under, because the source that named it may be an
    /// opaque handle with no name at all.
    static func parse(_ data: Data, limits: MediaDocumentLimits) throws -> LottieDocument {
        if data.starts(with: [0x50, 0x4B]) {
            let contents = try DotLottieArchive.read(data, limits: limits)
            return try LottieParser.parse(
                contents.animation,
                limits: limits,
                embeddedImages: contents.images
            )
        }
        return try LottieParser.parse(data, limits: limits)
    }
}

/// One opened Lottie document.
@MainActor
private final class LottieSession: MediaDocumentPlaybackSession {

    let metadata: ExtensionMediaMetadata
    let drivesItsOwnClock = false
    private(set) var currentProgress: Double = 0

    private let rasterizer: LottieRasterizer
    private let document: LottieDocument
    private let limits: MediaDocumentLimits
    private weak var host: MediaDocumentRenderHost?

    /// The one render in flight, and the position that arrived while it was running.
    ///
    /// **Never a queue.** A display link asking for sixty positions a second while a frame takes
    /// twenty milliseconds would otherwise accumulate work forever and drift further behind real
    /// time the longer the document plays; superseding the pending position drops frames instead,
    /// which is what the eye expects under load.
    private var renderTask: Task<Void, Never>?
    private var pendingProgress: Double?
    private var latestFrame: CGImage?
    private var isPresentationActive = true

    init(document: LottieDocument, limits: MediaDocumentLimits) {
        self.document = document
        self.limits = limits
        rasterizer = LottieRasterizer(document: document)
        metadata = ExtensionMediaMetadata(
            duration: document.duration,
            frameRate: document.frameRate,
            frameCount: document.frameCount,
            pixelWidth: document.width,
            pixelHeight: document.height,
            layerCount: document.totalLayerCount,
            markers: document.markers.map {
                ExtensionMediaMarker(name: $0.name, time: $0.time, duration: $0.duration)
            },
            notes: document.notes
        )
    }

    func attach(to host: MediaDocumentRenderHost) {
        self.host = host
        present(atProgress: currentProgress, force: true)
    }

    func present(atProgress progress: Double) {
        present(atProgress: progress, force: false)
    }

    private func present(atProgress progress: Double, force: Bool) {
        currentProgress = min(max(progress, 0), 1)
        guard isPresentationActive || force else { return }
        guard renderTask == nil else {
            pendingProgress = currentProgress
            return
        }
        startRender(at: currentProgress)
    }

    private func startRender(at progress: Double) {
        guard let host else { return }
        let pixelSize = host.renderPixelSize
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return }
        let frame = document.inPoint + (document.outPoint - document.inPoint) * progress
        let rasterizer = rasterizer

        renderTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                rasterizer.image(atFrame: frame, pixelSize: pixelSize)
            }.value
            guard let self else { return }
            self.renderTask = nil
            if let image {
                self.latestFrame = image
                self.host?.present(frame: image)
            }
            if let pending = self.pendingProgress {
                self.pendingProgress = nil
                self.startRender(at: pending)
            }
        }
    }

    func apply(_ playback: MediaPlaybackState) {
        // The timeline is the player's; nothing about loop mode or speed changes a frame.
    }

    func setPresentationActive(_ isActive: Bool) {
        isPresentationActive = isActive
        if !isActive {
            renderTask?.cancel()
            renderTask = nil
            pendingProgress = nil
        }
    }

    func copyCurrentFrame(maximumPixels: Int) throws -> CGImage {
        if let latestFrame { return latestFrame }
        let side = Double(maximumPixels).squareRoot()
        let frame = document.inPoint
            + (document.outPoint - document.inPoint) * currentProgress
        guard let image = rasterizer.image(
            atFrame: frame,
            pixelSize: CGSize(width: side, height: side)
        ) else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The current frame could not be decoded.")
            )
        }
        latestFrame = image
        return image
    }

    func invalidate() {
        renderTask?.cancel()
        renderTask = nil
        pendingProgress = nil
        latestFrame = nil
        host = nil
    }
}
