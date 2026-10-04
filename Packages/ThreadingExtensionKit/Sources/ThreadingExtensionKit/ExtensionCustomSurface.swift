import Foundation

/// A custom visual surface described by an extension and hosted by Threading.
///
/// The extension owns the declarative surface definition. Threading owns the native view,
/// rendering lifecycle, resource limits, and input delivery.
public enum ExtensionCustomSurface: Codable, Equatable, Sendable {
    case metal(ExtensionMetalSurface)

    private enum CodingKeys: String, CodingKey {
        case type
        case shaderResource
        case fragmentFunction
        case preferredFramesPerSecond
        case inputs
        case texture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ExtensionCustomSurfaceKind.self, forKey: .type) {
        case .metal:
            self = .metal(ExtensionMetalSurface(
                shaderResource: try container.decode(String.self, forKey: .shaderResource),
                fragmentFunction: try container.decodeIfPresent(
                    String.self,
                    forKey: .fragmentFunction
                ) ?? ExtensionMetalSurface.defaultFragmentFunction,
                preferredFramesPerSecond: try container.decodeIfPresent(
                    Int.self,
                    forKey: .preferredFramesPerSecond
                ) ?? 60,
                inputs: try container.decodeIfPresent(
                    [ExtensionSurfaceInputBinding].self,
                    forKey: .inputs
                ) ?? [],
                texture: try container.decodeIfPresent(String.self, forKey: .texture)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .metal(let surface):
            try container.encode(ExtensionCustomSurfaceKind.metal, forKey: .type)
            try container.encode(surface.shaderResource, forKey: .shaderResource)
            try container.encode(surface.fragmentFunction, forKey: .fragmentFunction)
            try container.encode(
                surface.preferredFramesPerSecond,
                forKey: .preferredFramesPerSecond
            )
            try container.encode(surface.inputs, forKey: .inputs)
            // Absent rather than null: a surface without a picture encodes exactly as it did
            // before the field existed, so an old publication round-trips byte for byte.
            try container.encodeIfPresent(surface.texture, forKey: .texture)
        }
    }

    public var kind: ExtensionCustomSurfaceKind {
        switch self {
        case .metal: .metal
        }
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        switch self {
        case .metal(let surface):
            surface.validationIssues(path: path)
        }
    }
}

public enum ExtensionCustomSurfaceKind: String, Codable, Equatable, Sendable {
    case metal
}

/// A constrained custom Metal fragment surface.
///
/// `shaderResource` is package-relative source. Threading supplies the fullscreen vertex stage,
/// a stable uniform ABI, and at most eight scalar inputs. The extension never receives an
/// `MTLDevice`, command encoder, buffer, or AppKit object, and never constructs a texture.
///
/// A surface may name one package image as `texture`. The host — never the extension — reads it
/// through the package image limits (4 MiB, 1,024 × 1,024), decodes it off the main thread,
/// uploads it, and hands the fragment function a read-only `texture2d<float>` and a linear,
/// clamp-to-edge sampler. With a texture stated, the fragment function's signature is
///
/// ```metal
/// float4 threadingExtensionFragment(
///     float2 uv,
///     constant ThreadingSurfaceUniforms &uniforms,
///     texture2d<float> image,
///     sampler imageSampler
/// );
/// ```
///
/// Until the picture arrives — and if it never does — the host binds a 1 × 1 transparent
/// texture, so a sample reads `float4(0)` and the surface draws on. Samples are sRGB-encoded
/// with straight (not premultiplied) alpha — the convention the fragment function's own return
/// value is blended in — so returning a sample composites the picture as it is. Without
/// `texture` the two-argument signature is unchanged.
public struct ExtensionMetalSurface: Equatable, Sendable {
    public static let defaultFragmentFunction = "threadingExtensionFragment"
    /// The SDK's own cadence ceiling. A contract may state a lower one through
    /// `ExtensionComponentNodeConstraints.maximumCustomSurfaceFramesPerSecond`.
    public static let maximumFramesPerSecond = 60
    /// The package image formats a surface's `texture` may name.
    public static let textureExtensions: Set<String> = ["png", "jpg", "jpeg"]

