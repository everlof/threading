import Foundation

/// The sizes and bounds of the PTY-host wire header. One namespace so neither end can pick a
/// different number and discover it three frames later.
public enum PTYHostFramingDefaults {

    /// `[u8 kind][u8 flags][u16 reserved][u32 length]`, little-endian throughout.
    ///
    /// Little-endian because both ends are arm64 and the header is read far more often than it
    /// is looked at by a person; network byte order would buy nothing and cost a swap per frame.
    public static let headerBytes = 8

    /// The largest payload a single frame may carry.
    ///
    /// Matched to `RemoteAccessDefaults.maximumFrameBytes` on purpose: the same terminal bytes
    /// cross both transports, so a burst that the remote mirror accepts must not be one the host
    /// link refuses. It is also the decoder's memory bound — see `PTYHostFrameDecoder`.
    public static let maximumPayloadBytes = 1 * 1024 * 1024

    /// `flags` bit 0 is reserved for the `[tag][payload]` compression byte in
    /// `docs/decisions/compressed-terminal-mirror.md` §4. Nothing sets it today; the framing
    /// layer carries `flags` through untouched so turning compression on later is a change in
    /// one consumer rather than a change to the header.
    public static let compressionFlag: UInt8 = 0x01

    /// The offset of the `length` field inside the header.
    static let lengthOffset = 4
}

/// What the payload of a frame is, which is also the `kind` byte on the wire.
///
/// Control frames are JSON so they are `Codable`, versionable and testable; bulk terminal bytes
/// travel outside JSON so the hot path pays no base64 tax. Input and output are separate kinds
/// rather than one "bytes" kind with a direction field, because the direction is already known
/// from the socket and a mislabelled frame should not be able to be *decoded* as the other one.
public enum PTYHostFrameKind: UInt8, Equatable, Sendable, CaseIterable {
    /// A JSON `PTYHostFrame`.
    case control = 0
    /// Raw PTY output, daemon to app. No envelope, no id: a connection is attached to one
    /// session at a time and the stream is ordered.
    case output = 1
    /// Raw input bytes, app to daemon.
    case input = 2
}

/// One complete frame, header already stripped.
public struct PTYHostWireFrame: Equatable, Sendable {
    public let kind: PTYHostFrameKind
    public let flags: UInt8
    public let payload: Data

    public init(kind: PTYHostFrameKind, flags: UInt8 = 0, payload: Data) {
        self.kind = kind
        self.flags = flags
        self.payload = payload
    }
}

/// Why a byte stream stopped being a conversation.
///
/// Both cases mean the same thing to the caller — **close this connection** — and neither means
/// anything else. A frame that cannot be believed is not skipped and not defaulted: once the
/// length or the kind is wrong there is no way to find the next header, so continuing would be
/// reading arbitrary payload bytes as a header. They are structural tokens rather than sentences
/// so a journal can group by cause; the daemon closes the one connection and stays up (D12).
public enum PTYHostFramingRefusal: Error, Equatable, Sendable {
    /// A header declared a payload larger than `maximumPayloadBytes`. Refused from the header
    /// alone, before a single payload byte is buffered — a cap on what is delivered is not a cap
    /// on what is read.
    case oversizePayload(length: UInt32)
    /// A `kind` byte this build has no meaning for. A future kind is additive on the sending
    /// side only once both ends know it, so meeting one here is a peer that should not have been
    /// admitted — `PTYHostProtocol.evaluate` is the gate that is supposed to catch it first.
    case unknownKind(UInt8)
}

// MARK: - Encoding

public enum PTYHostFraming {

    /// Frames one payload for the wire.
    ///
    /// Oversize is refused on the way *out* as well, and typed the same way, because the only
    /// alternatives are truncating (a silently corrupt stream) or trapping (a daemon that a
    /// large repaint can kill).
    public static func encode(
        kind: PTYHostFrameKind,
        flags: UInt8 = 0,
        payload: Data
    ) throws -> Data {
        guard payload.count <= PTYHostFramingDefaults.maximumPayloadBytes else {
            throw PTYHostFramingRefusal.oversizePayload(length: UInt32(clamping: payload.count))
        }
        var out = Data(capacity: PTYHostFramingDefaults.headerBytes + payload.count)
        out.append(kind.rawValue)
        out.append(flags)
        // The reserved pair is written as zero and ignored on the way in, so a later build may
        // give it a meaning without every earlier build refusing the frame.
        out.append(0)
        out.append(0)
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(payload)
        return out
    }

