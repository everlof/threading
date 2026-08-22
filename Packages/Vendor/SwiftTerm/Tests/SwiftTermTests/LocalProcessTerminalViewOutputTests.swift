#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
struct LocalProcessTerminalViewOutputTests {
    @Test @MainActor
    func ownedOutputObserverSeesTheDirectDeliveryReadPath() async throws {
        let payload = Array(repeating: Array("swiftterm-output-observer".utf8), count: 128)
            .flatMap { $0 }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftterm-output-observer-\(UUID().uuidString)")
        try Data(payload).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let capture = ProcessOutputCapture(expectedByteCount: payload.count)
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.setProcessOutputBytesHandler { bytes in
            capture.append(bytes)
        }
        view.process.startProcess(executable: "/bin/cat", args: [file.path])

        let received = await Task.detached {
            capture.wait(timeout: 5)
        }.value

        #expect(received)
        #expect(capture.bytes == payload)
        view.setProcessOutputBytesHandler(nil)
        view.process.terminate()
        _ = view.updateUiClosed()
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedByteCount: Int
    private var storage: [UInt8] = []

    init(expectedByteCount: Int) {
        self.expectedByteCount = expectedByteCount
    }

    var bytes: [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    func append(_ bytes: [UInt8]) {
        condition.lock()
        storage.append(contentsOf: bytes)
        if storage.count >= expectedByteCount {
            condition.broadcast()
        }
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while storage.count < expectedByteCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
#endif
