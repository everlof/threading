import Foundation

/// A separately signed macOS application that supplies optional privileged work for an
/// extension.
///
/// The companion is a worker, not a second extension API. The package's WebAssembly core still
/// owns settings, commands, component hooks, panels, tools, and ordinary host publications. A
/// companion may produce a remote surface or perform an OS operation only after Threading grants
/// the independently declared companion capabilities below.
public struct ExtensionCompanion: Codable, Equatable, Sendable {
    public static let maximumCount = 4

    public let id: String
    public let platform: ExtensionCompanionPlatform
    public let bundlePath: String
    public let activation: ExtensionCompanionActivation
    public let capabilities: Set<ExtensionCompanionCapability>
    public let operations: [ExtensionCompanionOperation]
    public let surfaces: [ExtensionRemoteSurface]

    public init(
        id: String,
        platform: ExtensionCompanionPlatform = .macOS,
        bundlePath: String,
        activation: ExtensionCompanionActivation = .onDemand,
        capabilities: Set<ExtensionCompanionCapability> = [],
        operations: [ExtensionCompanionOperation] = [],
        surfaces: [ExtensionRemoteSurface] = []
    ) {
        self.id = id
        self.platform = platform
        self.bundlePath = bundlePath
        self.activation = activation
        self.capabilities = capabilities
        self.operations = operations
        self.surfaces = surfaces
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, bundlePath, activation, capabilities, operations, surfaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        platform = try container.decodeIfPresent(
            ExtensionCompanionPlatform.self,
            forKey: .platform
        ) ?? .macOS
        bundlePath = try container.decode(String.self, forKey: .bundlePath)
        activation = try container.decodeIfPresent(
            ExtensionCompanionActivation.self,
            forKey: .activation
        ) ?? .onDemand
        capabilities = try container.decodeIfPresent(
            Set<ExtensionCompanionCapability>.self,
            forKey: .capabilities
        ) ?? []
        operations = try container.decodeIfPresent(
            [ExtensionCompanionOperation].self,
            forKey: .operations
        ) ?? []
        surfaces = try container.decodeIfPresent(
            [ExtensionRemoteSurface].self,
            forKey: .surfaces
        ) ?? []
    }

    /// The stable process identity expected in the nested app's `CFBundleIdentifier`.
    ///
    /// Deriving this rather than accepting an arbitrary identifier prevents one extension from
    /// presenting its worker as another product. Code-signing validation will bind the same
    /// identity before the companion runtime is allowed to launch.
    public func expectedBundleIdentifier(extensionIdentifier: String) -> String {
        "\(extensionIdentifier).companion.\(id)"
    }

    func validationIssues(
        path: String,
        extensionIdentifier: String
    ) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []

        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if !ExtensionIdentifierRules.isSafeRelativePath(bundlePath) {
            issues.append(.init(
                path: "\(path).bundlePath",
                message: "must be a safe package-relative path"
            ))
        } else if URL(fileURLWithPath: bundlePath).pathExtension.lowercased() != "app" {
            issues.append(.init(
                path: "\(path).bundlePath",
                message: "must name a macOS '.app' bundle"
            ))
        }
        if capabilities.count > ExtensionCompanionCapability.maximumPerCompanion {
            issues.append(.init(
                path: "\(path).capabilities",
                message: "must contain at most \(ExtensionCompanionCapability.maximumPerCompanion) values"
            ))
        }
        if operations.count > ExtensionCompanionOperation.maximumPerCompanion {
            issues.append(.init(
                path: "\(path).operations",
                message: "must contain at most \(ExtensionCompanionOperation.maximumPerCompanion) values"
            ))
        }
        if surfaces.count > ExtensionRemoteSurface.maximumPerCompanion {
            issues.append(.init(
                path: "\(path).surfaces",
                message: "must contain at most \(ExtensionRemoteSurface.maximumPerCompanion) values"
            ))
        }
        var operationIDs: Set<String> = []
        for (index, operation) in operations.enumerated() {
            let operationPath = "\(path).operations[\(index)]"
            issues.append(contentsOf: operation.validationIssues(path: operationPath))
            if !operationIDs.insert(operation.id).inserted {
                issues.append(.init(
                    path: "\(operationPath).id",
                    message: "duplicates '\(operation.id)'"
                ))
            }
        }
        var surfaceIDs: Set<String> = []
        for (index, surface) in surfaces.enumerated() {
            let surfacePath = "\(path).surfaces[\(index)]"
            issues.append(contentsOf: surface.validationIssues(path: surfacePath))
            if !surfaceIDs.insert(surface.id).inserted {
                issues.append(.init(
                    path: "\(surfacePath).id",
                    message: "duplicates '\(surface.id)'"
                ))
            }
        }
        if !surfaces.isEmpty, !capabilities.contains(.remoteSurfaces) {
            issues.append(.init(
                path: "\(path).capabilities",
                message: "must contain 'ui.remote-surfaces' when surfaces are declared"
            ))
        }

