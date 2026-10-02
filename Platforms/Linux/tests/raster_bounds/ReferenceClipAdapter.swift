import Foundation

// The frozen raster oracle predates compact context clips. Expand only at this test boundary so
// its scan converter and compositing code remain byte-for-byte frozen while the current context
// can pass the same clip coverage to both variants.
extension Rasterizer {
    static func fill(polygons: [[NSPoint]], evenOdd: Bool,
                     color: (CGFloat, CGFloat, CGFloat, CGFloat),
                     clip: [CGFloat]?, into bitmap: Bitmap, antialias: Bool) {
        precondition(antialias, "frozen reference measures the default antialiased path")
        fill(polygons: polygons, evenOdd: evenOdd, color: color, clip: clip, into: bitmap)
    }

    static func fill(polygons: [[NSPoint]], evenOdd: Bool,
                     color: (CGFloat, CGFloat, CGFloat, CGFloat),
                     region: RasterClip, into bitmap: Bitmap, antialias: Bool) {
        precondition(antialias, "frozen reference measures the default antialiased path")
        fill(polygons: polygons, evenOdd: evenOdd, color: color, region: region, into: bitmap)
    }

    static func mask(polygons: [[NSPoint]], evenOdd: Bool,
                     width: Int, height: Int, antialias: Bool) -> [CGFloat] {
        precondition(antialias, "frozen reference measures the default antialiased path")
        return mask(polygons: polygons, evenOdd: evenOdd, width: width, height: height)
    }

    static func fill(polygons: [[NSPoint]], evenOdd: Bool,
                     color: (CGFloat, CGFloat, CGFloat, CGFloat),
                     region: RasterClip, into bitmap: Bitmap) {
        var full = [CGFloat](repeating: 0, count: bitmap.width * bitmap.height)
        if region.width > 0, region.height > 0 {
            for y in 0..<region.height {
                for x in 0..<region.width {
                    full[(region.originY + y) * bitmap.width + region.originX + x] =
                        region.pixels[y * region.width + x]
                }
            }
        }
        fill(polygons: polygons, evenOdd: evenOdd, color: color, clip: full, into: bitmap)
    }
}
