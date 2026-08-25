import QuartzCore
import SwiftTerm
import UIKit
import XCTest
@testable import ThreadingMobile

@MainActor
final class RemoteTerminalLayoutViewTests: XCTestCase {
    func testFloatingControlArrivalFadesRisesAndScalesToItsSettledState() throws {
        let button = makeFloatingButton()

        button.setPresented(true, animated: true, reducesMotion: false)

        XCTAssertTrue(button.isPresented)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.layer.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(button.layer.transform))
        let animation = try XCTUnwrap(
            button.layer.animation(
                forKey: "threading.mobile-floating-scroll-to-end.presence"
            ) as? CAAnimationGroup
        )
        XCTAssertEqual(animation.duration, MobileDesign.Motion.floatingScrollArrival)
        XCTAssertEqual(animation.animations?.count, 2)
        let transform = try XCTUnwrap(
            animation.animations?.compactMap { $0 as? CABasicAnimation }
                .first(where: { $0.keyPath == "transform" })
        )
        let start = try XCTUnwrap(transform.fromValue as? NSValue).caTransform3DValue
        XCTAssertEqual(start.m11, MobileDesign.Motion.floatingScrollStartScale, accuracy: 0.001)
        XCTAssertEqual(start.m22, MobileDesign.Motion.floatingScrollStartScale, accuracy: 0.001)
        XCTAssertEqual(start.m42, MobileDesign.Offset.floatingScrollLift, accuracy: 0.001)
    }

    func testFloatingControlHonorsReduceMotionAtBothEndpoints() {
        let button = makeFloatingButton()

        button.setPresented(true, animated: true, reducesMotion: true)
        XCTAssertFalse(button.isHidden)
        XCTAssertNil(button.layer.animationKeys())

        button.setPresented(false, animated: true, reducesMotion: true)
        XCTAssertTrue(button.isHidden)
        XCTAssertEqual(button.layer.opacity, 0)
        XCTAssertFalse(CATransform3DIsIdentity(button.layer.transform))
    }

    func testFloatingControlCanReverseAnInterruptedDeparture() {
        let button = makeFloatingButton()
        button.setPresented(true, animated: false, reducesMotion: false)

        button.setPresented(false, animated: true, reducesMotion: false)
        button.setPresented(true, animated: true, reducesMotion: false)

        XCTAssertTrue(button.isPresented)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.layer.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(button.layer.transform))
    }

    func testNavigationWidthsClipOneSettledTerminalGrid() {
        let fixture = makeFixture()
        let originalWidth = fixture.terminal.bounds.width
        var finalContainerWidth = Fixture.containerWidth

        // A deliberately excessive transition cardinality: the work and retained view count stay
        // constant even if SwiftUI proposes far more frames than a real gesture ever will.
        for step in 0..<1_000 {
            let width = CGFloat(120 + step % 271)
            finalContainerWidth = width
            fixture.host.updateTerminalFrame(
                for: CGSize(width: width, height: Fixture.containerHeight),
                holdsWidth: true
            )
        }

        XCTAssertEqual(fixture.terminal.frame.width, originalWidth, accuracy: 0.01)
        XCTAssertEqual(fixture.host.settledTerminalWidth, originalWidth, accuracy: 0.01)
        XCTAssertEqual(
            fixture.host.pendingTerminalWidth ?? -1,
            finalContainerWidth - Fixture.contentInset * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(fixture.host.terminalWidthApplicationCount, 0)
    }

    func testWidthStormCommitsOnlyTheFinalSettledWidth() {
        let fixture = makeFixture()

        for width in [360.0, 300.0, 240.0] {
            fixture.host.updateTerminalFrame(
                for: CGSize(width: width, height: Fixture.containerHeight),
                holdsWidth: false
            )
        }

        XCTAssertEqual(
            fixture.terminal.frame.width,
            Fixture.containerWidth - Fixture.contentInset * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(fixture.host.terminalWidthApplicationCount, 0)

        fixture.host.settlePendingWidth()
        fixture.host.updateTerminalFrame(
            for: CGSize(width: 240, height: Fixture.containerHeight),
            holdsWidth: false
        )

        XCTAssertEqual(
            fixture.terminal.frame.width,
            240 - Fixture.contentInset * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(fixture.host.terminalWidthApplicationCount, 1)
        XCTAssertNil(fixture.host.pendingTerminalWidth)
    }

    func testHeightContinuesToFollowTheKeyboardWithoutChangingColumns() {
        let fixture = makeFixture()
        let terminalWidth = fixture.terminal.frame.width

        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: 380),
            holdsWidth: false
        )

        XCTAssertEqual(fixture.terminal.frame.width, terminalWidth, accuracy: 0.01)
        XCTAssertEqual(
            fixture.terminal.frame.height,
            380 - Fixture.contentInset * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(fixture.terminal.frame.origin.x, Fixture.contentInset, accuracy: 0.01)
        XCTAssertEqual(fixture.terminal.frame.origin.y, Fixture.contentInset, accuracy: 0.01)
    }

    func testCompletedBackDiscardsTheOutgoingWidthInsteadOfResizingBeforeTeardown() {
        let fixture = makeFixture()
        let originalWidth = fixture.terminal.frame.width

        fixture.host.updateTerminalFrame(
            for: CGSize(width: 120, height: Fixture.containerHeight),
            holdsWidth: true
        )
        fixture.host.transitionDidComplete(isCancelled: false, terminalWasSource: true)

        XCTAssertEqual(fixture.terminal.frame.width, originalWidth, accuracy: 0.01)
        XCTAssertEqual(fixture.host.settledTerminalWidth, originalWidth, accuracy: 0.01)
        XCTAssertEqual(fixture.host.terminalWidthApplicationCount, 0)
        XCTAssertNil(fixture.host.pendingTerminalWidth)
    }

    func testCancelledBackRestoresTheSettledWidthWithoutAnotherGrid() {
        let fixture = makeFixture()
        let originalWidth = fixture.terminal.frame.width

        fixture.host.updateTerminalFrame(
            for: CGSize(width: 120, height: Fixture.containerHeight),
            holdsWidth: true
        )
        fixture.host.transitionDidComplete(isCancelled: true, terminalWasSource: true)

        XCTAssertEqual(fixture.terminal.frame.width, originalWidth, accuracy: 0.01)
        XCTAssertEqual(fixture.host.terminalWidthApplicationCount, 0)
        XCTAssertNil(fixture.host.pendingTerminalWidth)
    }

    private func makeFixture() -> (
        host: RemoteTerminalLayoutView,
        terminal: RemoteTerminalView
    ) {
        let terminal = RemoteTerminalView(
            frame: CGRect(
                x: Fixture.contentInset,
                y: Fixture.contentInset,
                width: Fixture.containerWidth - Fixture.contentInset * 2,
                height: Fixture.containerHeight - Fixture.contentInset * 2
            ),
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let host = RemoteTerminalLayoutView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: Fixture.containerWidth,
                height: Fixture.containerHeight
            ),
            terminalView: terminal,
            contentInset: Fixture.contentInset
        )
        host.updateTerminalFrame(for: host.bounds.size, holdsWidth: false)
        return (host, terminal)
    }

    private func makeFloatingButton() -> MobileFloatingScrollToEndButton {
        MobileFloatingScrollToEndButton(
            accessibilityLabel: "Jump to bottom",
            accessibilityIdentifier: "scroll-test"
        )
    }

    private enum Fixture {
        static let containerWidth: CGFloat = 393
        static let containerHeight: CGFloat = 720
        static let contentInset = MobileDesign.Spacing.small
    }
}
