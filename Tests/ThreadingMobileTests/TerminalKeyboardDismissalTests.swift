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
        static let scale: CGFloat = 3
        /// A user-authored emoji cap on the top row, so the paperclip's pull is measured with
        /// the scrolling cap run beside it rather than a spacer.
        static let topRowEmoji = "🍕"
        static let agentKind = "codex"
        static let barWindowSize = CGSize(width: 390, height: 160)
        /// Where the bar has nothing drawn: the action row's middle, between the top-row cap and
        /// the trailing controls.
        static let surfaceSample = CGPoint(x: 195, y: 17)
        /// The rows without their hairlines: the top overlay and the divider between the rows.
        static let actionRowBand: Range<CGFloat> = 2..<32
        static let keyRowBand: Range<CGFloat> = 39..<73
        /// A plate over the surface is eighteen levels apart; anti-aliased ink and the hairline
        /// dividers are further. Anything nearer than this is the surface.
        static let surfaceTolerance = 8
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

    func testDetachReconcilesAvailabilityAfterTheDismantleTurn() async {
        let view = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        let bridge = TerminalKeyBridge()
        bridge.attachTerminalView(view)
        XCTAssertTrue(bridge.canShowKeyboard)

        bridge.detachTerminalView(view)

        XCTAssertNil(bridge.terminalView)
        // The published value is intentionally left alone in the representable's dismantle
        // stack. Its next-turn reconciliation is the exclusivity boundary under test.
        XCTAssertTrue(bridge.canShowKeyboard)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(bridge.canShowKeyboard)
    }

    func testAReplacementAttachmentWinsOverADeferredDetach() async {
        let first = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        let replacement = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        let bridge = TerminalKeyBridge()
        bridge.attachTerminalView(first)

        bridge.detachTerminalView(first)
        bridge.attachTerminalView(replacement)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(bridge.terminalView === replacement)
        XCTAssertTrue(bridge.canShowKeyboard)
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
        bridge.attachTerminalView(view)

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
        bridge.attachTerminalView(view)

        XCTAssertEqual(
            bridge.encodedBytes(for: .named(.down, [])),
            Array("\u{1b}OB".utf8)
        )
    }

    func testAnEmojiSnippetWithSubmitOffStaysRawInputWithoutReturn() {
        let bridge = TerminalKeyBridge()

        XCTAssertNil(terminalKeySubmissionText(.snippet(text: "🍕", submits: false)))
        XCTAssertEqual(
            bridge.encodedBytes(for: .snippet(text: "🍕", submits: false)),
            Array("🍕".utf8)
        )
    }

    /// A single raw PTY write containing text plus Return is read as a paste by agent TUIs. The
    /// key bar must recognize the submitting shape and hand only its text to the atomic route,
    /// whose host side writes Return separately.
    func testASubmittingSnippetUsesAtomicTerminalSubmission() {
        XCTAssertEqual(
            terminalKeySubmissionText(.snippet(text: "continue", submits: true)),
            "continue"
        )
        XCTAssertNil(terminalKeySubmissionText(.named(.enter, [])))
    }

    /// These are composite symbols whose chassis do not share a bounding box: the
    /// customization badge hangs below its keyboard while the Direct-input glyph is a plain
    /// chassis. Centering each whole image in the same frame puts the two boxes on different
    /// rows; baseline alignment rests them on one ground line. The chassis are different
    /// heights by design, so the ground line — not the tops — is the shared property. This
    /// samples the rendered chassis itself because equal SwiftUI frames cannot prove optical
    /// alignment.
    func testTheActionRowChassisShareOneGroundLine() throws {
        let controls = TerminalKeyBarActionControls(
            customize: {},
            showsInputModeControl: true,
            inputPreference: .direct,
            effectiveInputMode: .direct,
            canChooseInputPreference: true,
            toggleInputPreference: {}
        )
        let bitmap = try renderedAlpha(
            of: controls,
            size: CGSize(width: 88, height: 34),
            scale: 3
        )
        let customizationKeyboard = try mainInkRun(
            in: bitmap,
            xRange: 33..<63
        )
        let directInputChassis = try mainInkRun(
            in: bitmap,
            xRange: 165..<195
        )

        XCTAssertLessThanOrEqual(
            abs(customizationKeyboard.upperBound - directInputChassis.upperBound),
            2,
            "The chassis no longer rest on one ground line"
        )
    }

    // MARK: - Margins

    /// Both rows stand their outermost mark on the bar's one margin: the paperclip's ink where
    /// the bottom row's first plate starts, and each row's last glyph the same distance in from
    /// the other edge. Read off a drawn, hosted bar, because equal frames are not equal ink:
    /// placed by its frame the paperclip stood eleven points inboard of the cap under it.
    func testBothRowsStandTheirOutermostMarksOnOneMargin() throws {
        let store = MobileTerminalKeyboardStore(defaults: try XCTUnwrap(
            UserDefaults(suiteName: "TerminalKeyBarMargins-\(UUID().uuidString)")
        ))
        var keys = RemoteTerminalKeyboardLayout.standard(forAgentKind: Fixture.agentKind).keys
        keys.insert(RemoteTerminalKeyDefinition(
            customLabel: Fixture.topRowEmoji,
            action: .snippet(text: Fixture.topRowEmoji, submits: false),
            row: .top
        ), at: 0)
        store.setLayout(RemoteTerminalKeyboardLayout(keys: keys), forAgentKind: Fixture.agentKind)
        let bridge = TerminalKeyBridge()
        let terminal = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        bridge.attachTerminalView(terminal)
        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: "key-bar-margins",
                title: "Margins",
                agentKind: Fixture.agentKind,
                surface: .terminal,
                state: .idle,
                projectName: "Threading"
            ),
            client: RemoteClient(
                link: try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#preview"))
            )
        )
        let bar = TerminalKeyBar(
            connection: connection,
            bridge: bridge,
            agentKind: Fixture.agentKind,
            customize: {},
            inputPreference: .direct,
            effectiveInputMode: .direct,
            canChooseInputPreference: true,
            toggleInputPreference: {},
            showsAttachmentKey: true,
            canAttach: true,
            chooseAttachmentSource: {},
            isChoosingAttachmentSource: .constant(false),
            attachmentSourceActions: []
        )
        let host = UIHostingController(
            rootView: VStack(spacing: 0) {
                bar
                Spacer(minLength: 0)
            }
            .environmentObject(store)
            .mobileTheme(RemoteThemePalette(nil))
            .ignoresSafeArea()
        )
        let window = hostedWindow(rootViewController: host, size: Fixture.barWindowSize)
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        let bitmap = try drawnPixels(of: window, scale: Fixture.scale)

        let surface = bitmap.colour(
            x: Int(Fixture.surfaceSample.x * Fixture.scale),
            y: Int(Fixture.surfaceSample.y * Fixture.scale)
        )
        let actionRow = scaled(Fixture.actionRowBand)
        let keyRow = scaled(Fixture.keyRowBand)
        let paperclip = try XCTUnwrap(
            bitmap.firstColumn(differingFrom: surface, rows: actionRow),
            "the action row drew nothing"
        )
        let firstPlate = try XCTUnwrap(
            bitmap.firstColumn(differingFrom: surface, rows: keyRow),
            "the key row drew nothing"
        )
        let lastActionGlyph = try XCTUnwrap(
            bitmap.lastColumn(differingFrom: surface, rows: actionRow)
        )
        let keyboardGlyph = try XCTUnwrap(
            bitmap.lastColumn(differingFrom: surface, rows: keyRow)
        )

        let margin = Int(TerminalKeyBarMetrics.keyPadding * Fixture.scale)
        let farMargin = bitmap.width - 1 - margin
        let tolerance = Int(Fixture.scale)
        XCTAssertEqual(
            paperclip, margin, accuracy: tolerance,
            "the paperclip's ink is not on the cap run's margin"
        )
        XCTAssertEqual(
            firstPlate, margin, accuracy: tolerance,
            "the first cap's plate is not on the cap run's margin"
        )
        XCTAssertEqual(
            lastActionGlyph, farMargin, accuracy: tolerance,
            "the action row's last glyph is not on the trailing margin"
        )
        XCTAssertEqual(
            keyboardGlyph, farMargin, accuracy: tolerance,
            "the keyboard toggle's glyph is not on the trailing margin"
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
        bridge.attachTerminalView(view)
        XCTAssertTrue(view.becomeFirstResponder())
        return (window, view, bridge)
    }

    /// Premultiplied RGBA, one byte each, rows top to bottom.
    private struct AlphaBitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }

        func colour(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }

        func column(_ x: Int, differsFrom surface: (UInt8, UInt8, UInt8), in rows: Range<Int>) -> Bool {
            rows.contains { y in
                let (r, g, b) = colour(x: x, y: y)
                return max(
                    abs(Int(r) - Int(surface.0)),
                    abs(Int(g) - Int(surface.1)),
                    abs(Int(b) - Int(surface.2))
                ) > Fixture.surfaceTolerance
            }
        }

        func firstColumn(differingFrom surface: (UInt8, UInt8, UInt8), rows: Range<Int>) -> Int? {
            (0..<width).first { column($0, differsFrom: surface, in: rows) }
        }

        func lastColumn(differingFrom surface: (UInt8, UInt8, UInt8), rows: Range<Int>) -> Int? {
            (0..<width).last { column($0, differsFrom: surface, in: rows) }
        }
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
        return try alphaBitmap(of: XCTUnwrap(renderer.uiImage?.cgImage, "SwiftUI rendered no image"))
    }

    /// The window as drawn, which is the only place a SwiftUI `ScrollView`'s content appears:
    /// `ImageRenderer` leaves the UIKit-backed scroll views empty.
    private func drawnPixels(of window: UIWindow, scale: CGFloat) throws -> AlphaBitmap {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try alphaBitmap(of: XCTUnwrap(image.cgImage, "the window drew no image"))
    }

    private func alphaBitmap(of image: CGImage) throws -> AlphaBitmap {
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

    private func scaled(_ band: Range<CGFloat>) -> Range<Int> {
        Int(band.lowerBound * Fixture.scale)..<Int(band.upperBound * Fixture.scale)
    }

    private func hostedWindow(rootViewController: UIViewController, size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    /// The chassis is the tallest connected run of ink in the left half of each symbol; the
    /// customization badge sits outside this sample band.
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
