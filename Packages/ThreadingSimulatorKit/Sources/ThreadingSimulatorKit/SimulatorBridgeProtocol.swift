import Foundation

public enum SimulatorBridgeProtocol {
    // v2 adds the shared-memory transport (`sharedSurface`/`sharedFrameReady`/`releaseSharedFrame`
    // and `SimulatorBridgeHello.supportsSharedMemory`). The embedded helper is always the same
    // build as the app, so this negotiates cleanly; the minimum stays 1 so an older peer simply
    // never selects shared memory and both sides fall back to the codec path.
    public static let current = 2
    public static let minimumSupported = 1
}

public enum SimulatorBridgeCompatibility: String, Codable, Equatable, Sendable {
    case compatible
    case peerTooOld
    case selfTooOld

    public static func evaluate(peerVersion: Int, peerMinimum: Int) -> Self {
        if peerVersion < SimulatorBridgeProtocol.minimumSupported { return .peerTooOld }
        if SimulatorBridgeProtocol.current < peerMinimum { return .selfTooOld }
        return .compatible
    }
}

public enum SimulatorBridgeCodec: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case h264 = 1
    case jpeg = 2
}

public struct SimulatorBridgeCapabilities: Codable, Equatable, Sendable {
    public let codecs: [SimulatorBridgeCodec]
    public let supportsTouch: Bool
    public let supportsKeyboard: Bool
    public let supportsButtons: Bool
    public let maximumFramesPerSecond: Int

    public init(
        codecs: [SimulatorBridgeCodec],
        supportsTouch: Bool,
        supportsKeyboard: Bool,
        supportsButtons: Bool,
        maximumFramesPerSecond: Int
    ) {
        self.codecs = codecs
        self.supportsTouch = supportsTouch
        self.supportsKeyboard = supportsKeyboard
        self.supportsButtons = supportsButtons
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

public enum SimulatorBridgeButton: String, Codable, CaseIterable, Equatable, Sendable {
    case home
    case lock
    case side
}

public enum SimulatorBridgeInput: Codable, Equatable, Sendable {
    case tap(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Int)
    case text(String)
    case button(SimulatorBridgeButton)
}

/// A shared-memory frame transport: the helper copies each captured surface into one of a small
/// pool of shared buffers and tells the app which buffer is current, so the app reads the pixels
/// directly with no codec, encode, or decode. The buffer identifier is a per-session random value
/// exchanged only over the already-signature-verified control socket; the helper discards the
/// buffers on teardown. Passing the buffers as inherited file descriptors instead is a planned
/// hardening that removes the (same-user) guess surface.
public struct SimulatorSharedSurfaceDescriptor: Codable, Equatable, Sendable {
    /// The identifier of buffer *i* is `"\(namePrefix)\(i)"`. In the current prototype the helper
    /// backs each buffer with an `mmap`ed temp file, so this is a file-path prefix.
    public let namePrefix: String
    public let bufferCount: Int
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// The IOSurface pixel format four-char code (e.g. 'BGRA'); the app builds its image from it.
    public let pixelFormat: UInt32
    public let bufferByteLength: Int

    public init(
        namePrefix: String,
        bufferCount: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: UInt32,
        bufferByteLength: Int
    ) {
        self.namePrefix = namePrefix
        self.bufferCount = bufferCount
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.bufferByteLength = bufferByteLength
    }

    public func name(forBuffer index: Int) -> String { "\(namePrefix)\(index)" }
}

public struct SimulatorBridgeHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let minimumSupported: Int
    public let deviceID: UUID
    public let developerDirectory: String
    public let preferredCodecs: [SimulatorBridgeCodec]
    public let requestedFramesPerSecond: Int
    /// Whether the app can consume the shared-memory transport. Optional on the wire so a v1 peer
    /// that never wrote the field decodes as `false` and stays on the codec path.
    public let supportsSharedMemory: Bool

    public init(
        protocolVersion: Int = SimulatorBridgeProtocol.current,
        minimumSupported: Int = SimulatorBridgeProtocol.minimumSupported,
        deviceID: UUID,
        developerDirectory: String,
        preferredCodecs: [SimulatorBridgeCodec] = [.h264, .jpeg],
        requestedFramesPerSecond: Int = 30,
        supportsSharedMemory: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupported = minimumSupported
        self.deviceID = deviceID
        self.developerDirectory = developerDirectory
        self.preferredCodecs = preferredCodecs
        self.requestedFramesPerSecond = requestedFramesPerSecond
        self.supportsSharedMemory = supportsSharedMemory
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, minimumSupported, deviceID, developerDirectory
        case preferredCodecs, requestedFramesPerSecond, supportsSharedMemory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        minimumSupported = try container.decode(Int.self, forKey: .minimumSupported)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        developerDirectory = try container.decode(String.self, forKey: .developerDirectory)
        preferredCodecs = try container.decode([SimulatorBridgeCodec].self, forKey: .preferredCodecs)
        requestedFramesPerSecond = try container.decode(Int.self, forKey: .requestedFramesPerSecond)
        supportsSharedMemory = try container.decodeIfPresent(
            Bool.self, forKey: .supportsSharedMemory
        ) ?? false
    }
}

public struct SimulatorBridgeHelloReply: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let minimumSupported: Int
    public let selectedCodec: SimulatorBridgeCodec?
    /// Non-nil when the helper selected the shared-memory transport. When set, `selectedCodec` is
    /// nil and frames arrive as `sharedFrameReady` rather than `media` wire frames.
    public let sharedSurface: SimulatorSharedSurfaceDescriptor?
    public let capabilities: SimulatorBridgeCapabilities?
    public let refusal: SimulatorBridgeRefusal?
    public let coreSimulatorVersion: String?
    public let simulatorKitVersion: String?

