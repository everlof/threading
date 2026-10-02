import AppKit
import Dispatch
import Foundation

@main
struct ImageShimContracts {
    static func pixel(_ bitmap: Bitmap, _ x: Int, _ y: Int) -> [UInt8] {
        Array(bitmap.pixels[((y * bitmap.width + x) * 4)..<((y * bitmap.width + x) * 4 + 4)])
    }

    static func image(_ pixels: [UInt8], _ width: Int, _ height: Int) -> NSImage {
        NSImage(rgba: pixels, width: width, height: height)!
    }

    static func main() {
        precondition(NSImage(rgba: [], width: 0, height: 2) == nil)
        precondition(NSImage(rgba: [], width: Int.max, height: Int.max) == nil)
        precondition(NSImage(rgba: [0, 0, 0], width: 1, height: 1) == nil)
        precondition(NSImage(rgba: [0, 0, 0, 255], width: 1, height: 1,
                             size: NSSize(width: CGFloat.infinity, height: 1)) == nil)

        // An aligned rendition preserves source pixels exactly, including top/bottom orientation.
        let asymmetric = image([255, 0, 0, 255, 0, 255, 0, 255,
                                0, 0, 255, 255, 0, 0, 0, 0], 2, 2)
        let original = Bitmap(width: 5, height: 5)
        let originalContext = NSGraphicsContext(bitmap: original, scale: 1)
        NSGraphicsContext.current = originalContext
        asymmetric.draw(in: NSRect(x: 1, y: 1, width: 2, height: 2))
        precondition(pixel(original, 1, 2) == [255, 0, 0, 255])
        precondition(pixel(original, 2, 2) == [0, 255, 0, 255])
        precondition(pixel(original, 1, 3) == [0, 0, 255, 255])
        precondition(pixel(original, 2, 3) == [0, 0, 0, 0])

        // A real template leaf must tint only artwork alpha, leaving the already-painted ground.
        let tinted = Bitmap(width: 8, height: 8, background: (0.2, 0.4, 0.6, 1))
        let tintedContext = NSGraphicsContext(bitmap: tinted, scale: 1)
        NSGraphicsContext.current = tintedContext
        asymmetric.isTemplate = true
        TemplateImageDrawing.draw(asymmetric, in: NSRect(x: 2, y: 2, width: 2, height: 2),
                                  tint: NSColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        precondition(pixel(tinted, 2, 4) == [153, 51, 76, 255])
        precondition(pixel(tinted, 3, 5) == [51, 102, 153, 255])
        precondition(pixel(tinted, 1, 4) == [51, 102, 153, 255])

        // Fractional inherited clipping and opacity each apply once around an isolated group.
        let clipped = Bitmap(width: 8, height: 8)
        let clippedContext = NSGraphicsContext(bitmap: clipped, scale: 1)
        NSGraphicsContext.current = clippedContext
        clippedContext.alpha = 0.5
        NSBezierPath(rect: NSRect(x: 2.5, y: 0, width: 5, height: 8)).addClip()
        let solid = image([255, 255, 255, 255], 1, 1)
        solid.isTemplate = true
        TemplateImageDrawing.draw(solid, in: NSRect(x: 2, y: 2, width: 2, height: 2),
                                  tint: NSColor(white: 1, alpha: 0.5))
        precondition(pixel(clipped, 2, 4) == [255, 255, 255, 32])
        precondition(pixel(clipped, 3, 4) == [255, 255, 255, 64])

        let nested = Bitmap(width: 8, height: 8)
        let nestedContext = NSGraphicsContext(bitmap: nested, scale: 1)
        NSGraphicsContext.current = nestedContext
        nestedContext.alpha = 0.5
        nestedContext.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        nestedContext.alpha = 0.5
        TemplateImageDrawing.draw(solid, in: NSRect(x: 2, y: 2, width: 2, height: 2), tint: .white)
        nestedContext.cgContext.endTransparencyLayer()
        precondition(pixel(nested, 2, 4) == [255, 255, 255, 64])
        precondition(nestedContext.alpha == 0.5)

        // The translated 26px provider mark keeps the same tile bound on a full-size workspace.
        let workspace = Bitmap(width: 1600, height: 900)
        let workspaceContext = NSGraphicsContext(bitmap: workspace, scale: 2)
        NSGraphicsContext.current = workspaceContext
        workspaceContext.translateBy(x: 7.5, y: 18.5)
        TemplateImageDrawing.draw(solid, in: NSRect(x: 0, y: 0, width: 13, height: 13), tint: .white)
        precondition(workspaceContext.peakTransparencyLayerPixelCount <= 9 * 16 * 16)
        precondition(workspace.pixels.filter { $0 != 0 }.count == 26 * 26 * 4)

        // Two simultaneous drawing threads share neither current context nor saved colour state.
        let arrived = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        for index in 0..<2 {
            completed.enter()
            Thread {
                precondition(NSGraphicsContext.current == nil)
                let bitmap = Bitmap(width: 2, height: 2)
                let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
                NSGraphicsContext.current = context
                let ink = index == 0 ? NSColor(red: 1, green: 0, blue: 0, alpha: 1)
                    : NSColor(red: 0, green: 1, blue: 0, alpha: 1)
                ink.setFill()
                NSGraphicsContext.saveGraphicsState()
                NSColor.black.setFill()
                arrived.signal()
                precondition(proceed.wait(timeout: .now() + 5) == .success)
                precondition(NSGraphicsContext.current === context)
                NSGraphicsContext.restoreGraphicsState()
                NSRect(x: 0, y: 0, width: 2, height: 2).fill()
                precondition(pixel(bitmap, 0, 0) == (index == 0 ? [255, 0, 0, 255] : [0, 255, 0, 255]))
                NSGraphicsContext.current = nil
                completed.leave()
            }.start()
        }
        for _ in 0..<2 { precondition(arrived.wait(timeout: .now() + 5) == .success) }
        precondition(NSGraphicsContext.current === workspaceContext)
        for _ in 0..<2 { proceed.signal() }
        precondition(completed.wait(timeout: .now() + 5) == .success)
        NSGraphicsContext.current = nil
        print("PASS image shim: exact pixels, template alpha, clipping, nested groups, bounded tiles and thread isolation")
    }
}
