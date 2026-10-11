import Foundation

/// The subset of `android.emulation.control.EmulatorController` (the SDK's
/// `emulator/lib/emulator_controller.proto`) Threading drives, with each message hand-encoded at
/// its proto field numbers.
public enum EmulatorControlMethod: String, CaseIterable, Sendable {
    case getStatus
    case getScreenshot
    case streamScreenshot
    case sendTouch
    case sendKey
    case setPhysicalModel

    public static let service = "android.emulation.control.EmulatorController"

    public var path: String { "/\(Self.service)/\(rawValue)" }
}

public enum EmulatorImageFormat: UInt64, Sendable {
    case png = 0
    case rgba8888 = 1
    case rgb888 = 2

    public var bytesPerPixel: Int {
        switch self {
        case .png: return 0
        case .rgba8888: return 4
        case .rgb888: return 3
        }
    }
}

/// `Rotation.SkinRotation`: how the emulator has turned the delivered image.
public enum EmulatorSkinRotation: UInt64, Sendable, Equatable {
    case portrait = 0
    case landscape = 1
    case reversePortrait = 2
    case reverseLandscape = 3

    /// Clockwise quarter turns from the natural portrait orientation.
    public var quarterTurns: Int {
        switch self {
        case .portrait: return 0
        case .landscape: return 1
        case .reversePortrait: return 2
        case .reverseLandscape: return 3
        }
    }
}

public struct EmulatorScreenshotRequest: Equatable, Sendable {
    public var format: EmulatorImageFormat
    public var width: UInt32
    public var height: UInt32
    public var display: UInt32
    /// A `file://` URL of a region the emulator writes pixels into instead of the message.
    public var mmapHandle: String?

    public init(
        format: EmulatorImageFormat, width: UInt32 = 0, height: UInt32 = 0,
        display: UInt32 = 0, mmapHandle: String? = nil
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.display = display
        self.mmapHandle = mmapHandle
    }

    public func encoded() -> [UInt8] {
        var message = ProtobufWriter()
        message.varint(1, format.rawValue)
        message.varint(3, UInt64(width))
        message.varint(4, UInt64(height))
        message.varint(5, UInt64(display))
        if let mmapHandle {
            var transport = ProtobufWriter()
            transport.varint(1, 1) // MMAP
            transport.string(2, mmapHandle)
            message.message(6, transport)
        }
        return message.bytes
    }
}

public enum EmulatorDecodingError: Error, Equatable, Sendable {
    case unknownImageFormat(UInt64)
    case unknownRotation(UInt64)
}

public struct EmulatorImage: Equatable, Sendable {
    public let format: EmulatorImageFormat
    public let width: Int
    public let height: Int
    public let rotation: EmulatorSkinRotation
    /// Pixels, or empty when they were written to the MMAP region instead.
    public let pixels: [UInt8]
    public let sequence: UInt32
    public let timestampMicroseconds: UInt64

    public init(
        format: EmulatorImageFormat, width: Int, height: Int, rotation: EmulatorSkinRotation,
        pixels: [UInt8], sequence: UInt32, timestampMicroseconds: UInt64
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.rotation = rotation
        self.pixels = pixels
        self.sequence = sequence
        self.timestampMicroseconds = timestampMicroseconds
    }

    /// A display that is off or not yet posting frames reports a zero-sized image.
    public var isEmpty: Bool { width == 0 || height == 0 }

    public static func decode(_ bytes: [UInt8]) throws -> EmulatorImage {
        var format = EmulatorImageFormat.png
        var width = 0, height = 0
        var legacyWidth = 0, legacyHeight = 0
        var rotation = EmulatorSkinRotation.portrait
        var pixels: [UInt8] = []
        var sequence: UInt32 = 0
        var timestamp: UInt64 = 0
        var reader = ProtobufReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1:
                var formatReader = ProtobufReader(value.bytes)
                while let (formatField, formatValue) = try formatReader.next() {
                    switch formatField {
                    case 1:
                        // A format nobody modelled would be read as the wrong pixel layout.
                        guard let known = EmulatorImageFormat(rawValue: formatValue.uint64) else {
                            throw EmulatorDecodingError.unknownImageFormat(formatValue.uint64)
                        }
                        format = known
                    case 2:
                        var rotationReader = ProtobufReader(formatValue.bytes)
                        while let (rotationField, rotationValue) = try rotationReader.next() {
                            guard rotationField == 1 else { continue }
                            guard let known = EmulatorSkinRotation(rawValue: rotationValue.uint64) else {
                                throw EmulatorDecodingError.unknownRotation(rotationValue.uint64)
                            }
                            rotation = known
                        }
                    case 3: width = Int(formatValue.uint32)
                    case 4: height = Int(formatValue.uint32)
                    default: continue
                    }
                }
            case 2: legacyWidth = Int(value.uint32)
            case 3: legacyHeight = Int(value.uint32)
            case 4: pixels = value.bytes
            case 5: sequence = value.uint32
            case 6: timestamp = value.uint64
            default: continue
            }
        }
        return EmulatorImage(
            format: format, width: width > 0 ? width : legacyWidth, height: height > 0 ? height : legacyHeight,
            rotation: rotation, pixels: pixels, sequence: sequence, timestampMicroseconds: timestamp
        )
    }
}

