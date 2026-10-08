import XCTest
@testable import ThreadingSimulatorKit

final class SimulatorScreenOrientationTests: XCTestCase {
    func testOnlyKnownScreenPropertiesAreAdmitted() {
        XCTAssertNil(SimulatorScreenOrientation(rawValue: 0))
        XCTAssertNil(SimulatorScreenOrientation(rawValue: 5))
        XCTAssertEqual(SimulatorScreenOrientation(rawValue: 3), .landscapeLeft)
        XCTAssertEqual(SimulatorScreenOrientation(rawValue: 4), .landscapeRight)
    }

    func testUprightTouchMapsBackToTheNativeDigitizer() {
        let expected: [(SimulatorScreenOrientation, Double, Double)] = [
            (.portrait, 0.2, 0.7), (.portraitUpsideDown, 0.8, 0.3),
            (.landscapeLeft, 0.7, 0.8), (.landscapeRight, 0.3, 0.2)
        ]
        for (orientation, x, y) in expected {
            let point = orientation.nativePoint(x: 0.2, y: 0.7)
            XCTAssertEqual(point.x, x, accuracy: 0.0001)
            XCTAssertEqual(point.y, y, accuracy: 0.0001)
        }
    }

    func testAccessibilityCentersAndTouchCoordinatesUseTheSameAxes() {
        for orientation in SimulatorScreenOrientation.allCases {
            let rect = orientation.uprightRect(x: 20, y: 60, width: 40, height: 30,
                                               nativeWidth: 200, nativeHeight: 400)
            let width = orientation.swapsAxes ? 400.0 : 200.0
            let height = orientation.swapsAxes ? 200.0 : 400.0
            let point = orientation.nativePoint(x: (rect.x + rect.width / 2) / width,
                                               y: (rect.y + rect.height / 2) / height)
            XCTAssertEqual(point.x * 200, 40, accuracy: 0.0001)
            XCTAssertEqual(point.y * 400, 75, accuracy: 0.0001)
            XCTAssertEqual(rect.width * rect.height, 1200)
        }
    }

    func testLandscapeDimensionsAndPixelRotationMatchTheScreenProperties() {
        XCTAssertTrue(SimulatorScreenOrientation.landscapeLeft.swapsAxes)
        XCTAssertTrue(SimulatorScreenOrientation.landscapeRight.swapsAxes)
        XCTAssertFalse(SimulatorScreenOrientation.portraitUpsideDown.swapsAxes)
        XCTAssertEqual(SimulatorScreenOrientation.landscapeLeft.counterclockwiseQuarterTurns, 3)
        XCTAssertEqual(SimulatorScreenOrientation.landscapeRight.counterclockwiseQuarterTurns, 1)
    }

    func testARecoveredInputKeepsItsNativeTargetAcrossEveryPairOfOrientations() {
        for source in SimulatorScreenOrientation.allCases {
            for target in SimulatorScreenOrientation.allCases {
                let original = SimulatorBridgeInput.tap(x: 0.2, y: 0.7)
                let mapped = original.convertingCoordinates(from: source, to: target)
                guard case .tap(let x, let y) = mapped else { return XCTFail("The input kind changed.") }
                let expected = source.nativePoint(x: 0.2, y: 0.7)
                let actual = target.nativePoint(x: x, y: y)
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
            }
        }
    }

    func testOrientationMetadataIsOptionalForOlderReplies() throws {
        let reply = SimulatorBridgeHelloReply(selectedCodec: .jpeg, capabilities: nil, refusal: nil,
            coreSimulatorVersion: nil, simulatorKitVersion: nil, screenOrientation: .landscapeRight)
        XCTAssertEqual(try JSONDecoder().decode(SimulatorBridgeHelloReply.self, from: JSONEncoder().encode(reply)), reply)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        object.removeValue(forKey: "screenOrientation")
        let legacy = try JSONDecoder().decode(SimulatorBridgeHelloReply.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.screenOrientation)
    }

    func testUIKitUprightAccessibilityFramesAreNotRotatedTwice() {
        let transform = SimulatorScreenOrientation.landscapeLeft.accessibilityTransform(
            rootWidth: 874, rootHeight: 402, nativeWidth: 1206, nativeHeight: 2622)
        XCTAssertEqual(transform, .portrait)
        let dialog = SimulatorScreenOrientation.landscapeLeft.accessibilityTransform(
            rootWidth: 402, rootHeight: 874, nativeWidth: 1206, nativeHeight: 2622)
        XCTAssertEqual(dialog, .landscapeLeft)
        XCTAssertNil(SimulatorScreenOrientation.landscapeLeft.accessibilityTransform(
            rootWidth: 700, rootHeight: 300, nativeWidth: 1206, nativeHeight: 2622))
    }

    func testPortraitTreesNeverDependOnTheirRootCoveringTheDisplay() {
        // An iPad app in a multitasking frame, a root with no frame, and a point size that is not
        // an exact division of the buffer all read in the same axes as the frame.
        for (width, height) in [(507.0, 1133.0), (0.0, 0.0), (375.0, 812.0)] {
            XCTAssertEqual(SimulatorScreenOrientation.portrait.accessibilityTransform(
                rootWidth: width, rootHeight: height, nativeWidth: 1080, nativeHeight: 2340), .portrait)
        }
        XCTAssertEqual(SimulatorScreenOrientation.landscapeRight.accessibilityTransform(
            rootWidth: 812, rootHeight: 375, nativeWidth: 1080, nativeHeight: 2340), .portrait,
            "A point size that is not an exact division of the buffer is still the upright space.")
    }
}
