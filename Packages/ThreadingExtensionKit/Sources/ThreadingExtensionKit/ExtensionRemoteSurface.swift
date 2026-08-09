import Foundation

/// One pixel surface a companion is prepared to render.
///
/// A declaration grants no UI authority by itself. A running WebAssembly core must still
/// register a panel which references this surface, and the companion must have
/// `ui.remote-surfaces`.
public struct ExtensionRemoteSurface: Codable, Equatable, Sendable {
    public static let maximumPerCompanion = 16
    public static let maximumDimension = 4_096

    public let id: String
    public let title: String
    public let accessibilityLabel: String
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let acceptsPointer: Bool
    public let acceptsKeyboard: Bool

    public init(
        id: String,
        title: String,
        accessibilityLabel: String,
        maximumWidth: Int = 2_560,
        maximumHeight: Int = 1_600,
        acceptsPointer: Bool = false,
        acceptsKeyboard: Bool = false
    ) {
        self.id = id
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.acceptsPointer = acceptsPointer
        self.acceptsKeyboard = acceptsKeyboard
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        issues.append(contentsOf: remoteSurfaceTextIssues(
            title,
            path: "\(path).title",
            maximum: 120
        ))
        issues.append(contentsOf: remoteSurfaceTextIssues(
            accessibilityLabel,
            path: "\(path).accessibilityLabel",
            maximum: 240
        ))
        if !(1...Self.maximumDimension).contains(maximumWidth) {
            issues.append(.init(
                path: "\(path).maximumWidth",
                message: "must be between 1 and \(Self.maximumDimension)"
            ))
        }
        if !(1...Self.maximumDimension).contains(maximumHeight) {
            issues.append(.init(
                path: "\(path).maximumHeight",
                message: "must be between 1 and \(Self.maximumDimension)"
            ))
        }
        let pixels = maximumWidth.multipliedReportingOverflow(by: maximumHeight)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        if pixels.overflow || bytes.overflow
            || bytes.partialValue > ExtensionRemoteSurfaceWire.maximumPayloadBytes {
            issues.append(.init(
                path: path,
                message: "maximumWidth × maximumHeight must fit one bounded BGRA8 frame"
            ))
        }
        return issues
    }
}

/// A semantic panel's reference to one declared companion surface.
public struct ExtensionRemoteSurfaceReference: Codable, Equatable, Sendable {
    public let companionID: String
    public let surfaceID: String

    public init(companionID: String, surfaceID: String) {
        self.companionID = companionID
        self.surfaceID = surfaceID
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        [
            (companionID, "\(path).companionID"),
            (surfaceID, "\(path).surfaceID")
        ].compactMap { value, valuePath in
            ExtensionIdentifierRules.isContributionIdentifier(value)
                ? nil
                : ExtensionValidationIssue(
                    path: valuePath,
                    message: ExtensionIdentifierRules.contributionMessage
                )
        }
    }
}

public enum ExtensionRemoteSurfacePixelFormat:
    String,
    Codable,
    Equatable,
    Sendable
{
    /// Four 8-bit channels in blue, green, red, alpha byte order.
    case bgra8Premultiplied
}

public struct ExtensionRemoteSurfaceOpen: Codable, Equatable, Sendable {
    public let presentationID: String
    public let surfaceID: String
    public let viewport: ExtensionRemoteSurfaceViewport
    public let projectID: String?
    public let sessionID: String?

    public init(
        presentationID: String,
        surfaceID: String,
        viewport: ExtensionRemoteSurfaceViewport,
        projectID: String? = nil,
        sessionID: String? = nil
    ) {
        self.presentationID = presentationID
        self.surfaceID = surfaceID
        self.viewport = viewport
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

public struct ExtensionRemoteSurfacePresentation: Codable, Equatable, Sendable {
    public let presentationID: String

    public init(presentationID: String) {
        self.presentationID = presentationID
    }
}

/// Host-owned logical viewport. Dimensions are points; scale converts them to backing pixels.
public struct ExtensionRemoteSurfaceViewport: Codable, Equatable, Sendable {
    public let presentationID: String
    public let width: Double
    public let height: Double
    public let scale: Double
    public let isVisible: Bool

    public init(
        presentationID: String,
        width: Double,
        height: Double,
        scale: Double,
        isVisible: Bool
    ) {
        self.presentationID = presentationID
        self.width = width
        self.height = height
        self.scale = scale
        self.isVisible = isVisible
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues = remotePresentationIssues(presentationID, path: "\(path).presentationID")
        if !width.isFinite || width < 0 || width > 10_000 {
            issues.append(.init(path: "\(path).width", message: "must be finite and between 0 and 10000"))
        }
        if !height.isFinite || height < 0 || height > 10_000 {
            issues.append(.init(path: "\(path).height", message: "must be finite and between 0 and 10000"))
        }
        if !scale.isFinite || scale <= 0 || scale > 4 {
            issues.append(.init(path: "\(path).scale", message: "must be finite and greater than 0, up to 4"))
        }
        return issues
    }
}

public enum ExtensionRemoteSurfaceInputKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case pointerMoved
    case pointerDown
    case pointerUp
    case scroll
    case keyDown
    case keyUp
}

public enum ExtensionRemoteSurfaceModifier:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case shift
    case control
    case option
    case command
}

