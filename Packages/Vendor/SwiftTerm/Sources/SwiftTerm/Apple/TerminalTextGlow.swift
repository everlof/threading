//
//  TerminalTextGlow.swift
//  SwiftTerm
//
//  An opt-in phosphor glow for the Core Graphics renderer: a soft halo in each
//  run's own colour, painted beneath the text.
//

#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation

/// A soft halo beneath terminal text, in each run's own foreground colour.
///
/// The Core Graphics renderer draws the frame's lit content — glyph runs, box
/// drawing, block elements and Powerline glyphs — a second time into a bitmap
/// at `opacity`, blurs it, and paints the result under the frame. So bold, dim
/// and coloured text each glow in their own ink, while backgrounds,
/// underlines, strikethrough, images and the caret do not glow at all. The
/// halo lies beneath the text: a cell with an explicit background covers the
/// halo its neighbours cast into it. The Metal renderer ignores the glow.
///
/// A glow whose radius or opacity is zero (or not finite) is off, and an off
/// glow costs nothing: the renderer neither paints an underlay nor widens a
/// dirty region.
public struct TerminalTextGlow: Equatable, Sendable {
    /// The largest radius the renderer honours, in points. The underlay covers
    /// the dirty region grown by the radius, so a larger value is clamped
    /// rather than refused.
    public static let maximumRadius: CGFloat = 16

    /// How far the halo reaches from a glyph's ink, in points.
    public var radius: CGFloat
    /// The halo's strength, 0 to 1: the copy of the text that is blurred is
    /// drawn at this alpha.
    public var opacity: CGFloat

    public init(radius: CGFloat, opacity: CGFloat) {
        self.radius = radius
        self.opacity = opacity
    }

    /// The glow as the renderer will draw it, or nil when it would draw nothing.
    var normalized: TerminalTextGlow? {
        guard radius.isFinite, opacity.isFinite, radius > 0, opacity > 0 else {
            return nil
        }
        return TerminalTextGlow(
            radius: min(radius, Self.maximumRadius),
            opacity: min(opacity, 1))
    }

    /// The furthest, in points, that a glyph's ink can change a pixel.
    ///
    /// The blur's support is the radius rounded to whole device pixels, plus
    /// the one pixel `TextGlowUnderlayPlan` keeps as a margin; a device pixel is
    /// at most a point wide, so this holds at every display scale of at least
    /// 1. The frame tick pads its dirty region by it without knowing which
    /// scale the draw will use.
    var influence: CGFloat {
        radius + 1.5
    }

    /// Whole rows a halo can reach above and below the row that drew it.
    func reachInRows(cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        return Int((influence / cellHeight).rounded(.up))
    }
}

/// Where one frame's glow underlay lives and how it is blurred.
///
/// **The bitmap is at device resolution, on the device pixel grid.** Its origin
/// is a whole number of device pixels from the view's origin and it is drawn
/// back 1:1. A partial repaint and a full one therefore rasterize every glyph at
/// the same phase, blur the same values and land them on the same pixels, which
/// keeps a partial repaint pixel-identical to a full one
/// (`TextGlowTests.aPartialRepaintMatchesAFullOne`). A coarser bitmap blurred
/// fewer pixels but had to be scaled back up, and Core Graphics scaling an
/// 800 × 600-point underlay onto a Retina store cost 10–18 ms a frame — more
/// than everything it saved (see PERFORMANCE.md, "Text glow").
///
/// **The blur's support is the radius.** Three box passes approximate a
/// Gaussian; their half-widths sum to the radius in device pixels, so a glyph's
/// ink touches nothing further than that. The bitmap reaches one pixel further
/// past the dirty rectangle, so no pixel the dirty rectangle receives is one the
/// blur's edge treatment touched. `TerminalTextGlow.influence` bounds the same
/// distance from above for the dirty-region padding.
struct TextGlowUnderlayPlan: Equatable {
    let pixelsPerPoint: CGFloat
    /// The bitmap's bottom-left corner and size, in device pixels from the
    /// view's origin.
    let originX: Int
    let originY: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// Half-widths of the three box passes; their sum is the radius in pixels.
    let boxHalfWidths: [Int]

