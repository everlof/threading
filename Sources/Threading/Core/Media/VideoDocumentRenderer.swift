import AVFoundation
import AppKit
import ThreadingExtensionKit

/// What a movie turned out to be, read once and small enough to cross an actor boundary.
///
/// Numbers only. The asset the answers were read from stays where it was read, because
/// `AVURLAsset` is not `Sendable` and a plan that carried one would be a plan that cannot leave
/// the thread that made it.
struct VideoDocumentPlan: Sendable {
    let url: URL
    let duration: Double
    let frameRate: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAudio: Bool

    var frameCount: Int {
        guard duration > 0, frameRate > 0 else { return 0 }
        return Int((duration * frameRate).rounded())
    }
}

/// Movies, played by the platform's own audiovisual stack.
///
/// The second engine the host carries, and the first that reads its own file. Everything else in
/// the registry is handed bytes because everything else is small; a screen recording is the one
/// document in this app routinely larger than the whole rest of a session put together, and
/// `MediaDocumentFileRenderer` exists so playing one does not begin by copying one.
///
/// **Nothing here decodes.** `AVPlayer` hands frames straight to a compositor layer installed in
/// the canvas, so the pixels are never this process's memory and a 4K recording costs the same as
/// a thumbnail-sized one. That is also why the ceilings a parsed document is measured against —
/// bytes, frames, duration — are not applied to a movie: they bound an allocation this path never
/// makes. The one that *is* applied bounds the decoder's own claim about its natural size.
struct VideoDocumentRenderer: MediaDocumentFileRenderer {

    static let formats: Set<ExtensionMediaFormat> = [.video]

    /// The rate the player is told to mirror a movie's position at when the file does not say.
    ///
    /// A fallback for the *transport*, not for playback: the movie plays at its own rate whatever
    /// this is. Variable-frame-rate screen recordings report a nominal rate of zero, and a
    /// scrubber updated at one hertz reads as a stuck movie.
    static let fallbackFrameRate: Double = 30

    func open(
        fileAt url: URL,
        limits: MediaDocumentLimits
    ) async throws -> MediaDocumentPlaybackSession {
        let plan = try await Self.plan(for: url, limits: limits)
        return await MainActor.run {
            VideoPlaybackSession(plan: plan)
        }
    }

    // MARK: - Reading the file

    /// Asks the file what it is, off the main actor and without starting playback.
    ///
    /// Every question is asked of the platform rather than of the extension: a movie is a
    /// container whose contents only a decoder knows, and a name that ends in `.mp4` is a claim
    /// rather than evidence. A file that answers "not playable" is refused here, with a sentence,
    /// instead of becoming a canvas that stays black.
    static func plan(
        for url: URL,
        limits: MediaDocumentLimits
    ) async throws -> VideoDocumentPlan {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let isPlayable: Bool
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let assetDuration: CMTime
        do {
            isPlayable = try await asset.load(.isPlayable)
            assetDuration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The movie could not be read.")
            )
        }
        guard isPlayable else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("This movie is in a format this Mac cannot play.")
            )
        }
        guard let track = videoTracks.first else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("This file carries no video to play.")
            )
        }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        let nominalFrameRate: Float
        do {
            (naturalSize, transform, nominalFrameRate) = try await track.load(
                .naturalSize,
                .preferredTransform,
                .nominalFrameRate
            )
        } catch {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The movie could not be read.")
            )
        }

        // The *presented* size, not the stored one. A movie recorded in portrait stores a
        // landscape frame plus a rotation, and a canvas given the stored size draws a portrait
        // recording into a letterbox turned the wrong way.
        let presented = naturalSize.applying(transform)
        let width = Int(abs(presented.width).rounded())
        let height = Int(abs(presented.height).rounded())
        guard width > 0, height > 0 else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The movie has no readable size.")
            )
        }
        guard width <= limits.maximumVideoPixelDimension,
              height <= limits.maximumVideoPixelDimension else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The movie is larger than the %lld-pixel limit on either axis.",
                Int64(limits.maximumVideoPixelDimension)
            ))
        }

        let duration = assetDuration.isNumeric ? assetDuration.seconds : 0
        return VideoDocumentPlan(
            url: url,
            duration: duration.isFinite && duration > 0 ? duration : 0,
            frameRate: nominalFrameRate > 0 ? Double(nominalFrameRate) : fallbackFrameRate,
            pixelWidth: width,
            pixelHeight: height,
            hasAudio: !audioTracks.isEmpty
        )
    }
}

/// One movie, open and ready to play.
///
/// **Self-clocked**, and that is the whole reason this fits the seam without a new one:
/// `AVPlayer` owns the timeline, keeps audio and video together on it, and is only ever told what
/// the user asked for. The player above it stops asking for positions and starts mirroring them,
/// which is a `Double` read per tick against a decode per tick.
@MainActor
private final class VideoPlaybackSession: MediaDocumentPlaybackSession {

