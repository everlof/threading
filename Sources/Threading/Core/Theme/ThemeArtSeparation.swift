import AppKit

// MARK: - Theme Art Separation

/// Whether a theme's picture stands apart from the ground it is drawn on, and the rim that makes
/// it stand apart when it does not.
///
/// The eye finds a picture by its *edge*: the ring of opaque pixels that border transparency. A
/// cartoon drawn with a dark outline reads on a cream sidebar and vanishes on a near-black one.
/// Every picture slot is per appearance precisely so each can carry art drawn for its own ground,
/// and an author who copies the light file into the dark slot produces exactly that failure —
/// the first agent-made theme reviewed did it for all fourteen of its pictures, and its dark
/// Dock tile was a brown shape on a brown-black plate. So separation is measured on the edge
/// alone, against every ground the picture can land on, at `ThemeContrast.minimumRatio`, the
/// floor the theme's other non-text marks are held to.
///
/// Two consumers, two policies. Identity art — the Dock tile's mark and the sidebar's brand logo,
/// which say *this is the app* and must be findable — is rimmed by the host when it fails
/// (`legible(_:grounds:ink:)`): the author cannot see the plate it lands on, and the cost of the
/// failure is not finding the app. Decorative art — the mascot, sprites, backdrops — is reported
/// to the authoring agent instead (`ThemeArtAdvisory`), because a deliberately murky picture is a
/// design choice the host has no business outlining.
///
/// **Bounded.** A measure draws one `sampleSide`-pixel thumbnail and makes one pass over it. A
/// rim draws the picture `rimStamps.count` times into one canvas the picture's size plus the
/// rim. Both are pure Core Graphics, safe off the main actor; the main-actor entry point caches
/// by source identity, so a sidebar redraw is a dictionary read.
enum ThemeArtSeparation {

    /// How much of a picture's edge reaches the floor against its worst ground.
    struct Measure: Equatable, Sendable {
        /// 0–1: the share of edge pixels at or above `floor`.
        let share: Double

        var separates: Bool { share >= ThemeArtSeparation.requiredShare }

        /// The share as a whole percentage, for a tool line.
        var percent: Int { Int((share * 100).rounded()) }
    }

    // MARK: - Properties

    /// Big enough to see an outline a few percent of the picture wide, small enough that a
    /// measure is a few thousand pixels.
    static let sampleSide = 64
    /// The theme's non-text contrast floor.
    static let floor = Double(ThemeContrast.minimumRatio)
    /// Half the edge reaching the floor is what reads as "the shape is there". A picture whose
    /// outline fails but whose fill passes is still found by its fill, and passes.
    static let requiredShare = 0.5
    /// The rim's width as a share of the picture's longer side: about two points on the 24-point
    /// brand slot and five pixels on the Dock tile at its largest presentation — a sticker's
    /// rim, not a frame.
    static let rimWidthRatio: CGFloat = 0.04

