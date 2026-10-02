// Explicit cross-platform leaf laboratory. TemplateImageDrawing is compiled unchanged beside
// this file; only destination allocation and catalogue PNG decoding differ between platforms.
import AppKit
import Foundation
#if os(Linux)
import LinuxWindowBridge
#endif

@main
struct ImageHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("usage: ImageHarness CATALOGUE_OR_PROVIDER_MARKS_DIRECTORY NEW_OUTPUT_DIRECTORY")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var manifest: [[String: Any]] = []
        for provider in ["Claude", "Codex"] {
            let name = "AgentIcon\(provider)"
            let catalogue = source.appendingPathComponent("\(name).imageset/\(name)@2x.png")
            let path = FileManager.default.fileExists(atPath: catalogue.path)
                ? catalogue : source.appendingPathComponent("\(name).png")
            let png = try Data(contentsOf: path)
            let image = try load(png)
            image.isTemplate = true
            for scale in [1, 2] {
                for scene in ["unselected", "selected", "alpha", "alpha-background", "wide", "clip", "inherited", "plain", "plain-background"] {
                    let width = 64 * scale
                    let selected = scene == "selected"
                    let background = scene == "plain-background" ? NSColor(white: 0.93, alpha: 1) : selected ? NSColor(srgbRed: 0.12, green: 0.30, blue: 0.62, alpha: 1)
                        : NSColor(srgbRed: 0.10, green: 0.12, blue: 0.14, alpha: 1)
                    let transparent = ["alpha", "inherited", "wide", "clip", "plain"].contains(scene)
                    #if os(Linux)
                    let bitmap = Bitmap(width: width, height: width)
                    let context = NSGraphicsContext(bitmap: bitmap, scale: CGFloat(scale))
                    #else
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                        pixelsHigh: width, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4,
                        bitsPerPixel: 32)!
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                    #endif
                    NSGraphicsContext.current = context
                    if !transparent {
                        background.setFill()
                        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
                    }
                    if scene == "clip" {
                        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 64)).addClip()
                    }
                    if scene == "inherited" {
                        #if os(Linux)
                        context.alpha = 0.5
                        #else
                        context.cgContext.setAlpha(0.5)
                        #endif
                    }
                    image.size = NSSize(width: scene == "wide" ? 64 : 32, height: 32)
                    image.isTemplate = !scene.hasPrefix("plain")
                    let slot = NSRect(x: 16, y: 16, width: 32, height: 32)
                    let tint = selected ? NSColor.white
                        : NSColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: scene.hasPrefix("alpha") ? 0.5 : 1)
                    TemplateImageDrawing.draw(image, in: slot, tint: tint)
                    let fitted = TemplateImageDrawing.fitted(image, in: slot)
                    let filename = "\(provider.lowercased())-\(scene)-\(scale)x"
                    #if os(Linux)
                    let rgba = bitmap.pixels
                    try PNGWriter.write(bitmap, to: output.appendingPathComponent(filename + ".png"))
                    let peak = context.peakTransparencyLayerPixelCount
                    precondition(peak <= 6400, "small provider image allocated a window-sized layer")
                    #else
                    var rgba = [UInt8]()
                    rgba.reserveCapacity(width * width * 4)
                    for y in 0..<width {
                        for x in 0..<width {
                            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                            for value in [color.redComponent, color.greenComponent,
                                          color.blueComponent, color.alphaComponent] {
                                rgba.append(UInt8(clamping: Int((value * 255).rounded())))
                            }
                        }
                    }
                    try bitmap.representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent(filename + ".png"))
                    let peak = 0
                    #endif
                    try Data(rgba).write(to: output.appendingPathComponent(filename + ".rgba"))
                    manifest.append(["file": filename, "provider": provider, "scene": scene,
                        "scale": scale, "width": width, "height": width,
                        "fitted": [fitted.minX, fitted.minY, fitted.width, fitted.height].map { Double($0) },
                        "layerPeakPixels": peak])
                    NSGraphicsContext.current = nil
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("manifest.json"))
        print("PASS rendered 36 provider image cases using unchanged TemplateImageDrawing")
    }

    @MainActor private static func load(_ data: Data) throws -> NSImage {
        #if os(Linux)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        var width: Int32 = 0, height: Int32 = 0
        func decode(_ bytes: [UInt8], capacity: Int32 = 64 * 64 * 4) -> Int32 {
            bytes.withUnsafeBufferPointer { input in
                pixels.withUnsafeMutableBufferPointer { output in
                    tw_decode_provider_png(input.baseAddress, Int32(input.count), output.baseAddress,
                                           capacity, &width, &height)
                }
            }
        }
        precondition(decode([0, 1, 2, 3]) < 0, "malformed image admitted")
        precondition(decode([UInt8](repeating: 0, count: 65537)) < 0, "oversized image admitted")
        precondition(decode(Array(data), capacity: 1) < 0, "undersized destination admitted")
        precondition(decode(Array(data)) == 0 && width == 32 && height == 32,
                     "catalogue provider PNG must decode exactly")
        return NSImage(rgba: Array(pixels.prefix(Int(width * height * 4))),
                       width: Int(width), height: Int(height), size: NSSize(width: 32, height: 32))!
        #else
        guard let image = NSImage(data: data) else { fatalError("invalid catalogue provider PNG") }
        image.size = NSSize(width: 32, height: 32)
        return image
        #endif
    }
}
