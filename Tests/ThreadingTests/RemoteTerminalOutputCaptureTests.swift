import AppKit
import XCTest
@testable import Threading

/// SwiftTerm 2's local-process fast path parses through a private adapter rather than the
/// subclass's compatibility `dataReceived` method. Remote access depends on every PTY batch
/// reaching `EmojiFixedTerminalView.onOutputBytes`, so exercise the real process read path.
@MainActor
final class RemoteTerminalOutputCaptureTests: XCTestCase {
    func testDirectProcessOutputReachesTheRemoteMirrorHook() async throws {
        let payload = "threading-remote-output-\(UUID().uuidString)"
        let received = expectation(description: "raw PTY output reached Threading")
        let view = EmojiFixedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        var output = Data()
        view.onOutputBytes = { bytes in
            output.append(contentsOf: bytes)
            if String(decoding: output, as: UTF8.self).contains(payload) {
                received.fulfill()
            }
        }

        view.process.startProcess(executable: "/usr/bin/printf", args: [payload])
        await fulfillment(of: [received], timeout: 5)

        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(payload))
        view.process.terminate()
        _ = view.updateUiClosed()
    }
}