/// One contact in a `TouchEvent`. Coordinates are physical display pixels, top-left origin; a
/// pressure of zero lifts the contact.
public struct EmulatorTouch: Equatable, Sendable {
    public static let contactPressure: Int32 = 0x400

    public var x: Int32
    public var y: Int32
    public var identifier: Int32
    public var pressure: Int32

    public init(x: Int32, y: Int32, identifier: Int32, pressure: Int32) {
        self.x = x
        self.y = y
        self.identifier = identifier
        self.pressure = pressure
    }
}

public enum EmulatorRequests {
    public static func touchEvent(_ touches: [EmulatorTouch], display: UInt32 = 0) -> [UInt8] {
        var event = ProtobufWriter()
        for touch in touches {
            var message = ProtobufWriter()
            message.int32(1, touch.x)
            message.int32(2, touch.y)
            message.int32(3, touch.identifier)
            message.int32(4, touch.pressure)
            event.message(1, message)
        }
        event.varint(2, UInt64(display))
        return event.bytes
    }

    /// A W3C `KeyboardEvent.key` value pressed and released ("GoHome", "GoBack", "AppSwitch",
    /// "Power", "AudioVolumeUp", "Enter", "a").
    public static func keyPress(_ key: String) -> [UInt8] {
        var event = ProtobufWriter()
        event.varint(2, 2) // keypress
        event.string(4, key)
        return event.bytes
    }

    /// Printable text, translated by the emulator one keypress per character.
    public static func text(_ text: String) -> [UInt8] {
        var event = ProtobufWriter()
        event.string(5, text)
        return event.bytes
    }

    /// `PhysicalModelValue` setting the device's rotation sensor, in degrees about each axis.
    public static func rotation(x: Float, y: Float, z: Float) -> [UInt8] {
        var parameters = ProtobufWriter()
        var packed: [UInt8] = []
        for value in [x, y, z] {
            var raw = value.bitPattern.littleEndian
            withUnsafeBytes(of: &raw) { packed.append(contentsOf: $0) }
        }
        parameters.lengthDelimited(1, packed)
        var model = ProtobufWriter()
        model.varint(1, 1) // ROTATION
        model.message(3, parameters)
        return model.bytes
    }

    public static let empty: [UInt8] = []
}

public struct EmulatorStatus: Equatable, Sendable {
    public let version: String
    public let booted: Bool

    public static func decode(_ bytes: [UInt8]) throws -> EmulatorStatus {
        var version = ""
        var booted = false
        var reader = ProtobufReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: version = value.string
            case 3: booted = value.bool
            default: continue
            }
        }
        return EmulatorStatus(version: version, booted: booted)
    }
}

/// The typed calls over one authorized channel.
public final class EmulatorControlClient: @unchecked Sendable {
    public let channel: GRPCChannel
    private let authorization: @Sendable (EmulatorControlMethod) -> String?

    /// `authorization` returns the bearer token for a method, or nil for an unauthenticated
    /// emulator (one started with an allowlist that leaves the method unprotected).
    public init(channel: GRPCChannel, authorization: @escaping @Sendable (EmulatorControlMethod) -> String?) {
        self.channel = channel
        self.authorization = authorization
    }

    public func status() async throws -> EmulatorStatus {
        try EmulatorStatus.decode(try await unary(.getStatus, EmulatorRequests.empty))
    }

    public func screenshot(_ request: EmulatorScreenshotRequest) async throws -> EmulatorImage {
        try EmulatorImage.decode(try await unary(.getScreenshot, request.encoded(), timeout: 10))
    }

    @discardableResult
    public func streamScreenshots(
        _ request: EmulatorScreenshotRequest,
        onImage: @escaping @Sendable (Result<EmulatorImage, Error>) -> Void,
        onEnd: @escaping @Sendable (GRPCStatus) -> Void
    ) -> GRPCChannel.CallHandle {
        channel.call(
            EmulatorControlMethod.streamScreenshot.path, request: request.encoded(),
            metadata: metadata(.streamScreenshot),
            onMessage: { bytes in onImage(Result { try EmulatorImage.decode(bytes) }) },
            onEnd: onEnd
        )
    }

    public func sendTouch(_ touches: [EmulatorTouch]) async throws {
        _ = try await unary(.sendTouch, EmulatorRequests.touchEvent(touches))
    }

    public func pressKey(_ key: String) async throws {
        _ = try await unary(.sendKey, EmulatorRequests.keyPress(key))
    }

    public func type(_ text: String) async throws {
        _ = try await unary(.sendKey, EmulatorRequests.text(text))
    }

    public func setRotation(x: Float, y: Float, z: Float) async throws {
        _ = try await unary(.setPhysicalModel, EmulatorRequests.rotation(x: x, y: y, z: z))
    }

    private func unary(_ method: EmulatorControlMethod, _ request: [UInt8], timeout: TimeInterval = 5) async throws -> [UInt8] {
        try await channel.unary(method.path, request: request, metadata: metadata(method), timeout: timeout)
    }

    private func metadata(_ method: EmulatorControlMethod) -> [HTTP2Header] {
        authorization(method).map { [HTTP2Header("authorization", "Bearer \($0)")] } ?? []
    }
}
