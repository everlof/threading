import CoreGraphics
import Foundation

/// How an `ImageCompareView` composites its two sides.
///
/// The set is deliberately small. Onion-skinning is not missing: it is `.fade` standing at the
/// middle, which is why there is a scrubber and not a fifth blend. `.difference` is the one
/// composite the scrubber cannot express — it answers "did anything change at all", which no
/// blend fraction answers.
enum ImageCompareMode: String, CaseIterable, Codable {
    /// A vertical seam dragged left–right: old before it, new after it.
    case wipeHorizontal
    /// A horizontal seam dragged up–down: old above it, new below it.
    case wipeVertical
    /// Both images in place, the new one at the scrubbed opacity.
    case fade
    /// Pixel difference — identical areas read as no ink, changes as ink.
    case difference
    /// Both images whole, beside each other.
    case sideBySide

    /// Whether the mode reads the scrubbed fraction at all. `.difference` and `.sideBySide`
    /// have no position to scrub, so the handle hides rather than sitting dead.
    var usesFraction: Bool {
        switch self {
        case .wipeHorizontal, .wipeVertical, .fade: return true
        case .difference, .sideBySide: return false
        }
    }

    /// What the mode is called wherever it is named — the chip on the surface, and the row of
    /// buttons in an exported comparison.
    ///
    /// It lives on the mode rather than on the view because the export has no view: the page a
    /// comparison is written to has to label its own modes, and reaching through `ImageCompareView`
    /// for the words would put a main-actor hop in the middle of packaging a file.
    var title: String {
        switch self {
        case .wipeHorizontal: return L10n.string("Wipe ↔")
        case .wipeVertical: return L10n.string("Wipe ↕")
        case .fade: return L10n.string("Fade")
        case .difference: return L10n.string("Difference")
        case .sideBySide: return L10n.string("Side by Side")
        }
    }
}

/// The geometry of one compare rendering, computed pure so it can be pinned by unit tests.
///
/// All rects are in a **flipped** coordinate space (origin top-left, y growing downward),
/// which is what lets "the seam sweeps top to bottom" be written as plain addition; the view
/// that draws this declares `isFlipped` to match.
///
/// Both images draw at **one shared scale** — the union of the two pixel sizes aspect-fitted
/// into the container — and each centres in the fitted canvas. A per-image fit would silently
/// normalise a resized asset into "looks identical", which is the one lie an image diff must
/// not tell; a shared scale keeps a 100×100 old beside a 200×200 new visibly half the size.
struct ImageCompareLayout: Equatable {

    /// Where each side draws. `.sideBySide` gives the two sides different canvases; every
    /// other mode overlays them on the shared one.
    struct Placement: Equatable {
        let oldRect: CGRect
        let newRect: CGRect
        /// The rect the checkerboard and the seam live in: the fitted canvas.
        let canvasRect: CGRect
        /// The second canvas in `.sideBySide`, holding the new side.
        let secondaryCanvasRect: CGRect?
    }

    /// How much room the captions are given *before* the images are fitted.
    ///
    /// A caption printed over the comparison hides the pixels the comparison exists to show —
    /// and at rest it sits exactly where the wipe starts, so reading a label meant scrubbing
    /// it out from under. The band is reserved first and the images take what is left: the
    /// titles are legible at every fraction, and nothing has to move on hover to be read.
    struct CaptionBands: Equatable {
        let top: CGFloat
        let bottom: CGFloat

        static let none = CaptionBands(top: 0, bottom: 0)
    }

    /// The strips the captions draw in: flush against the images, never over them, and
    /// zero-height where the mode captions nothing.
    struct Captions: Equatable {
        let top: CGRect
        let bottom: CGRect
    }

    let placement: Placement
    /// The shared points-per-pixel scale both sides drew at.
    let scale: CGFloat
    let captions: Captions

