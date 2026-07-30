import XCTest
@testable import Threading

/// RFC 6455 conformance for the hand-rolled WebSocket codec. The vectors are the standard's
/// own §1.3 / §5.7 examples, so a regression here is measured against the spec rather than
/// against our own idea of it.
final class RemoteWebSocketTests: XCTestCase {

    // MARK: - Handshake

    /// RFC 6455 §1.3: key `dGhlIHNhbXBsZSBub25jZQ==` → accept `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
    func testHandshakeAcceptKeyMatchesTheStandardVector() {
        XCTAssertEqual(
            RemoteWebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testUpgradeResponseIsProducedForAValidRequest() throws {
        let raw = "GET /ws/session/abc HTTP/1.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        guard case .request(let request, _) = MCPConnection.parseRequest(from: Data(raw.utf8)) else {
            return XCTFail("expected a parsed request")
        }

        let data = try XCTUnwrap(RemoteWebSocket.upgradeResponseData(for: request))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        // A 101 must not carry a body framing header.
        XCTAssertFalse(text.contains("Content-Length"))
    }

    func testUpgradeResponseIsRefusedForANonUpgradeRequest() throws {
        let raw = "GET /ws/session/abc HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .request(let request, _) = MCPConnection.parseRequest(from: Data(raw.utf8)) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertNil(RemoteWebSocket.upgradeResponseData(for: request))
    }

    func testUpgradeRefusesAKeyThatIsNotA16ByteNonce() throws {
        let raw = "GET /ws/session/abc HTTP/1.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: bm90LTE2LWJ5dGVz\r\n\r\n"
        guard case .request(let request, _) = MCPConnection.parseRequest(from: Data(raw.utf8)) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertNil(RemoteWebSocket.upgradeResponseData(for: request))
    }

    // MARK: - Decode (client → server, masked)

    /// RFC 6455 §5.7: a single masked text frame carrying "Hello".
    func testMaskedHelloDecodesToHello() {
        let frameBytes: [UInt8] = [
            0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58,
        ]
        guard case .frame(let frame, let consumed) = decode(frameBytes) else {
            return XCTFail("expected a decoded frame")
        }
        XCTAssertEqual(consumed, frameBytes.count)
        XCTAssertTrue(frame.fin)
        XCTAssertEqual(frame.opcode, .text)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "Hello")
    }

    /// A client frame that arrives unmasked is a protocol error, closed with 1002.
    func testUnmaskedClientFrameIsRefused() {
        let frameBytes: [UInt8] = [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f] // unmasked "Hello"
        guard case .protocolError(let code, _) = decode(frameBytes) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
    }

