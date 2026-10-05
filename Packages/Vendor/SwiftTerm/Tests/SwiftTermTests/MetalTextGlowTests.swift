//
//  MetalTextGlowTests.swift
//  SwiftTermTests
//
//  The GPU halo's resource contract and the Metal terminal's captures: the halo is bounded by
//  its own size rather than refused at a large drawable, a live resize reuses its textures, a
//  terminal leaving its window lets them go, and a bitmap capture of a Metal terminal shows its
//  text.
//

#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import MetalKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("Metal text glow", .serialized)
struct MetalTextGlowTests {

    // MARK: - Layout

    /// A 6K pane's drawable is past the old 16,777,216-pixel refusal; it now glows at a
    /// resolution whose textures fit the bound, and so does the largest drawable Metal allows.
    @Test(arguments: [
        CGSize(width: 6_016, height: 3_384),
        CGSize(width: 6_016, height: 3_272),
        CGSize(width: 16_384, height: 16_384),
        CGSize(width: 5_120, height: 2_880),
        CGSize(width: 1_206, height: 2_622),
    ])
    func everyDrawableGetsABoundedHalo(size: CGSize) throws {
        for (radius, scale) in [(CGFloat(0.5), CGFloat(2)), (1.5, 2), (2.5, 2), (6, 2), (3, 1)] {
            let layout = try #require(MetalGlowHaloLayout(drawableSize: size, glowRadius: radius, scale: scale),
                                      "\(size) radius \(radius) at \(scale)x was refused")
            #expect(layout.textureWidth * layout.textureHeight <= MetalGlowHaloLayout.maximumTexturePixels)
            #expect(max(layout.textureWidth, layout.textureHeight) <= MetalGlowHaloLayout.maximumTextureDimension)
            #expect(layout.pixelWidth <= layout.textureWidth && layout.pixelHeight <= layout.textureHeight)
            #expect(layout.usedWidth <= CGFloat(layout.pixelWidth) && layout.usedHeight <= CGFloat(layout.pixelHeight))
            #expect(layout.resolution > 0 && layout.resolution <= 1)
            #expect(layout.radiusPixels >= 1)
        }
    }

    /// The ordinary case is unchanged: half resolution once the support reaches four device
    /// pixels, full below it.
    @Test func anOrdinaryPaneKeepsItsResolution() throws {
        let size = CGSize(width: 2_400, height: 1_600)
        #expect(try #require(MetalGlowHaloLayout(drawableSize: size, glowRadius: 2.5, scale: 2)).resolution == 0.5)
        #expect(try #require(MetalGlowHaloLayout(drawableSize: size, glowRadius: 1.5, scale: 1)).resolution == 1)
    }

    /// A live resize changes the drawable a few pixels a frame; the textures are allocated in
    /// buckets, so consecutive sizes share them.
    @Test func aLiveResizeStaysInsideOneBucket() throws {
        let sizes = (0..<40).map { CGSize(width: 1_800 + $0 * 3, height: 1_100 + $0) }
        let layouts = try sizes.map { try #require(MetalGlowHaloLayout(drawableSize: $0, glowRadius: 3, scale: 2)) }
        let distinct = Set(layouts.map { "\($0.textureWidth)x\($0.textureHeight)" })
        #expect(distinct.count <= 2, "a 120-pixel drag reallocated \(distinct.count) times")
    }

    @Test func nothingToDrawIsNoLayout() {
        #expect(MetalGlowHaloLayout(drawableSize: .zero, glowRadius: 3, scale: 2) == nil)
        #expect(MetalGlowHaloLayout(drawableSize: CGSize(width: 100, height: 100), glowRadius: 0, scale: 2) == nil)
    }

    // MARK: - Resources

    private func makeView(width: CGFloat = 400, height: CGFloat = 160) -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            font: nil,
            options: TerminalOptions(cols: 40, rows: 8, scrollback: 40))
        view.suspendsRenderingWhenNotVisible = false
        view.nativeBackgroundColor = .black
        view.feed(text: "\u{1B}[38;2;0;255;0mphosphor green glyphs\r\n\u{1B}[38;2;0;255;0mWWWW MMMM ####\u{1B}[0m")
        return view
    }

    private func hostWindow(for view: TerminalView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        return window
    }

    /// A glowing terminal that leaves its window releases its halo textures, keeps its
    /// renderer, and allocates again on the first frame back.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable))
    func leavingTheWindowReleasesTheHalo() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }
        let window = hostWindow(for: view)
        view.textGlow = TerminalTextGlow(radius: 3, opacity: 0.6)
        try view.setUseMetal(true)
        view.drawMetalFrameNow()
        #expect(view.renderOwner.metalGlowTextureBytes > 0, "the glowing frame allocated no halo")

        view.removeFromSuperview()
        #expect(view.isUsingMetalRenderer)
        #expect(view.renderOwner.metalGlowTextureBytes == 0, "a terminal off screen kept its halo")

        window.contentView = view
        view.drawMetalFrameNow()
        #expect(view.renderOwner.metalGlowTextureBytes > 0)
    }

    // MARK: - Captures

    /// Pixels of the capture that are the text's green — glyph or halo — rather than anything
    /// a blank terminal could produce.
    private func greenPixels(_ rep: NSBitmapImageRep) throws -> Int {
        let image = try #require(rep.cgImage)
        let width = image.width, height = image.height
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if green > 60 && green > red * 2 && green > blue * 2 { count += 1 }
        }
        return count
    }

    /// AppKit's `cacheDisplay` cannot read a `CAMetalLayer`, and reports itself as drawing to
    /// the screen, so a Metal terminal draws for it only inside `drawingForBitmapCapture`. Both
    /// halves are asserted: inside the scope the capture has the text (and its halo) on both
    /// Metal surfaces; outside it the terminal's own draw stays empty, which is what keeps an
    /// ordinary layer update from painting a second copy of the text under the GPU's.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable), arguments: [true, false])
    func aCaptureOfAMetalTerminalShowsItsText(layerSurface: Bool) throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }
        let window = hostWindow(for: view)
        view.usesMetalLayerSurface = layerSurface
        view.textGlow = TerminalTextGlow(radius: 3, opacity: 0.6)
        try view.setUseMetal(true)
        #expect(window.contentView === view)
        view.drawMetalFrameNow()

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(try greenPixels(rep) == 0, "a Metal terminal drew text outside a capture")

        let captured = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        TerminalView.drawingForBitmapCapture {
            view.cacheDisplay(in: view.bounds, to: captured)
        }
        #expect(try greenPixels(captured) > 200, "the capture of a Metal terminal is empty")

        // The same capture from an ancestor, the way a window snapshot takes it.
        let host = NSView(frame: view.frame)
        view.removeFromSuperview()
        host.addSubview(view)
        window.contentView = host
        view.drawMetalFrameNow()
        let whole = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        TerminalView.drawingForBitmapCapture {
            host.cacheDisplay(in: host.bounds, to: whole)
        }
        #expect(try greenPixels(whole) > 200, "a capture of the terminal's window is empty")
    }
}