    /// The scrubbed position, 0 at the seam's start (left, or top) and 1 at its end. In the
    /// wipes it is the seam's place; in `.fade` it is the new side's opacity. One number, so
    /// switching mode keeps the scrub where the user left it.
    static func clamped(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, 0), 1)
    }

    /// Aspect-fits `size` into `bounds` and centres it.
    private static func fit(_ size: CGSize, into bounds: CGRect) -> (rect: CGRect, scale: CGFloat) {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return (CGRect(origin: bounds.origin, size: .zero), 1)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2
        )
        return (CGRect(origin: origin, size: fitted), scale)
    }

    /// Centres `size`, scaled to points at `scale`, inside `canvas`.
    private static func centre(_ size: CGSize, at scale: CGFloat, in canvas: CGRect) -> CGRect {
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: canvas.midX - scaled.width / 2,
            y: canvas.midY - scaled.height / 2,
            width: scaled.width,
            height: scaled.height
        )
    }

    /// The caption strips around what was drawn. They hug the fitted canvas rather than the
    /// container's edges: an image that letterboxes leaves slack, and a title floating an inch
    /// off the picture it names reads as belonging to neither side.
    private static func captionRects(around span: CGRect, bands: CaptionBands) -> Captions {
        Captions(
            top: CGRect(x: span.minX, y: span.minY - bands.top, width: span.width, height: bands.top),
            bottom: CGRect(x: span.minX, y: span.maxY, width: span.width, height: bands.bottom)
        )
    }

    /// Lays two pixel sizes out in `bounds` for `mode`. A missing side (an added or deleted
    /// file) passes `.zero` and receives a zero-sized rect at the shared centre.
    ///
    /// `captions` is taken off the top and bottom before anything is fitted, so the images are
    /// sized against the room that is actually theirs.
    static func layout(
        oldSize: CGSize,
        newSize: CGSize,
        in bounds: CGRect,
        mode: ImageCompareMode,
        gap: CGFloat,
        captions bands: CaptionBands = .none
    ) -> ImageCompareLayout {
        let union = CGSize(
            width: max(oldSize.width, newSize.width),
            height: max(oldSize.height, newSize.height)
        )
        let content = CGRect(
            x: bounds.minX,
            y: bounds.minY + bands.top,
            width: bounds.width,
            height: max(0, bounds.height - bands.top - bands.bottom)
        )

        if mode == .sideBySide {
            let half = max(0, (content.width - gap) / 2)
            let leftBounds = CGRect(
                x: content.minX, y: content.minY, width: half, height: content.height
            )
            let rightBounds = CGRect(
                x: content.minX + half + gap, y: content.minY, width: half, height: content.height
            )
            let (leftCanvas, scale) = fit(union, into: leftBounds)
            let (rightCanvas, _) = fit(union, into: rightBounds)
            return ImageCompareLayout(
                placement: Placement(
                    oldRect: centre(oldSize, at: scale, in: leftCanvas),
                    newRect: centre(newSize, at: scale, in: rightCanvas),
                    canvasRect: leftCanvas,
                    secondaryCanvasRect: rightCanvas
                ),
                scale: scale,
                captions: captionRects(around: leftCanvas.union(rightCanvas), bands: bands)
            )
        }

        let (canvas, scale) = fit(union, into: content)
        return ImageCompareLayout(
            placement: Placement(
                oldRect: centre(oldSize, at: scale, in: canvas),
                newRect: centre(newSize, at: scale, in: canvas),
                canvasRect: canvas,
                secondaryCanvasRect: nil
            ),
            scale: scale,
            captions: captionRects(around: canvas, bands: bands)
        )
    }

    /// The seam's coordinate for a wipe at `fraction` — an x for the horizontal wipe, a y for
    /// the vertical one.
    static func seam(in canvas: CGRect, mode: ImageCompareMode, fraction: CGFloat) -> CGFloat {
        switch mode {
        case .wipeHorizontal: return canvas.minX + canvas.width * clamped(fraction)
        case .wipeVertical: return canvas.minY + canvas.height * clamped(fraction)
        default: return 0
        }
    }

    /// Maps a pointer location back to the fraction the seam (or blend) should take.
    static func fraction(at point: CGPoint, in canvas: CGRect, mode: ImageCompareMode) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 0 }
        switch mode {
        case .wipeHorizontal, .fade:
            return clamped((point.x - canvas.minX) / canvas.width)
        case .wipeVertical:
            return clamped((point.y - canvas.minY) / canvas.height)
        case .difference, .sideBySide:
            return 0
        }
    }

    /// The regions a wipe clips each side to: old keeps what the seam has not crossed (left of
    /// it, or above it), new takes what it has.
    static func wipeRegions(
        in canvas: CGRect,
        mode: ImageCompareMode,
        fraction: CGFloat
    ) -> (old: CGRect, new: CGRect) {
        let position = seam(in: canvas, mode: mode, fraction: fraction)
        switch mode {
        case .wipeHorizontal:
            let old = CGRect(
                x: canvas.minX, y: canvas.minY, width: position - canvas.minX, height: canvas.height
            )
            let new = CGRect(
                x: position, y: canvas.minY, width: canvas.maxX - position, height: canvas.height
            )
            return (old, new)
        case .wipeVertical:
            let old = CGRect(
                x: canvas.minX, y: canvas.minY, width: canvas.width, height: position - canvas.minY
            )
            let new = CGRect(
                x: canvas.minX, y: position, width: canvas.width, height: canvas.maxY - position
            )
            return (old, new)
        default:
            return (canvas, canvas)
        }
    }
}
