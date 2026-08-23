import XCTest

@testable import Threading

/// The activity tracker sits above SwiftTerm, so both keyboard paths have to cross the terminal
/// session delegate before bytes reach the PTY. A tracker-only test would leave remote input free
/// to bypass the boundary that fixes the phone's stale state.
@MainActor
final class TerminalUserInputActivityTests: XCTestCase {

    func testProgrammaticLocalInputReachesTheActivityBoundary() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.insertText("answer\r")

        XCTAssertEqual(delegate.inputs, [TerminalUserInput(
            bytes: Array("answer\r".utf8),
            submitsLine: true
        )])
    }

    func testRemoteInputReachesTheSameActivityBoundary() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.sendRemoteInput([0x1B, 0x5B, 0x41])
        session.sendRemoteInput([0x0D])

        XCTAssertEqual(delegate.inputs, [
            TerminalUserInput(bytes: [0x1B, 0x5B, 0x41], submitsLine: false),
            TerminalUserInput(bytes: [0x0D], submitsLine: true),
        ])
    }

    func testEmptyRemoteInputIsNotAnInteraction() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.sendRemoteInput([])

        XCTAssertTrue(delegate.inputs.isEmpty)
    }

    func testTerminalProtocolReplyIsNotUserInput() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.terminalView.send(
            source: session.terminalView,
            data: Array("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8)[...]
        )

        XCTAssertTrue(delegate.inputs.isEmpty)
    }

    func testRemoteBracketedPasteDoesNotSubmitItsEmbeddedNewline() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.sendRemoteInput(Array("\u{1B}[200~first\rsecond\u{1B}[201~".utf8))

        XCTAssertEqual(delegate.inputs.last?.submitsLine, false)
    }

    func testLocalPasteDoesNotSubmitItsEmbeddedNewline() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.pasteText("first\nsecond")

        XCTAssertFalse(delegate.inputs.isEmpty)
        XCTAssertTrue(delegate.inputs.allSatisfy { !$0.submitsLine })
    }

    func testRemoteKittyEnterIsASubmission() {
        let session = TerminalSession()
        let delegate = InputDelegate()
        session.delegate = delegate

        session.sendRemoteInput(Array("\u{1B}[13;1u\u{1B}[13;1:3u".utf8))

        XCTAssertEqual(delegate.inputs.last?.submitsLine, true)
    }
}

@MainActor
private final class InputDelegate: TerminalSessionDelegate {
    var inputs: [TerminalUserInput] = []

    func terminalSession(_ session: TerminalSession, didReceiveUserInput input: TerminalUserInput) {
        inputs.append(input)
    }
}
