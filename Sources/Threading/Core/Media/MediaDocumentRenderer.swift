import AppKit
import ThreadingExtensionKit

/// The ceilings a media document is measured against **before** anything is drawn.
///
/// Stated as a value rather than as constants inside each renderer, because the point of a
/// registry is that a second format cannot arrive with a second, quieter set of limits. A document
/// that exceeds any of these fails with a reason the extension can show, rather than being
/// partially drawn — a half-rendered animation is indistinguishable from a rendering bug.
struct MediaDocumentLimits: Equatable, Sendable {

    static let `default` = MediaDocumentLimits()

    /// The whole document, compressed. A `.lottie` container is measured here before it is opened.
    var maximumDocumentBytes = 16 * 1_024 * 1_024
    /// Either axis of the document's own natural size.
    var maximumPixelDimension = 4_096
    /// The canvas's backing store. A larger canvas draws at a reduced internal scale rather than
    /// allocating an unbounded frame — 2,048 × 2,048 at 1×, or 1,448² at 2×.
    var maximumBackingPixels = 4_194_304
    var maximumFrameCount = 4_096
    var maximumLayerCount = 512
    var maximumDurationSeconds: Double = 3_600

    // Archive ceilings, following `ClassicSkinLimits` — the same shape of attack, the same answer.
    var maximumArchiveEntries = 256
    var maximumArchiveEntryBytes = 8 * 1_024 * 1_024
    var maximumArchiveExpandedBytes = 32 * 1_024 * 1_024

    /// The largest frame `copyCurrentFrame` will hand the pasteboard.
    var maximumCopiedFramePixels = 4_194_304
}

/// Why a document did not play, in the host's own terms.
///
/// Mapped to `ExtensionMediaFailure` on the way out, so an extension branches on a stable reason
/// and shows a host-authored sentence. Neither carries a path or a byte of the document.
enum MediaDocumentFailure: Error, Equatable {
    /// No registered renderer carries this format.
    case unsupportedFormat(ExtensionMediaFormat)
    /// The handle names nothing this generation may open.
    case unresolvedSource
    /// The bytes are not the document they claimed to be.
    case invalidDocument(String)
    /// A stated ceiling was exceeded.
    case exceedsLimits(String)

    var extensionFailure: ExtensionMediaFailure {
        switch self {
        case .unsupportedFormat(let format):
            return ExtensionMediaFailure(
                reason: .unsupportedFormat,
                message: L10n.format(
                    "Threading carries no player for “%@” documents.",
                    format.rawValue
                )
            )
        case .unresolvedSource:
            return ExtensionMediaFailure(
                reason: .unresolvedSource,
                message: L10n.string("This document is no longer available to the extension.")
            )
        case .invalidDocument(let detail):
            return ExtensionMediaFailure(reason: .invalidDocument, message: detail)
        case .exceedsLimits(let detail):
            return ExtensionMediaFailure(reason: .exceedsLimits, message: detail)
        }
    }
}

/// The bounded surface a playback session draws into.
///
/// Two ways in, because two kinds of engine exist and forcing either through the other's shape is
/// the mistake this protocol is written to avoid: an engine with a native animation layer installs
/// it in `contentLayer` and runs its own clock, while a decoder that produces bitmaps hands the
/// host one bounded frame at a time. Requiring a `CGContext` rasterization per tick would put a
/// CoreAnimation layer tree on the main thread every frame.
@MainActor
protocol MediaDocumentRenderHost: AnyObject {
    /// Where engine-owned layers are installed. Already clipped and sized by the host.
    var contentLayer: CALayer { get }
    /// The device scale the host will draw at.
    var backingScale: CGFloat { get }
    /// The bounded pixel size a bitmap session should render into.
    var renderPixelSize: CGSize { get }
    /// Presents one bounded frame. **Never queues**: a frame that missed its deadline is replaced
    /// by the next one rather than shown late behind it.
    func present(frame: CGImage)
}

