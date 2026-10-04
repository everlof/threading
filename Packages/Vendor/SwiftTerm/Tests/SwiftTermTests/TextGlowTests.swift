//
//  TextGlowTests.swift
//  SwiftTermTests
//
//  The Core Graphics text glow: a halo in each run's own colour, never on
//  decorations, a dirty region widened by exactly the rows a halo can reach,
//  and a partial repaint that is pixel-identical to a full one.
//
//  The drawing tests call `drawTerminalContents` into their own persistent
//  Retina bitmap rather than going through `cacheDisplay`, because the
//  property under test is what a *partial* repaint leaves behind in a backing
//  store that already holds the previous frame, which `cacheDisplay` (always a
//  fresh image of the requested rectangle) cannot show.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
@Suite("Text glow", .serialized)
struct TextGlowTests {
    private static let scale: CGFloat = 2

    private func makeView(cols: Int = 20, rows: Int = 8) -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 480, height: 200),
            font: nil,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 40))
        view.setFrameSize(CGSize(
            width: view.cellDimension.width * CGFloat(cols),
            height: view.cellDimension.height * CGFloat(rows)))
        view.suspendsRenderingWhenNotVisible = false
        return view
    }

    /// A persistent backing store: premultiplied RGBA at 2x, bottom-up like an
    /// unflipped view.
    private final class Canvas {
        let context: CGContext
        let width: Int
        let height: Int

        init(size: CGSize, scale: CGFloat) {
            width = Int((size.width * scale).rounded())
            height = Int((size.height * scale).rounded())
            context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: scale, y: scale)
        }

        var bytes: [UInt8] {
            let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
        }

        /// Sum of alpha and of each premultiplied channel over a rectangle in
        /// view points, measured from the view's bottom-left like AppKit.
        func totals(in rect: CGRect, scale: CGFloat) -> (alpha: Int, red: Int, green: Int, blue: Int) {
            let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
            let minX = max(0, Int((rect.minX * scale).rounded()))
            let maxX = min(width, Int((rect.maxX * scale).rounded()))
            // Memory row 0 is the top of the image; view y grows upward.
            let minRow = max(0, height - Int((rect.maxY * scale).rounded()))
            let maxRow = min(height, height - Int((rect.minY * scale).rounded()))
            var alpha = 0, red = 0, green = 0, blue = 0
            for row in minRow..<maxRow {
                for x in minX..<maxX {
                    let offset = (row * width + x) * 4
                    red += Int(pointer[offset])
                    green += Int(pointer[offset + 1])
                    blue += Int(pointer[offset + 2])
                    alpha += Int(pointer[offset + 3])
                }
            }
            return (alpha, red, green, blue)
        }
    }

    /// What AppKit does for one dirty rectangle: clip to it, then draw it.
    private func draw(_ view: TerminalView, _ rect: CGRect, into canvas: Canvas) {
        let graphics = NSGraphicsContext(cgContext: canvas.context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        canvas.context.saveGState()
        canvas.context.clip(to: rect)
        view.drawTerminalContents(dirtyRect: rect, context: canvas.context, bufferOffset: 0)
        canvas.context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func prepare(_ view: TerminalView) -> CGRect? {
        view.prepareFrame(viewState: FrameViewState(view: view))?.region
    }

    /// The rectangle of whole terminal rows `first...last`, in view points.
    private func rowsRect(_ view: TerminalView, _ first: Int, _ last: Int) -> CGRect {
        let cellHeight = view.cellDimension.height
        return CGRect(
            x: 0,
            y: view.frame.height - CGFloat(last + 1) * cellHeight,
            width: view.bounds.width,
            height: CGFloat(last - first + 1) * cellHeight)
    }

    // MARK: - Model

    @Test func anOffGlowIsNilAndALargeOneIsClamped() {
        #expect(TerminalTextGlow(radius: 0, opacity: 0.5).normalized == nil)
        #expect(TerminalTextGlow(radius: 3, opacity: 0).normalized == nil)
        #expect(TerminalTextGlow(radius: .nan, opacity: 0.5).normalized == nil)
        #expect(TerminalTextGlow(radius: -2, opacity: 0.5).normalized == nil)
        let clamped = TerminalTextGlow(radius: 400, opacity: 3).normalized
        #expect(clamped == TerminalTextGlow(radius: TerminalTextGlow.maximumRadius, opacity: 1))

        let view = makeView()
        view.textGlow = TerminalTextGlow(radius: 0, opacity: 0.4)
        #expect(view.textGlow == nil)
        view.textGlow = TerminalTextGlow(radius: 3, opacity: 0.4)
        #expect(view.textGlow == TerminalTextGlow(radius: 3, opacity: 0.4))
    }

    @Test func reachIsTheInfluenceInWholeRows() {
        #expect(TerminalTextGlow(radius: 3, opacity: 1).reachInRows(cellHeight: 16) == 1)
        #expect(TerminalTextGlow(radius: 6, opacity: 1).reachInRows(cellHeight: 16) == 1)
        #expect(TerminalTextGlow(radius: 14.5, opacity: 1).reachInRows(cellHeight: 16) == 1)
        #expect(TerminalTextGlow(radius: 15, opacity: 1).reachInRows(cellHeight: 16) == 2)
        #expect(TerminalTextGlow(radius: 0.5, opacity: 1).influence > 0.5)
    }

    /// The influence bound has to hold at every scale the draw may use, since
    /// the frame tick pads by it without knowing which one that is.
    @Test func theUnderlayNeverReachesFurtherThanTheInfluence() throws {
        for radius in stride(from: CGFloat(0.5), through: 16, by: 0.25) {
            let glow = TerminalTextGlow(radius: radius, opacity: 1)
            for scale in [CGFloat(1), 1.5, 2, 3] {
                let plan = try #require(TextGlowUnderlayPlan(
                    glow: glow,
                    dirtyRect: CGRect(x: 100, y: 100, width: 50, height: 50),
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                    deviceScale: scale))
                #expect(plan.support <= glow.influence,
                        "radius \(radius) at \(scale)x reaches \(plan.support), past \(glow.influence)")
                #expect(plan.support >= radius - 0.5 / scale, "the halo is shorter than its radius")
                // Device pixels, drawn back 1:1: what exactness rests on.
                #expect(plan.pixelsPerPoint == scale)
                // The bitmap covers the dirty rectangle plus the whole support.
                #expect(plan.rect.insetBy(dx: plan.support - 0.000_1, dy: plan.support - 0.000_1)
                    .contains(CGRect(x: 100, y: 100, width: 50, height: 50)))
            }
        }
    }

    // MARK: - Pixels

    /// A red glyph alone on a row: with no glow the rows above and below hold
    /// nothing; with a glow they hold red, and only red.
    @Test func aGlyphsNeighbouringRowsGainItsColourOnlyWithAGlow() throws {
        let view = makeView(cols: 10, rows: 3)
        view.feed(text: "\u{1b}[2;5H\u{1b}[38;2;255;0;0mW\u{1b}[0m")
        _ = prepare(view)

        let above = rowsRect(view, 0, 0)
        let below = rowsRect(view, 2, 2)

        let plain = Canvas(size: view.bounds.size, scale: Self.scale)
        draw(view, view.bounds, into: plain)
        let glyphRow = plain.totals(in: rowsRect(view, 1, 1), scale: Self.scale)
        #expect(glyphRow.alpha > 0, "the glyph itself drew nothing")
        #expect(plain.totals(in: above, scale: Self.scale).alpha == 0)
        #expect(plain.totals(in: below, scale: Self.scale).alpha == 0)

        view.textGlow = TerminalTextGlow(radius: 6, opacity: 0.8)
        _ = prepare(view)
        let glowing = Canvas(size: view.bounds.size, scale: Self.scale)
        draw(view, view.bounds, into: glowing)

        for (name, rect) in [("above", above), ("below", below)] {
            let halo = glowing.totals(in: rect, scale: Self.scale)
            #expect(halo.alpha > 0, "no halo reached the row \(name)")
            #expect(halo.red > 0, "the halo \(name) is not red")
            #expect(halo.green == 0 && halo.blue == 0,
                    "the halo \(name) is not in the run's colour: \(halo)")
        }
    }

    /// Each run glows in its own ink: a green glyph's halo is green.
    @Test func eachRunGlowsInItsOwnColour() throws {
        let view = makeView(cols: 12, rows: 3)
        view.textGlow = TerminalTextGlow(radius: 6, opacity: 0.8)
        view.feed(text: "\u{1b}[2;2H\u{1b}[38;2;255;0;0mW\u{1b}[2;10H\u{1b}[38;2;0;255;0mW\u{1b}[0m")
        _ = prepare(view)
        let canvas = Canvas(size: view.bounds.size, scale: Self.scale)
        draw(view, view.bounds, into: canvas)

        let cellWidth = view.cellDimension.width
        let above = rowsRect(view, 0, 0)
        let overRed = CGRect(x: cellWidth * 1, y: above.minY, width: cellWidth, height: above.height)
        let overGreen = CGRect(x: cellWidth * 9, y: above.minY, width: cellWidth, height: above.height)
        let red = canvas.totals(in: overRed, scale: Self.scale)
        let green = canvas.totals(in: overGreen, scale: Self.scale)
        #expect(red.alpha > 0 && red.red > 0 && red.green == 0)
        #expect(green.alpha > 0 && green.green > 0 && green.red == 0)
    }

    /// An underline is a rule, not lit text: an underlined space draws its
    /// underline and casts nothing into the row below.
    @Test func decorationsDoNotGlow() throws {
        let view = makeView(cols: 10, rows: 3)
        view.textGlow = TerminalTextGlow(radius: 6, opacity: 0.8)
        view.feed(text: "\u{1b}[2;3H\u{1b}[4;38;2;255;0;0m    \u{1b}[0m")
        _ = prepare(view)
        let canvas = Canvas(size: view.bounds.size, scale: Self.scale)
        draw(view, view.bounds, into: canvas)

        #expect(canvas.totals(in: rowsRect(view, 1, 1), scale: Self.scale).alpha > 0,
                "the underline did not draw")
        #expect(canvas.totals(in: rowsRect(view, 2, 2), scale: Self.scale).alpha == 0,
                "the underline cast a halo")
    }

    // MARK: - Dirty regions

    /// With no glow the region is exactly what it always was; with one it
    /// grows by the halo's reach on both sides of the changed row.
    @Test func theDirtyRegionGrowsByTheReachOnlyWithAGlow() throws {
        let view = makeView(cols: 20, rows: 10)
        view.feed(text: (0..<10).map { "row \($0)" }.joined(separator: "\r\n"))
        _ = prepare(view)

        view.feed(text: "\u{1b}[5;1HX")
        let plain = try #require(prepare(view))
        #expect(plain.minY <= rowsRect(view, 4, 4).minY)
        #expect(plain.maxY == rowsRect(view, 4, 4).maxY,
                "the unglowing region changed shape")

        let glow = TerminalTextGlow(radius: 4, opacity: 0.5)
        view.textGlow = glow
        _ = prepare(view)  // the change itself repaints everything

        view.feed(text: "\u{1b}[5;1HY")
        let padded = try #require(prepare(view))
        let reach = glow.reachInRows(cellHeight: view.cellDimension.height)
        #expect(reach >= 1)
        let expected = rowsRect(view, 4 - reach, 4 + reach)
        #expect(padded.minY <= expected.minY)
        #expect(padded.maxY >= expected.maxY)
        #expect(padded.maxY == expected.maxY, "the region grew further than the reach")
    }

    @Test func settingAGlowRepaintsEveryRow() throws {
        let view = makeView(cols: 20, rows: 10)
        view.feed(text: "steady")
        _ = prepare(view)
        #expect(prepare(view) == nil)

        view.textGlow = TerminalTextGlow(radius: 3, opacity: 0.4)
        let region = try #require(prepare(view))
        #expect(region.contains(rowsRect(view, 0, 9)))

        _ = prepare(view)
        view.textGlow = nil
        let cleared = try #require(prepare(view))
        #expect(cleared.contains(rowsRect(view, 0, 9)))
    }

    /// The exactness rule. A row changes; the frame repaints only its region
    /// into a backing store holding the previous frame. The result must be the
    /// pixels a full repaint of the new frame produces — the old halo gone from
    /// the neighbours, the new halo drawn, and the halos the neighbours cast
    /// into the region put back.
    @Test(arguments: [
        nil,
        TerminalTextGlow(radius: 1.5, opacity: 0.5),
        TerminalTextGlow(radius: 4, opacity: 0.6),
        TerminalTextGlow(radius: 6, opacity: 0.8),
    ])
    func aPartialRepaintMatchesAFullOne(glow: TerminalTextGlow?) throws {
        // Retina and 1x, because the underlay's lattice is derived from it.
        for scale in [Self.scale, 1] {
            let view = makeView(cols: 20, rows: 10)
            view.textGlow = glow
            view.feed(text: (0..<10).map { "\u{1b}[38;5;\(1 + $0)mline \($0) WWWW" }
                .joined(separator: "\r\n"))
            _ = prepare(view)
            let store = Canvas(size: view.bounds.size, scale: scale)
            draw(view, view.bounds, into: store)

            view.feed(text: "\u{1b}[5;1H\u{1b}[38;2;255;255;0m#### changed ####\u{1b}[0m")
            let region = try #require(prepare(view))
            #expect(region != view.bounds, "the test needs a partial region")
            draw(view, region, into: store)

            let reference = Canvas(size: view.bounds.size, scale: scale)
            draw(view, view.bounds, into: reference)

            let partial = store.bytes
            let full = reference.bytes
            var worst = 0
            var differing = 0
            for index in partial.indices where partial[index] != full[index] {
                differing += 1
                worst = max(worst, abs(Int(partial[index]) - Int(full[index])))
            }
            #expect(differing == 0,
                    "glow \(String(describing: glow)) at \(scale)x: \(differing) bytes differ, worst by \(worst)")
        }
    }
}

