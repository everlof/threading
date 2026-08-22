import SwiftTerm
import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The key bar carries the way back from the keyboard, because it replaces SwiftTerm's own
/// accessory row which used to carry it. The control was there and did nothing at all.
@MainActor
final class TerminalKeyboardDismissalTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let windowFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        static let fontSize: CGFloat = 12
    }

    // MARK: - Tests

    func testDismissingPutsTheTerminalsKeyboardAway() {
        let (window, view, bridge) = makeFocusedTerminal()
        defer { window.isHidden = true }
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(bridge.isKeyboardShowing)

        bridge.dismissKeyboard()

        XCTAssertFalse(view.isFirstResponder)
        XCTAssertFalse(bridge.isKeyboardShowing)
    }

    /// Nothing is holding the keyboard and nothing crashes; the bar may be tapped either way.
    func testDismissingIsHarmlessWithNothingFocused() {
        let (window, view, bridge) = makeFocusedTerminal()
        defer { window.isHidden = true }
        bridge.dismissKeyboard()

        bridge.dismissKeyboard()

        XCTAssertFalse(view.isFirstResponder)
    }

    func testABridgeWithNoTerminalReportsNoKeyboard() {
        XCTAssertFalse(TerminalKeyBridge().isKeyboardShowing)
    }

    /// An unknown SF Symbol leaves the button's full slot in the bar but draws no glyph. That
    /// made the show-keyboard action present and accessible while visibly indistinguishable from
    /// empty space, so every symbol owned by this control is checked against the shipping SDK.
    func testEveryKeyBarControlHasAVisibleSystemSymbol() {
        for symbol in TerminalKeyBarSymbols.all {
            XCTAssertNotNil(UIImage(systemName: symbol), "Missing SF Symbol: \(symbol)")
        }
    }

    /// A SwiftUI button activates on touch-up. Treating that activation as modifier-down meant
    /// a person holding ⌃ with one finger and tapping ↑ with another sent a plain arrow, then
    /// armed ⌃ only after the chord was already over.
    func testAHeldModifierParticipatesInARealTwoFingerChord() {
        let bridge = TerminalKeyBridge()

        bridge.modifierTouchBegan(.control)
        XCTAssertEqual(bridge.modifiersForNextKey, .control)
        XCTAssertEqual(
            RemoteTerminalKeyEncoder.bytes(
                for: .named(.up, []),
                latched: bridge.modifiersForNextKey
            ),
            [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41]
        )

        bridge.consumeModifiersAfterKey()
        bridge.modifierTouchEnded(.control)
        XCTAssertFalse(bridge.activate(.control), "Chord release armed the next key")
        XCTAssertEqual(bridge.latch.phase(of: .control), .off)
        XCTAssertTrue(bridge.modifiersForNextKey.isEmpty)
    }

    /// The same physical lifecycle without a second key remains the documented tap-to-arm path.
    func testATappedModifierStillArmsTheNextKey() {
        let bridge = TerminalKeyBridge()

        bridge.modifierTouchBegan(.alt)
        bridge.modifierTouchEnded(.alt)

        XCTAssertTrue(bridge.activate(.alt))
        XCTAssertEqual(bridge.latch.phase(of: .alt), .armed)
        XCTAssertEqual(bridge.modifiersForNextKey, .alt)
    }

    /// Codex asks the terminal for event types before it opens `/model`. A cap used to bypass
    /// SwiftTerm after that negotiation and send only a legacy press; one touch now sends the
    /// exact enhanced press/release pair through the emulator's canonical encoder.
    func testOneArrowTapIsOneCompleteNegotiatedKeyLifecycle() {
        let view = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        view.feed(text: "\u{1b}[?1h\u{1b}[>7u")
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view

        XCTAssertEqual(
            bridge.encodedBytes(for: .named(.down, [])),
            Array("\u{1b}[B\u{1b}[1;1:3B".utf8)
        )
    }

    /// Enhanced keyboard reporting takes precedence over DECCKM for functional-key spelling.
    /// Without a negotiated mode, the same bridge still keeps the classic SS3 behavior.
    func testAClassicArrowStillHonoursApplicationCursorMode() {
        let view = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        view.feed(text: "\u{1b}[?1h")
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view

        XCTAssertEqual(
            bridge.encodedBytes(for: .named(.down, [])),
            Array("\u{1b}OB".utf8)
        )
    }

    /// These are composite symbols with different adornments below the shared keyboard motif.
    /// Centering each whole image in the same frame put those keyboards on different rows. This
    /// samples the rendered motif itself because equal SwiftUI frames cannot prove optical
    /// alignment.
    func testTheTrailingKeyboardMotifsShareOneVerticalLine() throws {
        let controls = TerminalKeyBarTrailingControls(
            isKeyboardVisible: true,
            canShowKeyboard: true,
            dismissKeyboard: {},
            showKeyboard: {},
            customize: {}
        )
        let bitmap = try renderedAlpha(
            of: controls,
            size: CGSize(width: 88, height: 34),
            scale: 3
        )
        let dismissalKeyboard = try mainInkRun(
            in: bitmap,
            xRange: 33..<63
        )
        let customizationKeyboard = try mainInkRun(
            in: bitmap,
            xRange: 165..<195
        )

        XCTAssertLessThanOrEqual(
            abs(dismissalKeyboard.lowerBound - customizationKeyboard.lowerBound),
            1,
            "The keyboard chassis tops no longer share a vertical ink line"
        )
        XCTAssertLessThanOrEqual(
            abs(dismissalKeyboard.upperBound - customizationKeyboard.upperBound),
            1,
            "The keyboard chassis bottoms no longer share a vertical ink line"
        )
    }

    /// A platform tripwire, not a behaviour of ours. `UIApplication.sendAction` broadcasting
    /// `resignFirstResponder` is the idiom that dismisses a `UITextField`, and the bar shipped
    /// with it — but it leaves this terminal first responder, which is why the button did
    /// nothing. If a future iOS makes this pass, the direct call is still correct and this test
    /// is what says the constraint has gone away.
    func testTheApplicationBroadcastStillDoesNotReachTheTerminal() {
        let (window, view, _) = makeFocusedTerminal()
        defer { window.isHidden = true }

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        XCTAssertTrue(view.isFirstResponder)
    }

    // MARK: - Private Methods

    private func makeFocusedTerminal() -> (UIWindow, RemoteTerminalView, TerminalKeyBridge) {
        let window = UIWindow(frame: Fixture.windowFrame)
        let view = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        window.addSubview(view)
        window.makeKeyAndVisible()
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view
        XCTAssertTrue(view.becomeFirstResponder())
        return (window, view, bridge)
    }

    private struct AlphaBitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func renderedAlpha<Content: View>(
        of view: Content,
        size: CGSize,
        scale: CGFloat
    ) throws -> AlphaBitmap {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.uiImage?.cgImage, "SwiftUI rendered no image")

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return AlphaBitmap(width: width, height: height, bytes: bytes)
    }

    /// The chassis is the tallest connected run of ink in the left half of each symbol. The
    /// dismissal chevron is shorter and separated below it; the customization badge is outside
    /// this sample band.
    private func mainInkRun(
        in bitmap: AlphaBitmap,
        xRange: Range<Int>
    ) throws -> ClosedRange<Int> {
        let occupiedRows = (0..<bitmap.height).filter { y in
            xRange.contains { x in
                bitmap.bytes[(y * bitmap.width + x) * 4 + 3] > 32
            }
        }
        let firstRow = try XCTUnwrap(occupiedRows.first, "The SF Symbol rendered no sampled ink")
        var runs: [ClosedRange<Int>] = []
        var start = firstRow
        var previous = firstRow
        for row in occupiedRows.dropFirst() {
            if row > previous + 1 {
                runs.append(start...previous)
                start = row
            }
            previous = row
        }
        runs.append(start...previous)
        return try XCTUnwrap(runs.max { $0.count < $1.count })
    }
}
