//
//  MetalSurfaceParityTests.swift
//  SwiftTermTests
//
//  The regression net for swapping MTKView out for a CAMetalLayer we own
//  (io-gaps.md G1, WO-F3).
//
//  Same renderer, same shaders, same snapshot — only the surface differs, so
//  the two must produce the same pixels. This is what makes the integration
//  safe to do without a live window: a mismatch here is a real defect, not a
//  rasterisation difference (comparing against the Core Graphics path would be
//  meaningless, since that is a different rasteriser entirely).
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import MetalKit
import QuartzCore

@Suite("MetalSurfaceParity")
@MainActor
struct MetalSurfaceParityTests {
    private static let width = 320
    private static let height = 120

    /// The halo appears, lies only around the text that cast it, stays under opaque cell
    /// backgrounds, and leaves exactly when the glow does — on both of the renderer's buffering
    /// paths, which build the halo pass from different vertex data.
    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func glowAddsForegroundHaloAndOpaqueCellBackgroundsStillCoverIt(mode: MetalBufferingMode) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let target = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), device: device)
        target.colorPixelFormat = .bgra8Unorm
        target.framebufferOnly = false
        target.isPaused = true
        let view = TerminalView(frame: target.frame)
        view.metalBufferingMode = mode
        view.nativeBackgroundColor = .black
        // Ink at the top left and alone at the bottom right, so a halo scaled, offset or
        // flipped by a wrong mapping lands where no text is.
        view.feed(text: "\u{1B}[?25l\u{1B}[38;2;0;255;255mForeground halo\r\n"
            + "\u{1B}[48;2;0;0;240m          \u{1B}[0m free ink\r\n"
            + "\u{1B}[999;30H\u{1B}[38;2;255;0;255mfar\u{1B}[0m")
        let plain = try #require(renderPixels(into: target, terminalView: view))
        let glow = TerminalTextGlow(radius: 6, opacity: 0.8)
        view.textGlow = glow
        let glowing = try #require(renderPixels(into: target, terminalView: view))
        #expect(plain.count == glowing.count)
        func isBlueBackground(_ offset: Int) -> Bool {
            plain[offset] == 240 && plain[offset + 1] == 0 && plain[offset + 2] == 0
        }

        // Ink: what the plain frame drew that is neither the black ground nor the blue cells.
        var ink = [Bool](repeating: false, count: Self.width * Self.height)
        for pixel in ink.indices {
            let offset = pixel * 4
            let lit = plain[offset] != 0 || plain[offset + 1] != 0 || plain[offset + 2] != 0
            ink[pixel] = lit && !isBlueBackground(offset)
        }
        #expect(ink.contains(true), "the fixture drew no text")
        // The halo's reach in drawable pixels at this 1x target: the radius, the box passes'
        // rounding at half resolution, and one halo pixel of bilinear upsampling.
        let reach = Int(ceil(glow.radius)) + 3
        let nearInk = Self.dilate(ink, by: reach)

        var changedCount = 0
        var stray = 0
        for pixel in ink.indices {
            let offset = pixel * 4
            let blueChanged = plain[offset] != glowing[offset]
            let greenChanged = plain[offset + 1] != glowing[offset + 1]
            let redChanged = plain[offset + 2] != glowing[offset + 2]
            guard blueChanged || greenChanged || redChanged else { continue }
            changedCount += 1
            if !nearInk[pixel] { stray += 1 }
        }
        #expect(changedCount > 50, "an enabled GPU halo must change pixels outside the original foreground")
        #expect(stray == 0, "\(stray) changed pixels lie further than \(reach) px from any text: a misplaced halo")
        let blueBackground = stride(from: 0, to: plain.count, by: 4).filter(isBlueBackground)
        #expect(blueBackground.count > 100, "the fixture must actually contain opaque ANSI backgrounds")
        #expect(blueBackground.allSatisfy { offset in (0..<4).allSatisfy { plain[offset + $0] == glowing[offset + $0] } })
        view.textGlow = nil
        let removed = try #require(renderPixels(into: target, terminalView: view))
        #expect(plain == removed)
        if mode == .perRowPersistent, let path = ProcessInfo.processInfo.environment["THREADING_GLOW_RENDER_OUT"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let provider = try #require(CGDataProvider(data: Data(glowing) as CFData))
            let image = try #require(CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: url.appendingPathComponent("metal-text-glow.png"))
        }
    }

    /// A mask grown by `radius` pixels in every direction (a square, so it bounds a box blur's
    /// support from above), done separably.
    private static func dilate(_ mask: [Bool], by radius: Int) -> [Bool] {
        var rows = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for nx in max(0, x - radius)...min(width - 1, x + radius) { rows[y * width + nx] = true }
            }
        }
        var result = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where rows[y * width + x] {
                for ny in max(0, y - radius)...min(height - 1, y + radius) { result[ny * width + x] = true }
            }
        }
        return result
    }

    /// Resizing a glowing surface by a few pixels at a time — a live resize — reuses one pair
    /// of halo textures instead of allocating a pair per frame.
    @Test func aGlowingResizeReusesItsHaloTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let target = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), device: device)
        target.colorPixelFormat = .bgra8Unorm
        target.framebufferOnly = false
        target.isPaused = true
        target.renderContentsScale = 1
        let view = TerminalView(frame: target.frame)
        view.textGlow = TerminalTextGlow(radius: 3, opacity: 0.6)
        view.feed(text: "resize me\r\n")
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        // 280–302 × 140–151 drawable pixels: one 384 × 256 bucket at full resolution.
        for step in 0..<12 {
            target.renderDrawableSize = CGSize(width: 280 + step * 2, height: 140 + step)
            #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
        }
        #expect(renderer.glowTextureAllocations == 1, "\(renderer.glowTextureAllocations) pairs for one drag")
        #expect(renderer.glowTextureBytes > 0)
    }

    /// Renders `content` through `target` and returns the drawable's pixels.
    private func renderPixels(into target: any MetalRenderTarget,
                              terminalView: TerminalView) -> [UInt8]? {
        // The renderer loads its shaders from the SwiftTerm resource bundle,
        // which is not present next to the SwiftPM test binary. When that is
        // the case there is nothing to compare, so skip rather than fail — the
        // app-side harness runs this same comparison where the bundle exists.
        target.renderContentsScale = 1
        target.renderDrawableSize = CGSize(width: Self.width, height: Self.height)
        // A windowless view takes NSScreen.main's scale (2 on a Retina display, 1 on an external
        // monitor or with the display asleep); pin it to the 1x drawable, or every cell is laid
        // out off the drawable and both frames come back as nothing but the clear colour.
        terminalView.metalScaleFactorOverride = 1
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard terminalView.renderSnapshotForMetal(renderer: renderer,
                                                  target: target) else { return nil }

        // Read back the texture that this frame rendered. A second drawable
        // acquisition can return another pool entry.
        guard let texture = renderer.lastRenderedTexture else { return nil }
        guard texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return bytes
    }

    private func makeTerminalView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        view.feed(text: "swiftterm parity \u{1b}[31mred\u{1b}[0m \u{1b}[1mbold\u{1b}[0m\r\nsecond line 0123456789\r\n")
        return view
    }

    /// The surfaces must agree on everything the renderer reads from them.
    /// A mismatch here changes how a frame is built, so it is worth asserting
    /// separately from the pixels.
    @Test func surfacesAgreeOnConfiguration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        let layerView = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                            width: Self.width, height: Self.height))
        layerView.renderDevice = device

        #expect(mtkView.renderPixelFormat == layerView.renderPixelFormat)

        let a: any MetalRenderTarget = mtkView
        let b: any MetalRenderTarget = layerView
        a.renderDrawableSize = CGSize(width: Self.width, height: Self.height)
        b.renderDrawableSize = CGSize(width: Self.width, height: Self.height)
        #expect(a.renderDrawableSize == b.renderDrawableSize)

        a.renderContentsScale = 2
        b.renderContentsScale = 2
        #expect(a.renderContentsScale == b.renderContentsScale)
        #expect(a.renderBounds == b.renderBounds)
    }

    /// The pixels themselves. Skips rather than fails when the environment has
    /// no usable device or drawable, so it stays honest on CI machines without
    /// a GPU surface.
    @Test func bothSurfacesProduceTheSamePixels() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false          // required to read the texture back
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        let layerView = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                             width: Self.width, height: Self.height))
        layerView.renderDevice = device
        layerView.metalLayer.framebufferOnly = false

        let terminalView = makeTerminalView()

        guard let fromMTK = renderPixels(into: mtkView, terminalView: terminalView),
              let fromLayer = renderPixels(into: layerView, terminalView: terminalView)
        else {
            return
        }

        #expect(fromMTK.count == fromLayer.count)
        guard fromMTK.count == fromLayer.count else { return }
        // Two blank frames match trivially; the comparison only means something over real ink.
        let ground = Array(fromMTK.prefix(4))
        let drewSomething = stride(from: 0, to: fromMTK.count, by: 4).contains {
            Array(fromMTK[$0 ..< $0 + 4]) != ground
        }
        #expect(drewSomething, "the fixture drew nothing")

        var differing = 0
        for index in stride(from: 0, to: fromMTK.count, by: 4) where
            fromMTK[index] != fromLayer[index] ||
            fromMTK[index + 1] != fromLayer[index + 1] ||
            fromMTK[index + 2] != fromLayer[index + 2] {
            differing += 1
        }
        let totalPixels = fromMTK.count / 4
        // Identical inputs through identical shaders: expect an exact match.
        #expect(differing == 0,
                "\(differing) of \(totalPixels) pixels differ between MTKView and CAMetalLayer surfaces")
    }
}
#endif
