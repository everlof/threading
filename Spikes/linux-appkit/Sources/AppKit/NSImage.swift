import Foundation

/// Decoded, bounded artwork. File decoding and resource lookup belong to the platform worker;
/// this leaf owns the real image sizing/drawing contract used by TemplateImageDrawing.
public final class NSImage {
    public static let maximumPixelDimension = 1024
    public var size: NSSize {
        didSet {
            precondition(size.width.isFinite && size.height.isFinite
                         && size.width >= 0 && size.height >= 0, "invalid image size")
        }
    }
    public var isTemplate = false
    private let width: Int
    private let height: Int
    private let rgba: [UInt8]

    /// Straight RGBA, row-major with the top row first; no row padding or implicit colour
    /// conversion. Invalid sizes/data refuse before allocating an image or multiplying lengths.
    public init?(rgba: [UInt8], width: Int, height: Int, size: NSSize? = nil) {
        guard (1...Self.maximumPixelDimension).contains(width),
              (1...Self.maximumPixelDimension).contains(height),
              rgba.count == width * height * 4 else { return nil }
        let naturalSize = size ?? NSSize(width: width, height: height)
        guard naturalSize.width.isFinite, naturalSize.height.isFinite,
              naturalSize.width >= 0, naturalSize.height >= 0 else { return nil }
        self.width = width; self.height = height; self.rgba = rgba
        self.size = naturalSize
    }

    public func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current,
              rect.width > 0, rect.height > 0 else { return }
        precondition([rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                     "nonfinite image destination")
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
                let sampled = sample(x: u * CGFloat(width) - 0.5, y: (1 - v) * CGFloat(height) - 0.5)
                let opacity = sampled.3
                context.composite(x: x, y: y,
                    color: (opacity > 0 ? sampled.0 / opacity : 0, opacity > 0 ? sampled.1 / opacity : 0,
                            opacity > 0 ? sampled.2 / opacity : 0, opacity * context.alpha),
                    coverage: coverage)
            }
        }
    }

    /// Bilinear sampling returns premultiplied RGBA; edge samples clamp within the actual image.
    private func sample(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
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
}
