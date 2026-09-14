import XCTest
@testable import Threading

final class SimulatorAddressingTests: XCTestCase {
    private func tap(
        x: Double? = nil, y: Double? = nil, ref: String? = nil,
        role: String? = nil, label: String? = nil, identifier: String? = nil
    ) -> SimulatorTapArguments {
        SimulatorTapArguments(x: x, y: y, ref: ref, role: role, label: label, identifier: identifier)
    }

    // MARK: - Tap addressing

    func testCoordinateModeIsAccepted() {
        guard case .coordinate(let x, let y) = SimulatorAgentCommandService.tapAddressing(
            from: tap(x: 0.25, y: 0.75)
        ) else { return XCTFail("expected coordinate") }
        XCTAssertEqual(x, 0.25)
        XCTAssertEqual(y, 0.75)
    }

    func testRefModeIsALocator() {
        guard case .locator(let locator) = SimulatorAgentCommandService.tapAddressing(
            from: tap(ref: "e12")
        ) else { return XCTFail("expected locator") }
        XCTAssertEqual(locator.ref, "e12")
    }

    func testSemanticModeIsALocator() {
        guard case .locator(let locator) = SimulatorAgentCommandService.tapAddressing(
            from: tap(role: "AXButton", label: "Continue")
        ) else { return XCTFail("expected locator") }
        XCTAssertEqual(locator.label, "Continue")
    }

    func testTwoModesAreRejected() {
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(
            from: tap(x: 0.1, y: 0.1, ref: "e1")
        ) else { return XCTFail("expected rejection") }
    }

    func testNoTargetIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(from: tap())
        else { return XCTFail("expected rejection") }
    }

    func testHalfACoordinateIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(from: tap(x: 0.5))
        else { return XCTFail("expected rejection") }
    }

    func testCoordinateOutOfRangeIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(
            from: tap(x: -0.1, y: 0.5)
        ) else { return XCTFail("expected rejection") }
    }

    func testMalformedRefIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(from: tap(ref: "button"))
        else { return XCTFail("expected rejection") }
    }

    func testRoleAloneIsNotASemanticTarget() {
        // role without a label or identifier cannot match anything, so it counts as no target.
        guard case .rejected = SimulatorAgentCommandService.tapAddressing(
            from: tap(role: "AXButton")
        ) else { return XCTFail("expected rejection") }
    }

    // MARK: - Type addressing

    private func type(
        _ text: String?, ref: String? = nil, role: String? = nil,
        label: String? = nil, identifier: String? = nil
    ) -> SimulatorTypeTextArguments {
        SimulatorTypeTextArguments(text: text, ref: ref, role: role, label: label, identifier: identifier)
    }

    func testTypeWithNoTargetGoesToFocused() {
        guard case .focused(let text) = SimulatorAgentCommandService.typeAddressing(
            from: type("hello")
        ) else { return XCTFail("expected focused") }
        XCTAssertEqual(text, "hello")
    }

    func testTypeWithRefFocusesFirst() {
        guard case .located(let locator, let text) = SimulatorAgentCommandService.typeAddressing(
            from: type("hello", ref: "e3")
        ) else { return XCTFail("expected located") }
        XCTAssertEqual(locator.ref, "e3")
        XCTAssertEqual(text, "hello")
    }

    func testTypeMissingTextIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.typeAddressing(from: type(nil))
        else { return XCTFail("expected rejection") }
    }

    func testTypeWithBothRefAndSemanticIsRejected() {
        guard case .rejected = SimulatorAgentCommandService.typeAddressing(
            from: type("hi", ref: "e1", label: "Field")
        ) else { return XCTFail("expected rejection") }
    }
}