    /// The bitmap's extent in view points.
    var rect: CGRect {
        CGRect(x: CGFloat(originX) / pixelsPerPoint,
               y: CGFloat(originY) / pixelsPerPoint,
               width: CGFloat(pixelWidth) / pixelsPerPoint,
               height: CGFloat(pixelHeight) / pixelsPerPoint)
    }

    /// The furthest, in points, that anything drawn into the bitmap reaches.
    var support: CGFloat {
        CGFloat(boxHalfWidths.reduce(0, +) + 1) / pixelsPerPoint
    }

    init?(glow: TerminalTextGlow, dirtyRect: CGRect, bounds: CGRect, deviceScale: CGFloat) {
        guard glow.radius > 0, deviceScale.isFinite else { return nil }
        // A context drawn below 1x (a thumbnail) still gets pixels of at most
        // one point, which is what `TerminalTextGlow.influence` assumes.
        pixelsPerPoint = max(1, deviceScale)

        let total = max(1, Int((glow.radius * pixelsPerPoint).rounded()))
        boxHalfWidths = [total / 3, (total + 1) / 3, (total + 2) / 3]

        // Everything that can change a pixel of the dirty rectangle lies within
        // the blur's support of it, and so do all the pixels the blur's edge
        // treatment leaves inexact.
        let margin = CGFloat(total + 1) / pixelsPerPoint
        let area = dirtyRect.insetBy(dx: -margin, dy: -margin)
            .intersection(bounds.insetBy(dx: -margin, dy: -margin))
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let minX = Int((area.minX * pixelsPerPoint).rounded(.down))
        let minY = Int((area.minY * pixelsPerPoint).rounded(.down))
        let maxX = Int((area.maxX * pixelsPerPoint).rounded(.up))
        let maxY = Int((area.maxY * pixelsPerPoint).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        originX = minX
        originY = minY
        pixelWidth = maxX - minX
        pixelHeight = maxY - minY
    }
}
#endif

#if os(macOS)
import Accelerate

extension TerminalView {
    /// Paints the text glow for `rows` beneath the frame, clipped to
    /// `dirtyRect`.
    ///
    /// Called after the dirty rectangle is cleared and before any row is
    /// drawn, so the halo sits under backgrounds and text alike. The rows
    /// within the glow's reach of the dirty rectangle are drawn into the
    /// underlay too: their halos land in it.
    ///
    /// The text is drawn into the underlay opaque and the opacity applied to
    /// the blurred result, because Core Graphics leaves its fast paths for any
    /// alpha below 1: drawing the text at the glow's alpha cost a millisecond
    /// more per Retina frame than scaling the bitmap afterwards, and
    /// compositing the underlay with a context alpha cost twenty times a
    /// plain source-over (9.7 ms against 0.4 ms for 1600 × 1200 pixels).
    func drawTextGlowUnderlay(
        _ glow: TerminalTextGlow,
        dirtyRect: CGRect,
        rows: ClosedRange<Int>,
        snapshot: TerminalSnapshot,
        renderContext: SnapshotRenderContext,
        yOffset: CGFloat,
        bufferOffset: Int,
        in context: CGContext
    ) {
        let device = context.convertToDeviceSpace(CGSize(width: 1, height: 1))
        let deviceScale = max(abs(device.width), abs(device.height))
        guard let plan = TextGlowUnderlayPlan(
                glow: glow, dirtyRect: dirtyRect, bounds: bounds, deviceScale: deviceScale),
              let underlay = Self.makeGlowBitmap(plan: plan, matching: context)
        else { return }
        underlay.translateBy(x: -CGFloat(plan.originX), y: -CGFloat(plan.originY))
        underlay.scaleBy(x: plan.pixelsPerPoint, y: plan.pixelsPerPoint)

        let cellHeight = cellDimension.height
        let reach = glow.reachInRows(cellHeight: cellHeight)
        let area = plan.rect
        var drewRows = false
        for row in (rows.lowerBound - reach)...(rows.upperBound + reach) {
            guard row >= 0, let snapshotRow = snapshot.row(atAbsolute: row) else {
                continue
            }
            let lineOrigin = CGPoint(
                x: 0, y: frame.height - cellHeight * CGFloat(row - bufferOffset + 1))
            guard lineOrigin.y < area.maxY, lineOrigin.y + cellHeight > area.minY else {
                continue
            }
            let preparedRow = coreGraphicsRenderCache.preparedRow(
                row: snapshotRow,
                absoluteRow: row,
                context: renderContext,
                builder: textBuilder)
            let renderMode = snapshotRow.line.renderMode
            beginRenderMode(renderMode, lineOrigin: lineOrigin, width: bounds.width, in: underlay)
            drawRowForeground(
                preparedRow,
                lineOrigin: lineOrigin,
                renderMode: renderMode,
                yOffset: yOffset,
                defaultForeground: renderContext.effectiveForegroundColor,
                smoothFonts: false,
                decorations: false,
                in: underlay)
            endRenderMode(renderMode, in: underlay)
            drewRows = true
        }

        guard drewRows,
              Self.blur(underlay, halfWidths: plan.boxHalfWidths, opacity: glow.opacity),
              let image = underlay.makeImage() else { return }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.draw(image, in: plan.rect)
        context.restoreGState()
    }

