import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Compiled beside the actual shim and Specimen sources by run.py. The native window's SDL
// transport and Pango text leaf are intentionally outside this raster-only comparison.
@MainActor
func render(_ root: NSView, scale: CGFloat = 2, background: NSColor, to path: String) throws {
    let bitmap = Bitmap(width: Int(root.frame.width * scale), height: Int(root.frame.height * scale),
                        background: background.components)
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = nil }
    root.render(in: context)
    try PNGWriter.write(bitmap, to: URL(fileURLWithPath: path))
}

@main
struct RasterBoundsFixture {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iterations = Int(CommandLine.arguments[2])!
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try saveMasks(output: output)

        let geometry = Bitmap(width: 257, height: 193, background: (0.1, 0.2, 0.3, 0.4))
        // Integer and fractional bounds, partially and entirely offscreen on either side,
        // narrow spans, opposite windings, disconnected polygons, and even-odd holes.
        let origins: [CGFloat] = [-290, -1.75, -0.001, 0, 0.25, 8.999, 127.125, 256.75, 290]
        for (index, x) in origins.enumerated() {
            let y = CGFloat(index * 17) - 3.25
            Rasterizer.fill(polygons: [rectangle(x, y, 13.75, 25.5)], evenOdd: false,
                color: (0.8, 0.25, 0.5, 0.7), clip: nil, into: geometry)
            Rasterizer.fill(polygons: [[NSPoint(x: x - 0.75, y: y + 10),
                NSPoint(x: x + 42.125, y: y - 7), NSPoint(x: x + 2.5, y: y + 31.75)]],
                evenOdd: false, color: (0.2, 0.8, 0.5, 0.37), clip: nil, into: geometry)
        }
        for x: CGFloat in [-1e30, 1e30] {
            Rasterizer.fill(polygons: [rectangle(x, 20, 13, 25)], evenOdd: false,
                color: (1, 0, 0, 1), clip: nil, into: geometry)
        }
        let outer = rectangle(60.25, 30.125, 121.5, 112.75)
        let inner = rectangle(85.75, 61.25, 53.125, 48.5)
        Rasterizer.fill(polygons: [outer, inner], evenOdd: true,
            color: (0.8, 0.1, 0.4, 0.4), clip: nil, into: geometry)
        Rasterizer.fill(polygons: [outer, Array(inner.reversed())], evenOdd: false,
            color: (0.1, 0.3, 0.8, 0.3), clip: nil, into: geometry)
        let fractionalMask = Rasterizer.mask(polygons: [rectangle(0.125, 7.75, 242.625, 150.5)],
                                            evenOdd: false, width: 257, height: 193)
        Rasterizer.fill(polygons: [rectangle(-20, -20, 300, 250)], evenOdd: false,
            color: (0.7, 0.3, 0.1, 0.2), clip: fractionalMask, into: geometry)
        try save(geometry, name: "fractional-offscreen-holes", output: output)

