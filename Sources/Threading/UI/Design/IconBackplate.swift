import AppKit

/// Whether a mark disappears into what it is drawn on, and the plate that rescues it.
///
/// The project icons have carried this since the sidebar started drawing brand marks: a dark
/// favicon on the dark sidebar is a hole, so it is set on a small opposing plate, decided from
/// the icon's own pixels rather than guessed from its source. What was missing is that the
/// *ground* was assumed to be the appearance — light or dark — when a row's ground is not a
/// constant at all. A selected row is filled with the theme's accent, and Claude's coral
/// starburst on a holly-red selection is the same hole for the same reason, one that no amount
/// of knowing "we are in dark mode" can predict.
///
/// So the rule here takes the ground it is actually drawn on, and the appearance case becomes
/// what it always was: a ground that happens to be the sidebar's surface.
///
/// **Tone, not WCAG luminance.** Both sides are measured as the alpha-weighted mean of
/// gamma-encoded sRGB, which is what the icon pixels can be averaged in cheaply and what the
/// existing plate thresholds were calibrated against. Contrast for *text* is a different
/// question with a different measure — `ThemeContrast` — and this is deliberately not that: a
/// mark only has to be findable, not readable.
enum IconBackplate {

    // MARK: - The Ground

    /// The tone of the surface a mark is actually drawn on.
    ///
    /// A type rather than a `CGFloat` because the number this rule needs is not one a caller can
    /// be trusted to write. It carried two named constants for a while — the tones of the light
    /// and dark *system* sidebars — and `ProjectIconStore` reached for them, since "which
    /// appearance is this" is a question with an easy answer and "what colour is under this icon"
    /// is not. They are the same answer only under the System theme. Windows 98's sidebar is
    /// `#C0C0C0`, tone 0.75, where the constant said 0.97; the Claude mark measures 0.53, so the
    /// separation the rule tests came out 0.44 against the constant and 0.23 against the surface
    /// actually painted, on either side of the 0.24 threshold. Every project favicon between
    /// roughly 0.51 and 0.73 lost its plate under half the themes in the app.
    ///
    /// So there is no way to state a ground except by handing over the colour, and the tone is
    /// measured here. The constants are gone rather than deprecated: a number that was wrong for
    /// nineteen of twenty-one themes should not be reachable.
    struct Ground: Equatable {

        /// 0 (black) to 1 (white), by the measure `IconBackplate` documents.
        let tone: CGFloat

        init(_ color: NSColor) {
            tone = IconBackplate.tone(of: color)
        }

        /// A stable, short key for caching a rendition composed against this ground.
        ///
        /// Quantized, because the ground is a measurement: a fill that resolves a thousandth
        /// differently between two reads is the same ground, and keying on the raw value would
        /// grow an entry per read. The step is far finer than `minimumSeparation`, so two grounds
        /// that share a key cannot disagree about the plate.
        var cacheKey: String {
            String(Int((tone * CGFloat(Defaults.groundKeySteps)).rounded()))
        }
    }

    // MARK: - Measuring

    /// The image's alpha-weighted mean tone over its visible pixels, 0 (black) to 1 (white).
    ///
    /// Transparent regions carry no weight, so a small dark glyph on a clear background reads
    /// as dark rather than as mostly-nothing. Renders into a small premultiplied bitmap and
    /// averages: with premultiplication each channel already carries its alpha, so
    /// channel-sum over alpha-sum is the alpha-weighted mean directly.
    static func tone(of image: NSImage) -> CGFloat? {
        let side = Defaults.sampleSize
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var toneSum = 0.0
        var alphaSum = 0.0

        for index in 0..<(side * side) {
            let offset = index * 4
            toneSum += 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
            alphaSum += Double(pixels[offset + 3])
        }

        guard alphaSum > 0 else { return nil }
        return CGFloat(toneSum / alphaSum)
    }

    /// The same measure for a flat colour, so a mark and its ground are comparable numbers.
    ///
    /// A translucent ground is composited onto its own base first by the caller; measured raw,
    /// a 20%-opaque accent would report the accent's tone rather than the muted one seen.
    static func tone(of color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
    }

