import Foundation

/// The HTTP/2 frame types this client speaks (RFC 9113 §6). PRIORITY and PUSH_PROMISE are parsed
/// only far enough to be ignored or refused.
public enum HTTP2FrameType: UInt8, Sendable {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case resetStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goAway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

public enum HTTP2Flag {
    public static let endStream: UInt8 = 0x1
    public static let ack: UInt8 = 0x1
    public static let endHeaders: UInt8 = 0x4
    public static let padded: UInt8 = 0x8
    public static let priority: UInt8 = 0x20
}

public enum HTTP2SettingsIdentifier: UInt16, Sendable {
    case headerTableSize = 0x1
    case enablePush = 0x2
    case maxConcurrentStreams = 0x3
    case initialWindowSize = 0x4
    case maxFrameSize = 0x5
    case maxHeaderListSize = 0x6
}

public struct HTTP2Frame: Equatable, Sendable {
    /// Every frame starts with this many octets.
    public static let headerLength = 9
    public static let defaultMaximumFrameSize = 16_384
    public static let largestMaximumFrameSize = 16_777_215

    public let rawType: UInt8
    public let flags: UInt8
    public let streamID: UInt32
    public let payload: [UInt8]

    public init(type: HTTP2FrameType, flags: UInt8 = 0, streamID: UInt32, payload: [UInt8] = []) {
        self.rawType = type.rawValue
        self.flags = flags
        self.streamID = streamID & 0x7FFF_FFFF
        self.payload = payload
    }

    init(rawType: UInt8, flags: UInt8, streamID: UInt32, payload: [UInt8]) {
        self.rawType = rawType
        self.flags = flags
        self.streamID = streamID & 0x7FFF_FFFF
        self.payload = payload
    }

    public var type: HTTP2FrameType? { HTTP2FrameType(rawValue: rawType) }

    public func hasFlag(_ flag: UInt8) -> Bool { flags & flag != 0 }

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.headerLength + payload.count)
        let length = UInt32(payload.count)
        bytes.append(UInt8((length >> 16) & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(rawType)
        bytes.append(flags)
        bytes.append(contentsOf: BigEndian.bytes(streamID))
        bytes.append(contentsOf: payload)
        return bytes
    }
}

/// Splits an inbound byte stream into frames, refusing any frame larger than the size this
/// endpoint advertised before the payload is buffered.
public struct HTTP2FrameReader: Sendable {
    private var buffer: [UInt8] = []
    private var consumed = 0
    public var maximumFrameSize: Int

    public init(maximumFrameSize: Int = HTTP2Frame.defaultMaximumFrameSize) {
        self.maximumFrameSize = maximumFrameSize
    }

    public mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    public mutating func nextFrame() throws -> HTTP2Frame? {
        let available = buffer.count - consumed
        guard available >= HTTP2Frame.headerLength else { compact(); return nil }
        let base = consumed
        let length = Int(buffer[base]) << 16 | Int(buffer[base + 1]) << 8 | Int(buffer[base + 2])
        guard length <= maximumFrameSize else { throw HTTP2Error.frameTooLarge(length) }
        guard available >= HTTP2Frame.headerLength + length else { compact(); return nil }
        let streamID = BigEndian.uint32(buffer, at: base + 5) & 0x7FFF_FFFF
        let payloadStart = base + HTTP2Frame.headerLength
        let frame = HTTP2Frame(
            rawType: buffer[base + 3], flags: buffer[base + 4], streamID: streamID,
            payload: Array(buffer[payloadStart..<(payloadStart + length)])
        )
        consumed = payloadStart + length
        return frame
    }

    private mutating func compact() {
        guard consumed > 0 else { return }
        buffer.removeFirst(consumed)
        consumed = 0
    }
}

public enum HTTP2Error: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case protocolError(String)
    case flowControl(String)
    case streamClosed(UInt32)
    case connectionClosed(errorCode: UInt32)
    case tooManyStreams
}

enum BigEndian {
    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