    /// A pixel at or above half coverage counts as the picture's own.
    private static let opaqueThreshold: UInt8 = 128
    /// Offsets the silhouette is stamped at, as fractions of the rim width: a full ring and a
    /// half ring inside it, so a narrow feature is filled rather than scalloped, plus the centre
    /// so nothing of the ground shows through a translucent part of the picture.
    private static let rimStamps: [CGPoint] = {
        func ring(_ count: Int, radius: CGFloat) -> [CGPoint] {
            (0..<count).map { step in
                let angle = CGFloat(step) / CGFloat(count) * 2 * .pi
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
        return [.zero] + ring(24, radius: 1) + ring(12, radius: 0.5)
    }()

    @MainActor private static let legibleCache = NSCache<NSString, LegibleEntry>()

    // MARK: - Public Methods

    /// The picture as identity art is drawn on `grounds`: itself when its edge separates, else
    /// with a rim of `ink` around its silhouette, drawn at no more than `maximumPixels` on its
    /// longer side — the most the place it is shown can display. The rim's cost grows with the
    /// square of that side: measured cold in a Debug build, 46 ms at 512, 14.5 ms at 256, 4.8 ms
    /// at the Dock mark's 141 and 2.2 ms at the brand logo's 96; a cached read is microseconds.
    ///
    /// Cached by the source image's identity, the grounds, the ink and the size. The entry keeps
    /// the source alive, so its identity cannot be reused by another picture while it stands.
    @MainActor
    static func legible(
        _ image: NSImage,
        grounds: [NSColor],
        ink: NSColor,
        maximumPixels: Int
    ) -> NSImage {
        let key = (cacheKey(for: image, grounds: grounds, ink: ink) + "|\(maximumPixels)") as NSString
        if let entry = legibleCache.object(forKey: key), entry.source === image {
            return entry.result
        }
        let result = rimmedIfNeeded(image, grounds: grounds, ink: ink, maximumPixels: maximumPixels) ?? image
        legibleCache.setObject(LegibleEntry(source: image, result: result), forKey: key)
        return result
    }

    /// `image` drawn no larger than `maximumSide` pixels on its longer side, aspect kept; the
    /// image itself when it already fits.
    static func fitted(_ image: CGImage, maximumSide: Int) -> CGImage? {
        let longer = max(image.width, image.height)
        guard longer > maximumSide, maximumSide > 0 else { return image }
        let scale = CGFloat(maximumSide) / CGFloat(longer)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The share of `image`'s edge that reaches the floor on every one of `grounds`, or nil when
    /// the picture has no opaque pixel to measure.
    static func measure(_ image: CGImage, grounds: [ThemeLuminance.RGB]) -> Measure? {
        guard !grounds.isEmpty, let pixels = thumbnail(image) else { return nil }
        let side = sampleSide
        func isOpaque(_ x: Int, _ y: Int) -> Bool {
            guard (0..<side).contains(x), (0..<side).contains(y) else { return false }
            return pixels[(y * side + x) * 4 + 3] >= opaqueThreshold
        }
        let groundLuminances = grounds.map(\.luminance)
        var edges = 0
        var clearing = 0
        for y in 0..<side {
            for x in 0..<side where isOpaque(x, y) {
                guard !isOpaque(x - 1, y) || !isOpaque(x + 1, y)
                        || !isOpaque(x, y - 1) || !isOpaque(x, y + 1) else { continue }
                edges += 1
                let offset = (y * side + x) * 4
                let alpha = Double(pixels[offset + 3]) / 255
                let divisor = max(alpha * 255, 1)
                let ink = ThemeLuminance.RGB(
                    r: Double(pixels[offset]) / divisor,
                    g: Double(pixels[offset + 1]) / divisor,
                    b: Double(pixels[offset + 2]) / divisor
                )
                let worst = zip(grounds, groundLuminances).map { ground, groundLuminance in
                    contrast(ink.over(ground, opacity: alpha).luminance, groundLuminance)
                }.min() ?? 1
                if worst >= floor { clearing += 1 }
            }
        }
        guard edges > 0 else { return nil }
        return Measure(share: Double(clearing) / Double(edges))
    }

    /// `image` with a solid rim of `ink` around its silhouette, on a canvas grown by the rim on
    /// every side so a picture drawn to its own edge keeps its whole rim.
    static func rimmed(_ image: CGImage, ink: CGColor) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rim = max(1, (max(width, height) * rimWidthRatio).rounded(.up))
        let canvas = CGRect(x: 0, y: 0, width: width + rim * 2, height: height + rim * 2)
        let placed = CGRect(x: rim, y: rim, width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(canvas.width),
                height: Int(canvas.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        // The union of the stamped silhouettes, filled with the ink: drawing the stamps inside a
        // transparency layer and then filling it `sourceIn` keeps their coverage and replaces
        // their colour, which is a dilation without a morphology filter.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for stamp in rimStamps {
            context.draw(image, in: placed.offsetBy(dx: stamp.x * rim, dy: stamp.y * rim))
        }
        context.setBlendMode(.sourceIn)
        context.setFillColor(ink)
        context.fill(canvas)
        context.endTransparencyLayer()
        context.setBlendMode(.normal)
        context.draw(image, in: placed)
        return context.makeImage()
    }

    /// An sRGB colour as the measure's value type.
    static func rgb(_ color: NSColor) -> ThemeLuminance.RGB {
        let value = color.usingColorSpace(.sRGB) ?? color
        return ThemeLuminance.RGB(r: value.redComponent, g: value.greenComponent, b: value.blueComponent)
    }

    /// The pixel dimensions a picture carries, falling back to its point size for a vector or
    /// drawn image whose representations have none.
    @MainActor
    static func pixelSize(of image: NSImage) -> CGSize {
        var largest: CGSize?
        for representation in image.representations {
            let width = CGFloat(representation.pixelsWide)
            let height = CGFloat(representation.pixelsHigh)
            guard width > 0, height > 0 else { continue }
            if let current = largest, current.width * current.height >= width * height { continue }
            largest = CGSize(width: width, height: height)
        }
        return largest ?? image.size
    }

    // MARK: - Private Methods

    private final class LegibleEntry {
        let source: NSImage
        let result: NSImage

        init(source: NSImage, result: NSImage) {
            self.source = source
            self.result = result
        }
    }

    @MainActor
    private static func rimmedIfNeeded(
        _ image: NSImage,
        grounds: [NSColor],
        ink: NSColor,
        maximumPixels: Int
    ) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let measure = measure(source, grounds: grounds.map(rgb)),
              !measure.separates,
              let working = fitted(source, maximumSide: maximumPixels),
              let rimmed = rimmed(working, ink: (ink.usingColorSpace(.sRGB) ?? ink).cgColor) else {
            return nil
        }
        // Grown by the rim in the same proportion as the pixels, so the picture keeps its own
        // point size inside a rim that sits outside it. A bitmap representation rather than
        // `NSImage(cgImage:size:)`, whose snapshot representation reports a backing-scaled pixel
        // count — and the Dock tile's enlargement cap is computed from the pixels.
        let scale = image.size.width / CGFloat(working.width)
        let representation = NSBitmapImageRep(cgImage: rimmed)
        representation.size = NSSize(width: CGFloat(rimmed.width) * scale, height: CGFloat(rimmed.height) * scale)
        let result = NSImage(size: representation.size)
        result.addRepresentation(representation)
        result.accessibilityDescription = image.accessibilityDescription
        return result
    }

    @MainActor
    private static func cacheKey(for image: NSImage, grounds: [NSColor], ink: NSColor) -> String {
        let colours = (grounds + [ink]).map { ($0.usingColorSpace(.sRGB) ?? $0).hexString }
        return "\(ObjectIdentifier(image))|" + colours.joined(separator: ",")
    }

    /// Straight RGBA bytes of `image` fitted, aspect kept, into a `sampleSide` square.
    private static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let side = sampleSide
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let buffer = context.data else { return nil }
        let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (CGFloat(side) - width) / 2,
            y: (CGFloat(side) - height) / 2,
            width: width,
            height: height
        ))
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