    // MARK: - Deciding

    /// Whether a mark of this tone vanishes into a ground of that tone.
    ///
    /// A mark with no measurable tone — an undecodable image — never plates: the plate is a
    /// rescue, and rescuing something we cannot see the shape of is how a plate ends up behind
    /// every icon in the list.
    static func isNeeded(markTone: CGFloat?, ground: Ground) -> Bool {
        guard let markTone else { return false }
        return abs(markTone - ground.tone) < Defaults.minimumSeparation
    }

    /// The neutral that opposes a ground.
    ///
    /// Fixed neutrals, deliberately outside the system palette and outside the theme: a plate
    /// exists to *oppose* the ground, and every themed colour follows it. This is the design
    /// system's one standing exception to "semantic roles only", and it is the whole reason the
    /// plate works under a red selection as well as under a grey sidebar.
    static func plateColor(against ground: Ground) -> NSColor {
        ground.tone < Defaults.midTone ? Defaults.lightPlate : Defaults.darkPlate
    }

    // MARK: - Composing

    /// The mark on its plate, or the mark unchanged when it does not need one.
    ///
    /// Template images are returned untouched whatever the ground: a template takes its
    /// context's tint, so it is already drawn in a colour chosen to be seen — plating one would
    /// put a light square behind a label-coloured glyph that was never in trouble.
    static func plated(
        _ image: NSImage,
        knownMarkTone: CGFloat? = nil,
        against ground: Ground,
        size: CGFloat = Defaults.displaySize,
        cornerRadius: CGFloat = Defaults.cornerRadius
    ) -> NSImage {
        guard !image.isTemplate,
              isNeeded(markTone: knownMarkTone ?? tone(of: image), ground: ground) else {
            return image
        }

        return compose(
            image,
            plate: plateColor(against: ground),
            size: size,
            cornerRadius: cornerRadius
        )
    }

    /// Draws the plate *around* the mark, never the mark into the plate: the ink keeps the
    /// size it draws at with no plate — its own, capped at the plate itself — so a mark
    /// gaining its plate on selection stays exactly where and how big it was, and only the
    /// plate fades in behind it. The margin is whatever the caller left between the two
    /// sizes; the session row hands a 13pt mark to its 16pt slot.
    ///
    /// An earlier version inset the ink by a fixed ratio of the plate instead, which meant a
    /// mark visibly shrank the moment its ground moved close to it — the plate arrived *as*
    /// the resize, on every selection change.
    ///
    /// The drawing-handler image re-renders per backing scale, so the rounded plate stays
    /// crisp on Retina.
    static func compose(
        _ base: NSImage,
        plate: NSColor,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let shape = NSBezierPath(
                roundedRect: bounds,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            plate.setFill()
            shape.fill()
            shape.addClip()

            base.draw(
                in: inkRect(for: base.size, in: bounds),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    /// Where the ink lands on its plate: centred, at its own size, scaled down only if it
    /// would not fit at all.
    private static func inkRect(for size: NSSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - drawn.width / 2,
            y: bounds.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    // MARK: - Defaults

    enum Defaults {
        static let sampleSize = 32

        /// How far a mark's tone must sit from its ground's before it can be found without a
        /// plate. Calibrated to reproduce the project icons' original appearance-based rule:
        /// their dark-sidebar floor of 0.4 and light-sidebar ceiling of 0.75 are this same
        /// separation from the two grounds those numbers described.
        static let minimumSeparation: CGFloat = 0.24

        /// Where a ground stops counting as dark and starts counting as light, for choosing
        /// which neutral opposes it.
        static let midTone: CGFloat = 0.5

        /// How finely `Ground.cacheKey` distinguishes two grounds — a hundredth of the tone
        /// scale, an order of magnitude finer than `minimumSeparation`.
        static let groundKeySteps = 100

        static let lightPlate = NSColor(white: 0.93, alpha: 0.96)
        static let darkPlate = NSColor(white: 0.16, alpha: 0.92)

        static let displaySize: CGFloat = 16
        static let cornerRadius: CGFloat = 4
    }
}