/// Normalized user input originating inside the host-owned surface view.
///
/// Pointer locations use a top-left origin and the closed 0...1 range. These values are data,
/// never synthesized system input.
public struct ExtensionRemoteSurfaceInput: Codable, Equatable, Sendable {
    public let presentationID: String
    public let kind: ExtensionRemoteSurfaceInputKind
    public let x: Double?
    public let y: Double?
    public let button: Int?
    public let deltaX: Double?
    public let deltaY: Double?
    public let keyCode: Int?
    public let characters: String?
    public let modifiers: [ExtensionRemoteSurfaceModifier]

    public init(
        presentationID: String,
        kind: ExtensionRemoteSurfaceInputKind,
        x: Double? = nil,
        y: Double? = nil,
        button: Int? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        keyCode: Int? = nil,
        characters: String? = nil,
        modifiers: [ExtensionRemoteSurfaceModifier] = []
    ) {
        self.presentationID = presentationID
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues = remotePresentationIssues(presentationID, path: "\(path).presentationID")
        if modifiers.count != Set(modifiers).count {
            issues.append(.init(path: "\(path).modifiers", message: "must not contain duplicates"))
        }
        if let characters, characters.count > 32 {
            issues.append(.init(path: "\(path).characters", message: "must contain at most 32 characters"))
        }
        switch kind {
        case .pointerMoved, .pointerDown, .pointerUp:
            if x.map({ !$0.isFinite || !(0...1).contains($0) }) ?? true {
                issues.append(.init(path: "\(path).x", message: "must be between 0 and 1"))
            }
            if y.map({ !$0.isFinite || !(0...1).contains($0) }) ?? true {
                issues.append(.init(path: "\(path).y", message: "must be between 0 and 1"))
            }
            if kind != .pointerMoved,
               button.map({ !(0...7).contains($0) }) ?? true {
                issues.append(.init(path: "\(path).button", message: "must be between 0 and 7"))
            }
        case .scroll:
            if deltaX.map({ !$0.isFinite || abs($0) > 100_000 }) ?? true {
                issues.append(.init(path: "\(path).deltaX", message: "must be a bounded finite value"))
            }
            if deltaY.map({ !$0.isFinite || abs($0) > 100_000 }) ?? true {
                issues.append(.init(path: "\(path).deltaY", message: "must be a bounded finite value"))
            }
        case .keyDown, .keyUp:
            if keyCode.map({ !(0...UInt16.max.intValue).contains($0) }) ?? true {
                issues.append(.init(path: "\(path).keyCode", message: "must be a UInt16 key code"))
            }
        }
        return issues
    }
}

public struct ExtensionRemoteSurfaceFrame: Codable, Equatable, Sendable {
    public let presentationID: String
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: ExtensionRemoteSurfacePixelFormat
    public let payloadLength: Int

    public init(
        presentationID: String,
        sequence: UInt64,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: ExtensionRemoteSurfacePixelFormat = .bgra8Premultiplied,
        payloadLength: Int
    ) {
        self.presentationID = presentationID
        self.sequence = sequence
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.payloadLength = payloadLength
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues = remotePresentationIssues(presentationID, path: "\(path).presentationID")
        if !(1...ExtensionRemoteSurface.maximumDimension).contains(width) {
            issues.append(.init(path: "\(path).width", message: "is outside the supported range"))
        }
        if !(1...ExtensionRemoteSurface.maximumDimension).contains(height) {
            issues.append(.init(path: "\(path).height", message: "is outside the supported range"))
        }
        let minimumRow = width.multipliedReportingOverflow(by: 4)
        if minimumRow.overflow
            || bytesPerRow < minimumRow.partialValue
            || bytesPerRow > minimumRow.partialValue + 65_536 {
            issues.append(.init(path: "\(path).bytesPerRow", message: "is invalid for a BGRA8 frame"))
        }
        let expected = bytesPerRow.multipliedReportingOverflow(by: height)
        if expected.overflow || payloadLength != expected.partialValue {
            issues.append(.init(path: "\(path).payloadLength", message: "does not match bytesPerRow × height"))
        }
        if payloadLength < 1 || payloadLength > ExtensionRemoteSurfaceWire.maximumPayloadBytes {
            issues.append(.init(path: "\(path).payloadLength", message: "exceeds the remote-surface payload limit"))
        }
        return issues
    }
}

