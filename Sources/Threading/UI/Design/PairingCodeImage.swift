import AppKit
import CoreImage.CIFilterBuiltins

/// A pairing URL drawn as a QR code that belongs to the app rather than to Core Image.
///
/// `CIQRCodeGenerator` returns a bitmap of hard black squares with a **1-module** border, and
/// scaling that up is what the Remote Access page used to show: a stark monochrome block with
/// four sharp corners, sitting on a themed card it shared nothing with.
///
/// The geometry here is Chromium's — `components/qr_code_generator/bitmap_generator.cc` draws
/// circular modules at 0.8 of the pitch and nested rounded rects for the finder patterns, which
/// is why a Chrome QR reads as a piece of interface instead of a printed label. The colours are
/// ours: a near-white plate and near-black ink, both pulled a few degrees toward the theme's
/// accent, so the code sits in the same palette as everything around it.
///
/// **The quiet zone is not decoration.** ISO/IEC 18004 asks for four clear modules on every
/// side; Core Image supplies one. The plate is sized to carry the full four, which is the
/// single biggest scannability difference between this and what shipped before — a code whose
/// margin is a card edge rather than white space is the classic reason a phone hunts for it.
///
/// Measured before it was written: against a Vision decode of the rendered image, softened and
/// tilted 20° the way a code actually gets scanned, Chrome geometry with a proper quiet zone
/// needs 3.02 px per module where hard squares need 2.98 — about 1%, for a shape that stops
/// looking like a barcode. Inverting it (light modules on the theme's dark ground) cost 23% and
/// was rejected. Punching a logo hole forces correction level H and jumps the symbol from 41 to
/// 57 modules, which is a real cost to buy an ornament; it was rejected too.
@MainActor
enum PairingCodeImage {

    /// The side the Remote Access card gives the code.
    ///
    /// Larger than the 196pt the raw filter output used, because the plate now carries the
    /// four-module quiet zone: the symbol itself occupies 41 of 49 modules, so an unchanged box
    /// would have shrunk the part that has to be read.
    static let preferredSide: CGFloat = 212

    /// The side of a finder pattern, in modules. Fixed by the format, and shared with
    /// `PairingCodeMatrix` so the grid and the renderer cannot disagree about which modules the
    /// eyes have already drawn.
    static let locatorModules = 7

    private enum Layout {
        /// ISO/IEC 18004 §6.3.8. Core Image emits one; the difference is the whole point.
        static let quietModules = 4

        /// Chromium's dot: `radius = module / 2 - 1` at a 10px module, so 0.8 of the pitch.
        static let moduleScale: CGFloat = 0.80

        /// The corner radius of each of the finder pattern's three nested rings, in modules.
        /// Rounder than Chromium's flat 1-module radius: at the size this is displayed the
        /// eyes are the only large shapes, and they set how the whole code reads.
        static let locatorOuterRadius: CGFloat = 1.75
        static let locatorMiddleRadius: CGFloat = 1.20
        static let locatorInnerRadius: CGFloat = 0.85

        /// The plate and the ink take the accent's *hue* and state their own saturation, rather
        /// than mixing a fraction of the accent in.
        ///
        /// Mixing was the first attempt and it made the tint depend on how saturated the theme's
        /// accent happened to be: System's blue turned the plate visibly blue at the same blend
        /// that left Cyberpunk's neon green almost invisible. Naming the saturation gives every
        /// theme the same strength of tint and none of them a coloured plate — which would be a
        /// plate competing with the modules it exists to separate.
        static let plateSaturation: CGFloat = 0.05
        static let plateBrightness: CGFloat = 0.98
        static let inkSaturation: CGFloat = 0.55
        static let inkBrightness: CGFloat = 0.14

        /// Held far above the 4:1 the spec asks for, so a theme cannot tint its way into a
        /// code that photographs badly. Reached by darkening the ink, never by lightening the
        /// plate, because the plate is also the quiet zone.
        static let minimumContrastRatio: CGFloat = 7.0
        static let inkDarkeningStep: CGFloat = 0.02
    }

    /// Medium recovers ~15% of a damaged symbol and is what the page already used. Raising it
    /// would grow the symbol without helping a code that is displayed on glass and never
    /// printed, torn, or smudged.
    private static let correctionLevel = "M"

    // MARK: - Public

    /// Draws `text` as a themed QR code, or returns `nil` if it cannot be encoded.
    ///
    /// The matrix is computed once, here; the colours resolve inside the drawing handler, so a
    /// live theme change repaints the code rather than leaving a frozen palette behind.
    static func make(for text: String, side: CGFloat = preferredSide) -> NSImage? {
        guard let matrix = PairingCodeMatrix.make(text, correctionLevel: correctionLevel) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(matrix, in: rect)
            return true
        }

