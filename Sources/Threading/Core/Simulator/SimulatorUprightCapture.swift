import CoreGraphics
import Foundation
import ImageIO
import ThreadingSimulatorKit
import UniformTypeIdentifiers

/// A public `simctl` capture in the axes the direct stream delivers.
///
/// CoreSimulator's public screenshot is the framebuffer in its native axes, while the helper turns
/// a landscape scene upright before the pane, an agent or input sees it. Without this, a landscape
/// app's screenshot fallback or hidden-pane agent screenshot came back sideways, and taps placed on
/// it landed in the wrong axes. The work is a decode, one bounded draw and an encode, done on a
/// worker; a portrait capture is returned untouched.
enum SimulatorUprightCapture {
    struct Result: @unchecked Sendable {
        /// The upright pixels.
        let image: CGImage
        /// PNG bytes for those pixels; the original bytes when no turn was needed.
        let png: Data
    }

    static func upright(_ data: Data, orientation: SimulatorScreenOrientation) async -> Result? {
        await Task.detached(priority: .userInitiated) { uprightNow(data, orientation: orientation) }.value
    }

    /// Synchronous body, separate for tests.
    static func uprightNow(_ data: Data, orientation: SimulatorScreenOrientation) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let native = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard orientation != .portrait else { return Result(image: native, png: data) }
        guard let rotated = rotated(native, counterclockwiseQuarterTurns: orientation.counterclockwiseQuarterTurns),
              let png = encodedPNG(rotated) else { return nil }
        return Result(image: rotated, png: png)
    }

    /// The same visual quarter turns `vImageRotate90_ARGB8888` applies in the helper.
    static func rotated(_ image: CGImage, counterclockwiseQuarterTurns turns: UInt8) -> CGImage? {
        let turns = Int(turns % 4)
        guard turns != 0 else { return image }
        let width = image.width
        let height = image.height
        let outputWidth = turns.isMultiple(of: 2) ? width : height
        let outputHeight = turns.isMultiple(of: 2) ? height : width
        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Core Graphics is y-up, so a positive angle is a counter-clockwise turn of the picture.
        switch turns {
        case 1: context.translateBy(x: CGFloat(height), y: 0)
        case 2: context.translateBy(x: CGFloat(width), y: CGFloat(height))
        default: context.translateBy(x: 0, y: CGFloat(width))
        }
        context.rotate(by: CGFloat(turns == 3 ? -1 : turns) * .pi / 2)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodedPNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
