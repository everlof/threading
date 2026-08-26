import Foundation

public struct SimulatorBridgeMediaFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeNanoseconds: UInt64
    public let width: UInt32
    public let height: UInt32
    public let codec: SimulatorBridgeCodec
    public let isKeyFrame: Bool
    /// H.264 parameter sets, encoded as `[u16 sps length][sps][u16 pps length][pps]`.
    public let codecConfiguration: Data
    public let bytes: Data

    public init(
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        width: UInt32,
        height: UInt32,
        codec: SimulatorBridgeCodec,
        isKeyFrame: Bool,
        codecConfiguration: Data = Data(),
        bytes: Data
    ) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.width = width
        self.height = height
        self.codec = codec
        self.isKeyFrame = isKeyFrame
        self.codecConfiguration = codecConfiguration
        self.bytes = bytes
    }

    public func encode() throws -> Data {
        guard width > 0, height > 0,
              codecConfiguration.count <= UInt16.max else {
            throw SimulatorBridgeFramingError.malformedMedia
        }
        var data = Data(capacity: 32 + codecConfiguration.count + bytes.count)
        append(sequence, to: &data)
        append(presentationTimeNanoseconds, to: &data)
        append(width, to: &data)
        append(height, to: &data)
        data.append(codec.rawValue)
        data.append(isKeyFrame ? 1 : 0)
        append(UInt16(codecConfiguration.count), to: &data)
        data.append(codecConfiguration)
        data.append(bytes)
        guard data.count <= SimulatorBridgeFramingDefaults.maximumMediaBytes else {
            throw SimulatorBridgeFramingError.oversized(
                kind: .media,
                length: UInt32(clamping: data.count)
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        let fixedBytes = 28
        guard data.count >= fixedBytes else { throw SimulatorBridgeFramingError.malformedMedia }
        let sequence = readUInt64(data, at: 0)
        let timestamp = readUInt64(data, at: 8)
        let width = readUInt32(data, at: 16)
        let height = readUInt32(data, at: 20)
        guard let codec = SimulatorBridgeCodec(rawValue: data[24]), width > 0, height > 0 else {
            throw SimulatorBridgeFramingError.malformedMedia
        }
        let configurationLength = Int(readUInt16(data, at: 26))
        let payloadStart = fixedBytes + configurationLength
        guard payloadStart <= data.count else { throw SimulatorBridgeFramingError.malformedMedia }
        return Self(
            sequence: sequence,
            presentationTimeNanoseconds: timestamp,
            width: width,
            height: height,
            codec: codec,
            isKeyFrame: data[25] == 1,
            codecConfiguration: Data(data[fixedBytes..<payloadStart]),
            bytes: Data(data[payloadStart...])
        )
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(into: UInt32(0)) { value, byte in
            value |= UInt32(data[offset + byte]) << UInt32(byte * 8)
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(into: UInt64(0)) { value, byte in
            value |= UInt64(data[offset + byte]) << UInt64(byte * 8)
        }
    }
}

public enum SimulatorBridgeH264Configuration {
    public static func encode(sequenceParameterSet: Data, pictureParameterSet: Data) throws -> Data {
        guard sequenceParameterSet.count <= UInt16.max,
              pictureParameterSet.count <= UInt16.max else {
            throw SimulatorBridgeFramingError.malformedMedia
        }
        var data = Data()
        append(UInt16(sequenceParameterSet.count), to: &data)
        data.append(sequenceParameterSet)
        append(UInt16(pictureParameterSet.count), to: &data)
        data.append(pictureParameterSet)
        return data
    }

    public static func decode(_ data: Data) throws -> (sequence: Data, picture: Data) {
        guard data.count >= 4 else { throw SimulatorBridgeFramingError.malformedMedia }
        let sequenceLength = Int(read(data, at: 0))
        let pictureLengthOffset = 2 + sequenceLength
        guard pictureLengthOffset + 2 <= data.count else {
            throw SimulatorBridgeFramingError.malformedMedia
        }
        let pictureLength = Int(read(data, at: pictureLengthOffset))
        guard pictureLengthOffset + 2 + pictureLength == data.count else {
            throw SimulatorBridgeFramingError.malformedMedia
        }
        return (
            Data(data[2..<(2 + sequenceLength)]),
            Data(data[(pictureLengthOffset + 2)...])
        )
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func read(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}