    /// How far off the player's own position an asked-for one has to be before it is a seek.
    ///
    /// Seconds, not progress: the same fraction is a different distance in a five-second clip and
    /// a fifty-minute recording. Without it every pause re-seeked to the position the transport
    /// had just mirrored *out* of the player, which is a seek to where the movie already is —
    /// audible as a stutter on every play/pause.
    private static let seekEpsilon: Double = 0.05
    /// The travel of a drag is answered loosely and its end exactly. A zero-tolerance seek per
    /// scrubber sample asks the decoder for an exact frame sixty times a second; a scrub that
    /// lands on the wrong frame at the *end* is a scrub that missed.
    private static let scrubTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    let metadata: ExtensionMediaMetadata
    let drivesItsOwnClock = true
    var hasAudio: Bool { plan.hasAudio }
    private(set) var hasReachedEnd = false

    private let plan: VideoDocumentPlan
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var state = MediaPlaybackState()
    private var isPresentationActive = true
    private var endObserver: NSObjectProtocol?
    /// Built on the first Copy Frame and kept: the generator caches what it has decoded, and a
    /// second copy from the same movie is the common case.
    private var frameGenerator: AVAssetImageGenerator?

    init(plan: VideoDocumentPlan) {
        self.plan = plan
        let item = AVPlayerItem(url: plan.url)
        player = AVPlayer(playerItem: item)
        // A local file is not a stream: waiting to "minimize stalling" turns a press of Play into
        // a pause of unpredictable length on a file the disk already has.
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        // The canvas draws the ground; a layer with an opinion about its own background would
        // paint a black plate inside a themed pane.
        playerLayer.backgroundColor = nil
        metadata = ExtensionMediaMetadata(
            duration: plan.duration,
            frameRate: plan.frameRate,
            frameCount: plan.frameCount,
            pixelWidth: plan.pixelWidth,
            pixelHeight: plan.pixelHeight,
            // One track drawn into one layer. Saying zero would read as a document that failed
            // to parse rather than as a movie.
            layerCount: 1
        )
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
    }

    // MARK: - Presentation

    func attach(to host: MediaDocumentRenderHost) {
        playerLayer.removeFromSuperlayer()
        playerLayer.frame = host.contentLayer.bounds
        // The canvas resizes its document layer on every pane resize and never asks its sublayers
        // anything; autoresizing is how a layer nobody owns a constraint on follows it.
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.contentLayer.addSublayer(playerLayer)
    }

    /// Where the movie is, as the player's own clock reports it.
    var currentProgress: Double {
        guard plan.duration > 0 else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return min(max(seconds / plan.duration, 0), 1)
    }

    /// A position asked for while the timeline belongs to this session: a seek, not a decode.
    func present(atProgress progress: Double) {
        seek(toProgress: progress, exactly: false)
    }

    func apply(_ playback: MediaPlaybackState) {
        state = playback
        player.isMuted = playback.isMuted

        if abs(playback.progress - currentProgress) * max(plan.duration, 1) > Self.seekEpsilon {
            seek(toProgress: playback.progress, exactly: true)
        }
        if playback.isPlaying, playback.progress < 1 {
            hasReachedEnd = false
        }
        // Rate is playback *and* speed in one value, so a speed change while playing is applied
        // by the same assignment rather than by a stop and a start. A player asked to play while
        // nobody is looking is a player making a sound behind another tab.
        player.rate = playback.isPlaying && isPresentationActive ? Float(playback.speed) : 0
    }

    /// Visibility, not playback. A movie behind another tab keeps its position, stops decoding,
    /// and — the part a silent animation never had to answer for — stops making a sound.
    func setPresentationActive(_ isActive: Bool) {
        guard isPresentationActive != isActive else { return }
        isPresentationActive = isActive
        if isActive {
            if state.isPlaying { player.rate = Float(state.speed) }
        } else {
            player.rate = 0
        }
    }

    func copyCurrentFrame(maximumPixels: Int) throws -> CGImage {
        let generator: AVAssetImageGenerator
        if let frameGenerator {
            generator = frameGenerator
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: plan.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            frameGenerator = generator
        }
        // The pasteboard's ceiling, expressed as the square it fits in. `maximumSize` bounds what
        // the generator produces rather than what this then has to scale down.
        let side = max(1, Double(maximumPixels).squareRoot())
        generator.maximumSize = CGSize(width: side, height: side)
        // Synchronous, and deliberately: Copy Frame is one user-initiated action on a local file,
        // and a copy that arrived a moment after the menu closed would land on a pasteboard the
        // user has already pasted from.
        guard let image = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil)
        else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The current frame could not be decoded.")
            )
        }
        return image
    }

    func invalidate() {
        player.rate = 0
        player.replaceCurrentItem(with: nil)
        playerLayer.removeFromSuperlayer()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        frameGenerator = nil
    }

    // MARK: - Timeline

    private func seek(toProgress progress: Double, exactly: Bool) {
        guard plan.duration > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let time = CMTime(seconds: clamped * plan.duration, preferredTimescale: 600)
        let tolerance = exactly ? CMTime.zero : Self.scrubTolerance
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        if clamped < 1 { hasReachedEnd = false }
    }

    /// The end of the movie, which only this session can see.
    ///
    /// `.pingPong` is honoured as `.loop` here rather than pretended at: playing backwards needs
    /// a decoder that can, most movie files' cannot, and a transport that silently did nothing
    /// would be worse than one that loops.
    private func reachedEnd() {
        switch state.loop {
        case .loop, .pingPong:
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if state.isPlaying, isPresentationActive {
                player.rate = Float(state.speed)
            }
        case .once:
            hasReachedEnd = true
        }
    }
}