    public init(
        protocolVersion: Int = SimulatorBridgeProtocol.current,
        minimumSupported: Int = SimulatorBridgeProtocol.minimumSupported,
        selectedCodec: SimulatorBridgeCodec?,
        sharedSurface: SimulatorSharedSurfaceDescriptor? = nil,
        capabilities: SimulatorBridgeCapabilities?,
        refusal: SimulatorBridgeRefusal?,
        coreSimulatorVersion: String?,
        simulatorKitVersion: String?
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupported = minimumSupported
        self.selectedCodec = selectedCodec
        self.sharedSurface = sharedSurface
        self.capabilities = capabilities
        self.refusal = refusal
        self.coreSimulatorVersion = coreSimulatorVersion
        self.simulatorKitVersion = simulatorKitVersion
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, minimumSupported, selectedCodec, sharedSurface
        case capabilities, refusal, coreSimulatorVersion, simulatorKitVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        minimumSupported = try container.decode(Int.self, forKey: .minimumSupported)
        selectedCodec = try container.decodeIfPresent(
            SimulatorBridgeCodec.self, forKey: .selectedCodec
        )
        sharedSurface = try container.decodeIfPresent(
            SimulatorSharedSurfaceDescriptor.self, forKey: .sharedSurface
        )
        capabilities = try container.decodeIfPresent(
            SimulatorBridgeCapabilities.self, forKey: .capabilities
        )
        refusal = try container.decodeIfPresent(SimulatorBridgeRefusal.self, forKey: .refusal)
        coreSimulatorVersion = try container.decodeIfPresent(
            String.self, forKey: .coreSimulatorVersion
        )
        simulatorKitVersion = try container.decodeIfPresent(
            String.self, forKey: .simulatorKitVersion
        )
    }
}

public enum SimulatorBridgeRefusal: String, Codable, Equatable, Sendable {
    case incompatibleProtocol
    case untrustedHost
    case untrustedFramework
    case invalidDeveloperDirectory
    case frameworkUnavailable
    case apiUnavailable
    case deviceUnavailable
    case screenUnavailable
    case codecUnavailable
    case malformedMessage
    case inputUnavailable
    case internalFailure
}

public enum SimulatorBridgeClientMessage: Codable, Equatable, Sendable {
    case hello(SimulatorBridgeHello)
    case setVisible(Bool)
    case acknowledgeFrame(UInt64)
    /// Shared-memory transport: the app has finished reading this buffer index, so the helper may
    /// write the next frame into it. This is the shared-memory analogue of `acknowledgeFrame`.
    case releaseSharedFrame(UInt32)
    case input(requestID: UUID, command: SimulatorBridgeInput)
    case stop
}

public struct SimulatorBridgeStatistics: Codable, Equatable, Sendable {
    public let capturedFrames: UInt64
    public let sentFrames: UInt64
    public let replacedFrames: UInt64
    public let encodedBytes: UInt64

    public init(
        capturedFrames: UInt64,
        sentFrames: UInt64,
        replacedFrames: UInt64,
        encodedBytes: UInt64
    ) {
        self.capturedFrames = capturedFrames
        self.sentFrames = sentFrames
        self.replacedFrames = replacedFrames
        self.encodedBytes = encodedBytes
    }
}

public enum SimulatorBridgeHelperMessage: Codable, Equatable, Sendable {
    case hello(SimulatorBridgeHelloReply)
    case inputResult(requestID: UUID, error: String?)
    case statistics(SimulatorBridgeStatistics)
    /// Shared-memory transport: the helper has written a frame into `bufferIndex`; the app reads
    /// that buffer, presents it, and answers with `releaseSharedFrame(bufferIndex)`.
    case sharedFrameReady(bufferIndex: UInt32, sequence: UInt64, presentationTimeNanoseconds: UInt64)
    case failure(SimulatorBridgeRefusal, detail: String)
}
