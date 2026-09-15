import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

@MainActor
final class SessionClipboardServiceTests: XCTestCase {
    private final class Device {}

    func testShippingMacWriterUsesAnIsolatedPasteboard() {
        let pasteboard = NSPasteboard(name: .init("clipboard-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(MacClipboardWriter.copy("  å\ncode\n", pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "  å\ncode\n")
    }

    func testMacPreservesWhitespaceAndRequiresExplicitTarget() {
        var written: [String] = []
        let service = SessionClipboardService(writeMac: { written.append($0); return true })
        service.copy(text: "  å\n", target: nil, sessionID: SessionID(), participantID: "owner", endpoints: []) {
            XCTAssertTrue($0.isError)
        }
        XCTAssertTrue(written.isEmpty)
        service.copy(text: "  å\n", target: "mac", sessionID: SessionID(), participantID: "owner", endpoints: []) {
            XCTAssertFalse($0.isError)
        }
        XCTAssertEqual(written, ["  å\n"])
    }

    func testGuestCannotWriteOwnersMacAndOversizedUTF8IsRejected() {
        let service = SessionClipboardService(writeMac: { _ in XCTFail("Must not write"); return true })
        service.copy(text: "hello", target: "mac", sessionID: SessionID(), participantID: "guest", endpoints: []) {
            XCTAssertTrue($0.isError)
        }
        service.copy(text: String(repeating: "å", count: 32_769), target: "mac", sessionID: SessionID(), participantID: "owner", endpoints: []) {
            XCTAssertTrue($0.isError)
        }
    }

    func testIOSNeverFallsBackToMac() {
        let service = SessionClipboardService(writeMac: { _ in XCTFail("Wrong device"); return true })
        service.copy(text: "hello", target: "ios", sessionID: SessionID(), participantID: "owner", endpoints: []) {
            XCTAssertTrue($0.isError)
            XCTAssertTrue($0.text.contains("unavailable"))
        }
    }

    func testReceiptMustMatchExactSocketSessionAndRequest() throws {
        let device = Device()
        let impostor = Device()
        let session = SessionID()
        let service = SessionClipboardService(writeMac: { _ in XCTFail("Wrong device"); return true })
        var sent: RemoteClipboardWrite?
        var receipts: [MCPToolResult] = []
        let endpoint = SessionClipboardService.Endpoint(
            id: ObjectIdentifier(device), deviceID: "phone", participantID: "owner",
            isCurrent: { true }, send: { sent = $0 }
        )
        service.copy(text: "  exact\n", target: "ios", sessionID: session, participantID: "owner", endpoints: [endpoint]) {
            receipts.append($0)
        }
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.text, "  exact\n")
        XCTAssertTrue(receipts.isEmpty, "Sending a frame is not proof of copying")
        service.receive(requestID: request.requestID, result: .copied, endpointID: ObjectIdentifier(impostor), sessionID: session)
        service.receive(requestID: request.requestID, result: .copied, endpointID: endpoint.id, sessionID: SessionID())
        service.receive(requestID: "unknown", result: .copied, endpointID: endpoint.id, sessionID: session)
        XCTAssertTrue(receipts.isEmpty)
        service.receive(requestID: request.requestID, result: .copied, endpointID: endpoint.id, sessionID: session)
        service.receive(requestID: request.requestID, result: .copied, endpointID: endpoint.id, sessionID: session)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertFalse(try XCTUnwrap(receipts.first).isError)
    }

    func testConcurrentWritesAndDisconnectAreBounded() {
        let device = Device()
        let service = SessionClipboardService(writeMac: { _ in false })
        var sent = 0
        let endpoint = SessionClipboardService.Endpoint(
            id: ObjectIdentifier(device), deviceID: "phone", participantID: "owner",
            isCurrent: { true }, send: { _ in sent += 1 }
        )
        var failures = 0
        for _ in 0..<1_000 {
            service.copy(text: "hello", target: "ios", sessionID: SessionID(), participantID: "owner", endpoints: [endpoint]) {
                XCTAssertTrue($0.isError)
                failures += 1
            }
        }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(failures, 999)
        service.disconnect(endpoint.id)
        XCTAssertEqual(failures, 1_000)
    }

    func testExpiredAndWrongParticipantEndpointsAreNotSelected() {
        let device = Device()
        let service = SessionClipboardService(writeMac: { _ in false })
        for (participant, current) in [("someone-else", true), ("owner", false)] {
            let endpoint = SessionClipboardService.Endpoint(
                id: ObjectIdentifier(device), deviceID: "phone", participantID: participant,
                isCurrent: { current }, send: { _ in XCTFail("Not authorized") }
            )
            service.copy(text: "hello", target: "ios", sessionID: SessionID(), participantID: "owner", endpoints: [endpoint]) {
                XCTAssertTrue($0.isError)
            }
        }
    }

    func testTimeoutReportsUnconfirmedAndLateReceiptDoesNotCompleteAgain() async throws {
        let device = Device()
        let session = SessionID()
        let service = SessionClipboardService(receiptTimeout: .milliseconds(1), writeMac: { _ in false })
        let finished = expectation(description: "receipt deadline")
        var sent: RemoteClipboardWrite?
        let endpoint = SessionClipboardService.Endpoint(
            id: ObjectIdentifier(device), deviceID: "phone", participantID: "owner",
            isCurrent: { true }, send: { sent = $0 }
        )
        service.copy(text: "hello", target: "ios", sessionID: session, participantID: "owner", endpoints: [endpoint]) {
            XCTAssertTrue($0.isError)
            XCTAssertTrue($0.text.contains("unconfirmed"))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        service.receive(requestID: try XCTUnwrap(sent).requestID, result: .copied, endpointID: endpoint.id, sessionID: session)
    }

    func testToolIsRegisteredWithTypedArgumentsAndExplicitDestination() throws {
        let data = Data(#"{"name":"copy_to_clipboard","arguments":{"text":"hello","target":"ios"}}"#.utf8)
        let call = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
        let arguments: CopyToClipboardArguments = try requireToolArguments(call.call, tool: .copyToClipboard)
        XCTAssertEqual(arguments.text, "hello")
        XCTAssertEqual(arguments.target, "ios")
        XCTAssertTrue(MCPTools.sessionTools.contains("copy_to_clipboard"))
        XCTAssertTrue(MCPBuiltInToolRegistry.issues.isEmpty)
    }
}
