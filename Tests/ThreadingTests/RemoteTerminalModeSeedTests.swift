import XCTest
import SwiftTerm
@testable import Threading

/// Mouse tracking is armed once, by a private-mode sequence a full-screen program emits when it
/// starts. `RemoteScreenSeed` reproduces the picture such a program is showing but not that
/// sequence, and the 512 KB ring rolls the original away within seconds of real output — so a
/// phone attaching to a running agent had a terminal at `mouseMode == .off` and swallowed every
/// tap. Clicking "click to go to bottom" answered on the Mac and did nothing on the phone.
///
/// These assert on the byte stream, because the byte stream is the whole contract, and then run
/// it through a second emulator, because reproducing the contract in a client is the point.
final class RemoteTerminalModeSeedTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// Tracking plus SGR encoding, the shape an agent TUI arms. Claude Code asks for
        /// any-event tracking (1003); every tracking mode is covered by its own case below.
        static let agentArming = "\u{1b}[?1002h\u{1b}[?1006h"
        static let cols = 80
        static let rows = 24
        static let clickColumn = 12
        static let clickRow = 4
    }

    // MARK: - Harness

    private final class Recorder: TerminalDelegate {
        var written: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) {
            written.append(contentsOf: data)
        }
        var text: String { String(decoding: written, as: UTF8.self) }
    }

    private var recorder = Recorder()

    private func makeTerminal() -> Terminal {
        recorder = Recorder()
        return Terminal(
            delegate: recorder,
            options: TerminalOptions(cols: Fixture.cols, rows: Fixture.rows, scrollback: 100)
        )
    }

    private func statement(for terminal: Terminal) -> Data {
        RemoteTerminalModeSeed.bytes(for: RemoteTerminalModes(terminal))
    }

    // MARK: - Reading The Mac

    func testAnUntrackedTerminalReportsNoMouseContract() {
        XCTAssertEqual(
            RemoteTerminalModes(makeTerminal()),
            .plain,
            "a shell prompt asks for nothing, and the client must not be told otherwise"
        )
    }

    func testTheArmedModesAreReadOffTheEmulator() {
        let terminal = makeTerminal()
        terminal.feed(text: Fixture.agentArming + "\u{1b}[?1h\u{1b}[?2004h\u{1b}[>7u")

        let modes = RemoteTerminalModes(terminal)

        XCTAssertEqual(modes.mouseReporting?.tracking, .buttonEvent)
        XCTAssertEqual(modes.mouseReporting?.encoding, .sgr)
        XCTAssertTrue(modes.applicationCursorKeys)
        XCTAssertTrue(modes.bracketedPaste)
        XCTAssertEqual(modes.keyboardEnhancementFlags, 7)
    }

    /// The phone's key bar asks its own emulator whether an arrow should be SS3 or CSI, and its
    /// paste asks whether to bracket. Both were answered by a terminal that never saw the TUI
    /// start, so a late joiner sent the sequences a full-screen program had not asked for.
    func testTheOtherStickyModesReachAClientThatNeverSawTheProgramStart() {
        let mac = makeTerminal()
        mac.feed(text: "\u{1b}[?1h\u{1b}[?2004h\u{1b}[>7u")
        let phone = makeTerminal()

        phone.feed(byteArray: [UInt8](statement(for: mac)))

        XCTAssertTrue(phone.applicationCursor, "an arrow would go out as CSI where the TUI wants SS3")
        XCTAssertTrue(phone.bracketedPasteMode, "an unbracketed multi-line paste runs line by line")
        XCTAssertEqual(
            phone.keyboardEnhancementFlags.rawValue,
            7,
            "a touch key must report the event lifecycle the TUI negotiated"
        )
    }

    func testTheStatementTurnsTheOtherStickyModesBackOff() {
        let mac = makeTerminal()
        let phone = makeTerminal()
        phone.feed(text: "\u{1b}[?1h\u{1b}[?2004h\u{1b}[>7u")

        phone.feed(byteArray: [UInt8](statement(for: mac)))

        XCTAssertFalse(phone.applicationCursor)
        XCTAssertFalse(phone.bracketedPasteMode)
        XCTAssertTrue(phone.keyboardEnhancementFlags.isEmpty)
    }

    // MARK: - The Statement

    func testTheStatementArmsAClientThatNeverSawTheProgramStart() {
        let mac = makeTerminal()
        mac.feed(text: Fixture.agentArming)

        // The phone: a terminal that has only ever seen the ring, which no longer holds the
        // sequence above.
        let phone = makeTerminal()
        XCTAssertEqual(phone.mouseMode, .off)

        phone.feed(byteArray: [UInt8](statement(for: mac)))

        XCTAssertEqual(phone.mouseMode, .buttonEventTracking)
        XCTAssertEqual(phone.mouseProtocol, .sgr)
    }

    func testAnArmedClientReportsATapAsAnSgrClick() {
        let mac = makeTerminal()
        mac.feed(text: Fixture.agentArming)
        let phone = makeTerminal()
        phone.feed(byteArray: [UInt8](statement(for: mac)))
        recorder.written.removeAll()

        phone.sendEvent(
            buttonFlags: phone.encodeButton(
                // Zero is the left button in xterm's numbering; one is the middle one, which is
                // what the iOS view used to send and no TUI answers.
                button: 0,
                release: false,
                shift: false,
                meta: false,
                control: false
            ),
            x: Fixture.clickColumn,
            y: Fixture.clickRow,
            pixelX: 0,
            pixelY: 0
        )

        XCTAssertEqual(
            recorder.text,
            "\u{1b}[<0;\(Fixture.clickColumn + 1);\(Fixture.clickRow + 1)M",
            "the click has to reach the agent in the encoding it asked for"
        )
    }

    /// A mirror replays history, and history holds modes that stopped being true. An agent that
    /// exited to a shell leaves an arming sequence in the ring; without the resets the phone
    /// would keep reporting clicks, which a shell reads as pasted escape text.
    func testTheStatementDisarmsAClientTheRingLeftArmed() {
        let mac = makeTerminal()
        let phone = makeTerminal()
        phone.feed(text: Fixture.agentArming)
        XCTAssertEqual(phone.mouseMode, .buttonEventTracking)

        phone.feed(byteArray: [UInt8](statement(for: mac)))

        XCTAssertEqual(phone.mouseMode, .off)
        XCTAssertEqual(phone.mouseProtocol, .x10)
    }

    func testEveryTrackingModeSurvivesTheRoundTrip() {
        let modes: [(arming: String, expected: Terminal.MouseMode)] = [
            ("\u{1b}[?9h", .x10),
            ("\u{1b}[?1000h", .vt200),
            ("\u{1b}[?1002h", .buttonEventTracking),
            ("\u{1b}[?1003h", .anyEvent),
        ]

        for mode in modes {
            let mac = makeTerminal()
            mac.feed(text: mode.arming)
            let phone = makeTerminal()

            phone.feed(byteArray: [UInt8](statement(for: mac)))

            XCTAssertEqual(phone.mouseMode, mode.expected, "\(mode.arming) did not survive")
        }
    }

    func testEveryEncodingSurvivesTheRoundTrip() {
        let encodings = ["\u{1b}[?1005h", "\u{1b}[?1006h", "\u{1b}[?1015h", "\u{1b}[?1016h", ""]

        for encoding in encodings {
            let mac = makeTerminal()
            // The tracking mode goes last: on this emulator resetting an encoding also stops
            // tracking, which is the ordering trap the statement itself has to avoid.
            mac.feed(text: encoding + "\u{1b}[?1002h")
            let phone = makeTerminal()

            phone.feed(byteArray: [UInt8](statement(for: mac)))

            XCTAssertEqual(
                phone.mouseProtocol,
                mac.mouseProtocol,
                "the encoding after \(encoding.debugDescription) did not survive"
            )
            XCTAssertEqual(
                phone.mouseMode,
                .buttonEventTracking,
                "selecting an encoding must not disarm the tracking it came with"
            )
        }
    }

    /// A bounded ring is a window over raw bytes and can end anywhere, including inside an
    /// escape sequence. A statement that lands inside a half-parsed one would be eaten by it —
    /// silently, and silence here is exactly the bug the statement exists to fix.
    func testTheStatementIsReadableAfterATruncatedSequence() {
        let mac = makeTerminal()
        mac.feed(text: Fixture.agentArming)
        let phone = makeTerminal()
        phone.feed(text: "\u{1b}[38;2;10")

        phone.feed(byteArray: [UInt8](statement(for: mac)))

        XCTAssertEqual(phone.mouseMode, .buttonEventTracking)
        XCTAssertEqual(phone.mouseProtocol, .sgr)
    }

    /// The tracking resets have to be finished before an encoding is chosen, and the encoding
    /// before the tracking is armed, or the statement disarms what it just said.
    func testTheStatementSetsTrackingLast() {
        let mac = makeTerminal()
        mac.feed(text: Fixture.agentArming)

        let bytes = String(decoding: statement(for: mac), as: UTF8.self)

        guard let encoding = bytes.range(of: "\u{1b}[?1006h"),
              let tracking = bytes.range(of: "\u{1b}[?1002h"),
              let lastReset = bytes.range(of: "\u{1b}[?1016l") else {
            return XCTFail("expected both sets and the encoding resets in \(bytes)")
        }
        XCTAssertTrue(lastReset.upperBound <= encoding.lowerBound)
        XCTAssertTrue(encoding.upperBound <= tracking.lowerBound)
    }
}
