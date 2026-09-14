import ThreadingSimulatorKit
import XCTest
@testable import Threading

final class SimulatorElementScreenshotTests: XCTestCase {
    func testScreenshotLocatorIsNilWithoutATarget() {
        let args = SimulatorScreenshotArguments(
            includeImage: true, ref: nil, role: nil, label: nil, identifier: nil
        )
        XCTAssertNil(SimulatorAgentCommandService.screenshotLocator(from: args))
    }

    func testScreenshotLocatorReadsTheTargetFields() {
        let args = SimulatorScreenshotArguments(
            includeImage: nil, ref: nil, role: "AXButton", label: "Kronaby", identifier: nil
        )
        let locator = SimulatorAgentCommandService.screenshotLocator(from: args)
        XCTAssertEqual(locator?.label, "Kronaby")
        XCTAssertEqual(locator?.role, "AXButton")
    }

    func testResolveElementReturnsTheMatchedElementAndRootSize() {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 402, height: 874),
            children: [
                SimulatorAccessibilityElement(
                    role: "AXButton", label: "Kronaby",
                    frame: .init(x: 346, y: 66, width: 36, height: 36)
                )
            ]
        )
        guard case .element(let element, let width, let height) =
            SimulatorElementResolver.resolveElement(
                .init(ref: nil, role: nil, label: "Kronaby", identifier: nil), in: root
            )
        else { return XCTFail("expected an element") }
        XCTAssertEqual(element.frame.width, 36)
        XCTAssertEqual(width, 402)
        XCTAssertEqual(height, 874)
    }

    func testResolveElementNotFound() {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication", frame: .init(x: 0, y: 0, width: 10, height: 10)
        )
        guard case .notFound = SimulatorElementResolver.resolveElement(
            .init(ref: nil, role: nil, label: "nope", identifier: nil), in: root
        ) else { return XCTFail("expected notFound") }
    }
}