    public static func encode(_ frame: PTYHostWireFrame) throws -> Data {
        try encode(kind: frame.kind, flags: frame.flags, payload: frame.payload)
    }
}

// MARK: - Incremental decoding

/// Reassembles frames from a `SOCK_STREAM` unix socket, which has no message boundaries of its
/// own.
///
/// This is the whole reason the framing exists. The remote mirror could lean on WebSocket
/// framing and in-order delivery; a raw stream socket hands over whatever the kernel had, so a
/// frame arrives split across three reads as readily as two frames arrive in one. `accept`
/// therefore takes *bytes*, not frames, and answers with however many complete frames those
/// bytes finished — nought, one, or several.
///
/// **Memory bound.** The decoder holds at most one header plus one maximum payload: a length
/// past `maximumPayloadBytes` is refused the moment the 8 header bytes are in hand, so a hostile
/// or broken peer cannot make the buffer grow by declaring a huge frame and then going quiet.
///
/// **Refusal is terminal.** After a refusal the decoder stays refused and every later `accept`
/// answers the same way. There is no resynchronisation point in a length-prefixed stream, so
/// "skip this frame and carry on" would mean guessing where the next header starts.
public struct PTYHostFrameDecoder: Sendable {

    /// What a read of bytes produced.
    public enum Outcome: Equatable, Sendable {
        /// Zero or more complete frames, in arrival order. Empty means the bytes were a partial
        /// frame and more are needed — not an error, and not something to report.
        case frames([PTYHostWireFrame])
        /// The connection must close. Every subsequent `accept` repeats this.
        case refused(PTYHostFramingRefusal)
    }

    private let maximumPayloadBytes: Int
    private var buffer = Data()
    private var refusal: PTYHostFramingRefusal?

    public init(maximumPayloadBytes: Int = PTYHostFramingDefaults.maximumPayloadBytes) {
        precondition(maximumPayloadBytes > 0, "A frame decoder needs a positive payload bound")
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// True once a refusal has been raised; the caller has closed, or is about to.
    public var isRefused: Bool { refusal != nil }

    /// Bytes held for a frame that has not finished arriving. Bounded by construction.
    public var bufferedBytes: Int { buffer.count }

    public mutating func accept(_ incoming: Data) -> Outcome {
        if let refusal { return .refused(refusal) }
        if !incoming.isEmpty { buffer.append(incoming) }

        // The buffer is consumed with a cursor and compacted once at the end rather than once
        // per frame. A `removeFirst` inside the loop is a memmove of everything still buffered,
        // and a read that finished several frames would pay it several times over — on the hot
        // path, for a terminal's output.
        var frames: [PTYHostWireFrame] = []
        var cursor = buffer.startIndex
        while true {
            let available = buffer.endIndex - cursor
            guard available >= PTYHostFramingDefaults.headerBytes else { break }

            let kindByte = buffer[cursor]
            let flags = buffer[cursor + 1]
            let lengthStart = cursor + PTYHostFramingDefaults.lengthOffset
            let length = UInt32(buffer[lengthStart])
                | UInt32(buffer[lengthStart + 1]) << 8
                | UInt32(buffer[lengthStart + 2]) << 16
                | UInt32(buffer[lengthStart + 3]) << 24

            // Length before kind: a 2 GiB length with a valid kind is the frame that must never
            // be buffered, and it is also the cheaper of the two checks to state first.
            guard length <= UInt32(maximumPayloadBytes) else {
                return refuse(.oversizePayload(length: length))
            }
            guard let kind = PTYHostFrameKind(rawValue: kindByte) else {
                return refuse(.unknownKind(kindByte))
            }

            let total = PTYHostFramingDefaults.headerBytes + Int(length)
            guard available >= total else { break }

            let payloadStart = cursor + PTYHostFramingDefaults.headerBytes
            let payload = Data(buffer[payloadStart..<(cursor + total)])
            frames.append(PTYHostWireFrame(kind: kind, flags: flags, payload: payload))
            cursor += total
        }

        if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
        return .frames(frames)
    }

    /// A refusal discards whatever was still buffered: those bytes belong to a stream nobody is
    /// going to read again. Frames already completed earlier in this same read are dropped with
    /// them — the caller is closing the connection, so handing back half a read would only
    /// invite acting on it.
    private mutating func refuse(_ reason: PTYHostFramingRefusal) -> Outcome {
        refusal = reason
        buffer = Data()
        return .refused(reason)
    }
}
