import ThreadingSimulatorKit
import XCTest
@testable import Threading

final class SimulatorElementResolverTests: XCTestCase {
    private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double)
        -> SimulatorAccessibilityElement.Frame {
        SimulatorAccessibilityElement.Frame(x: x, y: y, width: w, height: h)
    }

    private func locator(
        ref: String? = nil, role: String? = nil, label: String? = nil, identifier: String? = nil
    ) -> SimulatorAgentCommandService.ElementLocator {
        .init(ref: ref, role: role, label: label, identifier: identifier)
    }

    private func sampleRoot() -> SimulatorAccessibilityElement {
        SimulatorAccessibilityElement(
            role: "AXApplication",
            label: "Kronaby",
            frame: frame(0, 0, 402, 874),
            children: [
                SimulatorAccessibilityElement(
                    role: "AXButton",
                    label: "Try notification backend",
                    frame: frame(346, 66, 36, 36)
                ),
                SimulatorAccessibilityElement(
                    role: "AXImage",
                    label: "1 vibration",
                    identifier: "hybrid_level_1",
                    frame: frame(24, 124, 86, 44)
                ),
            ]
        )
    }

    // MARK: - Ref resolution

    func testRefResolvesToTheListedElementCentre() {
        // e1 is the first listed (interactive_only) element: the button, centre (364, 84) / (402, 874).
        guard case .point(let point) = SimulatorElementResolver.resolve(
            locator(ref: "e1"), in: sampleRoot()
        ) else { return XCTFail("expected a point") }
        XCTAssertEqual(point.x, 0.9055, accuracy: 0.001)
        XCTAssertEqual(point.y, 0.0961, accuracy: 0.001)
    }

    func testOutOfRangeRefIsNotFound() {
        guard case .notFound = SimulatorElementResolver.resolve(
            locator(ref: "e9"), in: sampleRoot()
        ) else { return XCTFail("expected notFound") }
    }

    // MARK: - Semantic resolution

    func testLabelResolvesToTheMatchingElement() {
        guard case .point(let point) = SimulatorElementResolver.resolve(
            locator(label: "1 vibration"), in: sampleRoot()
        ) else { return XCTFail("expected a point") }
        // Image centre (24+43, 124+22) / (402, 874).
        XCTAssertEqual(point.x, 67.0 / 402.0, accuracy: 0.001)
        XCTAssertEqual(point.y, 146.0 / 874.0, accuracy: 0.001)
    }

    func testIdentifierMatchesExactly() {
        guard case .point = SimulatorElementResolver.resolve(
            locator(identifier: "hybrid_level_1"), in: sampleRoot()
        ) else { return XCTFail("expected a point") }
    }

    func testLabelMatchIsCaseInsensitiveAndTrimmed() {
        guard case .point = SimulatorElementResolver.resolve(
            locator(label: "  try notification backend  "), in: sampleRoot()
        ) else { return XCTFail("expected a point") }
    }

    func testUnknownLabelIsNotFound() {
        guard case .notFound = SimulatorElementResolver.resolve(
            locator(label: "Does not exist"), in: sampleRoot()
        ) else { return XCTFail("expected notFound") }
    }

    func testAmbiguousLabelFailsRatherThanGuessing() {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            frame: frame(0, 0, 100, 100),
            children: [
                SimulatorAccessibilityElement(role: "AXButton", label: "Delete", frame: frame(0, 0, 10, 10)),
                SimulatorAccessibilityElement(role: "AXButton", label: "Delete", frame: frame(50, 50, 10, 10)),
            ]
        )
        guard case .ambiguous(let message) = SimulatorElementResolver.resolve(
            locator(label: "Delete"), in: root
        ) else { return XCTFail("expected ambiguous") }
        XCTAssertTrue(message.contains("2"), message)
    }

    func testRoleNarrowsAnOtherwiseAmbiguousLabel() {
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            frame: frame(0, 0, 100, 100),
            children: [
                SimulatorAccessibilityElement(role: "AXStaticText", label: "Save", frame: frame(0, 0, 10, 10)),
                SimulatorAccessibilityElement(role: "AXButton", label: "Save", frame: frame(50, 50, 10, 10)),
            ]
        )
        guard case .point(let point) = SimulatorElementResolver.resolve(
            locator(role: "AXButton", label: "Save"), in: root
        ) else { return XCTFail("expected a point") }
        // The button is the one at (50,50); centre (55,55)/100.
        XCTAssertEqual(point.x, 0.55, accuracy: 0.001)
    }

    // MARK: - Listing shared with the renderer

    func testListingOrderMatchesRefNumbering() {
        let listed = SimulatorElementListing.listed(sampleRoot(), interactiveOnly: true)
        XCTAssertEqual(listed.map(\.role), ["AXButton", "AXImage"])
    }

    /// A ref must denote the same element whether the snapshot was taken with interactive_only or
    /// not. When a non-interactive container precedes the interactive controls, the full-listing ref
    /// of a control is shifted past that container — the resolver must index the same full listing
    /// the renderer numbered, or an interactive_only=false ref would land on the wrong element.
    func testRefFromNonInteractiveSnapshotResolvesToTheElementItWasNumberedAgainst() {
        // Pre-order over the whole tree: e1 = the leading group, e2 = the button, e3 = the image.
        let root = SimulatorAccessibilityElement(
            role: "AXApplication",
            label: "App",
            frame: frame(0, 0, 100, 100),
            children: [
                SimulatorAccessibilityElement(role: "AXGroup", frame: frame(0, 0, 100, 10)),
                SimulatorAccessibilityElement(
                    role: "AXButton", label: "Go", frame: frame(40, 40, 20, 20)
                ),
                SimulatorAccessibilityElement(
                    role: "AXImage", label: "Art", frame: frame(0, 80, 100, 20)
                ),
            ]
        )
        // The renderer numbers these refs the same way in both filter modes.
        let full = SimulatorElementListing.listed(root, interactiveOnly: false)
        XCTAssertEqual(full.map(\.role), ["AXGroup", "AXButton", "AXImage"])

        // e2 (the button the agent saw in an interactive_only=false snapshot) resolves to the button,
        // not to the first *interactive* element — the bug this guards against.
        guard case .element(let element, _, _) = SimulatorElementResolver.resolveElement(
            locator(ref: "e2"), in: root
        ) else { return XCTFail("expected the button element") }
        XCTAssertEqual(element.role, "AXButton")
        XCTAssertEqual(element.label, "Go")

        // e1 resolves to the non-interactive container it was numbered against.
        guard case .element(let group, _, _) = SimulatorElementResolver.resolveElement(
            locator(ref: "e1"), in: root
        ) else { return XCTFail("expected the group element") }
        XCTAssertEqual(group.role, "AXGroup")
    }
}
