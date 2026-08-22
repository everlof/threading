import ThreadingExtensionKit
import XCTest
@testable import ThreadingMobile

final class RemoteExtensionSceneScalingTests: XCTestCase {
    func testMaximumDepthHierarchyProjectionHasLinearBound() {
        let stressMarkCount = 500
        let items = (0..<stressMarkCount).map { index in
            ExtensionSceneItem(
                id: "mark-\(index)",
                parentID: index == 0 ? nil : "mark-\(index - 1)",
                frame: ExtensionSceneRect(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let index = RemoteExtensionSceneHierarchyIndex(items: items)

        let root = index.traversal(focusedOn: "mark-0")
        XCTAssertEqual(root.visibleItems.count, stressMarkCount)
        XCTAssertLessThanOrEqual(root.workCount, stressMarkCount * 3)
        XCTAssertEqual(root.visibleItems.last?.id, "mark-499")

        let branch = index.traversal(focusedOn: "mark-250")
        XCTAssertEqual(branch.visibleItems.count, 250)
        XCTAssertLessThanOrEqual(branch.workCount, stressMarkCount * 2)
        XCTAssertEqual(branch.visibleItems.first?.id, "mark-250")
    }
}