// MARK: - Opt-in GPU cost measurement

/// GPU time per Metal frame with and without a glow, on a full Retina pane whose every cell
/// changes each frame. Off by default; run it with
///
///     SWIFTTERM_GLOW_BENCH=1 swift test -c release -Xswiftc -enable-testing \
///         --package-path Packages/Vendor/SwiftTerm --filter MetalTextGlowCost
///
/// Headless: frames are rendered into an offscreen drawable and timed by the command buffer's
/// own GPU start and end, so no window or awake display is needed. CPU encode time is reported
/// beside it.
@MainActor
@Suite("Metal text glow cost", .serialized)
struct MetalTextGlowCostTests {
    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
        func take() -> [Double] { lock.lock(); defer { values = []; lock.unlock() }; return values }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTERM_GLOW_BENCH"] == "1"
                   && MetalToggleTests.metalIsUsable))
    func measureMetalFrameWithAndWithoutGlow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let points = CGSize(width: 1_600, height: 1_000)
        let scale: CGFloat = 2
        let target = MTKView(frame: CGRect(origin: .zero, size: points), device: device)
        target.colorPixelFormat = .bgra8Unorm
        target.isPaused = true
        target.renderContentsScale = scale
        target.renderDrawableSize = CGSize(width: points.width * scale, height: points.height * scale)
        let view = TerminalView(frame: CGRect(origin: .zero, size: points), font: nil,
                                options: TerminalOptions(cols: 80, rows: 25, scrollback: 100))
        view.suspendsRenderingWhenNotVisible = false
        let cols = view.terminalDimensions.cols, rows = view.terminalDimensions.rows
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        let samples = Samples()
        TerminalView.onFrameGPUCompleted = { samples.append($0 * 1_000) }
        defer { TerminalView.onFrameGPUCompleted = nil }

        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        func denseFrame() -> String {
            var out = ""
            for row in 1...rows {
                out += "\u{1b}[\(row);1H"
                for _ in 0..<cols {
                    out += "\u{1b}[38;2;\(next(216));\(next(216));\(next(216))m"
                    out.unicodeScalars.append(UnicodeScalar(UInt8(33 + next(93))))
                }
            }
            return out
        }
        let configurations: [(String, TerminalTextGlow?)] = [
            ("off", nil),
            ("3pt/0.40", TerminalTextGlow(radius: 3, opacity: 0.4)),
            ("6pt/0.80", TerminalTextGlow(radius: 6, opacity: 0.8)),
        ]
        let rounds = Int(ProcessInfo.processInfo.environment["SWIFTTERM_GLOW_BENCH_ROUNDS"] ?? "") ?? 4
        let framesPerRound = 30
        var gpu = Array(repeating: [Double](), count: configurations.count)
        var cpu = Array(repeating: [Double](), count: configurations.count)
        for round in 0...rounds {
            for (index, configuration) in configurations.enumerated() {
                view.textGlow = configuration.1
                for _ in 0..<framesPerRound {
                    view.feed(text: denseFrame())
                    let start = DispatchTime.now().uptimeNanoseconds
                    #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if round > 0 { cpu[index].append(elapsed) }
                }
                let deadline = Date().addingTimeInterval(2)
                while samples.count < framesPerRound, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                let taken = samples.take()
                if round > 0 { gpu[index] += taken }
            }
        }
        var lines: [String] = []
        for (index, configuration) in configurations.enumerated() {
            let g = gpu[index].sorted(), c = cpu[index].sorted()
            lines.append(String(format: "| %@ | %d | %.3f | %.3f | %.3f | %.3f |", configuration.0, g.count,
                Self.percentile(g, 0.5), Self.percentile(g, 0.95), Self.percentile(c, 0.5), Self.percentile(c, 0.95)))
        }
        print("""
            METALGLOWBENCH drawable=\(Int(points.width * scale))x\(Int(points.height * scale)) grid=\(cols)x\(rows) dense
            | glow | frames | GPU p50 ms | GPU p95 ms | render+wait p50 ms | render+wait p95 ms |
            | --- | --- | --- | --- | --- | --- |
            \(lines.joined(separator: "\n"))
            """)
    }
}
#endif
