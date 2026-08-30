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

    func testKeyboardFrameStormClipsOneGridAndCommitsOnlyTheSettledHeight() {
        let fixture = makeFixture()
        let terminalWidth = fixture.terminal.frame.width
        let originalHeight = fixture.terminal.frame.height

        fixture.host.keyboardGeometryWillChange()
        for height in stride(from: 700.0, through: 380.0, by: -2.0) {
            fixture.host.updateTerminalFrame(
                for: CGSize(width: Fixture.containerWidth, height: height),
                holdsWidth: false
            )
        }

        XCTAssertEqual(fixture.terminal.frame.height, originalHeight, accuracy: 0.01)
        XCTAssertEqual(fixture.terminal.frame.width, terminalWidth, accuracy: 0.01)
        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 0)
        XCTAssertEqual(
            fixture.host.pendingTerminalHeight ?? -1,
            380 - Fixture.contentInset * 2,
            accuracy: 0.01
        )

        fixture.host.keyboardGeometryDidSettle()

        XCTAssertEqual(
            fixture.terminal.frame.height,
            380 - Fixture.contentInset * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 1)
        XCTAssertEqual(fixture.terminal.frame.origin.x, Fixture.contentInset, accuracy: 0.01)
        XCTAssertEqual(fixture.terminal.frame.origin.y, Fixture.contentInset, accuracy: 0.01)
    }

    func testTenThousandKeyboardFramesRetainOneViewAndReportOnlyTheFinalGrid() {
        let fixture = makeFixture()
        let terminalIdentity = ObjectIdentifier(fixture.terminal)
        let recorder = TerminalSizeRecorder()
        fixture.terminal.terminalDelegate = recorder
        fixture.terminal.setUsesLocalViewport(true)
        recorder.sizeReports.removeAll()

        fixture.host.keyboardGeometryWillChange()
        for step in 0..<10_000 {
            let height = CGFloat(380 + step % 321)
            fixture.host.updateTerminalFrame(
                for: CGSize(width: Fixture.containerWidth, height: height),
                holdsWidth: false
            )
        }

        XCTAssertEqual(ObjectIdentifier(fixture.host.terminalView), terminalIdentity)
        XCTAssertTrue(
            recorder.sizeReports.isEmpty,
            "presentation frames must not become terminal grids: \(recorder.sizeReports)"
        )
        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 0)

        fixture.host.keyboardGeometryDidSettle()

        XCTAssertEqual(ObjectIdentifier(fixture.host.terminalView), terminalIdentity)
        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 1)
        XCTAssertEqual(
            recorder.sizeReports.count,
            1,
            "one stable keyboard state must produce exactly one grid: \(recorder.sizeReports)"
        )
        XCTAssertEqual(recorder.sizeReports.last, fixture.terminal.terminalDimensions.rows)
    }

    func testRepeatedKeyboardCompletionAndDuplicateFinalHeightDoNotResizeAgain() {
        let fixture = makeFixture()
        fixture.host.keyboardGeometryWillChange()
        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: 380),
            holdsWidth: false
        )
        fixture.host.keyboardGeometryDidSettle()
        fixture.host.keyboardGeometryDidSettle()
        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: 380),
            holdsWidth: false
        )

        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 1)
    }

    func testCancelledKeyboardTransitionThatReturnsToItsCommittedHeightDoesNotResize() {
        let fixture = makeFixture()
        fixture.host.keyboardGeometryWillChange()
        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: 380),
            holdsWidth: false
        )
        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: Fixture.containerHeight),
            holdsWidth: false
        )
        fixture.host.keyboardGeometryDidSettle()

        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 0)
        XCTAssertEqual(
            fixture.terminal.frame.height,
            Fixture.containerHeight - Fixture.contentInset * 2,
            accuracy: 0.01
        )
    }

    func testTeardownCancelsAKeyboardHeightCommit() {
        let fixture = makeFixture()
        fixture.host.keyboardGeometryWillChange()
        fixture.host.updateTerminalFrame(
            for: CGSize(width: Fixture.containerWidth, height: 380),
            holdsWidth: false
        )

        fixture.host.cancelPendingLayout()
        fixture.host.keyboardGeometryDidSettle()

        XCTAssertEqual(fixture.host.terminalHeightApplicationCount, 0)
        XCTAssertNil(fixture.host.pendingTerminalHeight)
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

private final class TerminalSizeRecorder: NSObject, TerminalViewDelegate {
    var sizeReports: [Int] = []

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { sizeReports.append(newRows) }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(
        source: TerminalView,
        link: String,
        params: [String: String]
    ) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
