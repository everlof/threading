import Foundation

public enum ProtobufError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt8)
    case fieldTooLarge(Int)
}

/// The protobuf binary wire format, written by hand for the dozen emulator messages Threading
/// uses rather than through generated code and a runtime dependency. Unknown fields are skipped
/// on read, which is the forward-compatibility rule the emulator's own proto files rely on.
public struct ProtobufWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func varint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return } // proto3 omits defaults.
        tag(field, wireType: 0)
        Self.appendVarint(value, to: &bytes)
    }

    public mutating func int32(_ field: Int, _ value: Int32) {
        // Negative int32 is sign-extended to ten bytes on the wire.
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    public mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }

    public mutating func double(_ field: Int, _ value: Double) {
        guard value != 0 else { return }
        tag(field, wireType: 1)
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
    }

    public mutating func float(_ field: Int, _ value: Float) {
        guard value != 0 else { return }
        tag(field, wireType: 5)
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
    }

    public mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        lengthDelimited(field, Array(value.utf8))
    }

    public mutating func message(_ field: Int, _ value: ProtobufWriter) {
        lengthDelimited(field, value.bytes, keepEmpty: true)
    }

    public mutating func lengthDelimited(_ field: Int, _ value: [UInt8], keepEmpty: Bool = false) {
        guard keepEmpty || !value.isEmpty else { return }
        tag(field, wireType: 2)
        Self.appendVarint(UInt64(value.count), to: &bytes)
        bytes.append(contentsOf: value)
    }

    private mutating func tag(_ field: Int, wireType: UInt8) {
        Self.appendVarint(UInt64(field) << 3 | UInt64(wireType), to: &bytes)
    }

    static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var remainder = value
        while remainder >= 0x80 {
            bytes.append(UInt8(remainder & 0x7F) | 0x80)
            remainder >>= 7
        }
        bytes.append(UInt8(remainder))
    }
}

public enum ProtobufValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case lengthDelimited([UInt8])
    case fixed32(UInt32)

    public var uint64: UInt64 {
        switch self {
        case .varint(let value), .fixed64(let value): return value
        case .fixed32(let value): return UInt64(value)
        case .lengthDelimited: return 0
        }
    }

    public var int32: Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: uint64)) }
    public var uint32: UInt32 { UInt32(truncatingIfNeeded: uint64) }
    public var bool: Bool { uint64 != 0 }

    public var double: Double {
        if case .fixed64(let value) = self { return Double(bitPattern: value) }
        return 0
    }

    public var bytes: [UInt8] {
        if case .lengthDelimited(let value) = self { return value }
        return []
    }

    public var string: String { String(decoding: bytes, as: UTF8.self) }
}

/// Reads a message as `(field, value)` pairs. A length-delimited field is bounded by the
/// enclosing message, which the gRPC layer has already bounded.
public struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public mutating func next() throws -> (field: Int, value: ProtobufValue)? {
        guard offset < bytes.count else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch UInt8(key & 0x7) {
        case 0: return (field, .varint(try readVarint()))
        case 1:
            let raw = try take(8)
            return (field, .fixed64(raw.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else { throw ProtobufError.truncated }
            return (field, .lengthDelimited(try take(Int(length))))
        case 5:
            let raw = try take(4)
            return (field, .fixed32(raw.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }))
        case let wireType:
            throw ProtobufError.unsupportedWireType(wireType)
        }
    }

    /// Every field, for messages small enough to read whole.
    public static func fields(_ bytes: [UInt8]) throws -> [(field: Int, value: ProtobufValue)] {
        var reader = ProtobufReader(bytes)
        var result: [(field: Int, value: ProtobufValue)] = []
        while let entry = try reader.next() { result.append(entry) }
        return result
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw ProtobufError.truncated }
            let byte = bytes[offset]
            offset += 1
            guard shift < 64 else { throw ProtobufError.malformedVarint }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    private mutating func take(_ count: Int) throws -> [UInt8] {
        guard count <= bytes.count - offset else { throw ProtobufError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
