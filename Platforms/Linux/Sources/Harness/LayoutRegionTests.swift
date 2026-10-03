import AppKit
import Foundation

/// Pane bands ask the platform for a retained layout region. Linux decorations sit outside
/// this content tree, so these checks hold the zero-inset contract, its constraint ownership
/// and lifecycle rather than copying macOS window-control or default margin dimensions.
@MainActor
enum LayoutRegionTests {
    private static var failures: [String] = []
    private static let regions: [NSView.LayoutRegion] = [
        .safeArea(), .safeArea(cornerAdaptation: .horizontal),
        .safeArea(cornerAdaptation: .vertical), .margins(),
        .margins(cornerAdaptation: .horizontal), .margins(cornerAdaptation: .vertical)
    ]

    static func run() -> Bool {
        failures = []
        cachedRecipesDoNotAccumulateConstraints()
        regionGeometryFollowsResize(flipped: false)
        regionGeometryFollowsResize(flipped: true)
        nestedGuidesSurviveWindowMoves()

        if failures.isEmpty {
            print("layout regions: all cases pass")
            return true
        }
        for failure in failures { print("layout regions FAIL: \(failure)") }
        return false
    }

    private static func cachedRecipesDoNotAccumulateConstraints() {
        let view = NSView(frame: NSRect(x: 12, y: 15, width: 200, height: 100))
        let guides = regions.map { view.layoutGuide(for: $0) }
        expect("six semantic recipes", Set(regions).count == 6)
        expect("safe-area property uses the same guide", view.safeAreaLayoutGuide === guides[0])

        for _ in 0..<100 {
            for (region, guide) in zip(regions, guides) {
                expect("repeated region preserves guide", view.layoutGuide(for: region) === guide)
                expect("region guide belongs to its receiver", guide.owningView === view)
            }
        }
        expect("one guide per recipe", view.layoutGuides.count == 6)
        expect("four constraints per recipe", view.constraints.count == 24)
        expect("all region constraints remain active", view.constraints.allSatisfy(\.isActive))
    }

    private static func regionGeometryFollowsResize(flipped: Bool) {
        let view: NSView = flipped
            ? FlippedRegionView(frame: NSRect(x: 12, y: 15, width: 200, height: 100))
            : NSView(frame: NSRect(x: 12, y: 15, width: 200, height: 100))
        let guides = regions.map { view.layoutGuide(for: $0) }
        solve(view, name: "initial region layout")
        for (region, guide) in zip(regions, guides) {
            expect("initial guide is local bounds", guide.frame, view.bounds)
            expect("initial rect is local bounds", view.rect(for: region), view.bounds)
            expectZeroInsets(view.edgeInsets(for: region))
        }

        view.frame = NSRect(x: 30, y: 40, width: 320, height: 180)
        for region in regions {
            expect("rect answers resize before layout", view.rect(for: region), view.bounds)
        }
        solve(view, name: "resized region layout")
        for guide in guides { expect("guide follows resize", guide.frame, view.bounds) }
        expect("resize keeps the original equations", view.constraints.count == 24)
    }

    private static func nestedGuidesSurviveWindowMoves() {
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let firstRoot = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let secondRoot = FlippedRegionView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        firstWindow.contentView = firstRoot
        secondWindow.contentView = secondRoot
        defer {
            firstWindow.contentView = nil
            secondWindow.contentView = nil
        }

        let container = NSView(frame: NSRect(x: 40, y: 20, width: 200, height: 100))
        let guide = container.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        let child = NSView(frame: .zero)
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            child.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            child.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            child.heightAnchor.constraint(equalToConstant: 20)
        ])

        for index in 0..<20 {
            let root = index.isMultiple(of: 2) ? firstRoot : secondRoot
            let window = index.isMultiple(of: 2) ? firstWindow : secondWindow
            root.addSubview(container)
            solve(root, name: "reparented region layout")
            expect("nested guide preserves its receiver", guide.owningView === container)
            expect("nested guide identity survives reparenting",
                   container.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal)) === guide)
            expect("nested content enters destination window", container.window === window)
            expect("nested guide ignores ancestor origin and flipped state", guide.frame, container.bounds)
            expect("nested child uses the guide's local coordinates", child.frame,
                   NSRect(x: 8, y: 70, width: 184, height: 20))
            expect("reparenting keeps eight owned equations", container.constraints.count == 8)
            expect("reparenting keeps one owned guide", container.layoutGuides.count == 1)
        }

        container.removeFromSuperview()
        expect("detached subtree leaves its window", container.window == nil)
        container.frame.size = NSSize(width: 180, height: 80)
        solve(container, name: "detached region layout")
        expect("detached guide remains usable", guide.frame, container.bounds)
        expect("detached child follows resized guide", child.frame,
               NSRect(x: 8, y: 50, width: 164, height: 20))
        expect("detachment keeps the region's owned equations", container.constraints.count == 8)
    }

    private static func solve(_ view: NSView, name: String) {
        if let diagnosis = view.layoutSubtreeIfNeeded(), !diagnosis.solved {
            failures.append("\(name) did not solve")
        }
    }

    private static func expectZeroInsets(_ insets: NSEdgeInsets) {
        expect("Linux region has zero content insets",
               insets.top == 0 && insets.left == 0 && insets.bottom == 0 && insets.right == 0)
    }

    private static func expect(_ name: String, _ accepted: Bool) {
        if !accepted { failures.append(name) }
    }

    private static func expect(_ name: String, _ actual: NSRect, _ expected: NSRect) {
        let differences = [actual.minX - expected.minX, actual.minY - expected.minY,
                           actual.width - expected.width, actual.height - expected.height]
        if differences.contains(where: { abs($0) > 0.001 }) {
            failures.append("\(name): \(actual), expected \(expected)")
        }
    }
}

@MainActor
private final class FlippedRegionView: NSView {
    override var isFlipped: Bool { true }
}
