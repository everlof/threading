import AppKit
import Foundation

/// The spike's actual claim, drawn: `PlatinumBitmapFont.swift` is vendored byte-identical from
/// `Sources/Threading/UI/Design/`, and these are its glyphs, rasterized on Linux by a module we
/// simply named `AppKit`. Nothing in the file was touched — `./vendor.sh --verify` proves it.
@MainActor
enum Specimen {

    final class Window: NSView {
        static let titleHeight: CGFloat = 26
        var title = "Threading on Linux"
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.87, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            // Title bar.
            let bar = NSRect(x: bounds.minX, y: bounds.maxY - Self.titleHeight,
                             width: bounds.width, height: Self.titleHeight)
            NSColor(white: 0.78, alpha: 1).setFill()
            bar.fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            frame.lineWidth = 1
            frame.stroke()

            // An em-dash is not in the face, and the real file answers that by returning false
            // rather than drawing a blank — which is exactly what it did here on the first run.
            PlatinumBitmapFont.draw(
                title,
                penX: bounds.minX + 12,
                baselineFromTop: 18,
                in: bar,
                ink: NSColor(white: 0.1, alpha: 1)
            )
        }
    }

    /// Bounded diagnostic prose, using the same measured bitmap face as the specimen rows.
    final class Message: NSView {
        private static let maximumScalars = 1024
        private static let lineHeight: CGFloat = 16
        let text: String

        init(frame: NSRect, text: String) {
            self.text = String(text.unicodeScalars.prefix(Self.maximumScalars))
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(rect: bounds).addClip()
            let maximumLines = max(1, Int(bounds.height / Self.lineHeight))
            var lines = [String](), line = "", advance = 0
            for scalar in text.unicodeScalars {
                let glyph = scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : "?"
                let glyphAdvance = PlatinumBitmapFont.advance(of: glyph) ?? 0
                if scalar == "\n" || advance + glyphAdvance > Int(bounds.width) {
                    if scalar != "\n", let space = line.lastIndex(of: " ") {
                        lines.append(String(line[..<space]))
                        line = String(line[line.index(after: space)...])
                        advance = PlatinumBitmapFont.advance(of: line) ?? 0
                    } else {
                        lines.append(line); line = ""; advance = 0
                    }
                    if lines.count == maximumLines { break }
                    if scalar == "\n" { continue }
                }
                if glyph == " " && line.isEmpty { continue }
                line += glyph; advance += glyphAdvance
            }
            if lines.count < maximumLines { lines.append(line) }
            else { lines[maximumLines - 1] = "..." }
            for (index, value) in lines.enumerated() {
                PlatinumBitmapFont.draw(value, penX: 0,
                    baselineFromTop: CGFloat(index + 1) * Self.lineHeight - 2,
                    in: bounds, ink: NSColor(white: 0.15, alpha: 1))
            }
        }
    }

    final class Row: NSView {
        let text: String
        let accent: NSColor
        let selected: Bool

        init(frame: NSRect, text: String, accent: NSColor, selected: Bool) {
            self.text = text
            self.accent = accent
            self.selected = selected
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(rect: bounds).addClip()
            if selected {
                accent.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            }
            (selected ? NSColor(white: 1, alpha: 0.9) : accent).setFill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: bounds.midY - 4, width: 8, height: 8)).fill()
            PlatinumBitmapFont.draw(
                text,
                penX: 26,
                baselineFromTop: bounds.height / 2 + 4,
                in: bounds,
                ink: selected ? NSColor(white: 1, alpha: 1) : NSColor(white: 0.15, alpha: 1)
            )
        }
    }

    static func run(into directory: String) throws {
        let window = Window(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        let rows = [
            ("AnotherTerminal", true),
            ("ptyd on linux", false),
            ("AppKit shim spike", false),
            ("scaling gate", false)
        ]
        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        for (index, row) in rows.enumerated() {
            let y = window.frame.height - 26 - 24 - CGFloat(index) * 24
            window.addSubview(Row(
                frame: NSRect(x: 6, y: y, width: window.frame.width - 12, height: 22),
                text: row.0,
                accent: accent,
                selected: row.1
            ))
        }
        try render(window, scale: 3, background: NSColor(white: 0.55, alpha: 1), to: directory + "/specimen.png")

        if let advance = PlatinumBitmapFont.advance(of: "Threading on Linux") {
            print("PlatinumBitmapFont.advance(of:) = \(advance)px — the real file's own metrics")
        }
    }
}