public enum ExtensionRemoteSurfaceFrameDisposition:
    String,
    Codable,
    Equatable,
    Sendable
{
    case displayed
    case dropped
}

public struct ExtensionRemoteSurfaceFrameAcknowledgement:
    Codable,
    Equatable,
    Sendable
{
    public let presentationID: String
    public let sequence: UInt64
    public let disposition: ExtensionRemoteSurfaceFrameDisposition

    public init(
        presentationID: String,
        sequence: UInt64,
        disposition: ExtensionRemoteSurfaceFrameDisposition
    ) {
        self.presentationID = presentationID
        self.sequence = sequence
        self.disposition = disposition
    }
}

/// The control vocabulary carried by the dedicated remote-surface socket.
public enum ExtensionRemoteSurfaceMessage: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    case open(ExtensionRemoteSurfaceOpen)
    case close(ExtensionRemoteSurfacePresentation)
    case viewport(ExtensionRemoteSurfaceViewport)
    case input(ExtensionRemoteSurfaceInput)
    case frame(ExtensionRemoteSurfaceFrame)
    case acknowledgement(ExtensionRemoteSurfaceFrameAcknowledgement)

    private enum Kind: String, Codable {
        case open, close, viewport, input, frame, acknowledgement
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, type, open, close, viewport, input, frame, acknowledgement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .protocolVersion)
        guard version == Self.currentProtocolVersion else {
            throw ExtensionRemoteSurfaceWireError.unsupportedProtocol(version)
        }
        switch try container.decode(Kind.self, forKey: .type) {
        case .open:
            self = .open(try container.decode(ExtensionRemoteSurfaceOpen.self, forKey: .open))
        case .close:
            self = .close(try container.decode(ExtensionRemoteSurfacePresentation.self, forKey: .close))
        case .viewport:
            self = .viewport(try container.decode(ExtensionRemoteSurfaceViewport.self, forKey: .viewport))
        case .input:
            self = .input(try container.decode(ExtensionRemoteSurfaceInput.self, forKey: .input))
        case .frame:
            self = .frame(try container.decode(ExtensionRemoteSurfaceFrame.self, forKey: .frame))
        case .acknowledgement:
            self = .acknowledgement(try container.decode(
                ExtensionRemoteSurfaceFrameAcknowledgement.self,
                forKey: .acknowledgement
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentProtocolVersion, forKey: .protocolVersion)
        switch self {
        case .open(let value):
            try container.encode(Kind.open, forKey: .type)
            try container.encode(value, forKey: .open)
        case .close(let value):
            try container.encode(Kind.close, forKey: .type)
            try container.encode(value, forKey: .close)
        case .viewport(let value):
            try container.encode(Kind.viewport, forKey: .type)
            try container.encode(value, forKey: .viewport)
        case .input(let value):
            try container.encode(Kind.input, forKey: .type)
            try container.encode(value, forKey: .input)
        case .frame(let value):
            try container.encode(Kind.frame, forKey: .type)
            try container.encode(value, forKey: .frame)
        case .acknowledgement(let value):
            try container.encode(Kind.acknowledgement, forKey: .type)
            try container.encode(value, forKey: .acknowledgement)
        }
    }

    public func validate(payloadCount: Int) throws {
        var issues: [ExtensionValidationIssue] = []
        switch self {
        case .open(let value):
            issues.append(contentsOf: remotePresentationIssues(
                value.presentationID,
                path: "open.presentationID"
            ))
            if !ExtensionIdentifierRules.isContributionIdentifier(value.surfaceID) {
                issues.append(.init(
                    path: "open.surfaceID",
                    message: ExtensionIdentifierRules.contributionMessage
                ))
            }
            issues.append(contentsOf: value.viewport.validationIssues(path: "open.viewport"))
            if value.viewport.presentationID != value.presentationID {
                issues.append(.init(
                    path: "open.viewport.presentationID",
                    message: "must match open.presentationID"
                ))
            }
            if payloadCount != 0 {
                issues.append(.init(path: "payload", message: "is only valid for frame messages"))
            }
        case .close(let value):
            issues.append(contentsOf: remotePresentationIssues(
                value.presentationID,
                path: "close.presentationID"
            ))
            if payloadCount != 0 {
                issues.append(.init(path: "payload", message: "is only valid for frame messages"))
            }
        case .viewport(let value):
            issues.append(contentsOf: value.validationIssues(path: "viewport"))
            if payloadCount != 0 {
                issues.append(.init(path: "payload", message: "is only valid for frame messages"))
            }
        case .input(let value):
            issues.append(contentsOf: value.validationIssues(path: "input"))
            if payloadCount != 0 {
                issues.append(.init(path: "payload", message: "is only valid for frame messages"))
            }
        case .frame(let value):
            issues.append(contentsOf: value.validationIssues(path: "frame"))
            if value.payloadLength != payloadCount {
                issues.append(.init(path: "payload", message: "does not match frame.payloadLength"))
            }
        case .acknowledgement(let value):
            issues.append(contentsOf: remotePresentationIssues(
                value.presentationID,
                path: "acknowledgement.presentationID"
            ))
            if payloadCount != 0 {
                issues.append(.init(path: "payload", message: "is only valid for frame messages"))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

public struct ExtensionRemoteSurfacePacket: Equatable, Sendable {
    public let message: ExtensionRemoteSurfaceMessage
    public let payload: Data

    public init(message: ExtensionRemoteSurfaceMessage, payload: Data = Data()) {
        self.message = message
        self.payload = payload
    }
}

public enum ExtensionRemoteSurfaceWireError: Error, Equatable, LocalizedError {
    case unsupportedProtocol(Int)
    case headerTooLarge
    case payloadTooLarge
    case truncated
    case invalidHeader

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocol(let version):
            return "Remote-surface protocol \(version) is unsupported."
        case .headerTooLarge:
            return "The remote-surface header exceeds its limit."
        case .payloadTooLarge:
            return "The remote-surface payload exceeds its limit."
        case .truncated:
            return "The remote-surface packet ended early."
        case .invalidHeader:
            return "The remote-surface packet header is invalid."
        }
    }
}

/// Length-prefixed binary framing for the companion's dedicated full-duplex socket.
///
/// The four-byte big-endian header length is followed by a JSON message and then, for `.frame`,
/// the exact raw pixel payload declared by that message.
public enum ExtensionRemoteSurfaceWire {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumPayloadBytes = 32 * 1024 * 1024

    public static func encoded(_ packet: ExtensionRemoteSurfacePacket) throws -> Data {
        try packet.message.validate(payloadCount: packet.payload.count)
        let header = try JSONEncoder().encode(packet.message)
        guard header.count <= maximumHeaderBytes else {
            throw ExtensionRemoteSurfaceWireError.headerTooLarge
        }
        guard packet.payload.count <= maximumPayloadBytes else {
            throw ExtensionRemoteSurfaceWireError.payloadTooLarge
        }
        var result = Data()
        let length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
        result.append(header)
        result.append(packet.payload)
        return result
    }

    /// Reads one packet. Returns nil only for a clean EOF before the next packet begins.
    public static func read(from handle: FileHandle) throws -> ExtensionRemoteSurfacePacket? {
        guard let prefix = try readExactly(4, from: handle, allowsCleanEOF: true) else {
            return nil
        }
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumHeaderBytes else {
            throw ExtensionRemoteSurfaceWireError.headerTooLarge
        }
        guard let header = try readExactly(Int(length), from: handle) else {
            throw ExtensionRemoteSurfaceWireError.truncated
        }
        let message: ExtensionRemoteSurfaceMessage
        do {
            message = try JSONDecoder().decode(ExtensionRemoteSurfaceMessage.self, from: header)
        } catch let error as ExtensionRemoteSurfaceWireError {
            throw error
        } catch {
            throw ExtensionRemoteSurfaceWireError.invalidHeader
        }
        let payloadLength: Int
        if case .frame(let frame) = message {
            payloadLength = frame.payloadLength
        } else {
            payloadLength = 0
        }
        guard payloadLength <= maximumPayloadBytes else {
            throw ExtensionRemoteSurfaceWireError.payloadTooLarge
        }
        guard let payload = try readExactly(payloadLength, from: handle) else {
            throw ExtensionRemoteSurfaceWireError.truncated
        }
        try message.validate(payloadCount: payload.count)
        return ExtensionRemoteSurfacePacket(message: message, payload: payload)
    }

    public static func write(
        _ packet: ExtensionRemoteSurfacePacket,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: encoded(packet))
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        allowsCleanEOF: Bool = false
    ) throws -> Data? {
        if count == 0 { return Data() }
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            if chunk.isEmpty {
                if result.isEmpty, allowsCleanEOF { return nil }
                throw ExtensionRemoteSurfaceWireError.truncated
            }
            result.append(chunk)
        }
        return result
    }
}

private func remotePresentationIssues(
    _ value: String,
    path: String
) -> [ExtensionValidationIssue] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return [.init(path: path, message: "must not be empty")]
    }
    if value.count > 128 {
        return [.init(path: path, message: "must contain at most 128 characters")]
    }
    return []
}

private func remoteSurfaceTextIssues(
    _ value: String,
    path: String,
    maximum: Int
) -> [ExtensionValidationIssue] {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return [.init(path: path, message: "must not be empty")]
    }
    if value.count > maximum {
        return [.init(path: path, message: "must contain at most \(maximum) characters")]
    }
    return []
}

private extension UInt16 {
    var intValue: Int { Int(self) }
}
