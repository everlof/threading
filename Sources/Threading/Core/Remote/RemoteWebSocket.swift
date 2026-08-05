import Foundation
import CryptoKit

/// A hand-rolled RFC 6455 WebSocket, deliberately a **subset**: no extensions, no compression,
/// no server-side masking. The codebase already speaks hand-rolled HTTP/1.1 (`MCPConnection`),
/// so this is the same house style one layer up — and it keeps the one-dependency rule intact,
/// since `CryptoKit.Insecure.SHA1` is a system framework rather than a package.
///
/// Everything here is a **pure function on `Data`**. Framing is the classic bug farm (64-bit
/// lengths, fragmentation, control frames interleaved with data), so the codec is written to be
/// driven byte-by-byte from a test with no socket in sight — `RemoteConnection` is the only
/// thing that owns an `NWConnection`, and it calls into these functions.
enum RemoteWebSocket {

    /// The magic GUID from RFC 6455 §1.3, concatenated with the client key before hashing.
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// The most a control frame may carry (RFC 6455 §5.5). Enforced on the way in by
    /// `decodeFrame` and on the way out by `closeFrame`, so the two cannot disagree.
    static let maximumControlPayload = 125

    // MARK: - Opcodes

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        /// Control frames (close/ping/pong) have the high bit of the opcode set. They may never
        /// be fragmented and must carry no more than 125 bytes.
        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    /// Standard close codes used by this server.
    enum CloseCode {
        static let normal: UInt16 = 1000
        static let goingAway: UInt16 = 1001
        static let protocolError: UInt16 = 1002
        static let invalidPayloadData: UInt16 = 1007
        static let policyViolation: UInt16 = 1008
        static let messageTooBig: UInt16 = 1009
        static let tryAgainLater: UInt16 = 1013
    }

    // MARK: - Handshake

