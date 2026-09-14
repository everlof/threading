import ThreadingSimulatorKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorInspectorTargetTests: XCTestCase {
    private func element(
        role: String, label: String? = nil, identifier: String? = nil
    ) -> SimulatorAccessibilityElement {
        SimulatorAccessibilityElement(
            role: role, label: label, identifier: identifier,
            frame: .init(x: 0, y: 0, width: 10, height: 10)
        )
    }

    func testBadgeNameCombinesRefRoleAndLabel() {
        XCTAssertEqual(
            SimulatorPaneViewController.badgeName(
                ref: "e5", element: element(role: "AXButton", label: "Kronaby")
            ),
            "e5 · AXButton · Kronaby"
        )
        XCTAssertEqual(
            SimulatorPaneViewController.badgeName(ref: nil, element: element(role: "AXImage")),
            "AXImage"
        )
    }

    func testCopyTargetIsPasteReadyWithLabelIdentifierAndCoordinates() {
        let target = SimulatorPaneViewController.copyTarget(
            element: element(role: "AXButton", label: "Kronaby", identifier: "app_icon"),
            normalized: CGRect(x: 0.8, y: 0.05, width: 0.2, height: 0.1)
        )
        XCTAssertEqual(target, "\"Kronaby\" (AXButton) #app_icon at (0.900, 0.100)")
    }

    func testCopyTargetFallsBackToRoleWithoutALabel() {
        let target = SimulatorPaneViewController.copyTarget(
            element: element(role: "AXImage"),
            normalized: CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        )
        XCTAssertEqual(target, "AXImage at (0.250, 0.250)")
    }
}
