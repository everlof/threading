import AppKit
import Foundation

/// Hand-computed layouts, checked against the solver.
///
/// A constraint engine that is merely *plausible* is worse than none: it produces pictures that
/// look arranged and are wrong by a few points everywhere, and no render test would catch it. So
/// every case here states the answer arithmetically in its own name, and the flipped/unflipped
/// pair is checked separately because that conversion is the one place the drawing coordinate
/// system re-enters the layout space.
@MainActor
enum LayoutTests {

    private static var failures: [String] = []

    static func run() -> Bool {
        failures = []

        pinnedRowInUnflippedParent()
        pinnedRowInFlippedParent()
        centredBox()
        halfWidthByMultiplier()
        inequalityWithPriority()
        compressionResistanceBeatsHugging()
        chainedSiblings()
        unsatisfiableIsReported()
        guideDividesAColumn()
        warmStartAgreesWithColdSolve()
        warmStartSurvivesAnInfeasibleEdit()
        warmStartDoesNotDriftOverALongDrag()

        if failures.isEmpty {
            print("layout: all cases pass")
            return true
        }
        for failure in failures { print("layout FAIL: \(failure)") }
        return false
    }

    // MARK: - Cases

    /// AppKit's y grows upward, so a row pinned 8 from the top of a 100-tall parent and 24 tall
    /// has its *origin* at 100 - 8 - 24 = 68. Getting this backwards is the classic port bug.
    private static func pinnedRowInUnflippedParent() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let row = Box(frame: .zero)
        root.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        root.layoutSubtreeIfNeeded()
        expect("pinned row, unflipped", row.frame, NSRect(x: 8, y: 68, width: 184, height: 24))
    }

    /// The same constraints in a flipped parent put the origin at the top: y = 8.
    private static func pinnedRowInFlippedParent() {
        let root = FlippedBox(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let row = Box(frame: .zero)
        root.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        root.layoutSubtreeIfNeeded()
        expect("pinned row, flipped", row.frame, NSRect(x: 8, y: 8, width: 184, height: 24))
    }

    private static func centredBox() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 60),
            box.heightAnchor.constraint(equalToConstant: 20)
        ])
        root.layoutSubtreeIfNeeded()
        expect("centred", box.frame, NSRect(x: 70, y: 40, width: 60, height: 20))
    }

    private static func halfWidthByMultiplier() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            box.topAnchor.constraint(equalTo: root.topAnchor),
            box.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.5, constant: -10),
            box.heightAnchor.constraint(equalToConstant: 10)
        ])
        root.layoutSubtreeIfNeeded()
        expect("multiplier", box.frame, NSRect(x: 0, y: 90, width: 90, height: 10))
    }

    /// A low-priority width of 300 cannot beat a required trailing edge: the box stops at 180.
    /// This is the case a sort-order "priority" gets wrong, which is why the engine spends error
    /// variables on it.
    private static func inequalityWithPriority() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        let wide = box.widthAnchor.constraint(equalToConstant: 300)
        wide.priority = .defaultLow
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            box.topAnchor.constraint(equalTo: root.topAnchor),
            box.heightAnchor.constraint(equalToConstant: 10),
            wide
        ])
        root.layoutSubtreeIfNeeded()
        expect("priority yields to required", box.frame, NSRect(x: 10, y: 90, width: 180, height: 10))
    }

    /// Intrinsic width 120, hugging low, compression resistance high, and a container too narrow:
    /// resistance wins, so the view overflows rather than shrinking.
    private static func compressionResistanceBeatsHugging() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let label = IntrinsicBox(frame: .zero, intrinsic: NSSize(width: 120, height: 16))
        root.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let narrow = label.widthAnchor.constraint(equalToConstant: 40)
        narrow.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            label.topAnchor.constraint(equalTo: root.topAnchor),
            narrow
        ])
        root.layoutSubtreeIfNeeded()
        expect("resistance beats a weaker width", label.frame.width, 120)
        expect("intrinsic height applies", label.frame.height, 16)
    }

    /// Three siblings in a row, each 4 apart, the last pinned to the trailing edge: the shared
    /// width is (200 - 2*8 - 2*4) / 3 = 58.666…
    private static func chainedSiblings() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let boxes = (0..<3).map { _ -> Box in
            let box = Box(frame: .zero)
            root.addSubview(box)
            box.translatesAutoresizingMaskIntoConstraints = false
            return box
        }
        var constraints: [NSLayoutConstraint] = [
            boxes[0].leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            boxes[2].trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8)
        ]
        for (index, box) in boxes.enumerated() {
            constraints.append(box.topAnchor.constraint(equalTo: root.topAnchor, constant: 6))
            constraints.append(box.heightAnchor.constraint(equalToConstant: 28))
            if index > 0 {
                constraints.append(box.leadingAnchor.constraint(equalTo: boxes[index - 1].trailingAnchor, constant: 4))
                constraints.append(box.widthAnchor.constraint(equalTo: boxes[0].widthAnchor))
            }
        }
        NSLayoutConstraint.activate(constraints)
        root.layoutSubtreeIfNeeded()
        let expected = (200.0 - 16 - 8) / 3
        expect("equal siblings share the row", boxes[0].frame.width, CGFloat(expected))
        expect("last sibling meets the trailing inset", boxes[2].frame.maxX, 192)
    }

    /// Two required widths that disagree. The engine must say so; a silent zero would ship as an
    /// invisible view and be debugged as a drawing bug.
    private static func unsatisfiableIsReported() {
        let root = Box(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            box.topAnchor.constraint(equalTo: root.topAnchor),
            box.heightAnchor.constraint(equalToConstant: 10),
            box.widthAnchor.constraint(equalToConstant: 10),
            box.widthAnchor.constraint(equalToConstant: 20)
        ])
        let diagnosis = root.layoutSubtreeIfNeeded()
        if diagnosis?.solved != false {
            failures.append("unsatisfiable constraints reported as solved")
        }
    }

    /// A guide is a rectangle with anchors and no view — it has to take part in the same solve.
    private static func guideDividesAColumn() {
        let root = FlippedBox(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let guide = NSLayoutGuide()
        root.addLayoutGuide(guide)
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            guide.heightAnchor.constraint(equalToConstant: 50),
            guide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            guide.widthAnchor.constraint(equalTo: root.widthAnchor),
            box.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: 6),
            box.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 4),
            box.widthAnchor.constraint(equalToConstant: 30),
            box.heightAnchor.constraint(equalToConstant: 10)
        ])
        root.layoutSubtreeIfNeeded()
        expect("guide positions a sibling", box.frame, NSRect(x: 4, y: 76, width: 30, height: 10))
    }

    /// The one that matters most about the incremental path: a warm-started re-solve must land on
    /// the same geometry a cold solve would. A fast layout that is quietly a *different* layout is
    /// worse than a slow one, and it would show up as a drift of a point or two that no assertion
    /// about the first frame could ever catch.
    private static func warmStartAgreesWithColdSolve() {
        func build() -> (NSView, [NSView], NSLayoutConstraint) {
            let root = FlippedBox(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
            var boxes: [NSView] = []
            var previous: NSView?
            var inset: NSLayoutConstraint!
            for index in 0..<5 {
                let box = IntrinsicBox(frame: .zero, intrinsic: NSSize(width: 60 + CGFloat(index) * 7, height: 18))
                root.addSubview(box)
                box.translatesAutoresizingMaskIntoConstraints = false
                let leading = box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10)
                if index == 0 { inset = leading }
                var constraints: [NSLayoutConstraint] = [
                    leading,
                    box.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
                    box.heightAnchor.constraint(equalToConstant: 20)
                ]
                let wide = box.widthAnchor.constraint(equalToConstant: 400)
                wide.priority = .defaultLow
                constraints.append(wide)
                if let previous {
                    constraints.append(box.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 6))
                } else {
                    constraints.append(box.topAnchor.constraint(equalTo: root.topAnchor, constant: 12))
                }
                NSLayoutConstraint.activate(constraints)
                boxes.append(box)
                previous = box
            }
            return (root, boxes, inset)
        }

        // Warm: solve, move a constant, solve again on the retained tableau.
        let (warmRoot, warmBoxes, warmInset) = build()
        var diagnosis = LayoutEngine.layout(warmRoot)
        if diagnosis.incremental { failures.append("first solve claimed to be incremental") }
        warmInset.constant = 34
        warmRoot.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        diagnosis = LayoutEngine.layout(warmRoot)
        if !diagnosis.incremental {
            failures.append("a constant-only change did not warm start")
        }

        // Cold: the same tree, the same final numbers, no retained tableau.
        let (coldRoot, coldBoxes, coldInset) = build()
        coldInset.constant = 34
        coldRoot.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        LayoutEngine.forget(coldRoot)
        LayoutEngine.layout(coldRoot)

        for (index, pair) in zip(warmBoxes, coldBoxes).enumerated() {
            expect("warm start matches cold solve, box \(index)", pair.0.frame, pair.1.frame)
        }
    }

    /// An edit can make a satisfiable program unsatisfiable. The warm path has to notice, rather
    /// than returning the stale geometry it happens to be holding.
    private static func warmStartSurvivesAnInfeasibleEdit() {
        let root = FlippedBox(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let box = Box(frame: .zero)
        root.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        let width = box.widthAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            box.topAnchor.constraint(equalTo: root.topAnchor),
            box.heightAnchor.constraint(equalToConstant: 10),
            width
        ])
        if LayoutEngine.layout(root).solved != true {
            failures.append("the satisfiable starting layout did not solve")
        }
        // 400 wide, pinned 10 from the leading edge, inside 200: impossible.
        width.constant = 400
        let after = LayoutEngine.layout(root)
        if after.solved {
            failures.append("an infeasible edit was reported as solved")
        }
    }

    /// A window drag is not one edit, it is hundreds. Each one pivots the retained tableau again,
    /// and every pivot is floating-point arithmetic on a matrix that is never rebuilt — so the
    /// question is not whether one warm solve is right but whether the two-hundredth still is.
    /// This is the failure a warm-start cache is most likely to ship with, because it looks
    /// perfect on the first frame and drifts somewhere no assertion is watching.
    private static func warmStartDoesNotDriftOverALongDrag() {
        let root = FlippedBox(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        var boxes: [NSView] = []
        var previous: NSView?
        for index in 0..<4 {
            let box = IntrinsicBox(frame: .zero, intrinsic: NSSize(width: 50 + CGFloat(index) * 11, height: 18))
            root.addSubview(box)
            box.translatesAutoresizingMaskIntoConstraints = false
            var constraints: [NSLayoutConstraint] = [
                box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                box.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
                box.heightAnchor.constraint(equalToConstant: 20)
            ]
            let wide = box.widthAnchor.constraint(equalToConstant: 500)
            wide.priority = .defaultLow
            constraints.append(wide)
            if let previous {
                constraints.append(box.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 5))
            } else {
                constraints.append(box.topAnchor.constraint(equalTo: root.topAnchor, constant: 10))
            }
            NSLayoutConstraint.activate(constraints)
            boxes.append(box)
            previous = box
        }

        LayoutEngine.layout(root)
        // Two hundred resizes on the retained tableau, ending where a cold solve can be compared.
        for step in 1...200 {
            let width = 200 + CGFloat(step % 97)
            root.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            let result = LayoutEngine.layout(root)
            if !result.incremental { failures.append("drag step \(step) fell back to a cold solve") ; break }
            if !result.solved { failures.append("drag step \(step) failed to solve") ; break }
        }
        let drifted = boxes.map(\.frame)

        LayoutEngine.forget(root)
        LayoutEngine.layout(root)
        for (index, box) in boxes.enumerated() {
            expect("no drift after 200 warm solves, box \(index)", drifted[index], box.frame)
        }
    }

    // MARK: - Fixtures

    class Box: NSView {}

    final class FlippedBox: Box {
        override var isFlipped: Bool { true }
    }

    final class IntrinsicBox: Box {
        private let intrinsic: NSSize
        init(frame: NSRect, intrinsic: NSSize) {
            self.intrinsic = intrinsic
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { intrinsic }
    }

    // MARK: - Assertions

    private static func expect(_ name: String, _ actual: NSRect, _ expected: NSRect) {
        let tolerance: CGFloat = 0.01
        let matches = abs(actual.minX - expected.minX) < tolerance
            && abs(actual.minY - expected.minY) < tolerance
            && abs(actual.width - expected.width) < tolerance
            && abs(actual.height - expected.height) < tolerance
        if !matches {
            failures.append("\(name): got \(actual), expected \(expected)")
        }
    }

    private static func expect(_ name: String, _ actual: CGFloat, _ expected: CGFloat) {
        if abs(actual - expected) > 0.01 {
            failures.append("\(name): got \(actual), expected \(expected)")
        }
    }
}
