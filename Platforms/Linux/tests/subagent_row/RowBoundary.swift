import AppKit

// The production row and item model are compiled unchanged. This is the diagnostic host's
// fixed-palette counterpart of the app-owned theme, localization, font and selection services.
enum L10n {
    static func string(_ value: String) -> String { value }
    static func format(_ format: String, _ value: String) -> String {
        String(format: format, value)
    }
}

@MainActor extension NSTextField {
    func applyFont(_ role: Design.FontRole,
                   in surface: Design.Typography.FontSurface = .chrome) {
        let resolved = role.resolved(in: surface)
        font = resolved
        invalidateIntrinsicContentSize()
    }
}

@MainActor extension BackdropThemedControl {
    func resolvedGround() -> NSColor { Specimen.headerGround }
}

// A fixed diagnostic selection still follows the production quiet-selection rule: reduce the
// authored wash in 24 steps until ordinary label ink reaches 4.5:1 on the painted ground.
@MainActor struct SelectionSurface {
    let fill: NSColor
    let ground: NSColor

    static func quiet(over hostGround: NSColor) -> SelectionSurface {
        let authored = NSColor(red: 0.24, green: 0.42, blue: 0.72, alpha: 0.28)
        let label = Design.Text.label
        for step in 0...24 {
            let alpha = authored.alphaComponent * CGFloat(24 - step) / 24
            let fill = authored.withAlphaComponent(alpha)
            let ground = fill.composited(over: hostGround)
            if label.contrastRatio(on: ground) >= 4.5 {
                return SelectionSurface(fill: fill, ground: ground)
            }
        }
        return SelectionSurface(fill: authored, ground: authored.composited(over: hostGround))
    }
}

@MainActor extension NSColor {
    func composited(over background: NSColor) -> NSColor {
        let foreground = usingColorSpace(.sRGB) ?? self
        let backdrop = background.usingColorSpace(.sRGB) ?? background
        let alpha = foreground.alphaComponent
        return NSColor(
            red: foreground.redComponent * alpha + backdrop.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + backdrop.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + backdrop.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private var luminance: CGFloat {
        let rgb = usingColorSpace(.sRGB) ?? self
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    func contrastRatio(on ground: NSColor) -> CGFloat {
        let a = luminance
        let b = ground.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func legible(on ground: NSColor) -> NSColor {
        if contrastRatio(on: ground) >= 4.5 { return self }
        let pole = NSColor.black.contrastRatio(on: ground)
            >= NSColor.white.contrastRatio(on: ground) ? NSColor.black : NSColor.white
        for step in 1...24 {
            let amount = CGFloat(step) / 24
            let ink = blended(withFraction: amount, of: pole) ?? pole
            if ink.contrastRatio(on: ground) >= 4.5 { return ink }
        }
        return pole
    }
}

// The same single hairline used by SubagentTranscriptHeadingView; the focused fixture's
// measured subject is the navigator row, but the source file includes this sibling view.
@MainActor final class SeparatorView: NSView, ThemedComponent {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }
    override func draw(_ dirtyRect: NSRect) {
        Design.Text.tertiary.setFill()
        bounds.fill()
    }
}