/// One opened document, ready to play.
///
/// Deliberately engine-neutral. `drivesItsOwnClock` is the fork: a session that answers `true`
/// owns its timeline and is only told what the user asked for, and one that answers `false` is
/// asked to present a position by the player's display link.
@MainActor
protocol MediaDocumentPlaybackSession: AnyObject {
    var metadata: ExtensionMediaMetadata { get }

    /// Whether this session runs its own clock rather than being ticked by the player.
    var drivesItsOwnClock: Bool { get }

    /// The position a self-clocked session is currently showing, `0…1`. Host-clocked sessions
    /// answer with whatever they were last asked to present.
    var currentProgress: Double { get }

    func attach(to host: MediaDocumentRenderHost)

    /// Host-clocked sessions: show the frame at this normalized position. Called at most once per
    /// display tick, and never while the clock is stopped.
    func present(atProgress progress: Double)

    func apply(_ playback: MediaPlaybackState)

    /// Visibility, not playback. A session whose presentation is inactive stops its own clock,
    /// releases what it can, and resumes from where it was.
    func setPresentationActive(_ isActive: Bool)

    /// A bounded snapshot for the pasteboard. Never returned to the extension.
    func copyCurrentFrame(maximumPixels: Int) throws -> CGImage

    func invalidate()
}

/// The host's resolved playback intent — what the extension asked for, after Reduce Motion and
/// clamping. `progress` is resolved rather than optional here: "keep the current position" is a
/// question the player has already answered by the time a session is told anything.
struct MediaPlaybackState: Equatable, Sendable {
    var isPlaying: Bool
    var loop: ExtensionMediaLoopMode
    var speed: Double
    var progress: Double

    init(
        isPlaying: Bool = false,
        loop: ExtensionMediaLoopMode = .loop,
        speed: Double = 1,
        progress: Double = 0
    ) {
        self.isPlaying = isPlaying
        self.loop = loop
        self.speed = speed.isFinite
            ? min(max(speed, ExtensionMediaPlayback.speedRange.lowerBound),
                  ExtensionMediaPlayback.speedRange.upperBound)
            : 1
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
    }
}

/// One format's decoder.
///
/// `open` completes away from the main actor: parsing a document and expanding an archive are the
/// two most expensive things in this feature and neither belongs in a frame.
protocol MediaDocumentRenderer: Sendable {
    static var formats: Set<ExtensionMediaFormat> { get }

    func open(
        _ document: Data,
        limits: MediaDocumentLimits
    ) async throws -> MediaDocumentPlaybackSession
}

/// The single place a document format is carried.
///
/// This is the decision the `.diagram` attachment kind declined once — *rendering would take an
/// engine the app does not carry* — reversed deliberately and exactly once, behind a registry, so
/// every format after the first is an implementation of a protocol rather than a new extension API.
@MainActor
enum MediaDocumentRendererRegistry {

    private static var renderers: [ExtensionMediaFormat: any MediaDocumentRenderer] = [
        // `animatedImage` is first on purpose: it fixes an existing wart — an animated GIF
        // attachment shows one frame today, because `BoundedImageDecoder` decodes index 0 — while
        // proving the seam with a decoder the platform already ships.
        .animatedImage: AnimatedImageDocumentRenderer(),
        .lottie: LottieDocumentRenderer(),
        .dotLottie: LottieDocumentRenderer()
    ]

    static var supportedFormats: Set<ExtensionMediaFormat> {
        Set(renderers.keys)
    }

    static func renderer(for format: ExtensionMediaFormat) -> (any MediaDocumentRenderer)? {
        renderers[format]
    }

    static func supports(_ format: ExtensionMediaFormat) -> Bool {
        renderers[format] != nil
    }

    /// Installs a renderer for the duration of a test. Returns the previous entry so the caller
    /// can put it back; a registry a test can only add to is a registry the next test inherits.
    @discardableResult
    static func setRendererForTesting(
        _ renderer: (any MediaDocumentRenderer)?,
        for format: ExtensionMediaFormat
    ) -> (any MediaDocumentRenderer)? {
        let previous = renderers[format]
        renderers[format] = renderer
        return previous
    }
}