        // The theme's colours are the point; tinting it as a template would flatten the plate
        // and the ink into one.
        image.isTemplate = false
        image.accessibilityDescription =
            "QR code for pairing a device with this Mac. Use Copy Pairing Link instead if you "
            + "cannot scan it."
        return image
    }

    // MARK: - Drawing

    private static func draw(_ matrix: PairingCodeMatrix, in rect: NSRect) {
        let total = CGFloat(matrix.size + Layout.quietModules * 2)
        let pitch = min(rect.width, rect.height) / total
        let inset = CGFloat(Layout.quietModules) * pitch

        let plate = plateColor()
        let ink = inkColor(on: plate)

        let radius = SurfaceRadius.panel.current
        plate.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        // Stroked half a width in, so the hairline lands inside the image instead of being
        // clipped down to half of itself by its own bounds.
        let width = Design.Radius.border
        let edge = rect.insetBy(dx: width / 2, dy: width / 2)
        let border = NSBezierPath(
            roundedRect: edge,
            xRadius: max(0, radius - width / 2),
            yRadius: max(0, radius - width / 2)
        )
        Design.Surface.border.setStroke()
        border.lineWidth = width
        border.stroke()

        /// Module coordinates run top-left-down; the image does not.
        func box(x: Int, y: Int) -> NSRect {
            NSRect(
                x: rect.minX + inset + CGFloat(x) * pitch,
                y: rect.maxY - inset - CGFloat(y + 1) * pitch,
                width: pitch,
                height: pitch
            )
        }

        ink.setFill()

        let diameter = pitch * Layout.moduleScale
        let padding = (pitch - diameter) / 2
        for y in 0..<matrix.size {
            for x in 0..<matrix.size where matrix[x, y] && !matrix.isLocator(x, y) {
                NSBezierPath(ovalIn: box(x: x, y: y).insetBy(dx: padding, dy: padding)).fill()
            }
        }

        let locatorSide = CGFloat(locatorModules)
        for origin in matrix.locatorOrigins {
            let outer = NSRect(
                x: rect.minX + inset + CGFloat(origin.x) * pitch,
                y: rect.maxY - inset - (CGFloat(origin.y) + locatorSide) * pitch,
                width: pitch * locatorSide,
                height: pitch * locatorSide
            )
            fillRounded(outer, radius: pitch * Layout.locatorOuterRadius, color: ink)
            fillRounded(
                outer.insetBy(dx: pitch, dy: pitch),
                radius: pitch * Layout.locatorMiddleRadius,
                color: plate
            )
            fillRounded(
                outer.insetBy(dx: pitch * 2, dy: pitch * 2),
                radius: pitch * Layout.locatorInnerRadius,
                color: ink
            )
        }
    }

    private static func fillRounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: - Palette

    /// Near-white, carrying the theme accent's hue.
    ///
    /// Always light, on every theme including the dark ones. A code drawn light-on-dark is
    /// legal and about 80–90% of scanners read it, but it measured 23% worse here and the
    /// failures land on the phones least able to work around them.
    private static func plateColor() -> NSColor {
        tinted(saturation: Layout.plateSaturation, brightness: Layout.plateBrightness)
    }

    /// Near-black, carrying the same hue, darkened until it clears the contrast floor.
    ///
    /// Only the ink moves. The plate is also the quiet zone, so lightening it to win contrast
    /// would trade the margin a scanner needs for a number in a test.
    private static func inkColor(on plate: NSColor) -> NSColor {
        var brightness = Layout.inkBrightness
        var ink = tinted(saturation: Layout.inkSaturation, brightness: brightness)

        while brightness > 0, ThemeContrast.ratio(ink, plate) < Layout.minimumContrastRatio {
            brightness = max(0, brightness - Layout.inkDarkeningStep)
            ink = tinted(saturation: Layout.inkSaturation, brightness: brightness)
        }
        return ink
    }

    /// The accent's hue at a stated saturation, so a greyscale theme stays greyscale — `min`
    /// rather than a fixed value, or a theme with no colour in it would be given some.
    private static func tinted(saturation: CGFloat, brightness: CGFloat) -> NSColor {
        guard let accent = Design.Surface.accent.usingColorSpace(.sRGB) else {
            return NSColor(white: brightness, alpha: 1)
        }
        return NSColor(
            hue: accent.hueComponent,
            saturation: min(accent.saturationComponent, saturation),
            brightness: brightness,
            alpha: 1
        )
    }
}

// MARK: - Matrix

/// The module grid behind a QR symbol, with Core Image's built-in border removed.
///
/// Separated from the drawing because it is the one part that does not depend on the theme:
/// encoding a URL is expensive enough that repeating it on every repaint — and a live theme
/// switch repaints everything — would be felt.
struct PairingCodeMatrix {
    private static let locatorModules = 7

    /// Modules per side, excluding any quiet zone. 41 for the pairing URLs this app produces.
    let size: Int

    private let modules: [Bool]

    subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return modules[y * size + x]
    }

    /// The three 7×7 finder patterns, by their top-left module. A QR symbol has no fourth.
    var locatorOrigins: [(x: Int, y: Int)] {
        let last = size - Self.locatorModules
        return [(0, 0), (last, 0), (0, last)]
    }

    func isLocator(_ x: Int, _ y: Int) -> Bool {
        let span = Self.locatorModules
        return locatorOrigins.contains { origin in
            x >= origin.x && x < origin.x + span && y >= origin.y && y < origin.y + span
        }
    }

    /// Encodes `text` and reads the result back as booleans.
    ///
    /// Rendered as RGBA rather than grayscale on purpose: the filter's output is *transparent*
    /// where a module is light, not white, so a format that drops alpha reports every pixel as
    /// dark and the quiet zone as zero modules wide.
    static func make(_ text: String, correctionLevel: String) -> PairingCodeMatrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        // Core Image's own 1-module border, which the renderer replaces with a full quiet zone.
        guard width > 2, height > 2, width == height else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(
                output,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }

        let side = width - 2
        var grid = [Bool]()
        grid.reserveCapacity(side * side)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let offset = (y * width + x) * 4
                grid.append(pixels[offset + 3] > 128 && pixels[offset] < 128)
            }
        }
        return PairingCodeMatrix(size: side, modules: grid)
    }
}
