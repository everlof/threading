import Foundation

public enum SimulatorBridgeFramingDefaults {
    public static let headerBytes = 8
    public static let maximumControlBytes = 256 * 1024
    public static let maximumMediaBytes = 8 * 1024 * 1024
    public static let maximumBufferedBytes = maximumMediaBytes + headerBytes
}

public enum SimulatorBridgeFrameKind: UInt8, Equatable, Sendable {
    case control = 0
    case media = 1
}

public struct SimulatorBridgeWireFrame: Equatable, Sendable {
    public let kind: SimulatorBridgeFrameKind
    public let payload: Data

    public init(kind: SimulatorBridgeFrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

public enum SimulatorBridgeFramingError: Error, Equatable, Sendable {
    case oversized(kind: SimulatorBridgeFrameKind, length: UInt32)
    case unknownKind(UInt8)
    case malformedMedia
}

public enum SimulatorBridgeFraming {
    public static func encode(kind: SimulatorBridgeFrameKind, payload: Data) throws -> Data {
        let maximum = kind == .control
            ? SimulatorBridgeFramingDefaults.maximumControlBytes
            : SimulatorBridgeFramingDefaults.maximumMediaBytes
        guard payload.count <= maximum else {
            throw SimulatorBridgeFramingError.oversized(
                kind: kind,
                length: UInt32(clamping: payload.count)
            )
        }
        var output = Data(capacity: SimulatorBridgeFramingDefaults.headerBytes + payload.count)
        output.append(kind.rawValue)
        output.append(contentsOf: [0, 0, 0])
        append(UInt32(payload.count), to: &output)
        output.append(payload)
        return output
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

public struct SimulatorBridgeFrameDecoder: Sendable {
    public enum Outcome: Equatable, Sendable {
        case frames([SimulatorBridgeWireFrame])
        case refused(SimulatorBridgeFramingError)
    }

    private var buffer = Data()
    private var refusal: SimulatorBridgeFramingError?

    public init() {}

    public var bufferedBytes: Int { buffer.count }

    public mutating func accept(_ bytes: Data) -> Outcome {
        if let refusal { return .refused(refusal) }
        buffer.append(bytes)
        var frames: [SimulatorBridgeWireFrame] = []
        var cursor = buffer.startIndex
        while buffer.endIndex - cursor >= SimulatorBridgeFramingDefaults.headerBytes {
            let rawKind = buffer[cursor]
            guard let kind = SimulatorBridgeFrameKind(rawValue: rawKind) else {
                return refuse(.unknownKind(rawKind))
            }
            let lengthStart = cursor + 4
            let length = UInt32(buffer[lengthStart])
                | UInt32(buffer[lengthStart + 1]) << 8
                | UInt32(buffer[lengthStart + 2]) << 16
                | UInt32(buffer[lengthStart + 3]) << 24
            let maximum = kind == .control
                ? SimulatorBridgeFramingDefaults.maximumControlBytes
                : SimulatorBridgeFramingDefaults.maximumMediaBytes
            guard length <= maximum else {
                return refuse(.oversized(kind: kind, length: length))
            }
            let total = SimulatorBridgeFramingDefaults.headerBytes + Int(length)
            guard buffer.endIndex - cursor >= total else { break }
            let start = cursor + SimulatorBridgeFramingDefaults.headerBytes
            frames.append(SimulatorBridgeWireFrame(
                kind: kind,
                payload: Data(buffer[start..<(cursor + total)])
            ))
            cursor += total
        }
        if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
        return .frames(frames)
    }

    private mutating func refuse(_ error: SimulatorBridgeFramingError) -> Outcome {
        refusal = error
        buffer.removeAll(keepingCapacity: false)
        return .refused(error)
    }
}
