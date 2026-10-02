import AppKit
import Foundation

/// Shim-only shapes, so a wrong picture later can be blamed on the vendored code rather than on
/// the rasterizer.
@MainActor
enum Smoke {

    final class Plate: NSView {
        var fill = NSColor(red: 0.16, green: 0.45, blue: 0.86, alpha: 1)
        var border: NSColor?
        var radius: CGFloat = 10

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            if let border {
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
                ring.lineWidth = 1
                border.setStroke()
                ring.stroke()
            }
        }
    }

    final class Disc: NSView {
        var fill = NSColor(red: 0.95, green: 0.42, blue: 0.2, alpha: 0.9)
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        }
    }

    static func run(into directory: String) throws {
        let root = Plate(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        root.fill = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        root.radius = 16

        let chip = Plate(frame: NSRect(x: 16, y: 34, width: 140, height: 52))
        chip.radius = 26
        chip.border = NSColor(white: 1, alpha: 0.25)
        root.addSubview(chip)

        let disc = Disc(frame: NSRect(x: 180, y: 30, width: 60, height: 60))
        root.addSubview(disc)

        let faded = Plate(frame: NSRect(x: 250, y: 30, width: 56, height: 60))
        faded.fill = NSColor(red: 0.4, green: 0.9, blue: 0.6, alpha: 1)
        faded.alphaValue = 0.35
        faded.radius = 8
        root.addSubview(faded)

        try render(root, background: NSColor(white: 0.85, alpha: 1), to: directory + "/smoke.png")
    }
}
