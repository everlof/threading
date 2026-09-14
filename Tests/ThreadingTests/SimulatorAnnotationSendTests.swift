import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorAnnotationSendTests: XCTestCase {
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

    // MARK: - Message building

    func testMessageIncludesOnlyPendingNotesNumberedByPin() {
        let all = [
            ImageAnnotation(point: CGPoint(x: 0.1, y: 0.1), note: "first"),
            ImageAnnotation(point: CGPoint(x: 0.2, y: 0.2), note: "already sent"),
            ImageAnnotation(point: CGPoint(x: 0.3, y: 0.3), note: "third"),
        ]
        // Only the 1st and 3rd are pending; the message numbers them by their pin (list index).
        let pending = [all[0], all[2]]
        let message = SimulatorPaneViewController.annotationMessage(
            allNotes: all, pending: pending, device: device
        )

        XCTAssertTrue(message.hasPrefix("Please address these Simulator annotations from me:"), message)
        XCTAssertTrue(message.contains("Annotation 1"), message)
        XCTAssertTrue(message.contains("Annotation 3"), message)
        XCTAssertFalse(message.contains("Annotation 2"), message)
        XCTAssertTrue(message.contains("Note: first"), message)
        XCTAssertTrue(message.contains("Note: third"), message)
        XCTAssertFalse(message.contains("already sent"), message)
        XCTAssertTrue(message.contains("(0.1, 0.1) normalized"), message)
        XCTAssertTrue(message.contains(device.id.rawValue), message)
    }

    // MARK: - The reusable Send bar

    func testSendBarShowsTheCountAndHidesWhenEmpty() {
        let bar = AnnotationSendBar()

        bar.setPending(count: 3, sending: false)
        XCTAssertEqual(bar.sendButton.title, "Send (3)")
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.sendButton.isEnabled)
        XCTAssertTrue(bar.hasPending)

        bar.setPending(count: 0, sending: false)
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse(bar.hasPending)
    }

    func testSendBarDisablesWhileSending() {
        let bar = AnnotationSendBar()
        bar.setPending(count: 2, sending: true)
        XCTAssertFalse(bar.sendButton.isEnabled)
        XCTAssertEqual(bar.sendButton.title, "Send (2)")
    }

    func testSendBarFiresOnSend() {
        let bar = AnnotationSendBar()
        bar.setPending(count: 1, sending: false)
        var fired = false
        bar.onSend = { fired = true }
        // Dispatch the button's wired target/action, the way a real click would.
        _ = bar.sendButton.sendAction(bar.sendButton.action, to: bar.sendButton.target)
        XCTAssertTrue(fired)
    }
}
