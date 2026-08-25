import Foundation

public enum SimulatorBridgeProtocol {
    public static let current = 1
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

public struct SimulatorBridgeHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let minimumSupported: Int
    public let deviceID: UUID
    public let developerDirectory: String
    public let preferredCodecs: [SimulatorBridgeCodec]
    public let requestedFramesPerSecond: Int

    public init(
        protocolVersion: Int = SimulatorBridgeProtocol.current,
        minimumSupported: Int = SimulatorBridgeProtocol.minimumSupported,
        deviceID: UUID,
        developerDirectory: String,
        preferredCodecs: [SimulatorBridgeCodec] = [.h264, .jpeg],
        requestedFramesPerSecond: Int = 30
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupported = minimumSupported
        self.deviceID = deviceID
        self.developerDirectory = developerDirectory
        self.preferredCodecs = preferredCodecs
        self.requestedFramesPerSecond = requestedFramesPerSecond
    }
}

public struct SimulatorBridgeHelloReply: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let minimumSupported: Int
    public let selectedCodec: SimulatorBridgeCodec?
    public let capabilities: SimulatorBridgeCapabilities?
    public let refusal: SimulatorBridgeRefusal?
    public let coreSimulatorVersion: String?
    public let simulatorKitVersion: String?

    public init(
        protocolVersion: Int = SimulatorBridgeProtocol.current,
        minimumSupported: Int = SimulatorBridgeProtocol.minimumSupported,
        selectedCodec: SimulatorBridgeCodec?,
        capabilities: SimulatorBridgeCapabilities?,
        refusal: SimulatorBridgeRefusal?,
        coreSimulatorVersion: String?,
        simulatorKitVersion: String?
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupported = minimumSupported
        self.selectedCodec = selectedCodec
        self.capabilities = capabilities
        self.refusal = refusal
        self.coreSimulatorVersion = coreSimulatorVersion
        self.simulatorKitVersion = simulatorKitVersion
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
    case failure(SimulatorBridgeRefusal, detail: String)
}
