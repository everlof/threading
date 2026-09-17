import AppKit
import Foundation

/// What a from-scratch re-solve costs as a list gets longer.
///
/// This is the measurement the Scaling Gate would demand before any of this went near a sidebar,
/// and the reason it is here rather than later: a constraint engine that is correct and
/// super-linear is not a layout engine, it is a demo. The shape of the curve decides whether
/// "own the solver" means "write a solver" or "write an *incremental* solver", and those are
/// different projects.
@MainActor
enum LayoutBenchmark {

    static func run() {
        print("")
        print("layout solve cost — one full re-solve of a constraint-driven list")
        print("  rows   items   constraints    rows(LP)   vars      median ms")
        for count in [5, 10, 20, 40, 80] {
            var samples: [Double] = []
            var diagnosis: LayoutEngine.Diagnosis?
            for _ in 0..<5 {
                let root = makeList(rowCount: count)
                let result = LayoutEngine.layout(root)
                diagnosis = result
                samples.append(result.seconds * 1000)
            }
            samples.sort()
            guard let diagnosis else { continue }
            let median = samples[samples.count / 2]
            print(String(
                format: "  %4d   %5d   %11d   %8d   %5d   %10.1f",
                count, diagnosis.itemCount, diagnosis.constraintCount,
                diagnosis.rowCount, diagnosis.variableCount, median
            ))
            if !diagnosis.solved { print("     (did not solve)") }
        }
        print("")
    }

    /// A sidebar's shape: a scrolling column of rows, each row holding a dot, a label box and a
    /// trailing chip, pinned the way this app's rows actually are.
    private static func makeList(rowCount: Int) -> NSView {
        let root = Flipped(frame: NSRect(x: 0, y: 0, width: 280, height: CGFloat(rowCount) * 28 + 16))
        var previous: NSView?
        for _ in 0..<rowCount {
            let row = Flipped(frame: .zero)
            root.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false

            let dot = NSView(frame: .zero)
            let label = NSView(frame: .zero)
            let chip = NSView(frame: .zero)
            for child in [dot, label, chip] {
                row.addSubview(child)
                child.translatesAutoresizingMaskIntoConstraints = false
            }

            var constraints: [NSLayoutConstraint] = [
                row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                row.heightAnchor.constraint(equalToConstant: 24),

                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),

                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.heightAnchor.constraint(equalToConstant: 14),
                label.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -6),

                chip.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                chip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chip.widthAnchor.constraint(equalToConstant: 34),
                chip.heightAnchor.constraint(equalToConstant: 14)
            ]
            // The label would rather be wide, and yields to the chip. A soft constraint per row is
            // what makes this a real solve rather than a chain of substitutions.
            let wide = label.widthAnchor.constraint(equalToConstant: 400)
            wide.priority = .defaultLow
            constraints.append(wide)

            if let previous {
                constraints.append(row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 4))
            } else {
                constraints.append(row.topAnchor.constraint(equalTo: root.topAnchor, constant: 8))
            }
            NSLayoutConstraint.activate(constraints)
            previous = row
        }
        return root
    }

    final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }
}