        let expectedIdentifier = expectedBundleIdentifier(
            extensionIdentifier: extensionIdentifier
        )
        if !ExtensionIdentifierRules.isReverseDNSIdentifier(expectedIdentifier) {
            issues.append(.init(
                path: "\(path).id",
                message: "does not produce a valid companion bundle identifier"
            ))
        }
        return issues
    }
}

/// One statically declared operation the Wasm core may ask its own companion to perform.
///
/// The schemas make the crossing inspectable without exposing an arbitrary pipe. Threading still
/// treats values as untrusted and enforces bounded JSON envelopes in both directions.
public struct ExtensionCompanionOperation: Codable, Equatable, Sendable {
    public static let maximumPerCompanion = 64

    public let id: String
    public let title: String
    public let description: String
    public let inputSchema: ExtensionJSONValue
    public let outputSchema: ExtensionJSONValue

    public init(
        id: String,
        title: String,
        description: String,
        inputSchema: ExtensionJSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ]),
        outputSchema: ExtensionJSONValue = .object([:])
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        issues.append(contentsOf: companionTextIssues(
            title,
            path: "\(path).title",
            maximum: 120
        ))
        issues.append(contentsOf: companionTextIssues(
            description,
            path: "\(path).description",
            maximum: 500
        ))
        if case .object(let schema) = inputSchema,
           schema["type"] == .string("object") {
            // Companion inputs are object-rooted like commands and services.
        } else {
            issues.append(.init(
                path: "\(path).inputSchema",
                message: "must be a JSON Schema object whose top-level type is 'object'"
            ))
        }
        if case .object = outputSchema {
            // The output value itself may have any JSON shape.
        } else {
            issues.append(.init(
                path: "\(path).outputSchema",
                message: "must be a JSON Schema object"
            ))
        }
        return issues
    }
}

/// Platform of a nested companion.
///
/// Only macOS is meaningful to the desktop host today. Keeping the platform explicit prevents
/// a later iOS renderer or remote client from accidentally trying to execute a desktop worker.
public enum ExtensionCompanionPlatform: String, Codable, Equatable, Sendable {
    case macOS
}

/// When Threading may run a companion.
///
/// `onDemand` is the quiet default for a device surface or one-shot integration.
/// `whileExtensionEnabled` is separately visible authority for proxies, watchers, and other
/// background services.
public enum ExtensionCompanionActivation: String, Codable, Equatable, Sendable {
    case onDemand
    case whileExtensionEnabled
}

/// OS-facing authority requested by one companion process.
///
/// This is intentionally separate from `ExtensionCapability`: a companion that captures a
/// window does not thereby gain project, session, account, storage, or other Threading host data.
/// Raw values keep future manifests inspectable by older hosts, which can then reject an
/// unsupported authority before copying or executing code.
public struct ExtensionCompanionCapability:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable
{
    public static let maximumPerCompanion = 32

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let backgroundService = Self(rawValue: "background.service")
    public static let processSpawn = Self(rawValue: "process.spawn")
    public static let networkClient = Self(rawValue: "network.client")
    public static let networkListen = Self(rawValue: "network.listen")
    public static let userSelectedFilesRead = Self(
        rawValue: "filesystem.user-selected.read"
    )
    public static let userSelectedFilesWrite = Self(
        rawValue: "filesystem.user-selected.write"
    )
    public static let screenCapture = Self(rawValue: "screen.capture")
    public static let inputControl = Self(rawValue: "input.control")
    public static let appleEvents = Self(rawValue: "automation.apple-events")
    public static let notifications = Self(rawValue: "notifications.post")
    public static let clipboardRead = Self(rawValue: "clipboard.read")
    public static let clipboardWrite = Self(rawValue: "clipboard.write")
    public static let remoteSurfaces = Self(rawValue: "ui.remote-surfaces")
}

/// Companion authorities understood by this SDK snapshot.
///
/// Runtime support remains independently fail-closed in the host. This list describes the
/// vocabulary an installer can inspect and present; it does not grant any entitlement or TCC
/// permission by itself.
public enum ThreadingCompanionAPI {
    public static let protocolVersion = 1

    public static let supportedCapabilities: Set<ExtensionCompanionCapability> = [
        .backgroundService,
        .processSpawn,
        .networkClient,
        .networkListen,
        .userSelectedFilesRead,
        .userSelectedFilesWrite,
        .screenCapture,
        .inputControl,
        .appleEvents,
        .notifications,
        .clipboardRead,
        .clipboardWrite,
        .remoteSurfaces
    ]
}

/// The first line a supervised companion writes to stdout.
///
/// Threading supplies the expected ID and generation in the launch environment and verifies both
/// here before treating the worker as ready. A stale process therefore cannot reconnect as a
/// newer generation merely because it still has a pipe open.
public struct ExtensionCompanionHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let companionID: String
    public let generation: String

    public init(
        protocolVersion: Int = ThreadingCompanionAPI.protocolVersion,
        companionID: String,
        generation: String
    ) {
        self.protocolVersion = protocolVersion
        self.companionID = companionID
        self.generation = generation
    }
}

