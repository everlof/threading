import AppKit
import Foundation

/// The same sidebar as `Specimen`, with every frame removed: nothing here sets a rectangle, and
/// the geometry in `constraints.png` is entirely the solver's answer.
///
/// Worth drawing rather than only asserting. A constraint engine can pass a dozen arithmetic
/// cases and still produce a picture that is subtly not a layout — rows a point out of step,
/// a trailing chip that clears its label by the wrong margin — and this repository already treats
/// rendered state as where appearance gets reviewed.
@MainActor
enum ConstraintSpecimen {

    class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    class Plate: Flipped {
        var fill: NSColor = .clear
        var radius: CGFloat = 0
        var border: NSColor?

        override func draw(_ dirtyRect: NSRect) {
            guard fill != .clear || border != nil else { return }
            let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            if fill != .clear {
                fill.setFill()
                path.fill()
            }
            if let border {
                let ring = NSBezierPath(
                    roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: max(0, radius - 0.5),
                    yRadius: max(0, radius - 0.5)
                )
                ring.lineWidth = 1
                border.setStroke()
                ring.stroke()
            }
        }
    }

    final class Label: Plate {
        var text: String = ""
        var ink: NSColor = NSColor(white: 0.15, alpha: 1)

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // A label clips to its own box. Without this the glyphs overrun a frame the solver
            // compressed correctly, and the picture accuses the layout of a bug the drawing has.
            NSBezierPath(rect: bounds).addClip()
            PlatinumBitmapFont.draw(
                text,
                penX: 0,
                baselineFromTop: bounds.height / 2 + 4,
                in: bounds,
                ink: ink
            )
        }

        /// The intrinsic width the real face measures — which is how a label earns its size from
        /// the solver instead of being told one.
        override var intrinsicContentSize: NSSize {
            guard let advance = PlatinumBitmapFont.advance(of: text) else {
                return NSSize(width: NSView.noIntrinsicMetric, height: 12)
            }
            return NSSize(width: CGFloat(advance), height: 12)
        }
    }

    static func run(into directory: String) throws {
        let rows = [
            ("AnotherTerminal", "claude", true),
            ("ptyd on linux", "codex", false),
            ("AppKit shim spike", "claude", false),
            ("a name long enough to meet the chip", "grok", false)
        ]

        let root = Plate(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
        root.fill = NSColor(white: 0.91, alpha: 1)
        root.radius = 8
        root.border = NSColor(white: 0.55, alpha: 1)

        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        var constraints: [NSLayoutConstraint] = []
        var previous: NSView?

        for (title, kind, selected) in rows {
            let row = Plate(frame: .zero)
            row.radius = 5
            row.fill = selected ? accent : .clear
            root.addSubview(row)

            let dot = Plate(frame: .zero)
            dot.radius = 4
            dot.fill = selected ? NSColor(white: 1, alpha: 0.9) : accent

            let label = Label(frame: .zero)
            label.text = title
            label.ink = selected ? NSColor(white: 1, alpha: 1) : NSColor(white: 0.15, alpha: 1)

            let chip = Label(frame: .zero)
            chip.text = kind
            chip.radius = 6
            chip.fill = selected ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0.2, alpha: 0.08)
            chip.ink = selected ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0.3, alpha: 1)

            for child in [dot, label, chip] as [NSView] {
                row.addSubview(child)
                child.translatesAutoresizingMaskIntoConstraints = false
            }
            row.translatesAutoresizingMaskIntoConstraints = false

            constraints += [
                row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                row.heightAnchor.constraint(equalToConstant: 28),

                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),

                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                // The label yields to the chip rather than overrunning it — the one inequality
                // that makes the long fourth row interesting.
                label.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -8),

                chip.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                chip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chip.heightAnchor.constraint(equalToConstant: 16)
            ]
            // The chip is as wide as its own glyphs plus padding, measured by the real face.
            if let advance = PlatinumBitmapFont.advance(of: kind) {
                constraints.append(chip.widthAnchor.constraint(equalToConstant: CGFloat(advance) + 12))
            }

            if let previous {
                constraints.append(row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 4))
            } else {
                constraints.append(row.topAnchor.constraint(equalTo: root.topAnchor, constant: 8))
            }
            previous = row
        }

        NSLayoutConstraint.activate(constraints)
        let diagnosis = LayoutEngine.layout(root)
        print("constraints.png — \(diagnosis.constraintCount) constraints over \(diagnosis.itemCount) items, solved: \(diagnosis.solved), \(String(format: "%.1f", diagnosis.seconds * 1000))ms")

        for row in root.subviews {
            guard let label = row.subviews.compactMap({ $0 as? Label }).first else { continue }
            print(String(
                format: "    %-38s width %6.1f  intrinsic %6.1f  %@",
                (label.text as NSString).utf8String!, label.frame.width,
                label.intrinsicContentSize.width,
                label.frame.width < label.intrinsicContentSize.width - 0.5 ? "compressed" : "at intrinsic"
            ))
        }

        try render(root, scale: 3, background: NSColor(white: 0.55, alpha: 1), to: directory + "/constraints.png")
    }
}
