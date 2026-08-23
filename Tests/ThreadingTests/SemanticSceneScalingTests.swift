import AppKit
import XCTest
@testable import Threading

@MainActor
final class SemanticSceneScalingTests: XCTestCase {
    private let stressMarkCount = 500

    func testMaximumSceneUsesOneCanvasAndVirtualAccessibilityMarks() throws {
        var activations = 0
        var items: [SemanticSceneView.Item] = []
        items.reserveCapacity(stressMarkCount)
        for index in 0..<stressMarkCount {
            let activation: (() -> Void)?
            if index == 0 {
                activation = { activations += 1 }
            } else {
                activation = nil
            }
            items.append(SemanticSceneView.Item(
                id: "mark-\(index)",
                normalizedFrame: NSRect(
                    x: CGFloat(index % 25) / 25,
                    y: CGFloat(index / 25) / 20,
                    width: 1 / 25,
                    height: 1 / 20
                ),
                shape: .rectangle,
                color: .category(index),
                label: nil,
                detail: nil,
                accessibilityLabel: "Mark \(index)",
                accessibilityValue: nil,
                isEnabled: true,
                isSelected: false,
                onActivate: activation
            ))
        }
        let scene = SemanticSceneView(accessibilityLabel: "Stress scene", items: items)
        scene.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        scene.layoutSubtreeIfNeeded()

        let subviewCount = scene.subviews.count
        XCTAssertEqual(subviewCount, 0, "marks must remain values on one canvas")
        let accessibilityMarks = try XCTUnwrap(scene.accessibilityChildren())
        XCTAssertEqual(accessibilityMarks.count, stressMarkCount)
        XCTAssertEqual(
            (accessibilityMarks[0] as? NSAccessibilityElement)?.accessibilityIdentifier(),
            "semantic-scene.item.mark-0"
        )
        XCTAssertTrue(scene.performPrimaryAction())
        XCTAssertEqual(activations, 1)
    }

    func testDeepHierarchyTraversalHasLinearBound() {
        let items = (0..<stressMarkCount).map { index in
            SemanticSceneView.Item(
                id: "mark-\(index)",
                parentID: index == 0 ? nil : "mark-\(index - 1)",
                normalizedFrame: NSRect(x: 0, y: 0, width: 1, height: 1),
                shape: .ellipse,
                color: .neutral,
                label: nil,
                detail: nil,
                accessibilityLabel: "Mark \(index)",
                accessibilityValue: nil,
                isEnabled: true,
                isSelected: false,
                onActivate: nil
            )
        }
        let index = SemanticSceneHierarchyIndex(items: items)

        let rootTraversal = index.traversal(focusedOn: "mark-0")
        XCTAssertEqual(rootTraversal.visibleItems.count, stressMarkCount)
        XCTAssertLessThanOrEqual(rootTraversal.workCount, stressMarkCount * 3)
        XCTAssertEqual(rootTraversal.visibleItems.last?.depth, stressMarkCount - 1)

        let branchTraversal = index.traversal(focusedOn: "mark-250")
        XCTAssertEqual(branchTraversal.visibleItems.count, 250)
        XCTAssertLessThanOrEqual(branchTraversal.workCount, stressMarkCount * 2)
    }

    func testHierarchyFocusReusesItsCanvas() throws {
        let items = [
            item(id: "root", parentID: nil, frame: NSRect(x: 0, y: 0, width: 1, height: 1)),
            item(id: "branch", parentID: "root", frame: NSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            item(id: "leaf", parentID: "branch", frame: NSRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        ]
        let hierarchy = SemanticHierarchySceneView(
            accessibilityLabel: "Hierarchy",
            rootID: "root",
            preferredAspectRatio: 1,
            items: items
        )
        let originalCanvas = try XCTUnwrap(descendants(of: hierarchy).compactMap { $0 as? SemanticSceneView }.first)
        let branch = try XCTUnwrap(originalCanvas.accessibilityChildren()?[1] as? NSAccessibilityElement)

        XCTAssertTrue(branch.accessibilityPerformPress())

        let canvases = descendants(of: hierarchy).compactMap { $0 as? SemanticSceneView }
        XCTAssertEqual(canvases.count, 1)
        XCTAssertTrue(canvases[0] === originalCanvas)
    }

    /// Colour derivation is per *kind* of mark, not per mark.
    ///
    /// A hierarchy fill is mixed in Oklab from the resolved panel, which costs three surface
    /// composites and two colour-space round trips inside an appearance push. Every mark sharing
    /// a colour role, depth, enabled state and emphasis paints the identical result, so a
    /// 500-mark scene was doing that five hundred times per repaint — and because hover marked
    /// the whole view dirty, crossing from one mark to its neighbour paid all five hundred
    /// again. This pins the bound the cache exists for; it is a count rather than a duration so
    /// it means the same thing on every machine.
    func testAStressedHierarchyDerivesAFillPerKindOfMarkNotPerMark() throws {
        // The focus, and then a row of leaves under it that share a colour role and a depth.
        // Whatever the scene costs to paint, it is one derivation for the focus and one for all
        // the leaves together.
        var items = [hierarchyMark(
            id: "root",
            parentID: nil,
            depth: 0,
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )]
        for index in 0..<(stressMarkCount - 1) {
            items.append(hierarchyMark(
                id: "leaf-\(index)",
                parentID: "root",
                depth: 1,
                frame: NSRect(
                    x: CGFloat(index % 25) / 25,
                    y: CGFloat(index / 25) / 20,
                    width: 1 / 25,
                    height: 1 / 20
                )
            ))
        }

        let scene = SemanticSceneView(accessibilityLabel: "Stress hierarchy", items: items)
        scene.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        scene.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(scene.bitmapImageRepForCachingDisplay(in: scene.bounds))
        scene.cacheDisplay(in: scene.bounds, to: image)

        XCTAssertEqual(scene.derivedHierarchyFillCount, 2)
    }

    private func hierarchyMark(
        id: String,
        parentID: String?,
        depth: Int,
        frame: NSRect
    ) -> SemanticSceneView.Item {
        SemanticSceneView.Item(
            id: id,
            parentID: parentID,
            normalizedFrame: frame,
            shape: .ellipse,
            color: .neutral,
            hierarchyDepth: depth,
            label: nil,
            detail: nil,
            accessibilityLabel: id,
            accessibilityValue: nil,
            isEnabled: true,
            isSelected: false,
            onActivate: nil
        )
    }

    private func item(
        id: String,
        parentID: String?,
        frame: NSRect
    ) -> SemanticSceneView.Item {
        SemanticSceneView.Item(
            id: id,
            parentID: parentID,
            normalizedFrame: frame,
            shape: .ellipse,
            color: .neutral,
            label: id,
            detail: nil,
            accessibilityLabel: id,
            accessibilityValue: nil,
            isEnabled: true,
            isSelected: false,
            onActivate: nil
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