// MARK: - Opt-in cost measurement

/// Frame-draw cost with and without a glow, through the production draw into a
/// Retina bitmap. Off by default; run it with
///
///     SWIFTTERM_GLOW_BENCH=1 swift test -c release -Xswiftc -enable-testing \
///         --filter TextGlowCost
///
/// It drives `drawTerminalContents` directly instead of an on-screen window so
/// it measures the same work on every run whether or not a display is awake:
/// RenderBench needs a window the window server is compositing.
@MainActor
@Suite("Text glow cost", .serialized)
struct TextGlowCostTests {
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// RenderBench's own shapes: `dense` gives every cell a truecolor
    /// foreground and background, `scroll` scrolls a screen of plain ASCII,
    /// and `line` rewrites one row in place — the status-line case, and the one
    /// whose region the glow widens.
    private static func frames(_ scenario: String, cols: Int, rows: Int, count: Int) -> [String] {
        var rng = SplitMix64(state: 42)
        return (0..<count).map { index in
            var out = ""
            switch scenario {
            case "dense":
                for row in 1...rows {
                    out += "\u{1b}[\(row);1H"
                    for _ in 0..<cols {
                        out += "\u{1b}[38;2;\(rng.below(216));\(rng.below(216));\(rng.below(216));"
                            + "48;2;\(rng.below(216));\(rng.below(216));\(rng.below(216))m"
                        out.unicodeScalars.append(UnicodeScalar(UInt8(33 + rng.below(93))))
                    }
                }
            case "scroll":
                for _ in 0..<rows {
                    for _ in 0..<(cols - 1) {
                        out.unicodeScalars.append(UnicodeScalar(UInt8(97 + rng.below(26))))
                    }
                    out += "\r\n"
                }
            default:
                out += "\u{1b}[\(1 + index % rows);1H\u{1b}[2K"
                for _ in 0..<(cols - 1) {
                    out.unicodeScalars.append(UnicodeScalar(UInt8(97 + rng.below(26))))
                }
            }
            return out
        }
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTERM_GLOW_BENCH"] == "1"))
    func measureFrameDrawWithAndWithoutGlow() throws {
        let rounds = Int(ProcessInfo.processInfo.environment["SWIFTTERM_GLOW_BENCH_ROUNDS"] ?? "") ?? 5
        let framesPerRound = 40
        let configurations: [(String, TerminalTextGlow?)] = [
            ("off", nil),
            ("3pt/0.40", TerminalTextGlow(radius: 3, opacity: 0.4)),
            ("6pt/0.80", TerminalTextGlow(radius: 6, opacity: 0.8)),
        ]
        var lines: [String] = []
        for scenario in ["dense", "scroll", "line"] {
            // RenderBench's window: 800 x 600 points.
            let view = TerminalView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                font: nil,
                options: TerminalOptions(cols: 80, rows: 25, scrollback: 500))
            view.suspendsRenderingWhenNotVisible = false
            let cols = view.terminalDimensions.cols
            let rows = view.terminalDimensions.rows
            let script = Self.frames(scenario, cols: cols, rows: rows, count: framesPerRound)
            let width = Int(800 * 2), height = Int(600 * 2)
            let context = try #require(CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)

            var samples = Array(repeating: [Double](), count: configurations.count)
            var areas = Array(repeating: 0.0, count: configurations.count)
            var rowsBuilt = Array(repeating: 0, count: configurations.count)
            // Interleaved by round so drift in machine load lands on every
            // configuration alike; the first round is warm-up.
            for round in 0...rounds {
                for (index, configuration) in configurations.enumerated() {
                    view.textGlow = configuration.1
                    view.feed(text: "\u{1b}[H\u{1b}[2J")
                    _ = view.prepareFrame(viewState: FrameViewState(view: view))
                    for frame in script {
                        view.feed(text: frame)
                        let region = view.prepareFrame(viewState: FrameViewState(view: view))?.region
                            ?? view.bounds
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = graphics
                        context.saveGState()
                        context.clip(to: region)
                        view.resetDiagnostics()
                        let start = DispatchTime.now().uptimeNanoseconds
                        view.drawTerminalContents(dirtyRect: region, context: context, bufferOffset: 0)
                        let elapsed = DispatchTime.now().uptimeNanoseconds - start
                        context.restoreGState()
                        NSGraphicsContext.restoreGraphicsState()
                        if round > 0 {
                            samples[index].append(Double(elapsed) / 1_000_000)
                            areas[index] += region.height / view.bounds.height
                            rowsBuilt[index] += view.diagnostics.coreGraphicsRowsBuilt
                        }
                    }
                }
            }
            let baseline = samples[0].sorted()
            for (index, configuration) in configurations.enumerated() {
                let sorted = samples[index].sorted()
                let p50 = Self.percentile(sorted, 0.5)
                lines.append(String(
                    format: "| %@ | %@ | %dx%d | %d | %.3f | %.3f | %.3f | %.2fx | %.2f | %.1f |",
                    scenario, configuration.0, cols, rows, sorted.count,
                    p50, Self.percentile(sorted, 0.95), sorted.last ?? 0,
                    p50 / max(Self.percentile(baseline, 0.5), 0.000_001),
                    areas[index] / Double(max(1, sorted.count)),
                    Double(rowsBuilt[index]) / Double(max(1, sorted.count))))
            }
        }
        print("""
            GLOWBENCH scale=2 view=800x600pt
            | scenario | glow | grid | frames | p50 ms | p95 ms | max ms | p50 vs off | mean region (fraction of view) | rows built per frame |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            \(lines.joined(separator: "\n"))
            """)
    }
}
#endif
