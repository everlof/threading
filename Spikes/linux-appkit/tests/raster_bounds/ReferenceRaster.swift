// Frozen pre-X-bound implementation. Keep this independent of future raster optimizations;
// run.py compiles it in place of Raster.swift and compares exact output bytes.
import Foundation

/// The leaf the whole spike rests on: a scanline rasterizer with analytic horizontal coverage
/// and 4× vertical supersampling, compositing straight-alpha sRGB source-over.
///
/// Deliberately small. The question the spike asks is not "can we write a rasterizer" — Skia and
/// Cairo both exist — it is whether Threading's drawing code says anything a rasterizer cannot
/// hear. Everything here is replaceable by a real backend without the callers noticing.
public final class Bitmap: @unchecked Sendable {

    public let width: Int
    public let height: Int
    /// Straight (non-premultiplied) RGBA, 8 bits per component, row-major, top row first.
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, background: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)) {
        self.width = width
        self.height = height
        let component: (CGFloat) -> UInt8 = { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        let seed = [component(background.0), component(background.1), component(background.2), component(background.3)]
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = seed[0]; pixels[index + 1] = seed[1]
            pixels[index + 2] = seed[2]; pixels[index + 3] = seed[3]
        }
    }

    /// A platform text leaf can compose into the already rendered frame without copying it.
    /// The caller must finish its write before this closure returns.
    public func withMutablePixels<Result>(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Result)
        rethrows -> Result {
        try pixels.withUnsafeMutableBufferPointer { buffer in try body(buffer) }
    }

    // MARK: - Compositing

    func blend(x: Int, y: Int, red: CGFloat, green: CGFloat, blue: CGFloat, coverage: CGFloat) {
        guard x >= 0, x < width, y >= 0, y < height, coverage > 0 else { return }
        let index = (y * width + x) * 4
        let source = min(1, coverage)
        let destinationAlpha = CGFloat(pixels[index + 3]) / 255
        let outAlpha = source + destinationAlpha * (1 - source)
        guard outAlpha > 0 else { return }
        func mix(_ destination: UInt8, _ sourceValue: CGFloat) -> UInt8 {
            let d = CGFloat(destination) / 255
            let value = (sourceValue * source + d * destinationAlpha * (1 - source)) / outAlpha
            return UInt8(max(0, min(255, (value * 255).rounded())))
        }
        pixels[index] = mix(pixels[index], red)
        pixels[index + 1] = mix(pixels[index + 1], green)
        pixels[index + 2] = mix(pixels[index + 2], blue)
        pixels[index + 3] = UInt8(max(0, min(255, (outAlpha * 255).rounded())))
    }
}

// MARK: - Coverage

enum Rasterizer {

    static let subsamples = 4

    /// Fills `polygons` (already flattened, in device pixels, y-down) into `bitmap`.
    ///
    /// `clip`, when present, multiplies coverage — which is how `addClip()` is honoured without
    /// a second buffer per nesting level.
    static func fill(
        polygons: [[NSPoint]],
        evenOdd: Bool,
        color: (CGFloat, CGFloat, CGFloat, CGFloat),
        clip: [CGFloat]?,
        into bitmap: Bitmap
    ) {
        guard !polygons.isEmpty else { return }
        var edges: [(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, winding: CGFloat)] = []
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for polygon in polygons where polygon.count > 1 {
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                guard a.y != b.y else { continue }
                edges.append((a.x, a.y, b.x, b.y, b.y > a.y ? 1 : -1))
                minY = min(minY, min(a.y, b.y)); maxY = max(maxY, max(a.y, b.y))
            }
        }
        guard !edges.isEmpty else { return }

        let firstRow = max(0, Int(minY.rounded(.down)))
        let lastRow = min(bitmap.height - 1, Int(maxY.rounded(.up)))
        guard firstRow <= lastRow else { return }

        var coverage = [CGFloat](repeating: 0, count: bitmap.width)
        let step = 1 / CGFloat(subsamples)
        let weight = step

        for row in firstRow...lastRow {
            for index in coverage.indices { coverage[index] = 0 }
            for sub in 0..<subsamples {
                let sampleY = CGFloat(row) + (CGFloat(sub) + 0.5) * step
                var crossings: [(x: CGFloat, winding: CGFloat)] = []
                for edge in edges {
                    let (lowY, highY) = edge.y0 < edge.y1 ? (edge.y0, edge.y1) : (edge.y1, edge.y0)
                    guard sampleY >= lowY, sampleY < highY else { continue }
                    let t = (sampleY - edge.y0) / (edge.y1 - edge.y0)
                    crossings.append((edge.x0 + t * (edge.x1 - edge.x0), edge.winding))
                }
                guard crossings.count > 1 else { continue }
                crossings.sort { $0.x < $1.x }

                var winding: CGFloat = 0
                for index in 0..<(crossings.count - 1) {
                    winding += evenOdd ? 1 : crossings[index].winding
                    let inside = evenOdd ? Int(winding) % 2 != 0 : winding != 0
                    guard inside else { continue }
                    span(from: crossings[index].x, to: crossings[index + 1].x, weight: weight, into: &coverage)
                }
            }
            for column in 0..<bitmap.width {
                var value = coverage[column] * color.3
                if let clip { value *= clip[row * bitmap.width + column] }
                guard value > 0.0005 else { continue }
                bitmap.blend(x: column, y: row, red: color.0, green: color.1, blue: color.2, coverage: value)
            }
        }
    }

    /// Adds a horizontal span's coverage with fractional ends, so a vertical edge at x = 10.25
    /// leaves 0.75 in that pixel rather than a jagged 0 or 1.
    private static func span(from startX: CGFloat, to endX: CGFloat, weight: CGFloat, into coverage: inout [CGFloat]) {
        let start = max(0, startX)
        let end = min(CGFloat(coverage.count), endX)
        guard end > start else { return }
        let firstPixel = Int(start.rounded(.down))
        let lastPixel = min(coverage.count - 1, Int((end - 0.000_001).rounded(.down)))
        guard firstPixel <= lastPixel else { return }
        if firstPixel == lastPixel {
            coverage[firstPixel] += (end - start) * weight
            return
        }
        coverage[firstPixel] += (CGFloat(firstPixel + 1) - start) * weight
        if firstPixel + 1 <= lastPixel - 1 {
            for pixel in (firstPixel + 1)...(lastPixel - 1) { coverage[pixel] += weight }
        }
        coverage[lastPixel] += (end - CGFloat(lastPixel)) * weight
    }

    /// The same coverage, accumulated into a clip mask instead of pixels.
    static func mask(polygons: [[NSPoint]], evenOdd: Bool, width: Int, height: Int) -> [CGFloat] {
        let probe = Bitmap(width: width, height: height)
        fill(polygons: polygons, evenOdd: evenOdd, color: (1, 1, 1, 1), clip: nil, into: probe)
        var mask = [CGFloat](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            mask[index] = CGFloat(probe.pixels[index * 4 + 3]) / 255
        }
        return mask
    }
}
