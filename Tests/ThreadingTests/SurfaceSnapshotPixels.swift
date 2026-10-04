import AppKit
import XCTest

/// Reads one pixel back from an `ExtensionMetalSurfaceView.snapshotImage`.
///
/// The snapshot is a BGRA bitmap (`alphaFirst`, 32-bit little-endian), and
/// `NSBitmapImageRep.colorAt(x:y:)` reads that layout's bytes in big-endian order — red comes
/// back as blue, and alpha as the blue byte. Redrawing the image through Core Graphics, which
/// honours the bitmap's own byte order, into a known RGBA buffer gives the components the surface
/// actually drew.
enum SurfaceSnapshotPixels {
    struct RGBA: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    private static let bytesPerPixel = 4

    /// The pixel at (`x`, `y`), with `y` counted from the top row.
    static func rgba(in image: NSImage, x: Int, y: Int) throws -> RGBA {
        let pixels = try all(in: image)
        let index = y * pixels.width + x
        return try XCTUnwrap(pixels.values.indices.contains(index) ? pixels.values[index] : nil)
    }

    /// The largest alpha anywhere in the image.
    static func maximumAlpha(in image: NSImage) throws -> Double {
        try all(in: image).values.map(\.alpha).max() ?? 0
    }

    private static func all(in image: NSImage) throws -> (width: Int, values: [RGBA]) {
        let bitmap = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let space = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not redraw the snapshot")
        let maximum = Double(UInt8.max)
        let values = stride(from: 0, to: bytes.count, by: bytesPerPixel).map { offset in
            RGBA(
                red: Double(bytes[offset]) / maximum,
                green: Double(bytes[offset + 1]) / maximum,
                blue: Double(bytes[offset + 2]) / maximum,
                alpha: Double(bytes[offset + 3]) / maximum
            )
        }
        return (width, values)
    }
}
