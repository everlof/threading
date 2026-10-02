import AppKit

// The fixed palette facts copied from the native Specimen shell. The reusable neutral-ink and
// legibility leaves are linked unchanged beside this test boundary.
@MainActor enum Specimen {
    static let bodyGround = NSColor(white: 0.87, alpha: 1)
    static let headerGround = NSColor(white: 0.78, alpha: 1)

    struct Ink {
        let label: NSColor
        let secondary: NSColor
        init(on ground: NSColor) {
            let rgb = ground.usingColorSpace(.sRGB) ?? ground
            guard let resolved = NeutralInk.resolve(
                on: .init(red: rgb.redComponent, green: rgb.greenComponent,
                          blue: rgb.blueComponent, alpha: rgb.alphaComponent),
                increasedContrast: false,
                readingRatio: TextLegibilityPolicy.readingRatio,
                glanceRatio: TextLegibilityPolicy.glanceRatio,
                strengthSteps: TextLegibilityPolicy.strengthSteps
            ) else { preconditionFailure("Unsupported diagnostic ground") }
            let base: CGFloat = resolved.base == .white ? 1 : 0
            label = NSColor(white: base, alpha: resolved.label.alpha)
            secondary = NSColor(white: base, alpha: resolved.secondary.alpha)
        }
    }
}