    public let shaderResource: String
    public let fragmentFunction: String
    public let preferredFramesPerSecond: Int
    public let inputs: [ExtensionSurfaceInputBinding]
    /// A package-relative PNG or JPEG the host binds at fragment texture index 0, or nil for a
    /// surface drawn from its inputs alone. Stating one changes the fragment ABI; see the type.
    public let texture: String?

    public init(
        shaderResource: String,
        fragmentFunction: String = Self.defaultFragmentFunction,
        preferredFramesPerSecond: Int = 60,
        inputs: [ExtensionSurfaceInputBinding] = [],
        texture: String? = nil
    ) {
        self.shaderResource = shaderResource
        self.fragmentFunction = fragmentFunction
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.inputs = inputs
        self.texture = texture
    }

    public var isValid: Bool { validationIssues(path: "surface").isEmpty }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isSafeRelativePath(shaderResource)
            || URL(fileURLWithPath: shaderResource).pathExtension.lowercased() != "metal" {
            issues.append(.init(
                path: "\(path).shaderResource",
                message: "must be a package-relative '.metal' path"
            ))
        }
        if let texture,
           !ExtensionIdentifierRules.isSafeRelativePath(texture)
            || !Self.textureExtensions.contains(
                URL(fileURLWithPath: texture).pathExtension.lowercased()
            ) {
            issues.append(.init(
                path: "\(path).texture",
                message: "must be a package-relative '.png', '.jpg' or '.jpeg' path"
            ))
        }
        if !Self.isMetalIdentifier(fragmentFunction) {
            issues.append(.init(
                path: "\(path).fragmentFunction",
                message: "must be a valid Metal function identifier"
            ))
        }
        if !(1...Self.maximumFramesPerSecond).contains(preferredFramesPerSecond) {
            issues.append(.init(
                path: "\(path).preferredFramesPerSecond",
                message: "must be between 1 and \(Self.maximumFramesPerSecond)"
            ))
        }
        if inputs.count > 8 {
            issues.append(.init(path: "\(path).inputs", message: "must contain at most 8 inputs"))
        }
        var seen: Set<String> = []
        for (index, input) in inputs.enumerated() {
            issues.append(contentsOf: input.validationIssues(path: "\(path).inputs[\(index)]"))
            if !seen.insert(input.name).inserted {
                issues.append(.init(
                    path: "\(path).inputs[\(index)].name",
                    message: "duplicates '\(input.name)'"
                ))
            }
        }
        return issues
    }

    private static func isMetalIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isASCIILetter else { return false }
        return value.allSatisfy { $0 == "_" || $0.isASCIILetter || $0.isASCIIDigit }
    }
}

public struct ExtensionSurfaceInputBinding: Codable, Equatable, Sendable {
    public let name: String
    public let value: ExtensionSurfaceScalar

