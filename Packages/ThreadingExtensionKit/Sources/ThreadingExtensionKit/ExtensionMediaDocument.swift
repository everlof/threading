import Foundation

/// A document that varies over time, played by a **host-owned** renderer.
///
/// Every other node in the vocabulary is a still. This one is not, and the reason it is a document
/// handle plus a playback intent — rather than a surface an extension draws into — is the same
/// altitude rule the rest of the vocabulary follows: *a contribution describes meaning, Threading
/// chooses pixels*. The extension says which document, whether it is playing, how fast, and how it
/// loops. Threading carries the decoder, the clock, the transport, the ceilings, the theme and the
/// accessibility, and returns a coalesced state report.
///
/// The alternative was measured and rejected: `ExtensionRemoteSurface` already carries frames from
/// a companion into a host view, and using it here would mean shipping a separately signed macOS
/// application to play a vector animation — taking the whole advanced tier's disclosure with it,
/// and losing the mobile mirror, since a companion surface is deliberately not projected.
///
/// No document bytes, no rendered pixels and no filesystem path cross this boundary in either
/// direction. `source` is either a package-relative resource the host already validates, or an
/// opaque handle the host minted and can resolve itself.
public struct ExtensionMediaDocument: Codable, Equatable, Sendable {

    /// Playback survives a panel replacement keyed on this.
    ///
    /// The load-bearing field. An extension that replaces its panel to update a label must not
    /// restart the animation, exactly as the workspace navigator preserves selection and scroll
    /// position across a refresh. A *changed* id is what resets playback.
    public let id: String
    public let source: ExtensionMediaSource
    public let format: ExtensionMediaFormat
    public let playback: ExtensionMediaPlayback
    public let transport: ExtensionMediaTransport
    /// Whether the host offers its own Copy Frame action.
    ///
    /// Host-owned for the same authority reason everything else here is: the extension asks for the
    /// affordance, and neither rendered bytes nor pasteboard access cross the boundary.
    public let allowsFrameCopy: Bool
    public let accessibilityLabel: String
    /// The canvas's preferred width ÷ height. Nil takes the document's own.
    public let preferredAspectRatio: Double?
    /// Raised with a coalesced `ExtensionMediaStateReport` as the action's value.
    ///
    /// Never per frame, and never per loop iteration: `ready`, `completed`, `failed`, play/pause
    /// and **scrub end**. A report per frame would be a callback whose frequency is the display's,
    /// over a JSONL broker round trip — a Scaling Gate violation on its face.
    public let stateActionID: String?