        let clipped = Bitmap(width: 321, height: 217, background: (0.2, 0.3, 0.4, 0.6))
        let context = NSGraphicsContext(bitmap: clipped, scale: 1)
        NSGraphicsContext.current = context
        context.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: 5.125, y: 9.75, width: 300.5, height: 194.25),
                     xRadius: 17, yRadius: 11).addClip()
        context.saveGraphicsState()
        context.translateBy(x: 15.5, y: 3.25)
        context.concat(CGAffineTransform(rotationAngle: 0.07))
        let hole = NSBezierPath(rect: NSRect(x: -8.25, y: 20.5, width: 280, height: 160.25))
        hole.appendRect(NSRect(x: 60.75, y: 45.125, width: 80.5, height: 60.75))
        hole.windingRule = .evenOdd
        hole.addClip()
        NSColor(red: 0.8, green: 0.2, blue: 0.7, alpha: 0.65).setFill()
        NSBezierPath(ovalIn: NSRect(x: -17.5, y: -3.25, width: 325.75, height: 220.125)).fill()
        NSColor(red: 0.1, green: 0.8, blue: 0.7, alpha: 0.35).setStroke()
        let stroke = NSBezierPath(roundedRect: NSRect(x: 30.25, y: 30.5, width: 160.75, height: 100.125),
                                  xRadius: 18.25, yRadius: 11.75)
        stroke.lineWidth = 3.25
        stroke.stroke()
        context.restoreGraphicsState()
        NSColor(white: 0.85, alpha: 0.4).setStroke()
        let crossing = NSBezierPath()
        crossing.move(to: NSPoint(x: -12.125, y: -4.75))
        crossing.line(to: NSPoint(x: 160.25, y: 190.125))
        crossing.line(to: NSPoint(x: 340.75, y: 2.25))
        crossing.lineWidth = 2.5
        crossing.stroke()
        context.restoreGraphicsState()
        NSGraphicsContext.current = nil
        try save(clipped, name: "nested-clips-translucent-strokes", output: output)

        // Exact specimen drawing used by WindowHarness before Pango labels are composited.
        // Normal and maximum native geometries, one row and a full bounded viewport.
        for (width, height, rows) in [(800, 480, 1), (800, 480, 8), (960, 600, 11),
                                     (1280, 900, 1), (1280, 900, 17)] {
            let name = "navigator-\(width)x\(height)-\(rows)rows"
            let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: width / 2, height: height / 2))
            root.title = ""
            let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
            let selectedInk = Specimen.Ink(on: accent)
            for index in 0..<rows {
                let top = Specimen.Window.titleHeight + 2 + CGFloat(index) * 24
                let frame = NSRect(x: 6, y: CGFloat(height / 2) - top - 22,
                                   width: CGFloat(width / 2 - 12), height: 22)
                root.addSubview(Specimen.Row(frame: frame, text: "", accent: accent, selected: index == 0,
                    ink: index == 0 ? selectedInk : root.bodyInk))
            }
            for iteration in 0..<iterations {
                let bitmap = Bitmap(width: width, height: height, background: (0.87, 0.87, 0.87, 1))
                let graphics = NSGraphicsContext(bitmap: bitmap, scale: 2)
                NSGraphicsContext.current = graphics
                #if RASTER_MASK_PROFILE
                RasterMaskProfile.reset()
                #endif
                #if RASTER_CPU_TIMINGS
                let cpuStarted = processCPUTime()
                #endif
                let started = DispatchTime.now().uptimeNanoseconds
                root.render(in: graphics)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                NSGraphicsContext.current = nil
                #if RASTER_CPU_TIMINGS
                let cpuElapsed = (processCPUTime() - cpuStarted) * 1_000
                print("RASTER_CPU \(name) iteration=\(iteration) milliseconds=\(cpuElapsed)")
                #endif
                print("RASTER_TIMING \(name) iteration=\(iteration) milliseconds=\(elapsed)")
                #if RASTER_MASK_PROFILE
                print("RASTER_MASK \(name) calls=\(RasterMaskProfile.calls) pixels=\(RasterMaskProfile.pixels) milliseconds=\(RasterMaskProfile.seconds * 1_000)")
                #endif
                fflush(stdout)
                if iteration == 0 { try save(bitmap, name: name, output: output) }
            }
        }
    }

    static func saveMasks(output: URL) throws {
        // Preserve exact CGFloat results, not only their final 8-bit image projection. The
        // narrowest spans straddle fill's threshold and alpha's half-byte rounding boundaries.
        var result = Data()
        let widths: [CGFloat] = [0, 0.000_000_5, 0.000_499_999, 0.0005, 0.000_500_001,
            0.5 / 255 - 0.000_000_01, 0.5 / 255, 0.5 / 255 + 0.000_000_01,
            1.5 / 255 - 0.000_000_01, 1.5 / 255, 1.5 / 255 + 0.000_000_01,
            0.25, 0.5, 0.999_999_99, 1, 1.25]
        for width in widths {
            for y: CGFloat in [-0.125, 0, 0.124_999, 0.125, 0.125_001, 0.75] {
                let polygons = [rectangle(0, y, width, 1)]
                let mask = Rasterizer.mask(polygons: polygons, evenOdd: false, width: 3, height: 3)
                for value in mask {
                    var bits = Double(value).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                }
            }
        }
        try result.write(to: output.appendingPathComponent("fractional-thresholds.mask"))
    }

    #if RASTER_CPU_TIMINGS
    static func processCPUTime() -> Double {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
    #endif

    static func rectangle(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [NSPoint] {
        [NSPoint(x: x, y: y), NSPoint(x: x + width, y: y),
         NSPoint(x: x + width, y: y + height), NSPoint(x: x, y: y + height)]
    }

    static func save(_ bitmap: Bitmap, name: String, output: URL) throws {
        try Data(bitmap.pixels).write(to: output.appendingPathComponent(name + ".rgba"))
        try PNGWriter.write(bitmap, to: output.appendingPathComponent(name + ".png"))
    }
}

#if RASTER_MASK_PROFILE
enum RasterMaskProfile {
    static var calls = 0
    static var pixels = 0
    static var seconds = 0.0
    static func reset() { calls = 0; pixels = 0; seconds = 0 }
    static func record(seconds elapsed: Double, pixels count: Int) {
        calls += 1
        pixels += count
        seconds += elapsed
    }
}
#endif