    /// An 8-bit premultiplied bitmap for the underlay, in the destination's
    /// colour space when a bitmap can use it — so compositing it needs no
    /// colour matching — and sRGB otherwise.
    private static func makeGlowBitmap(plan: TextGlowUnderlayPlan, matching context: CGContext) -> CGContext? {
        func bitmap(_ space: CGColorSpace) -> CGContext? {
            CGContext(
                data: nil,
                width: plan.pixelWidth,
                height: plan.pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        if let space = context.colorSpace, space.model == .rgb, let matched = bitmap(space) {
            return matched
        }
        return CGColorSpace(name: CGColorSpace.sRGB).flatMap(bitmap)
    }

    /// Box-blurs a premultiplied RGBA bitmap in place, one pass per half-width,
    /// then scales every channel by `opacity`. Pixels beyond the edge read as
    /// transparent.
    private static func blur(_ bitmap: CGContext, halfWidths: [Int], opacity: CGFloat) -> Bool {
        guard let data = bitmap.data else { return false }
        let byteCount = bitmap.bytesPerRow * bitmap.height
        guard let scratch = malloc(byteCount) else { return false }
        defer { free(scratch) }
        var source = vImage_Buffer(
            data: data,
            height: vImagePixelCount(bitmap.height),
            width: vImagePixelCount(bitmap.width),
            rowBytes: bitmap.bytesPerRow)
        var destination = vImage_Buffer(
            data: scratch,
            height: source.height,
            width: source.width,
            rowBytes: source.rowBytes)
        let transparent: [UInt8] = [0, 0, 0, 0]
        for half in halfWidths where half > 0 {
            let size = UInt32(2 * half + 1)
            let status = vImageBoxConvolve_ARGB8888(
                &source, &destination, nil, 0, 0, size, size,
                transparent, vImage_Flags(kvImageBackgroundColorFill))
            guard status == kvImageNoError else { return false }
            swap(&source, &destination)
        }

        // Premultiplied, so scaling all four channels alike is the alpha
        // multiply. It writes into the bitmap from whichever buffer the last
        // pass left the result in (in place when that is the bitmap).
        let divisor: Int32 = 256
        let scale = Int16(max(0, min(CGFloat(divisor), (opacity * CGFloat(divisor)).rounded())))
        var matrix: [Int16] = [
            scale, 0, 0, 0,
            0, scale, 0, 0,
            0, 0, scale, 0,
            0, 0, 0, scale,
        ]
        var output = vImage_Buffer(
            data: data, height: source.height, width: source.width, rowBytes: source.rowBytes)
        let status = vImageMatrixMultiply_ARGB8888(
            &source, &output, &matrix, divisor, nil, nil, vImage_Flags(kvImageNoFlags))
        return status == kvImageNoError
    }
}
#endif
