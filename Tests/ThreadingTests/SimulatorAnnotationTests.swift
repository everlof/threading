import Foundation
import XCTest
@testable import Threading

final class SimulatorAnnotationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "simulator-annotation-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func device(_ raw: String) -> SimulatorDeviceID {
        SimulatorDeviceID(raw)!
    }

    func testAnnotationsRoundTripPerDevice() {
        let store = SimulatorAnnotationStore(defaults: defaults)
        let deviceA = device("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let deviceB = device("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")

        let notes = [
            ImageAnnotation(point: CGPoint(x: 0.2, y: 0.3), note: "the login button"),
            ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5), note: "empty state"),
        ]
        store.setAnnotations(notes, for: deviceA)

        XCTAssertEqual(store.annotations(for: deviceA), notes)
        // A different device has its own, independent list.
        XCTAssertTrue(store.annotations(for: deviceB).isEmpty)
    }

    func testAnnotationsPersistAcrossStoreInstances() {
        let deviceA = device("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        SimulatorAnnotationStore(defaults: defaults).setAnnotations(
            [ImageAnnotation(point: CGPoint(x: 0.1, y: 0.1), note: "kept")],
            for: deviceA
        )
        // A fresh store reads the persisted list — this survives a relaunch.
        let reread = SimulatorAnnotationStore(defaults: defaults).annotations(for: deviceA)
        XCTAssertEqual(reread.map(\.note), ["kept"])
    }

    func testEmptyClearsTheDeviceKey() {
        let store = SimulatorAnnotationStore(defaults: defaults)
        let deviceA = device("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        store.setAnnotations([ImageAnnotation(point: .zero, note: "x")], for: deviceA)
        store.setAnnotations([], for: deviceA)
        XCTAssertTrue(store.annotations(for: deviceA).isEmpty)
    }

    func testTheListIsCappedAtTheMaximum() {
        let store = SimulatorAnnotationStore(defaults: defaults)
        let deviceA = device("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let many = (0..<50).map { ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5), note: "\($0)") }
        store.setAnnotations(many, for: deviceA)
        XCTAssertEqual(store.annotations(for: deviceA).count, SimulatorAnnotationStore.maximumCount)
    }
}

final class SimulatorAnnotationRendererTests: XCTestCase {
    private let device = SimulatorDevice(
        id: SimulatorDeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        name: "iPhone 17 Pro",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        runtimeName: "iOS 26.5",
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        family: .iPhone,
        state: .booted,
        lastBootedAt: nil
    )

    func testRendersUserAuthoredNotesWithNumberedPinsAndCoordinates() throws {
        let notes = [
            ImageAnnotation(point: CGPoint(x: 0.25, y: 0.75), note: "the login button"),
            ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5), note: "check this alignment"),
        ]
        let result = SimulatorAnnotationRenderer.result(annotations: notes, device: device)
        XCTAssertFalse(result.isError)

        let json = try XCTUnwrap(result.text.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertEqual(object["provenance"] as? String, "user_authored")
        XCTAssertEqual(object["device_id"] as? String, device.id.rawValue)
        XCTAssertEqual(object["count"] as? Int, 2)

        let annotations = try XCTUnwrap(object["annotations"] as? [[String: Any]])
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations.first?["pin"] as? Int, 1)
        XCTAssertEqual(annotations.first?["note"] as? String, "the login button")
        XCTAssertEqual(annotations.first?["x"] as? Double, 0.25)
        XCTAssertEqual(annotations.first?["y"] as? Double, 0.75)
        XCTAssertEqual(annotations.last?["pin"] as? Int, 2)
    }

    func testRendersAnEmptyListAsZeroNotes() throws {
        let result = SimulatorAnnotationRenderer.result(annotations: [], device: device)
        let json = try XCTUnwrap(result.text.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertEqual(object["count"] as? Int, 0)
        XCTAssertEqual((object["annotations"] as? [Any])?.count, 0)
    }
}
