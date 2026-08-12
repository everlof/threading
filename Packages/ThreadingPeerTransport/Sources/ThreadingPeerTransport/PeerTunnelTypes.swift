import Foundation

public enum PeerTunnelBounds {
    public static let maximumStreams = 32
    public static let streamWindowBytes = 256 * 1_024
    public static let maximumBufferedChunksPerStream = 512
    public static let headerBytes = 12
    public static let maximumDataBytes = 48 * 1_024
    public static let streamOpenTimeout: TimeInterval = 10
    public static let flowControlTimeout: TimeInterval = 30
}

public enum PeerTunnelRole: Sendable {
    /// Opens logical streams, normally the iOS loopback proxy.
    case client
    /// Accepts logical streams and bridges them to the Mac's loopback remote server.
    case server
}

public enum PeerTunnelError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case closed
    case protocolViolation
    case unsupportedVersion(UInt8)
    case tooManyStreams(limit: Int)
    case unknownStream(UInt32)
    case streamNotOpen(UInt32)
    case streamClosed(UInt32)
    case writeTooLarge(actual: Int, limit: Int)
    case receiveWindowExceeded(streamID: UInt32, limit: Int)
    case receiveChunkLimitExceeded(streamID: UInt32, limit: Int)
    case invalidAcknowledgement(streamID: UInt32)
    case streamOpenTimedOut(UInt32)
    case flowControlTimedOut(UInt32)
    case transport(String)
}

extension PeerTunnelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notStarted:
            return "The peer tunnel has not started."
        case .alreadyStarted:
            return "The peer tunnel has already started."
        case .closed:
            return "The peer tunnel is closed."
        case .protocolViolation:
            return "The peer sent an invalid tunnel frame."
        case .unsupportedVersion(let version):
            return "The peer tunnel version \(version) is unsupported."
        case .tooManyStreams(let limit):
            return "The peer tunnel exceeded its \(limit)-stream limit."
        case .unknownStream(let streamID):
            return "The peer referenced unknown tunnel stream \(streamID)."
        case .streamNotOpen(let streamID):
            return "Tunnel stream \(streamID) is not open."
        case .streamClosed(let streamID):
            return "Tunnel stream \(streamID) is closed."
        case .writeTooLarge(let actual, let limit):
            return "The tunnel write was \(actual) bytes; the per-frame limit is \(limit)."
        case .receiveWindowExceeded(let streamID, let limit):
            return "Tunnel stream \(streamID) exceeded its \(limit)-byte receive window."
        case .receiveChunkLimitExceeded(let streamID, let limit):
            return "Tunnel stream \(streamID) exceeded its \(limit)-chunk receive limit."
        case .invalidAcknowledgement(let streamID):
            return "Tunnel stream \(streamID) acknowledged bytes it had not received."
        case .streamOpenTimedOut(let streamID):
            return "Tunnel stream \(streamID) was not accepted in time."
        case .flowControlTimedOut(let streamID):
            return "Tunnel stream \(streamID) did not replenish flow-control credit in time."
        case .transport(let message):
            return message
        }
    }
}

public protocol PeerMessageTransport: Sendable {
    func sendWhenWritable(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

extension WebRTCPeerTransport: PeerMessageTransport {}

struct PeerTunnelFrame: Equatable, Sendable {
    enum Operation: UInt8, Sendable {
        case open = 1
        case opened = 2
        case data = 3
        case window = 4
        case end = 5
        case reset = 6
    }

    static let magic: UInt16 = 0x5452
    static let version: UInt8 = 1

    let operation: Operation
    let streamID: UInt32
    let value: UInt32
    let payload: Data

    static func control(_ operation: Operation, streamID: UInt32) -> Self {
        Self(operation: operation, streamID: streamID, value: 0, payload: Data())
    }

    static func data(streamID: UInt32, payload: Data) -> Self {
        Self(
            operation: .data,
            streamID: streamID,
            value: UInt32(payload.count),
            payload: payload
        )
    }

    static func window(streamID: UInt32, bytes: Int) -> Self {
        Self(operation: .window, streamID: streamID, value: UInt32(bytes), payload: Data())
    }

    func encoded() throws -> Data {
        guard streamID != 0 else { throw PeerTunnelError.protocolViolation }
        switch operation {
        case .data:
            guard payload.count == Int(value),
                  payload.count <= PeerTunnelBounds.maximumDataBytes else {
                throw PeerTunnelError.protocolViolation
            }
        case .window:
            guard payload.isEmpty, value > 0,
                  value <= UInt32(PeerTunnelBounds.streamWindowBytes) else {
                throw PeerTunnelError.protocolViolation
            }
        case .open, .opened, .end, .reset:
            guard payload.isEmpty, value == 0 else {
                throw PeerTunnelError.protocolViolation
            }
        }

        var data = Data(capacity: PeerTunnelBounds.headerBytes + payload.count)
        data.appendInteger(Self.magic)
        data.append(Self.version)
        data.append(operation.rawValue)
        data.appendInteger(streamID)
        data.appendInteger(value)
        data.append(payload)
        return data
    }

    init(decoding data: Data) throws {
        guard data.count >= PeerTunnelBounds.headerBytes,
              data.count <= PeerTransportBounds.maximumMessageBytes,
              data.readUInt16(at: 0) == Self.magic,
              let operation = Operation(rawValue: data[3]) else {
            throw PeerTunnelError.protocolViolation
        }
        let version = data[2]
        guard version == Self.version else {
            throw PeerTunnelError.unsupportedVersion(version)
        }
        let streamID = data.readUInt32(at: 4)
        let value = data.readUInt32(at: 8)
        guard streamID != 0 else { throw PeerTunnelError.protocolViolation }
        let payload = Data(data.dropFirst(PeerTunnelBounds.headerBytes))

        self.init(operation: operation, streamID: streamID, value: value, payload: payload)
        _ = try encoded()
    }

    private init(operation: Operation, streamID: UInt32, value: UInt32, payload: Data) {
        self.operation = operation
        self.streamID = streamID
        self.value = value
        self.payload = payload
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}
