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
