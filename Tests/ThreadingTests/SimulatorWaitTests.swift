import ThreadingSimulatorKit
import XCTest
@testable import Threading

final class SimulatorWaitTests: XCTestCase {
    private func wait(
        role: String? = nil, label: String? = nil, identifier: String? = nil,
        until: String? = nil, timeout: Int? = nil
    ) -> SimulatorWaitArguments {
        SimulatorWaitArguments(
            role: role, label: label, identifier: identifier,
            until: until, timeoutMilliseconds: timeout
        )
    }

    // MARK: - Validation

    func testAcceptsALabelWithDefaults() {
        guard case .accepted(let request) = SimulatorAgentCommandService.waitRequest(
            from: wait(label: "Continue")
        ) else { return XCTFail("expected acceptance") }
        XCTAssertEqual(request.condition, .appears)
        XCTAssertEqual(request.timeoutMilliseconds, 5_000)
        XCTAssertEqual(request.locator.label, "Continue")
    }

    func testDisappearsConditionIsParsed() {
        guard case .accepted(let request) = SimulatorAgentCommandService.waitRequest(
            from: wait(identifier: "spinner", until: "disappears")
        ) else { return XCTFail("expected acceptance") }
        XCTAssertEqual(request.condition, .disappears)
    }

    func testRequiresASemanticTarget() {
        guard case .rejected = SimulatorAgentCommandService.waitRequest(from: wait(role: "AXButton"))
        else { return XCTFail("expected rejection") }
    }

    func testRejectsAnUnknownUntil() {
        guard case .rejected = SimulatorAgentCommandService.waitRequest(
            from: wait(label: "X", until: "maybe")
        ) else { return XCTFail("expected rejection") }
    }

    func testRejectsAnOutOfRangeTimeout() {
        guard case .rejected = SimulatorAgentCommandService.waitRequest(
            from: wait(label: "X", timeout: 60_000)
        ) else { return XCTFail("expected rejection") }
    }

    // MARK: - Match count (the appear/disappear basis)

    func testMatchCountCountsMatchingElements() {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 100, height: 100),
            children: [
                SimulatorAccessibilityElement(role: "AXButton", label: "OK", frame: .init(x: 0, y: 0, width: 1, height: 1)),
                SimulatorAccessibilityElement(role: "AXButton", label: "OK", frame: .init(x: 2, y: 2, width: 1, height: 1)),
                SimulatorAccessibilityElement(role: "AXStaticText", label: "Done", frame: .init(x: 3, y: 3, width: 1, height: 1)),
            ]
        )
        XCTAssertEqual(
            SimulatorElementResolver.matchCount(.init(ref: nil, role: nil, label: "OK", identifier: nil), in: root),
            2
        )
        XCTAssertEqual(
            SimulatorElementResolver.matchCount(.init(ref: nil, role: "AXStaticText", label: "Done", identifier: nil), in: root),
            1
        )
        XCTAssertEqual(
            SimulatorElementResolver.matchCount(.init(ref: nil, role: nil, label: "Missing", identifier: nil), in: root),
            0
        )
    }
}
