import Foundation

public enum SimulatorBridgeProtocol {
    // v2 adds the shared-memory transport (`sharedSurface`/`sharedFrameReady`/`releaseSharedFrame`
    // and `SimulatorBridgeHello.supportsSharedMemory`). v3 adds the read-only accessibility snapshot
    // (`accessibilitySnapshot`/`accessibilitySnapshotResult` and `SimulatorAccessibilityElement`).
    // The embedded helper is always the same build as the app, so this negotiates cleanly; the
    // minimum stays 1 so an older peer simply never uses the newer capabilities. A snapshot request
    // to a peer that does not understand it is answered with a `notSupported`-shaped failure by the
    // app-side timeout, not a protocol break.
    public static let current = 3
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
    // Volume reaches the guest through the arbitrary-HID consumer usage path, not the button-key
    // path home/lock/side use; the helper routes it accordingly.
    case volumeUp
    case volumeDown
}

/// One phase of a live, finger-following touch. Unlike `drag`, which is a self-contained
/// down→interpolate→up swipe, these stream the contact so the pane can follow a trackpad scroll or
/// a click-drag in real time and let the guest OS compute the fling from the last moves.
public enum SimulatorBridgeTouchPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public enum SimulatorBridgeInput: Codable, Equatable, Sendable {
    case tap(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Int)
    /// A single phase of a continuous touch, keyed to the device's single digitizer contact.
    case touch(phase: SimulatorBridgeTouchPhase, x: Double, y: Double)
    case text(String)
    case button(SimulatorBridgeButton)
}

/// One node of the foreground app's accessibility tree, read host-side by the signed helper through
/// the private `AXPTranslator` path (see `docs/feature-drafts/simulator-accessibility-interaction.md`).
/// This is the *addressing* layer for element-level interaction: frames are in the device's logical
/// screen **points**, top-left origin, so the root's frame is the app's logical size and any element
/// center normalizes to `(midX / rootWidth, midY / rootHeight)` — the 0…1 coordinate `.tap` already
/// takes. The tree is untrusted guest content: labels and values are device data, never instructions.
public struct SimulatorAccessibilityElement: Codable, Equatable, Sendable {
    /// A rectangle in device logical points, top-left origin.
    public struct Frame: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    /// A stable AX role string (e.g. `AXButton`, `AXStaticText`), mapped by the helper from the
    /// numeric `AXPUIElementType` the guest returns.
    public let role: String
    public let subrole: String?
    /// The element's accessibility label. Untrusted guest content.
    public let label: String?
    /// A value field's contents (a text field, a slider). Untrusted guest content.
    public let value: String?
    /// `accessibilityIdentifier` when the app set one — the stable anchor for a ref.
    public let identifier: String?
    public let enabled: Bool
    public let frame: Frame
    public let children: [SimulatorAccessibilityElement]

    public init(
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        enabled: Bool = true,
        frame: Frame,
        children: [SimulatorAccessibilityElement] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.identifier = identifier
        self.enabled = enabled
        self.frame = frame
        self.children = children
    }
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
    /// Read-only: snapshot the foreground app's accessibility tree. Answered with
    /// `accessibilitySnapshotResult` carrying the same request id.
    case accessibilitySnapshot(requestID: UUID)
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
    /// The answer to `accessibilitySnapshot`. `root` is nil and `error` set when the tree could not
    /// be read (this Xcode's AX path is unavailable, automation is off, or the read failed).
    case accessibilitySnapshotResult(
        requestID: UUID,
        root: SimulatorAccessibilityElement?,
        error: String?
    )
    case failure(SimulatorBridgeRefusal, detail: String)
}