/// A bounded control message written by Threading to a companion's stdin.
///
/// Graceful lifecycle messages share the private stdin stream with correlated operation
/// requests. The distinct envelopes keep shutdown impossible to mistake for extension input.
public struct ExtensionCompanionHostMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case shutdown
    }

    public let type: Kind
    public let generation: String

    public init(type: Kind, generation: String) {
        self.type = type
        self.generation = generation
    }
}

/// Wasm-core-to-host body for one declared companion operation.
public struct ExtensionCompanionOperationCall: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let arguments: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        arguments: ExtensionJSONValue = .emptyObject
    ) {
        self.protocolVersion = protocolVersion
        self.arguments = arguments
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if case .object = arguments {
            // Valid.
        } else {
            issues.append(.init(path: "arguments", message: "must be a JSON object"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Host-to-companion request on the companion's private control stream.
public struct ExtensionCompanionOperationRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let generation: String
    public let operationID: String
    public let arguments: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        generation: String,
        operationID: String,
        arguments: ExtensionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.generation = generation
        self.operationID = operationID
        self.arguments = arguments
    }

    public func validate() throws {
        let issues = companionOperationWireIssues(
            protocolVersion: protocolVersion,
            requestID: requestID,
            generation: generation,
            operationID: operationID,
            arguments: arguments
        )
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Companion-to-host correlated result.
public struct ExtensionCompanionOperationResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let generation: String
    public let operationID: String
    public let value: ExtensionJSONValue?
    public let error: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        generation: String,
        operationID: String,
        value: ExtensionJSONValue? = nil,
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.generation = generation
        self.operationID = operationID
        self.value = value
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, requestID, generation, operationID, value, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestID = try container.decode(String.self, forKey: .requestID)
        generation = try container.decode(String.self, forKey: .generation)
        operationID = try container.decode(String.self, forKey: .operationID)
        value = container.contains(.value)
            ? try container.decode(ExtensionJSONValue.self, forKey: .value)
            : nil
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(generation, forKey: .generation)
        try container.encode(operationID, forKey: .operationID)
        if let value {
            try container.encode(value, forKey: .value)
        }
        try container.encodeIfPresent(error, forKey: .error)
    }

    public func validate() throws {
        var issues = companionOperationWireIssues(
            protocolVersion: protocolVersion,
            requestID: requestID,
            generation: generation,
            operationID: operationID,
            arguments: .emptyObject
        )
        if value == nil, error == nil {
            issues.append(.init(path: "value", message: "or error must be present"))
        }
        if let error {
            if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "error", message: "must not be empty when present"))
            }
            if error.count > 2_000 {
                issues.append(.init(path: "error", message: "must contain at most 2000 characters"))
            }
            if value != nil {
                issues.append(.init(path: "error", message: "cannot be combined with a value"))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Successful host-broker result returned to the Wasm core.
public struct ExtensionCompanionOperationCallResult: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let companionID: String
    public let operationID: String
    public let value: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        companionID: String,
        operationID: String,
        value: ExtensionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.companionID = companionID
        self.operationID = operationID
        self.value = value
    }
}

/// Environment keys supplied by the companion supervisor.
///
/// There is deliberately no host URL, bearer token, storage path, project ID, or session ID.
/// Those belong to separately declared and brokered APIs.
public enum ExtensionCompanionEnvironment {
    public static let extensionIdentifier = "THREADING_EXTENSION_ID"
    public static let companionIdentifier = "THREADING_COMPANION_ID"
    public static let generation = "THREADING_COMPANION_GENERATION"
    public static let capabilitiesJSON = "THREADING_COMPANION_CAPABILITIES_JSON"
    /// Dedicated full-duplex binary socket for declared remote surfaces. Absent when the
    /// companion declares no surfaces.
    public static let remoteSurfaceDescriptor = "THREADING_COMPANION_SURFACE_FD"
}

private func companionOperationWireIssues(
    protocolVersion: Int,
    requestID: String,
    generation: String,
    operationID: String,
    arguments: ExtensionJSONValue
) -> [ExtensionValidationIssue] {
    var issues: [ExtensionValidationIssue] = []
    if protocolVersion != 1 {
        issues.append(.init(
            path: "protocolVersion",
            message: "expected 1, got \(protocolVersion)"
        ))
    }
    if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.init(path: "requestID", message: "must not be empty"))
    }
    if generation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.init(path: "generation", message: "must not be empty"))
    }
    if !ExtensionIdentifierRules.isContributionIdentifier(operationID) {
        issues.append(.init(
            path: "operationID",
            message: ExtensionIdentifierRules.contributionMessage
        ))
    }
    if case .object = arguments {
        // Valid.
    } else {
        issues.append(.init(path: "arguments", message: "must be a JSON object"))
    }
    return issues
}

private func companionTextIssues(
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
