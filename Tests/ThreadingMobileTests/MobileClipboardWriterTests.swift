import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileClipboardWriterTests: XCTestCase {
    func testShippingConnectionDispatchesWritesAndDiscardsRetiredGenerations() async throws {
        var writes: [String] = []
        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: UUID().uuidString, title: "Clipboard", agentKind: "codex",
                surface: .conversation, state: .idle, projectName: "Fixture"
            ),
            client: RemoteClient(link: DemoExperience.link),
            clipboardWriter: { writes.append($0.text); return .copied }
        )
        connection.connect()
        defer { connection.disconnect(markEnded: false) }
        for _ in 0..<200 {
            if connection.phase == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.phase, .connected)
        let request = RemoteClipboardWrite(
            requestID: "request", text: "exact text", expiresAt: Date().timeIntervalSince1970 + 10
        )
        let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        connection.receiveServerTextForTesting(wire)
        for _ in 0..<200 {
            if writes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(writes, ["exact text"])
        connection.receiveServerTextForTesting(wire)
        connection.disconnect(markEnded: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(writes, ["exact text"], "A retired socket must not overwrite the clipboard")
    }

    func testCopiesExactTextToAnIsolatedPasteboard() throws {
        let name = UIPasteboard.Name("clipboard-test-\(UUID())")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let request = RemoteClipboardWrite(requestID: "request", text: "  å\ncode\n", expiresAt: 110)
        XCTAssertEqual(MobileClipboardWriter.copy(request, isActive: true, now: 100, pasteboard: pasteboard), .copied)
        XCTAssertEqual(pasteboard.string, request.text)
    }

    func testBackgroundExpiredAndOversizedRequestsPreserveExistingClipboard() throws {
        let name = UIPasteboard.Name("clipboard-test-\(UUID())")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        pasteboard.string = "keep me"
        let request = RemoteClipboardWrite(requestID: "request", text: "replace", expiresAt: 110)
        XCTAssertEqual(MobileClipboardWriter.copy(request, isActive: false, now: 100, pasteboard: pasteboard), .inactive)
        XCTAssertEqual(MobileClipboardWriter.copy(request, isActive: true, now: 110, pasteboard: pasteboard), .expired)
        let oversized = RemoteClipboardWrite(requestID: "request", text: String(repeating: "å", count: 32_769), expiresAt: 110)
        XCTAssertEqual(MobileClipboardWriter.copy(oversized, isActive: true, now: 100, pasteboard: pasteboard), .invalid)
        XCTAssertEqual(pasteboard.string, "keep me")
    }
}
