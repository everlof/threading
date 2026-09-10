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
                ) ?? []
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
/// `MTLDevice`, command encoder, texture, buffer, or AppKit object.
public struct ExtensionMetalSurface: Equatable, Sendable {
    public static let defaultFragmentFunction = "threadingExtensionFragment"
    /// The SDK's own cadence ceiling. A contract may state a lower one through
    /// `ExtensionComponentNodeConstraints.maximumCustomSurfaceFramesPerSecond`.
    public static let maximumFramesPerSecond = 60

    public let shaderResource: String
    public let fragmentFunction: String
    public let preferredFramesPerSecond: Int
    public let inputs: [ExtensionSurfaceInputBinding]

    public init(
        shaderResource: String,
        fragmentFunction: String = Self.defaultFragmentFunction,
        preferredFramesPerSecond: Int = 60,
        inputs: [ExtensionSurfaceInputBinding] = []
    ) {
        self.shaderResource = shaderResource
        self.fragmentFunction = fragmentFunction
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.inputs = inputs
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isSafeRelativePath(shaderResource)
            || URL(fileURLWithPath: shaderResource).pathExtension.lowercased() != "metal" {
            issues.append(.init(
                path: "\(path).shaderResource",
                message: "must be a package-relative '.metal' path"
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

    /// Every signal this SDK release names. A host may supply fewer — it refuses a patch naming
    /// one it cannot answer — and never more without a new SDK release naming them here.
    public static let all: [Self] = [
        .activeAccountUsageRemaining,
        .workloadIntensity,
        .workloadWorkingCount,
        .timeOfDayFraction
    ]
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
