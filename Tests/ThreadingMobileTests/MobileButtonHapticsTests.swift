import UIKit
import XCTest
@testable import ThreadingMobile

final class MobileButtonHapticsTests: XCTestCase {
    @MainActor
    private final class RecordingImpactFeedback: MobileImpactFeedbackProducing {
        private(set) var prepareCount = 0
        private(set) var intensities: [CGFloat] = []

        func prepare() {
            prepareCount += 1
        }

        func impactOccurred(intensity: CGFloat) {
            intensities.append(intensity)
        }
    }

    @MainActor
    func testSuccessfulButtonPressUsesTheTerminalKeyImpactAndReprepares() {
        let recorder = RecordingImpactFeedback()
        let feedback = MobileButtonFeedback(generator: recorder)
        let button = UIButton(type: .system)

        MobileButtonHaptics.install(on: button, feedback: feedback)

        XCTAssertTrue(MobileButtonHaptics.isInstalled(on: button))
        XCTAssertEqual(recorder.prepareCount, 0, "installing many controls must do no engine work")

        button.sendActions(for: .touchDown)
        XCTAssertEqual(recorder.prepareCount, 1, "touch-down should warm the engine")

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.intensities, [MobileButtonFeedback.impactIntensity])
        XCTAssertEqual(recorder.prepareCount, 2, "a completed press should warm the next one")
    }

    @MainActor
    func testCancelledAndDisabledButtonsDoNotConfirmAnAction() {
        let recorder = RecordingImpactFeedback()
        let button = UIButton(type: .system)
        MobileButtonHaptics.install(
            on: button,
            feedback: MobileButtonFeedback(generator: recorder)
        )

        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchCancel)
        XCTAssertTrue(recorder.intensities.isEmpty)

        button.isEnabled = false
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(recorder.intensities.isEmpty)
    }

    @MainActor
    func testInstallationIsIdempotent() {
        let first = RecordingImpactFeedback()
        let second = RecordingImpactFeedback()
        let button = UIButton(type: .system)

        MobileButtonHaptics.install(
            on: button,
            feedback: MobileButtonFeedback(generator: first)
        )
        MobileButtonHaptics.install(
            on: button,
            feedback: MobileButtonFeedback(generator: second)
        )
        button.sendActions(for: .touchUpInside)

        XCTAssertEqual(first.intensities.count, 1)
        XCTAssertTrue(second.intensities.isEmpty, "a second installer must not double the impact")
    }

    @MainActor
    func testMenuButtonConfirmsTheMenuPresentationEvent() {
        let recorder = RecordingImpactFeedback()
        let button = UIButton(type: .system)
        MobileButtonHaptics.install(
            on: button,
            activationEvent: .menuActionTriggered,
            feedback: MobileButtonFeedback(generator: recorder)
        )

        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(recorder.intensities.isEmpty)

        button.sendActions(for: .menuActionTriggered)
        XCTAssertEqual(recorder.intensities, [MobileButtonFeedback.impactIntensity])
    }

    @MainActor
    func testSharedNativeConversationControlsAdoptTheButtonBoundary() {
        let floatingButton = MobileFloatingScrollToEndButton(
            accessibilityLabel: "Latest",
            accessibilityIdentifier: "latest"
        )
        let disclosure = RemoteToolDisclosureControl()

        XCTAssertTrue(MobileButtonHaptics.isInstalled(on: floatingButton))
        XCTAssertTrue(MobileButtonHaptics.isInstalled(on: disclosure))
    }
}
