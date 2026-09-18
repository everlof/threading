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
        print("layout solve cost — cold (first solve) vs warm (a constant moved, tableau reused)")
        print("                                                              warm, no active-set  warm, crossing")
        print("  rows   items   constraints   LP rows    vars      cold ms   change ms  pivots    ms      pivots")
        for count in [5, 10, 20, 40, 80, 160] {
            // Cold: a brand-new tree each time, so nothing is retained.
            var cold: [Double] = []
            var shape: LayoutEngine.Diagnosis?
            for _ in 0..<3 {
                let root = makeList(rowCount: count)
                let result = LayoutEngine.layout(root)
                shape = result
                cold.append(result.seconds * 1000)
                LayoutEngine.forget(root)
            }

            // Warm, narrow sweep: a drag that never changes *which* constraints are active. The
            // easy case, and the one a benchmark will report by accident if nobody checks the
            // pivot count — with zero pivots this measures the B⁻¹ · b multiply and nothing else.
            let narrow = warmSweep(rowCount: count, widths: [260, 280, 300])
            // Warm, threshold-crossing: wide enough that each row's label stops being clipped by
            // its chip and its soft 400pt width starts being satisfiable. The active set changes,
            // so the dual simplex actually has to pivot. This is the number to quote.
            let crossing = warmSweep(rowCount: count, widths: [200, 700, 240, 900, 300, 460])

            cold.sort()
            guard let shape, narrow.solved, crossing.solved else { continue }
            print(String(
                format: "  %4d   %5d   %11d   %7d   %5d   %10.1f %10.2f %7d %10.2f %7d",
                count, shape.itemCount, shape.constraintCount,
                shape.rowCount, shape.variableCount,
                cold[cold.count / 2],
                narrow.median, narrow.pivots,
                crossing.median, crossing.pivots
            ))
        }
        print("")
    }

    private struct Sweep {
        var median: Double
        var pivots: Int
        var solved: Bool
    }

    /// Build one tree, solve it once, then walk it through `widths` several times over, reusing
    /// the retained tableau. Reports the median re-solve and the median pivot count — the second
    /// of which is what says whether the warm path was actually exercised.
    private static func warmSweep(rowCount: Int, widths: [CGFloat]) -> Sweep {
        let root = makeList(rowCount: rowCount)
        guard LayoutEngine.layout(root).solved else {
            LayoutEngine.forget(root)
            return Sweep(median: 0, pivots: 0, solved: false)
        }
        var times: [Double] = []
        var pivots: [Int] = []
        var solved = true
        for pass in 0..<3 {
            for width in widths {
                _ = pass
                root.frame = NSRect(x: 0, y: 0, width: width, height: root.frame.height)
                let result = LayoutEngine.layout(root)
                times.append(result.seconds * 1000)
                pivots.append(result.pivots)
                if !result.solved || !result.incremental { solved = false }
            }
        }
        LayoutEngine.forget(root)
        times.sort()
        pivots.sort()
        return Sweep(median: times[times.count / 2], pivots: pivots[pivots.count / 2], solved: solved)
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
