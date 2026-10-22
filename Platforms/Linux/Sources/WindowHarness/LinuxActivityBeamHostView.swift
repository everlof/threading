import AppKit

/// Linux renderer for BorderBeamKit's host contract. The shared AgentActivityBeamView owns
/// workload, theme, motion, and constraints; this leaf supplies native pixels.
@MainActor
final class LinuxActivityBeamHostView: NSView {
    enum Size { case pulseInner }
    enum ColorVariant { case mono, colorful }
    enum Theme { case auto }

    struct Configuration {
        let size: Size
        let colorVariant: ColorVariant
        let theme: Theme
        let active: Bool
        let borderRadius: Double
        let strength: Double
    }

    var configuration = Configuration(size: .pulseInner, colorVariant: .mono,
                                      theme: .auto, active: false, borderRadius: 0, strength: 0) {
        didSet { needsDisplay = true }
    }
    var rendersStatically = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard configuration.active else { return }
        let inset: CGFloat = 1.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(CGFloat(configuration.borderRadius), min(rect.width, rect.height) / 2)
        let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        ring.lineWidth = 2
        let ink = configuration.colorVariant == .colorful
            ? LinuxTheme.color("accent") : LinuxTheme.color("label")
        ink.withAlphaComponent(CGFloat(configuration.strength)).setStroke()
        ring.stroke()
    }

    func withCachedDisplayFallback<Result>(_ body: () throws -> Result) rethrows -> Result {
        try body()
    }
}

typealias BorderBeamHostView = LinuxActivityBeamHostView

extension AppThemePalette.Palette {
    var isSystem: Bool { true }
}