    /// The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`.
    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + acceptGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The raw bytes of a `101 Switching Protocols` response, or nil if the request is not a
    /// valid WebSocket upgrade. Kept separate from `HTTPResponse` because `serialized` there
    /// hard-codes `Content-Length`/`Connection: keep-alive`, neither of which a 101 may carry.
    static func upgradeResponseData(for request: HTTPRequest) -> Data? {
        guard request.method == "GET",
              request.header("upgrade")?.lowercased() == "websocket",
              request.header("connection")?
                .split(separator: ",")
                .contains(where: {
                    $0.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare("upgrade") == .orderedSame
                }) ?? false,
              request.header("sec-websocket-version") == "13",
              let key = request.header("sec-websocket-key"),
              let nonce = Data(base64Encoded: key),
              nonce.count == 16 else {
            return nil
        }

        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey(for: key))\r\n\r\n"
        return Data(head.utf8)
    }

    // MARK: - Frame model

    struct Frame: Equatable {
        let fin: Bool
        let opcode: Opcode
        let payload: Data
    }

    /// What one pass over the buffer found — mirrors `MCPConnection.ParseOutcome`: not-all-here,
    /// a frame with the byte count it consumed, or an unrecoverable framing error that must
    /// close the connection with a close code.
    enum DecodeOutcome: Equatable {
        case incomplete
        case frame(Frame, consumed: Int)
        case protocolError(closeCode: UInt16, reason: String)
    }

    /// Decodes one frame from the front of `buffer`. Client-to-server frames MUST be masked
    /// (RFC 6455 §5.1); an unmasked frame is a protocol error, not something to tolerate.
    ///
    /// Length limits are enforced *before* the payload is waited on, so an oversized declared
    /// length is refused the moment it is known rather than after buffering it.
    static func decodeFrame(from buffer: Data, maximumPayload: Int) -> DecodeOutcome {
        let count = buffer.count
        guard count >= 2 else { return .incomplete }

        let base = buffer.startIndex
        func byte(_ offset: Int) -> UInt8 { buffer[base + offset] }

        let b0 = byte(0)
        let b1 = byte(1)

        let fin = (b0 & 0x80) != 0
        guard (b0 & 0x70) == 0 else {
            return .protocolError(closeCode: CloseCode.protocolError, reason: "Reserved bits set")
        }
        guard let opcode = Opcode(rawValue: b0 & 0x0F) else {
            return .protocolError(closeCode: CloseCode.protocolError, reason: "Unknown opcode")
        }

        // A server accepts only masked frames from a client.
        guard (b1 & 0x80) != 0 else {
            return .protocolError(closeCode: CloseCode.protocolError, reason: "Client frame not masked")
        }

        var cursor = 2
        let len7 = Int(b1 & 0x7F)
        let payloadLength: Int

        if len7 < 126 {
            payloadLength = len7
        } else if len7 == 126 {
            guard count >= cursor + 2 else { return .incomplete }
            payloadLength = Int(byte(cursor)) << 8 | Int(byte(cursor + 1))
            cursor += 2
            guard payloadLength >= 126 else {
                return .protocolError(
                    closeCode: CloseCode.protocolError,
                    reason: "Non-minimal payload length"
                )
            }
        } else {
            guard count >= cursor + 8 else { return .incomplete }
            var value: UInt64 = 0
            for offset in 0..<8 { value = (value << 8) | UInt64(byte(cursor + offset)) }
            cursor += 8
            // The most significant bit of a 64-bit length must be 0 (RFC 6455 §5.2).
            guard value & 0x8000_0000_0000_0000 == 0 else {
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Length MSB set")
            }
            guard value > UInt64(UInt16.max) else {
                return .protocolError(
                    closeCode: CloseCode.protocolError,
                    reason: "Non-minimal payload length"
                )
            }
            guard value <= UInt64(maximumPayload) else {
                return .protocolError(closeCode: CloseCode.messageTooBig, reason: "Frame exceeds maximum")
            }
            payloadLength = Int(value)
        }

        if opcode.isControl {
            guard fin else {
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Fragmented control frame")
            }
            guard payloadLength <= maximumControlPayload else {
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Control frame too large")
            }
        }

        guard payloadLength <= maximumPayload else {
            return .protocolError(closeCode: CloseCode.messageTooBig, reason: "Frame exceeds maximum")
        }

        // Masking key (4 bytes) then the payload.
        guard count >= cursor + 4 else { return .incomplete }
        var maskKey = [UInt8](repeating: 0, count: 4)
        for offset in 0..<4 { maskKey[offset] = byte(cursor + offset) }
        cursor += 4

        guard count >= cursor + payloadLength else { return .incomplete }
        var payload = [UInt8](repeating: 0, count: payloadLength)
        for offset in 0..<payloadLength {
            payload[offset] = byte(cursor + offset) ^ maskKey[offset & 0x3]
        }
        cursor += payloadLength

        return .frame(Frame(fin: fin, opcode: opcode, payload: Data(payload)), consumed: cursor)
    }

    /// Encodes one server frame. Server frames are never masked (RFC 6455 §5.1).
    static func encodeFrame(opcode: Opcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue) // FIN set, single unfragmented frame.

        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            var value = UInt64(length)
            var bytes = [UInt8](repeating: 0, count: 8)
            for index in (0..<8).reversed() {
                bytes[index] = UInt8(value & 0xFF)
                value >>= 8
            }
            frame.append(contentsOf: bytes)
        }

        frame.append(payload)
        return frame
    }

    static func textFrame(_ text: String) -> Data { encodeFrame(opcode: .text, payload: Data(text.utf8)) }
    static func binaryFrame(_ data: Data) -> Data { encodeFrame(opcode: .binary, payload: data) }
    static func pingFrame(_ data: Data = Data()) -> Data { encodeFrame(opcode: .ping, payload: data) }
    static func pongFrame(_ data: Data = Data()) -> Data { encodeFrame(opcode: .pong, payload: data) }

    /// A close frame, with `reason` trimmed to what a control frame is allowed to carry.
    ///
    /// The trim is not decoration. `decodeFrame` refuses an inbound control frame over
    /// `maximumControlPayload`, and without this the encoder would happily emit one — Threading
    /// sending a frame its own decoder would close the connection over. Every reason passed here
    /// today is a short literal, so this bounds a public entry point before a longer one reaches
    /// it rather than fixing a live break.
    static func closeFrame(code: UInt16, reason: String = "") -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        payload.append(reasonFitting(reason, within: maximumControlPayload - 2))
        return encodeFrame(opcode: .close, payload: payload)
    }

    /// `reason` in UTF-8, cut to `budget` bytes on a character boundary.
    ///
    /// Counted per `Character` rather than per byte because a close reason must still be valid
    /// UTF-8 (`Reassembler.closePayloadError` checks exactly that on the way in) — slicing the
    /// bytes at 123 would leave a split scalar and produce the malformed payload this is meant
    /// to avoid.
    private static func reasonFitting(_ reason: String, within budget: Int) -> Data {
        var bytes = Data()
        for character in reason {
            let encoded = Data(String(character).utf8)
            guard bytes.count + encoded.count <= budget else { break }
            bytes.append(encoded)
        }
        return bytes
    }

    /// Echoes a validated peer close payload, as RFC 6455 recommends for the close handshake.
    static func closeFrame(payload: Data) -> Data {
        encodeFrame(opcode: .close, payload: payload)
    }

    // MARK: - Reassembly

    /// A completed application message, or a control frame that arrived between data fragments.
    enum Message: Equatable {
        case text(Data)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close(Data)
    }

    /// Folds a sequence of frames into messages, applying the fragmentation rules of RFC 6455
    /// §5.4. Control frames pass straight through and never disturb a message in flight.
    struct Reassembler {
        private let maximumBytes: Int
        private var messageOpcode: Opcode?
        private var buffer = Data()

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        enum Outcome: Equatable {
            /// A data fragment was buffered; nothing complete yet.
            case buffered
            case message(Message)
            case protocolError(closeCode: UInt16, reason: String)
        }

        mutating func accept(_ frame: Frame) -> Outcome {
            // Control frames are self-contained and may interleave with a fragmented message.
            if frame.opcode.isControl {
                switch frame.opcode {
                case .ping: return .message(.ping(frame.payload))
                case .pong: return .message(.pong(frame.payload))
                case .close:
                    if let error = Self.closePayloadError(frame.payload) { return error }
                    return .message(.close(frame.payload))
                default:
                    return .protocolError(closeCode: CloseCode.protocolError, reason: "Bad control frame")
                }
            }

            switch frame.opcode {
            case .text, .binary:
                guard messageOpcode == nil else {
                    return .protocolError(
                        closeCode: CloseCode.protocolError,
                        reason: "New data frame during fragmented message"
                    )
                }
                messageOpcode = frame.opcode
                buffer = frame.payload

            case .continuation:
                guard messageOpcode != nil else {
                    return .protocolError(
                        closeCode: CloseCode.protocolError,
                        reason: "Continuation with no message in progress"
                    )
                }
                buffer.append(frame.payload)

            default:
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Unexpected opcode")
            }

            guard buffer.count <= maximumBytes else {
                return .protocolError(closeCode: CloseCode.messageTooBig, reason: "Message exceeds maximum")
            }

            guard frame.fin else { return .buffered }

            let completed = messageOpcode
            let data = buffer
            messageOpcode = nil
            buffer = Data()

            switch completed {
            case .text:
                guard String(data: data, encoding: .utf8) != nil else {
                    return .protocolError(
                        closeCode: CloseCode.invalidPayloadData,
                        reason: "Text message is not UTF-8"
                    )
                }
                return .message(.text(data))
            case .binary: return .message(.binary(data))
            default:
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Unreachable message state")
            }
        }

        /// A close payload is empty or begins with a valid status code followed by UTF-8.
        /// A one-byte code and wire-reserved codes are protocol errors; malformed reason text is
        /// invalid payload data. Kept in the reassembler so `RemoteConnection` only ever sees a
        /// close frame safe to echo.
        private static func closePayloadError(_ payload: Data) -> Outcome? {
            guard !payload.isEmpty else { return nil }
            guard payload.count >= 2 else {
                return .protocolError(
                    closeCode: CloseCode.protocolError,
                    reason: "Close payload has a partial status code"
                )
            }

            let start = payload.startIndex
            let code = UInt16(payload[start]) << 8 | UInt16(payload[start + 1])
            let standard = (1000...1014).contains(code)
                && ![1004, 1005, 1006].contains(code)
            let privateUse = (3000...4999).contains(code)
            guard standard || privateUse else {
                return .protocolError(closeCode: CloseCode.protocolError, reason: "Invalid close code")
            }

            let reason = payload.dropFirst(2)
            guard String(data: reason, encoding: .utf8) != nil else {
                return .protocolError(
                    closeCode: CloseCode.invalidPayloadData,
                    reason: "Close reason is not UTF-8"
                )
            }
            return nil
        }
    }
}