    public init(name: String, value: ExtensionSurfaceScalar) {
        self.name = name
        self.value = value
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(name) {
            issues.append(.init(
                path: "\(path).name",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        issues.append(contentsOf: value.validationIssues(path: "\(path).value"))
        return issues
    }
}

/// A scalar supplied to a custom surface either directly or from a host-owned live signal.
public enum ExtensionSurfaceScalar: Codable, Equatable, Sendable {
    case constant(Double)
    case signal(ExtensionHostSignal, mapping: ExtensionScalarMapping)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case signal
        case mapping
    }

    private enum Kind: String, Codable {
        case constant
        case signal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .constant:
            self = .constant(try container.decode(Double.self, forKey: .value))
        case .signal:
            self = .signal(
                try container.decode(ExtensionHostSignal.self, forKey: .signal),
                mapping: try container.decodeIfPresent(
                    ExtensionScalarMapping.self,
                    forKey: .mapping
                ) ?? .identity
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constant(let value):
            try container.encode(Kind.constant, forKey: .type)
            try container.encode(value, forKey: .value)
        case .signal(let signal, let mapping):
            try container.encode(Kind.signal, forKey: .type)
            try container.encode(signal, forKey: .signal)
            try container.encode(mapping, forKey: .mapping)
        }
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        switch self {
        case .constant(let value):
            return value.isFinite
                ? []
                : [.init(path: "\(path).value", message: "must be finite")]
        case .signal(let signal, let mapping):
            var issues = signal.rawValue.isEmpty
                ? [.init(path: "\(path).signal", message: "must not be empty")]
                : [ExtensionValidationIssue]()
            issues.append(contentsOf: mapping.validationIssues(path: "\(path).mapping"))
            return issues
        }
    }
}

/// A stable host-owned live value. Unknown signals are rejected by a host that cannot supply
/// them, while remaining decodable for authoring and inspection.
public struct ExtensionHostSignal: RawRepresentable, Codable, Hashable, Sendable,
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

    /// Remaining fraction, `0...1`, for the active session account's most constrained current
    /// limit. The signal resolves to its binding's fallback when no usage reading is available.
    public static let activeAccountUsageRemaining: Self =
        "active-account.usage-remaining"

    /// The app-wide activity envelope, `0...1`: a floor set by how many sessions are working
    /// right now, raised by recent output and decaying with quiet. This is the same reading the
    /// sidebar's workload analyzer draws, so a surface bound to it moves with the fleet rather
    /// than with a clock.
    public static let workloadIntensity: Self = "workload.intensity"

    /// The exact number of sessions working right now, as a count rather than a fraction. Bind
    /// it with an `inputMaximum` of your own choosing — eight is a busy Mac — so the mapping
    /// decides what "many" means for your surface.
    public static let workloadWorkingCount: Self = "workload.working-count"

    /// How far the local day has run, `0...1` from midnight to midnight, so a surface can follow
    /// the hour without the extension ever reading the clock.
    public static let timeOfDayFraction: Self = "time.day-fraction"

    /// The user-enabled, host-analyzed audio feed. Availability is 0 or 1; all other values
    /// are normalized 0...1 and resolve to the binding's fallback when capture is unavailable.
    /// A binding grants no recording, microphone, source selection or raw-audio authority.
    public static let audioAvailable: Self = "audio.available"
    public static let audioLevel: Self = "audio.level"
    public static let audioBass: Self = "audio.bass"
    public static let audioMids: Self = "audio.mids"
    public static let audioTreble: Self = "audio.treble"
    public static let audioBand0: Self = "audio.band.0"
    public static let audioBand1: Self = "audio.band.1"
    public static let audioBand2: Self = "audio.band.2"
    public static let audioBand3: Self = "audio.band.3"
    public static let audioBand4: Self = "audio.band.4"
    public static let audioBand5: Self = "audio.band.5"
    public static let audioBand6: Self = "audio.band.6"
    public static let audioBand7: Self = "audio.band.7"

    /// Bands run from bass to treble: 20–80, 80–200, 200–500, 500–1,200, 1,200–3,000,
    /// 3,000–6,000, 6,000–12,000 and 12,000–20,000 Hz (bounded by the source's Nyquist limit).
    public static let audioBands: [Self] = [
        .audioBand0, .audioBand1, .audioBand2, .audioBand3,
        .audioBand4, .audioBand5, .audioBand6, .audioBand7
    ]
    public static let audioSignals: [Self] = [
        .audioAvailable, .audioLevel, .audioBass, .audioMids, .audioTreble
    ] + audioBands

    public var requiresAudioCapture: Bool { Self.audioSignals.contains(self) }

    /// `1` when the app theme variant in force for the *surface's own* appearance is a dark
    /// variant, else `0`. Answered per surface, so under an adaptive theme a window drawn in
    /// light and one drawn in dark each read their own variant.
    public static let themeDark: Self = "theme.dark"
    /// The red, green and blue components, `0...1` in sRGB, of the theme's resolved `accent`
    /// role for the surface's own appearance — what Threading draws its own accents in, so a
    /// surface can lean toward the user's theme without the extension ever reading a colour.
    public static let themeAccentRed: Self = "theme.accent.red"
    public static let themeAccentGreen: Self = "theme.accent.green"
    public static let themeAccentBlue: Self = "theme.accent.blue"
    /// The red, green and blue components, `0...1` in sRGB, of the theme's resolved `ground`
    /// role — the window's own backdrop — for the surface's own appearance.
    public static let themeGroundRed: Self = "theme.ground.red"
    public static let themeGroundGreen: Self = "theme.ground.green"
    public static let themeGroundBlue: Self = "theme.ground.blue"

    /// The theme readings, in a stable order: darkness, then the accent and ground triples.
    public static let themeSignals: [Self] = [
        .themeDark,
        .themeAccentRed, .themeAccentGreen, .themeAccentBlue,
        .themeGroundRed, .themeGroundGreen, .themeGroundBlue
    ]

    /// A pulse when any session's turn comes back with an answer: `1` at the moment it happens,
    /// easing smoothly to `0` over `momentPulseDuration`, and `0` between moments. A turn that
    /// was interrupted, refused or stopped by a usage limit is not a finish and does not pulse.
    public static let momentTurnFinished: Self = "moment.turn-finished"
    /// A pulse when any session starts waiting on the person — a permission, a question — with
    /// the same shape as `momentTurnFinished`.
    public static let momentNeedsAttention: Self = "moment.needs-attention"

    /// How long a moment pulse takes to fall from `1` to `0`, in seconds. A moment arriving
    /// before the last one has decayed restarts the pulse at `1`.
    public static let momentPulseDuration: Double = 1.5

    /// The app-event pulses. A host reads them only while motion is allowed; otherwise a
    /// binding reads its fallback, as audio does.
    public static let momentSignals: [Self] = [.momentTurnFinished, .momentNeedsAttention]

    /// Whether this signal is a *reaction* to something happening — work, sound, an app event —
    /// rather than a standing fact about where or when the surface is drawn.
    ///
    /// True for `workload.*`, the audio level, bass/mids/treble and band readings, and
    /// `moment.*`. False for `audio.available` (a capability, not a reading), the theme
    /// readings, the time of day and the account's remaining usage. A host applies the person's
    /// reaction policy and strength to reactive readings — it may damp, hold or silence them —
    /// and never to the others, so bind a reactive signal for movement and a non-reactive one
    /// for identity and colour.
    public var isReactive: Bool { Self.reactiveSignals.contains(self) }

    private static let reactiveSignals: Set<Self> = Set(
        [.workloadIntensity, .workloadWorkingCount]
            + audioSignals.filter { $0 != .audioAvailable }
            + momentSignals
    )

    /// Every signal this SDK release names. A host may supply fewer — it refuses a patch naming
    /// one it cannot answer — and never more without a new SDK release naming them here.
    public static let all: [Self] = [
        .activeAccountUsageRemaining,
        .workloadIntensity,
        .workloadWorkingCount,
        .timeOfDayFraction
    ] + audioSignals + themeSignals + momentSignals
}

public struct ExtensionScalarMapping: Codable, Equatable, Sendable {
    public static let identity = Self()

    public let inputMinimum: Double
    public let inputMaximum: Double
    public let outputMinimum: Double
    public let outputMaximum: Double
    public let curve: ExtensionScalarCurve
    public let fallback: Double

    public init(
        inputMinimum: Double = 0,
        inputMaximum: Double = 1,
        outputMinimum: Double = 0,
        outputMaximum: Double = 1,
        curve: ExtensionScalarCurve = .linear,
        fallback: Double = 0
    ) {
        self.inputMinimum = inputMinimum
        self.inputMaximum = inputMaximum
        self.outputMinimum = outputMinimum
        self.outputMaximum = outputMaximum
        self.curve = curve
        self.fallback = fallback
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        let values = [inputMinimum, inputMaximum, outputMinimum, outputMaximum, fallback]
        guard values.allSatisfy(\.isFinite) else {
            return [.init(path: path, message: "all scalar mapping values must be finite")]
        }
        guard inputMaximum > inputMinimum else {
            return [.init(
                path: "\(path).inputMaximum",
                message: "must be greater than inputMinimum"
            )]
        }
        return []
    }
}

public enum ExtensionScalarCurve: String, Codable, Equatable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
}

private extension Character {
    var isASCIILetter: Bool {
        ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }

    var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
