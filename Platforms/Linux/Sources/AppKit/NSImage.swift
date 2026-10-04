import Foundation

/// Raw values match AppKit, including its non-sequential `medium` value.
public enum NSImageInterpolation: Int, Sendable {
    case `default` = 0
    case none = 1
    case low = 2
    case high = 3
    case medium = 4
}

public enum NSImageRep {
    public enum HintKey: String, Hashable, Sendable {
        case interpolation = "NSImageHintInterpolation"
    }
}

/// Decoded, bounded artwork. File decoding and resource lookup belong to the platform worker;
/// this leaf owns the real image sizing/drawing contract used by TemplateImageDrawing.
public final class NSImage {
    /// The host supplies platform artwork for SF Symbol names. Keeping lookup here gives
    /// production views the AppKit initializer without baking a diagnostic glyph catalogue
    /// into the graphics shim.
    @MainActor public static var systemSymbolProvider: ((String, String?) -> NSImage?)?

    /// Symbol sizing requested by a view. The Linux symbol provider remains app-owned; decoded
    /// artwork keeps its own dimensions, while the configuration travels with the image view.
    public struct SymbolConfiguration: Sendable {
        public let pointSize: CGFloat
        public let weight: NSFont.Weight

        public init(pointSize: CGFloat, weight: NSFont.Weight) {
            self.pointSize = pointSize
            self.weight = weight
        }
    }

    public static let maximumPixelDimension = 1024
    public var size: NSSize {
        didSet {
            precondition(size.width.isFinite && size.height.isFinite
                         && size.width >= 0 && size.height >= 0, "invalid image size")
        }
    }
    public var isTemplate = false
    public var accessibilityDescription: String?
    private let width: Int
    private let height: Int
    private let rgba: [UInt8]

    private init(validatedRGBA: [UInt8], width: Int, height: Int, size: NSSize) {
        self.width = width; self.height = height; self.rgba = validatedRGBA
        self.size = size
    }

    /// Straight RGBA, row-major with the top row first; no row padding or implicit colour
    /// conversion. Invalid sizes/data refuse before allocating an image or multiplying lengths.
    public convenience init?(rgba: [UInt8], width: Int, height: Int, size: NSSize? = nil) {
        guard (1...Self.maximumPixelDimension).contains(width),
              (1...Self.maximumPixelDimension).contains(height),
              rgba.count == width * height * 4 else { return nil }
        let naturalSize = size ?? NSSize(width: width, height: height)
        guard naturalSize.width.isFinite, naturalSize.height.isFinite,
              naturalSize.width >= 0, naturalSize.height >= 0 else { return nil }
        self.init(validatedRGBA: rgba, width: width, height: height, size: naturalSize)
    }

    @MainActor public convenience init?(systemSymbolName: String,
                                        accessibilityDescription: String?) {
        guard let symbol = Self.systemSymbolProvider?(systemSymbolName,
                                                      accessibilityDescription) else { return nil }
        self.init(validatedRGBA: symbol.rgba, width: symbol.width, height: symbol.height,
                  size: symbol.size)
        isTemplate = symbol.isTemplate
        self.accessibilityDescription = accessibilityDescription
    }