    /// A declared length past the maximum is refused the moment it is known, without buffering.
    func testOversizeFrameIsRefusedBeforeItsPayloadArrives() {
        // Binary, masked, 16-bit length = 200, and nothing else in the buffer.
        let header: [UInt8] = [0x82, 0xFE, 0x00, 0xC8]
        guard case .protocolError(let code, _) =
            RemoteWebSocket.decodeFrame(from: Data(header), maximumPayload: 10) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.messageTooBig)
    }

    func testExtendedLengthMustUseTheSmallestEncoding() {
        // A 5-byte payload encoded with the 16-bit form is forbidden by RFC 6455 §5.2.
        let bytes: [UInt8] = [0x81, 0xFE, 0x00, 0x05]
        guard case .protocolError(let code, _) = decode(bytes) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)

        // So is a 16-bit-sized payload declared with the 64-bit form.
        let wide: [UInt8] = [0x82, 0xFF, 0, 0, 0, 0, 0, 0, 0x01, 0x00]
        guard case .protocolError(let wideCode, _) = decode(wide) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(wideCode, RemoteWebSocket.CloseCode.protocolError)
    }

    /// Bytes fed one at a time: every prefix is `.incomplete` until the last byte lands.
    func testFrameIsIncompleteUntilFullyBuffered() {
        let frameBytes: [UInt8] = [
            0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58,
        ]
        for prefix in 1..<frameBytes.count {
            XCTAssertEqual(
                decode(Array(frameBytes.prefix(prefix))), .incomplete,
                "prefix of \(prefix) bytes should be incomplete"
            )
        }
        if case .frame = decode(frameBytes) {} else {
            XCTFail("the full frame should decode")
        }
    }

    /// A masked frame using the 16-bit extended length form round-trips its whole payload.
    func testExtendedLengthMaskedFrameDecodes() {
        let payload = [UInt8](repeating: 0x41, count: 300) // 'A' * 300
        let key: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var bytes: [UInt8] = [0x82, 0x80 | 126, 0x01, 0x2C] // binary, masked, len = 300
        bytes.append(contentsOf: key)
        for (index, byte) in payload.enumerated() { bytes.append(byte ^ key[index & 0x3]) }

        guard case .frame(let frame, let consumed) = decode(bytes) else {
            return XCTFail("expected a decoded frame")
        }
        XCTAssertEqual(consumed, bytes.count)
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertEqual(Array(frame.payload), payload)
    }

    // MARK: - Encode (server → client, unmasked)

    /// RFC 6455 §5.7: a single unmasked text frame carrying "Hello".
    func testEncodeHelloMatchesTheStandardVector() {
        let data = RemoteWebSocket.encodeFrame(opcode: .text, payload: Data("Hello".utf8))
        XCTAssertEqual(Array(data), [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
    }

    func testEncodeUses16BitLengthAtThe126Boundary() {
        let data = RemoteWebSocket.encodeFrame(opcode: .binary, payload: Data(repeating: 0, count: 200))
        XCTAssertEqual(data[data.startIndex], 0x82)             // FIN + binary
        XCTAssertEqual(data[data.startIndex + 1], 126)          // extended-16 marker
        XCTAssertEqual(data[data.startIndex + 2], 0x00)         // length high byte
        XCTAssertEqual(data[data.startIndex + 3], 0xC8)         // length low byte (200)
        XCTAssertEqual(data.count, 4 + 200)
    }

    func testEncodeUses64BitLengthPastUInt16() {
        let length = 70_000
        let data = RemoteWebSocket.encodeFrame(opcode: .binary, payload: Data(repeating: 0, count: length))
        XCTAssertEqual(data[data.startIndex + 1], 127)          // extended-64 marker
        XCTAssertEqual(data.count, 10 + length)                 // 2 + 8-byte length + payload
    }

    func testCloseFrameCarriesItsCode() {
        let data = RemoteWebSocket.closeFrame(code: RemoteWebSocket.CloseCode.normal)
        XCTAssertEqual(data[data.startIndex], 0x88)             // FIN + close
        XCTAssertEqual(data[data.startIndex + 1], 2)            // 2-byte payload
        XCTAssertEqual(data[data.startIndex + 2], 0x03)         // 1000 >> 8
        XCTAssertEqual(data[data.startIndex + 3], 0xE8)         // 1000 & 0xFF
    }

    // MARK: - Outbound backpressure

    func testOutboundBudgetIncludesTheFrameBeingEnqueued() {
        let limit = 100
        XCTAssertTrue(RemoteConnection.canEnqueueOutbound(
            pendingBytes: 60,
            nextBytes: 40,
            limit: limit
        ))
        XCTAssertFalse(RemoteConnection.canEnqueueOutbound(
            pendingBytes: 60,
            nextBytes: 41,
            limit: limit
        ))
        XCTAssertFalse(RemoteConnection.canEnqueueOutbound(
            pendingBytes: 0,
            nextBytes: Int.max,
            limit: limit
        ))
    }

    // MARK: - Reassembly

    func testFragmentedMessageReassembles() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        XCTAssertEqual(
            reassembler.accept(.init(fin: false, opcode: .text, payload: Data("Hel".utf8))),
            .buffered
        )
        XCTAssertEqual(
            reassembler.accept(.init(fin: true, opcode: .continuation, payload: Data("lo".utf8))),
            .message(.text(Data("Hello".utf8)))
        )
    }

    func testControlFrameInterleavesWithoutDisturbingReassembly() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        _ = reassembler.accept(.init(fin: false, opcode: .text, payload: Data("Hel".utf8)))
        XCTAssertEqual(
            reassembler.accept(.init(fin: true, opcode: .ping, payload: Data("ping".utf8))),
            .message(.ping(Data("ping".utf8)))
        )
        XCTAssertEqual(
            reassembler.accept(.init(fin: true, opcode: .continuation, payload: Data("lo".utf8))),
            .message(.text(Data("Hello".utf8)))
        )
    }

    func testContinuationWithNoMessageIsAProtocolError() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        guard case .protocolError(let code, _) =
            reassembler.accept(.init(fin: true, opcode: .continuation, payload: Data())) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
    }

    func testNewDataFrameDuringFragmentationIsAProtocolError() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        _ = reassembler.accept(.init(fin: false, opcode: .text, payload: Data("Hel".utf8)))
        guard case .protocolError =
            reassembler.accept(.init(fin: true, opcode: .binary, payload: Data("x".utf8))) else {
            return XCTFail("expected a protocol error")
        }
    }

    func testReassemblyRefusesAMessagePastItsCap() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 4)
        guard case .protocolError(let code, _) =
            reassembler.accept(.init(fin: true, opcode: .text, payload: Data("Hello".utf8))) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.messageTooBig)
    }

    func testTextMessageMustBeValidUTF8() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        guard case .protocolError(let code, _) = reassembler.accept(
            .init(fin: true, opcode: .text, payload: Data([0xC3, 0x28]))
        ) else {
            return XCTFail("expected invalid payload data")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.invalidPayloadData)
    }

    func testClosePayloadCannotContainOnlyOneCodeByte() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        guard case .protocolError(let code, _) = reassembler.accept(
            .init(fin: true, opcode: .close, payload: Data([0x03]))
        ) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
    }

    func testClosePayloadRejectsReservedWireCode() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        guard case .protocolError(let code, _) = reassembler.accept(
            .init(fin: true, opcode: .close, payload: Data([0x03, 0xED])) // 1005
        ) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
    }

    func testValidClosePayloadPassesThroughForEcho() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        let payload = Data([0x03, 0xE8]) + Data("done".utf8)
        XCTAssertEqual(
            reassembler.accept(.init(fin: true, opcode: .close, payload: payload)),
            .message(.close(payload))
        )
    }

    // MARK: - Helpers

    private func decode(_ bytes: [UInt8]) -> RemoteWebSocket.DecodeOutcome {
        RemoteWebSocket.decodeFrame(from: Data(bytes), maximumPayload: RemoteAccessDefaults.maximumFrameBytes)
    }
}