    public init(
        id: String,
        source: ExtensionMediaSource,
        format: ExtensionMediaFormat,
        playback: ExtensionMediaPlayback = .init(),
        transport: ExtensionMediaTransport = .hostOwned,
        allowsFrameCopy: Bool = false,
        accessibilityLabel: String,
        preferredAspectRatio: Double? = nil,
        stateActionID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.format = format
        self.playback = playback
        self.transport = transport
        self.allowsFrameCopy = allowsFrameCopy
        self.accessibilityLabel = accessibilityLabel
        self.preferredAspectRatio = preferredAspectRatio
        self.stateActionID = stateActionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, format, playback, transport, allowsFrameCopy
        case accessibilityLabel, preferredAspectRatio, stateActionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(ExtensionMediaSource.self, forKey: .source)
        format = try container.decode(ExtensionMediaFormat.self, forKey: .format)
        playback = try container.decodeIfPresent(
            ExtensionMediaPlayback.self,
            forKey: .playback
        ) ?? .init()
        transport = try container.decodeIfPresent(
            ExtensionMediaTransport.self,
            forKey: .transport
        ) ?? .hostOwned
        allowsFrameCopy = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsFrameCopy
        ) ?? false
        accessibilityLabel = try container.decode(String.self, forKey: .accessibilityLabel)
        preferredAspectRatio = try container.decodeIfPresent(
            Double.self,
            forKey: .preferredAspectRatio
        )
        stateActionID = try container.decodeIfPresent(String.self, forKey: .stateActionID)
    }

    public func validationIssues(path: String, maximumTextLength: Int = 10_000) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        issues.append(contentsOf: source.validationIssues(path: "\(path).source"))
        if format.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).format", message: "must not be empty"))
        }
        issues.append(contentsOf: playback.validationIssues(path: "\(path).playback"))
        let trimmedLabel = accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty {
            issues.append(.init(path: "\(path).accessibilityLabel", message: "must not be empty"))
        } else if accessibilityLabel.count > maximumTextLength {
            issues.append(.init(
                path: "\(path).accessibilityLabel",
                message: "exceeds maximum length \(maximumTextLength)"
            ))
        }
        if let preferredAspectRatio,
           !preferredAspectRatio.isFinite || preferredAspectRatio <= 0 {
            issues.append(.init(
                path: "\(path).preferredAspectRatio",
                message: "must be a positive finite ratio"
            ))
        }
        if let stateActionID,
           !ExtensionIdentifierRules.isContributionIdentifier(stateActionID) {
            issues.append(.init(
                path: "\(path).stateActionID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        return issues
    }
}

/// Where the document comes from. Never a path, and never bytes.
public enum ExtensionMediaSource: Codable, Equatable, Sendable {
    /// Package-relative, bounded, and validated exactly like every other package resource.
    case extensionResource(String)
    /// An opaque handle minted by `host.project.files.read`, resolved by the host at render time.
    case fileHandle(String)
    /// An opaque attachment handle, valid **only** inside the `attachments.preview@1` contract.
    /// Used anywhere else it is refused, so a preview handle cannot be replayed into a panel.
    case sessionAttachment(String)

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum Kind: String, Codable {
        case extensionResource
        case fileHandle
        case sessionAttachment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        switch try container.decode(Kind.self, forKey: .type) {
        case .extensionResource: self = .extensionResource(value)
        case .fileHandle: self = .fileHandle(value)
        case .sessionAttachment: self = .sessionAttachment(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .extensionResource(let value):
            try container.encode(Kind.extensionResource, forKey: .type)
            try container.encode(value, forKey: .value)
        case .fileHandle(let value):
            try container.encode(Kind.fileHandle, forKey: .type)
            try container.encode(value, forKey: .value)
        case .sessionAttachment(let value):
            try container.encode(Kind.sessionAttachment, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    /// The longest an opaque handle may be. Handles are host-minted identifiers, not payloads;
    /// a value past this is something else wearing a handle's shape.
    public static let maximumHandleLength = 256

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        switch self {
        case .extensionResource(let resource):
            guard ExtensionIdentifierRules.isSafeRelativePath(resource) else {
                return [.init(
                    path: "\(path).value",
                    message: "must be a relative path without '.' or '..' components"
                )]
            }
            return []
        case .fileHandle(let handle), .sessionAttachment(let handle):
            if handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [.init(path: "\(path).value", message: "must not be empty")]
            }
            if handle.count > Self.maximumHandleLength {
                return [.init(
                    path: "\(path).value",
                    message: "must contain at most \(Self.maximumHandleLength) characters"
                )]
            }
            return []
        }
    }
}

/// A document format the host's renderer registry may carry.
///
/// A raw-value type rather than a closed enum, so a newer manifest stays inspectable on an older
/// host: Threading can say *this format is not carried by this version* instead of failing to
/// decode the panel around it.
public struct ExtensionMediaFormat: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A bare Lottie (bodymovin) JSON document.
    public static let lottie = Self(rawValue: "lottie")
    /// A `.lottie` ZIP container holding a manifest, one or more animations and their assets.
    public static let dotLottie = Self(rawValue: "dot-lottie")
    /// An animated raster document — GIF or APNG.
    public static let animatedImage = Self(rawValue: "animated-image")
}

public enum ExtensionMediaLoopMode: String, Codable, CaseIterable, Equatable, Sendable {
    case once
    case loop
    case pingPong = "ping-pong"
}

public enum ExtensionMediaBackground: String, Codable, CaseIterable, Equatable, Sendable {
    /// The pane's own surface, from the theme.
    case surface
    /// The checkerboard that says *this document has transparency*.
    case checkerboard
    /// Nothing behind the document at all.
    case transparent
}

/// What the host is being asked to do with the document.
public struct ExtensionMediaPlayback: Codable, Equatable, Sendable {
    public static let speedRange: ClosedRange<Double> = 0.1...4

    public let isPlaying: Bool
    public let loop: ExtensionMediaLoopMode
    public let speed: Double
    /// `0…1`. Nil keeps the current position, which is what makes a panel replacement that only
    /// changes a label leave the animation where it was.
    public let progress: Double?
    public let background: ExtensionMediaBackground

    public init(
        isPlaying: Bool = false,
        loop: ExtensionMediaLoopMode = .loop,
        speed: Double = 1,
        progress: Double? = nil,
        background: ExtensionMediaBackground = .surface
    ) {
        self.isPlaying = isPlaying
        self.loop = loop
        self.speed = speed
        self.progress = progress
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case isPlaying, loop, speed, progress, background
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        loop = try container.decodeIfPresent(
            ExtensionMediaLoopMode.self,
            forKey: .loop
        ) ?? .loop
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        background = try container.decodeIfPresent(
            ExtensionMediaBackground.self,
            forKey: .background
        ) ?? .surface
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !speed.isFinite || !Self.speedRange.contains(speed) {
            issues.append(.init(
                path: "\(path).speed",
                message: "must be between \(Self.speedRange.lowerBound) "
                    + "and \(Self.speedRange.upperBound)"
            ))
        }
        if let progress, !progress.isFinite || progress < 0 || progress > 1 {
            issues.append(.init(path: "\(path).progress", message: "must be between 0 and 1"))
        }
        return issues
    }
}

/// Who draws the controls.
public enum ExtensionMediaTransport: String, Codable, CaseIterable, Equatable, Sendable {
    /// Threading draws play/pause, the scrubber and the elapsed time.
    case hostOwned = "host-owned"
    /// Canvas only. The extension supplies its own **low-frequency** controls beside it; a
    /// scrubber it drew itself would be a display-rate callback over a broker round trip.
    case hidden
}

// MARK: - State report

public enum ExtensionMediaPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case playing
    case paused
    case completed
    case failed
}

/// One marker inside a document — a named point on its timeline.
public struct ExtensionMediaMarker: Codable, Equatable, Sendable {
    public static let maximumCount = 64

    public let name: String
    /// Seconds from the document's start.
    public let time: Double
    /// Seconds. Zero for an instant marker.
    public let duration: Double

    public init(name: String, time: Double, duration: Double = 0) {
        self.name = name
        self.time = time
        self.duration = duration
    }
}

public struct ExtensionMediaMetadata: Codable, Equatable, Sendable {
    public let duration: Double
    public let frameRate: Double
    public let frameCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let layerCount: Int
    /// Capped at `ExtensionMediaMarker.maximumCount`.
    public let markers: [ExtensionMediaMarker]
    /// What the host declined to honour in this document, in the host's own vocabulary —
    /// `expressions-disabled`, `external-assets-dropped`. The extension shows the note; it never
    /// receives what was dropped.
    public let notes: [String]

    public init(
        duration: Double,
        frameRate: Double,
        frameCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        layerCount: Int,
        markers: [ExtensionMediaMarker] = [],
        notes: [String] = []
    ) {
        self.duration = duration
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.layerCount = layerCount
        self.markers = Array(markers.prefix(ExtensionMediaMarker.maximumCount))
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case duration, frameRate, frameCount, pixelWidth, pixelHeight, layerCount
        case markers, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(Double.self, forKey: .duration)
        frameRate = try container.decode(Double.self, forKey: .frameRate)
        frameCount = try container.decode(Int.self, forKey: .frameCount)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        layerCount = try container.decode(Int.self, forKey: .layerCount)
        markers = try container.decodeIfPresent(
            [ExtensionMediaMarker].self,
            forKey: .markers
        ) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// Why a document did not play.
///
/// A raw-value reason plus a host-authored sentence: the reason is what an extension may branch
/// on, and the sentence is what it may show. Neither carries a path or a byte of the document.
public struct ExtensionMediaFailure: Codable, Equatable, Sendable {
    public struct Reason: RawRepresentable, Codable, Hashable, Sendable,
        ExpressibleByStringLiteral
    {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// The host carries no renderer for this format.
        public static let unsupportedFormat: Self = "unsupported-format"
        /// The handle names nothing this generation may open — revoked, replaced, or minted for
        /// another contract.
        public static let unresolvedSource: Self = "unresolved-source"
        /// The document parsed as the wrong thing, or not at all.
        public static let invalidDocument: Self = "invalid-document"
        /// A stated ceiling was exceeded: bytes, pixels, layers, frames, archive entries.
        public static let exceedsLimits: Self = "exceeds-limits"
    }

    public let reason: Reason
    public let message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// A coalesced report about one media document, raised as the value of `stateActionID`.
public struct ExtensionMediaStateReport: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let documentID: String
    public let phase: ExtensionMediaPhase
    public let progress: Double
    /// Present on `.ready`.
    public let metadata: ExtensionMediaMetadata?
    /// Present on `.failed`.
    public let failure: ExtensionMediaFailure?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        documentID: String,
        phase: ExtensionMediaPhase,
        progress: Double,
        metadata: ExtensionMediaMetadata? = nil,
        failure: ExtensionMediaFailure? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.documentID = documentID
        self.phase = phase
        self.progress = progress
        self.metadata = metadata
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, documentID, phase, progress, metadata, failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .protocolVersion
        ) ?? Self.currentProtocolVersion
        documentID = try container.decode(String.self, forKey: .documentID)
        phase = try container.decode(ExtensionMediaPhase.self, forKey: .phase)
        progress = try container.decode(Double.self, forKey: .progress)
        metadata = try container.decodeIfPresent(ExtensionMediaMetadata.self, forKey: .metadata)
        failure = try container.decodeIfPresent(ExtensionMediaFailure.self, forKey: .failure)
    }

    /// The report as the JSON an action carries.
    ///
    /// Actions already move an `ExtensionJSONValue`, so the report reuses that transport rather
    /// than adding a second one: the host gains no new route, and an extension that does not
    /// declare `stateActionID` receives nothing at all.
    public var actionValue: ExtensionJSONValue {
        (try? ExtensionJSONValue.encoding(self)) ?? .emptyObject
    }

    /// Reads a report back out of an action value on the extension's side.
    public init?(actionValue: ExtensionJSONValue) {
        guard let report = try? actionValue.decoded(as: Self.self) else { return nil }
        self = report
    }
}

public extension ExtensionNode {

    /// Whether anywhere in this tree asks the host to play a document.
    ///
    /// Used by the capability gate: the authority is about the *contribution*, not the manifest,
    /// so a node buried three stacks down still has to have been disclosed.
    var containsMediaDocument: Bool {
        switch self {
        case .media:
            return true
        case .stack(_, _, let children):
            return children.contains { $0.containsMediaDocument }
        case .overlay(let base, let overlay):
            return base.containsMediaDocument || overlay.containsMediaDocument
        case .disclosure(_, let summary, let detail):
            return summary.containsMediaDocument || detail.contains { $0.containsMediaDocument }
        case .text, .image, .button, .textInput, .picker, .scene, .status, .proceed,
             .customSurface, .divider, .spacer, .flexibleSpacer:
            return false
        }
    }

    /// Every media document in this tree, in document order.
    var mediaDocuments: [ExtensionMediaDocument] {
        switch self {
        case .media(let document):
            return [document]
        case .stack(_, _, let children):
            return children.flatMap(\.mediaDocuments)
        case .overlay(let base, let overlay):
            return base.mediaDocuments + overlay.mediaDocuments
        case .disclosure(_, let summary, let detail):
            return summary.mediaDocuments + detail.flatMap(\.mediaDocuments)
        case .text, .image, .button, .textInput, .picker, .scene, .status, .proceed,
             .customSurface, .divider, .spacer, .flexibleSpacer:
            return []
        }
    }
}

public extension ExtensionJSONValue {

    /// Round-trips any `Encodable` through JSON into the value actions carry.
    static func encoding<Value: Encodable>(_ value: Value) throws -> ExtensionJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ExtensionJSONValue.self, from: data)
    }

    func decoded<Value: Decodable>(as type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