    /// Preserve the provider's raster artwork while applying the requested point-size canvas.
    /// The host authors supported symbol weights in its raster artwork.
    public func withSymbolConfiguration(_ configuration: SymbolConfiguration) -> NSImage {
        precondition(configuration.pointSize.isFinite && configuration.pointSize > 0,
                     "invalid symbol configuration")
        let image = NSImage(validatedRGBA: rgba, width: width, height: height,
                            size: NSSize(width: configuration.pointSize,
                                         height: configuration.pointSize))
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// A small AppKit drawing-handler image, rasterized eagerly at the diagnostic window's 2×
    /// backing scale. The callback is bounded by the same maximum as decoded artwork; the
    /// production generated project icon uses a 16-point canvas and is cached after this pass.
    public convenience init(size: NSSize, flipped: Bool,
                            drawingHandler: (NSRect) -> Bool) {
        precondition(size.width.isFinite && size.height.isFinite
                     && size.width > 0 && size.height > 0, "invalid drawing-handler image size")
        let scale: CGFloat = 2
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        precondition((1...Self.maximumPixelDimension).contains(pixelWidth)
                     && (1...Self.maximumPixelDimension).contains(pixelHeight),
                     "drawing-handler image exceeds pixel limit")
        let bitmap = Bitmap(width: pixelWidth, height: pixelHeight)
        let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        if flipped { context.flipVertically(in: size.height) }
        _ = drawingHandler(NSRect(origin: .zero, size: size))
        NSGraphicsContext.current = previous
        self.init(validatedRGBA: bitmap.pixels, width: pixelWidth, height: pixelHeight, size: size)
    }

    public func draw(in rect: NSRect) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
             respectFlipped: false, hints: nil)
    }

    /// Draw a source rectangle in image points. `.zero` denotes the whole image, as in AppKit.
    /// The quality hint takes precedence over the current context setting for this draw only.
    public func draw(in rect: NSRect, from sourceRect: NSRect,
                     operation: NSGraphicsContext.CompositingOperation, fraction: CGFloat,
                     respectFlipped: Bool, hints: [NSImageRep.HintKey: Any]?) {
        guard let context = NSGraphicsContext.current,
              rect.width > 0, rect.height > 0 else { return }
        let source = sourceRect == .zero ? NSRect(origin: .zero, size: size) : sourceRect
        guard size.width > 0, size.height > 0,
              source.width > 0, source.height > 0 else { return }
        precondition([rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                     "nonfinite image destination")
        precondition([source.minX, source.minY, source.maxX, source.maxY].allSatisfy(\.isFinite),
                     "nonfinite image source")
        precondition(fraction.isFinite, "nonfinite image opacity")
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.compositingOperation = operation
        context.alpha *= min(1, max(0, fraction))
        let interpolation: NSImageInterpolation = {
            if let value = hints?[.interpolation] as? NSImageInterpolation { return value }
            if let raw = hints?[.interpolation] as? Int,
               let value = NSImageInterpolation(rawValue: raw) { return value }
            return context.imageInterpolation
        }()
        let transform = context.transform
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 0.000_000_001 else { return }
        let corners = [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                       NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY)]
            .map(transform.apply)
        precondition(corners.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "nonfinite image transform")
        let left = Int(max(0, min(CGFloat(context.bitmap.width), corners.map(\.x).min()!.rounded(.down))))
        let right = Int(max(0, min(CGFloat(context.bitmap.width), corners.map(\.x).max()!.rounded(.up))))
        let top = Int(max(0, min(CGFloat(context.bitmap.height), corners.map(\.y).min()!.rounded(.down))))
        let bottom = Int(max(0, min(CGFloat(context.bitmap.height), corners.map(\.y).max()!.rounded(.up))))
        guard left < right, top < bottom else { return }
        // Sample in premultiplied space so a transparent border never adds black fringes.
        // Coverage uses four samples per axis at fractional/rotated destination edges. Artwork
        // samples at the pixel centre, preserving exact pixels for an aligned 1:1 rendition.
        // Work is bounded by the visible transformed destination, with no image-sized mask.
        let steps = context.shouldAntialias ? 4 : 1
        let weight = 1 / CGFloat(steps * steps)
        let sourcePixelsWide = source.width / size.width * CGFloat(width)
        let sourcePixelsHigh = source.height / size.height * CGFloat(height)
        let destinationPixelsWide = hypot(transform.a, transform.b) * rect.width
        let destinationPixelsHigh = hypot(transform.c, transform.d) * rect.height
        let footprintX = sourcePixelsWide / max(0.000_001, destinationPixelsWide)
        let footprintY = sourcePixelsHigh / max(0.000_001, destinationPixelsHigh)
        let flipped = respectFlipped && context.isFlipped
        for y in top..<bottom {
            for x in left..<right {
                var coverage: CGFloat = 0
                for sy in 0..<steps {
                    for sx in 0..<steps {
                        let dx = CGFloat(x) + (CGFloat(sx) + 0.5) / CGFloat(steps) - transform.tx
                        let dy = CGFloat(y) + (CGFloat(sy) + 0.5) / CGFloat(steps) - transform.ty
                        let u = ((transform.d * dx - transform.c * dy) / determinant - rect.minX) / rect.width
                        let v = ((-transform.b * dx + transform.a * dy) / determinant - rect.minY) / rect.height
                        guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                        coverage += weight
                    }
                }
                guard coverage > 0 else { continue }
                let dx = CGFloat(x) + 0.5 - transform.tx, dy = CGFloat(y) + 0.5 - transform.ty
                let u = ((transform.d * dx - transform.c * dy) / determinant - rect.minX) / rect.width
                let v = ((-transform.b * dx + transform.a * dy) / determinant - rect.minY) / rect.height
                let imageX = (source.minX + u * source.width) / size.width * CGFloat(width) - 0.5
                let sourceY = flipped ? source.maxY - v * source.height
                                      : source.minY + v * source.height
                let imageY = (size.height - sourceY) / size.height * CGFloat(height) - 0.5
                let sampled = sample(x: imageX, y: imageY, interpolation: interpolation,
                                     footprintX: footprintX, footprintY: footprintY)
                let opacity = sampled.3
                context.composite(x: x, y: y,
                    color: (opacity > 0 ? sampled.0 / opacity : 0, opacity > 0 ? sampled.1 / opacity : 0,
                            opacity > 0 ? sampled.2 / opacity : 0, opacity * context.alpha),
                    coverage: coverage)
            }
        }
    }

    /// All filtered paths work in premultiplied space, so transparent image edges cannot
    /// introduce the RGB value stored behind their zero alpha. Sampling never allocates a
    /// destination-sized intermediate; even high-quality downsampling has a fixed tap bound.
    private func sample(x: CGFloat, y: CGFloat, interpolation: NSImageInterpolation,
                        footprintX: CGFloat, footprintY: CGFloat)
        -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch interpolation {
        case .none:
            let x = Int(max(0, min(CGFloat(width - 1), x.rounded())))
            let y = Int(max(0, min(CGFloat(height - 1), y.rounded())))
            let offset = (y * width + x) * 4
            let alpha = CGFloat(rgba[offset + 3]) / 255
            return (CGFloat(rgba[offset]) / 255 * alpha,
                    CGFloat(rgba[offset + 1]) / 255 * alpha,
                    CGFloat(rgba[offset + 2]) / 255 * alpha, alpha)
        case .default, .low:
            return sampleBilinear(x: x, y: y)
        case .medium, .high:
            if footprintX > 1.2 || footprintY > 1.2 {
                let xSteps = Int(min(4, max(1, ceil(footprintX))))
                let ySteps = Int(min(4, max(1, ceil(footprintY))))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                for sy in 0..<ySteps {
                    for sx in 0..<xSteps {
                        let offsetX = (CGFloat(sx) + 0.5) / CGFloat(xSteps) - 0.5
                        let offsetY = (CGFloat(sy) + 0.5) / CGFloat(ySteps) - 0.5
                        let pixel = sampleBilinear(x: x + offsetX * footprintX,
                                                   y: y + offsetY * footprintY)
                        r += pixel.0; g += pixel.1; b += pixel.2; a += pixel.3
                    }
                }
                let count = CGFloat(xSteps * ySteps)
                return (r / count, g / count, b / count, a / count)
            }
            return sampleBicubic(x: x, y: y)
        }
    }

    private func sampleBilinear(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let x = max(0, min(CGFloat(width - 1), x)), y = max(0, min(CGFloat(height - 1), y))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = x - CGFloat(x0), fy = y - CGFloat(y0)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        for (px, py, weight) in [(x0, y0, (1 - fx) * (1 - fy)), (x1, y0, fx * (1 - fy)),
                                 (x0, y1, (1 - fx) * fy), (x1, y1, fx * fy)] {
            let offset = (py * width + px) * 4
            let alpha = CGFloat(rgba[offset + 3]) / 255 * weight
            r += CGFloat(rgba[offset]) / 255 * alpha
            g += CGFloat(rgba[offset + 1]) / 255 * alpha
            b += CGFloat(rgba[offset + 2]) / 255 * alpha
            a += alpha
        }
        return (r, g, b, a)
    }

    private func sampleBicubic(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        func weight(_ distance: CGFloat) -> CGFloat {
            let t = abs(distance)
            if t < 1 { return 1.5 * t * t * t - 2.5 * t * t + 1 }
            if t < 2 { return -0.5 * t * t * t + 2.5 * t * t - 4 * t + 2 }
            return 0
        }
        let baseX = Int(floor(x)), baseY = Int(floor(y))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        for py in (baseY - 1)...(baseY + 2) {
            let wy = weight(y - CGFloat(py))
            guard wy != 0 else { continue }
            let cy = max(0, min(height - 1, py))
            for px in (baseX - 1)...(baseX + 2) {
                let contribution = wy * weight(x - CGFloat(px))
                guard contribution != 0 else { continue }
                let cx = max(0, min(width - 1, px))
                let offset = (cy * width + cx) * 4
                let alpha = CGFloat(rgba[offset + 3]) / 255 * contribution
                r += CGFloat(rgba[offset]) / 255 * alpha
                g += CGFloat(rgba[offset + 1]) / 255 * alpha
                b += CGFloat(rgba[offset + 2]) / 255 * alpha
                a += alpha
            }
        }
        a = max(0, min(1, a))
        return (max(0, min(a, r)), max(0, min(a, g)), max(0, min(a, b)), a)
    }
}
