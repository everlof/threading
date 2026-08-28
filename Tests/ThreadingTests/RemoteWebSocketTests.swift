import XCTest
@testable import Threading

/// RFC 6455 conformance for the hand-rolled WebSocket codec. The vectors are the standard's
/// own §1.3 / §5.7 examples, so a regression here is measured against the spec rather than
/// against our own idea of it.
final class RemoteWebSocketTests: XCTestCase {

    func testDecoderAcceptsANonZeroBasedCursorSlice() {
        let prefix = Data([0xFF, 0xFE, 0xFD])
        let maskedEmptyPing = Data([0x89, 0x80, 0, 0, 0, 0])
        let storage = prefix + maskedEmptyPing

        guard case .frame(let frame, let consumed) = RemoteWebSocket.decodeFrame(
            from: storage[prefix.count...],
            maximumPayload: RemoteAccessDefaults.maximumFrameBytes
        ) else {
            return XCTFail("the decoder did not accept a cursor slice")
        }

        XCTAssertEqual(frame.opcode, .ping)
        XCTAssertTrue(frame.payload.isEmpty)
        XCTAssertEqual(consumed, maskedEmptyPing.count)
    }

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
        XCTAssertEqual(reassembler.bufferedByteCount, 0, "the refused opening frame was retained")
    }

    func testReassemblyRefusesAContinuationBeforeItCrossesTheCap() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 4)
        XCTAssertEqual(
            reassembler.accept(.init(
                fin: false,
                opcode: .text,
                payload: Data("123".utf8)
            )),
            .buffered
        )

        guard case .protocolError(let code, _) = reassembler.accept(.init(
            fin: true,
            opcode: .continuation,
            payload: Data("45".utf8)
        )) else {
            return XCTFail("expected a protocol error")
        }

        XCTAssertEqual(code, RemoteWebSocket.CloseCode.messageTooBig)
        XCTAssertEqual(
            reassembler.bufferedByteCount,
            3,
            "the refused fragment entered the buffer before its admission check"
        )
    }

    func testFragmentedMessageAtTheCapReassembles() {
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 4)
        XCTAssertEqual(
            reassembler.accept(.init(
                fin: false,
                opcode: .text,
                payload: Data("12".utf8)
            )),
            .buffered
        )
        XCTAssertEqual(
            reassembler.accept(.init(
                fin: true,
                opcode: .continuation,
                payload: Data("34".utf8)
            )),
            .message(.text(Data("1234".utf8)))
        )
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

    // MARK: - Malformed framing

    /// RSV1/2/3 signal an extension. This codec negotiates none, so a frame that sets any of
    /// them means the peer is speaking something we did not agree to.
    func testReservedBitsAreRefused() {
        for reserved: UInt8 in [0x40, 0x20, 0x10, 0x70] {
            guard case .protocolError(let code, _) = decode([0x80 | reserved | 0x01, 0x80, 0, 0, 0, 0]) else {
                return XCTFail("RSV bits \(reserved) should be a protocol error")
            }
            XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
        }
    }

    /// 0x3–0x7 are reserved data opcodes and 0xB–0xF reserved control opcodes. None may be
    /// guessed at — an unknown opcode is a framing error, not a frame to skip.
    func testReservedOpcodesAreRefused() {
        for opcode: UInt8 in [0x3, 0x4, 0x5, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF] {
            guard case .protocolError(let code, _) = decode([0x80 | opcode, 0x80, 0, 0, 0, 0]) else {
                return XCTFail("opcode \(opcode) should be a protocol error")
            }
            XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
        }
    }

    /// RFC 6455 §5.5: a control frame may not be fragmented, and may not exceed 125 bytes.
    /// Both are checked before the payload is waited on.
    func testControlFramesMayNotBeFragmentedOrOversized() {
        for control: UInt8 in [0x8, 0x9, 0xA] {
            // FIN clear on a control frame.
            guard case .protocolError(let fragmented, _) = decode([control, 0x80, 0, 0, 0, 0]) else {
                return XCTFail("a fragmented control frame should be refused")
            }
            XCTAssertEqual(fragmented, RemoteWebSocket.CloseCode.protocolError)

            // 126 bytes declared through the 16-bit form — one past the control limit.
            guard case .protocolError(let oversized, _) =
                decode([0x80 | control, 0x80 | 126, 0x00, 0x7E]) else {
                return XCTFail("an oversized control frame should be refused")
            }
            XCTAssertEqual(oversized, RemoteWebSocket.CloseCode.protocolError)
        }

        // Exactly 125 is legal, and is the boundary the two checks meet at.
        var atLimit: [UInt8] = [0x89, 0x80 | 125, 0, 0, 0, 0]
        atLimit.append(contentsOf: [UInt8](repeating: 0, count: 125))
        guard case .frame(let frame, _) = decode(atLimit) else {
            return XCTFail("a 125-byte ping is within the control limit")
        }
        XCTAssertEqual(frame.opcode, .ping)
        XCTAssertEqual(frame.payload.count, 125)
    }

    /// RFC 6455 §5.2: the high bit of a 64-bit length must be 0. Read as signed it would be a
    /// negative count, which is the shape of every length-field bug worth having a test for.
    func testSixtyFourBitLengthWithTheHighBitSetIsRefused() {
        let bytes: [UInt8] = [0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0x01]
        guard case .protocolError(let code, _) = decode(bytes) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
    }

    /// A declared length that is merely enormous, rather than malformed, is refused as too big
    /// rather than buffered towards.
    func testAnEnormousDeclaredLengthIsRefusedAsTooBig() {
        let bytes: [UInt8] = [0x82, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        guard case .protocolError(let code, _) =
            RemoteWebSocket.decodeFrame(from: Data(bytes), maximumPayload: 1024) else {
            return XCTFail("expected a protocol error")
        }
        XCTAssertEqual(code, RemoteWebSocket.CloseCode.messageTooBig)
    }

    /// A zero-length masked frame is still a frame: the mask key is present and consumed, and
    /// the payload is empty rather than the decode being reported incomplete forever.
    func testAnEmptyMaskedFrameDecodesAndConsumesItsMaskKey() {
        guard case .frame(let frame, let consumed) = decode([0x81, 0x80, 0xAA, 0xBB, 0xCC, 0xDD]) else {
            return XCTFail("expected a decoded frame")
        }
        XCTAssertEqual(consumed, 6)
        XCTAssertTrue(frame.payload.isEmpty)
        XCTAssertEqual(frame.opcode, .text)
    }

    /// An all-zero mask key is legal and leaves the payload as-is — which is the one key that
    /// makes a "masked twice" or "never unmasked" bug invisible, so it is pinned deliberately
    /// alongside the non-trivial key the §5.7 vector uses.
    func testAnAllZeroMaskKeyLeavesThePayloadUnchanged() {
        var bytes: [UInt8] = [0x81, 0x80 | 5, 0, 0, 0, 0]
        bytes.append(contentsOf: Array("Hello".utf8))
        guard case .frame(let frame, _) = decode(bytes) else {
            return XCTFail("expected a decoded frame")
        }
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "Hello")
    }

    // MARK: - Close codes at their boundaries

    /// The close-code validator is a range test, and every one of these sits one step either
    /// side of an edge of it. 1015 is the one that matters most: it is assigned (TLS handshake
    /// failure) but must never appear on the wire, and it is adjacent to the top of the
    /// allowed 1000–1014 band.
    func testCloseCodeRangeEdges() {
        func outcome(_ code: UInt16) -> RemoteWebSocket.Reassembler.Outcome {
            var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
            let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
            return reassembler.accept(.init(fin: true, opcode: .close, payload: payload))
        }

        for accepted: UInt16 in [1000, 1001, 1014, 3000, 4999] {
            guard case .message(.close) = outcome(accepted) else {
                return XCTFail("\(accepted) is a close code a peer may send")
            }
        }

        for refused: UInt16 in [0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000, 65535] {
            guard case .protocolError(let code, _) = outcome(refused) else {
                return XCTFail("\(refused) must never be accepted from the wire")
            }
            XCTAssertEqual(code, RemoteWebSocket.CloseCode.protocolError)
        }
    }

    /// The encoder must not emit a control frame its own decoder would refuse. A long reason is
    /// cut to fit, on a character boundary so the payload stays valid UTF-8 — a byte-wise cut
    /// would split a scalar and produce exactly the malformed close this guards against.
    func testALongCloseReasonIsTrimmedToALegalControlFrame() {
        let data = RemoteWebSocket.closeFrame(
            code: RemoteWebSocket.CloseCode.policyViolation,
            reason: String(repeating: "é", count: 400)
        )

        let payloadLength = Int(data[data.startIndex + 1])
        XCTAssertLessThanOrEqual(payloadLength, RemoteWebSocket.maximumControlPayload)
        XCTAssertEqual(data.count, 2 + payloadLength)

        let payload = data.dropFirst(2)
        XCTAssertNotNil(
            String(data: payload.dropFirst(2), encoding: .utf8),
            "the reason was cut through a UTF-8 scalar"
        )

        // And the codec accepts what it produced, which is the property that actually matters.
        var reassembler = RemoteWebSocket.Reassembler(maximumBytes: 1024)
        guard case .message(.close) = reassembler.accept(
            .init(fin: true, opcode: .close, payload: Data(payload))
        ) else {
            return XCTFail("the codec emitted a close frame it will not accept")
        }
    }

    /// A short reason is passed through untouched, so the trim cannot quietly cost detail.
    func testAShortCloseReasonSurvivesIntact() {
        let data = RemoteWebSocket.closeFrame(code: RemoteWebSocket.CloseCode.protocolError, reason: "Unknown opcode")
        XCTAssertEqual(String(decoding: data.dropFirst(4), as: UTF8.self), "Unknown opcode")
    }

    // MARK: - Helpers

    private func decode(_ bytes: [UInt8]) -> RemoteWebSocket.DecodeOutcome {
        RemoteWebSocket.decodeFrame(from: Data(bytes), maximumPayload: RemoteAccessDefaults.maximumFrameBytes)
    }
}
