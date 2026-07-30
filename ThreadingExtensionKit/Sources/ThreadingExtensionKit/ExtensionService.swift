import Foundation

/// A statically inspectable service exposed by one extension to other extensions.
///
/// Services exchange JSON values through Threading's broker. They never expose the provider's
/// storage directory, process, host token, or implementation type.
public struct ExtensionServiceDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let description: String
    public let inputSchema: ExtensionJSONValue
    public let outputSchema: ExtensionJSONValue

    public init(
        id: String,
        version: Int = 1,
        title: String,
        description: String,
        inputSchema: ExtensionJSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ]),
        outputSchema: ExtensionJSONValue = .object([:])
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if version < 1 {
            issues.append(.init(path: "\(path).version", message: "must be at least 1"))
        }
        issues.append(contentsOf: serviceTextIssues(
            title,
            path: "\(path).title",
            maximum: 120
        ))
        issues.append(contentsOf: serviceTextIssues(
            description,
            path: "\(path).description",
            maximum: 500
        ))
        if case .object(let input) = inputSchema,
           input["type"] == .string("object") {
            // Service arguments are always an object so the wire format can evolve compatibly.
        } else {
            issues.append(.init(
                path: "\(path).inputSchema",
                message: "must be a JSON Schema object whose top-level type is 'object'"
            ))
        }
        if case .object = outputSchema {
            // Output may be any JSON shape, so its schema need not declare an object root.
        } else {
            issues.append(.init(
                path: "\(path).outputSchema",
                message: "must be a JSON Schema object"
            ))
        }
        return issues
    }
}

/// One exact service authority requested by a consuming extension.
///
/// Exact versions make upgrades explicit. A provider may publish several versions under
/// different definitions while consumers migrate independently.
public struct ExtensionServiceDependency: Codable, Equatable, Hashable, Sendable {
    public let providerIdentifier: String
    public let serviceID: String
    public let version: Int
    public let required: Bool

    public init(
        providerIdentifier: String,
        serviceID: String,
        version: Int = 1,
        required: Bool = false
    ) {
        self.providerIdentifier = providerIdentifier
        self.serviceID = serviceID
        self.version = version
        self.required = required
    }

    public func validationIssues(
        path: String,
        consumerIdentifier: String
    ) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isReverseDNSIdentifier(providerIdentifier) {
            issues.append(.init(
                path: "\(path).providerIdentifier",
                message: "must be a lowercase reverse-DNS identifier"
            ))
        }
        if providerIdentifier == consumerIdentifier {
            issues.append(.init(
                path: "\(path).providerIdentifier",
                message: "must name another extension"
            ))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(serviceID) {
            issues.append(.init(
                path: "\(path).serviceID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if version < 1 {
            issues.append(.init(path: "\(path).version", message: "must be at least 1"))
        }
        return issues
    }
}

/// The consumer-to-host body for one declared service call.
public struct ExtensionServiceCall: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let serviceVersion: Int
    public let arguments: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        serviceVersion: Int = 1,
        arguments: ExtensionJSONValue = .emptyObject
    ) {
        self.protocolVersion = protocolVersion
        self.serviceVersion = serviceVersion
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
        if serviceVersion < 1 {
            issues.append(.init(path: "serviceVersion", message: "must be at least 1"))
        }
        if case .object = arguments {
            // Service inputs are object-rooted, matching their declared input schemas.
        } else {
            issues.append(.init(path: "arguments", message: "must be a JSON object"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// The broker-to-provider request delivered on the provider's JSONL process stream.
public struct ExtensionServiceRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let callerExtensionIdentifier: String
    public let serviceID: String
    public let serviceVersion: Int
    public let arguments: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        callerExtensionIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        arguments: ExtensionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.callerExtensionIdentifier = callerExtensionIdentifier
        self.serviceID = serviceID
        self.serviceVersion = serviceVersion
        self.arguments = arguments
    }

    public func validate() throws {
        var issues = serviceWireIssues(
            protocolVersion: protocolVersion,
            requestID: requestID,
            serviceID: serviceID,
            serviceVersion: serviceVersion
        )
        if !ExtensionIdentifierRules.isReverseDNSIdentifier(callerExtensionIdentifier) {
            issues.append(.init(
                path: "callerExtensionIdentifier",
                message: "must be a lowercase reverse-DNS identifier"
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

/// The provider's correlated service result.
public struct ExtensionServiceResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let serviceID: String
    public let serviceVersion: Int
    public let value: ExtensionJSONValue?
    public let error: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        serviceID: String,
        serviceVersion: Int,
        value: ExtensionJSONValue? = nil,
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.serviceID = serviceID
        self.serviceVersion = serviceVersion
        self.value = value
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case serviceID
        case serviceVersion
        case value
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestID = try container.decode(String.self, forKey: .requestID)
        serviceID = try container.decode(String.self, forKey: .serviceID)
        serviceVersion = try container.decode(Int.self, forKey: .serviceVersion)
        value = container.contains(.value)
            ? try container.decode(ExtensionJSONValue.self, forKey: .value)
            : nil
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(serviceID, forKey: .serviceID)
        try container.encode(serviceVersion, forKey: .serviceVersion)
        if let value {
            try container.encode(value, forKey: .value)
        }
        try container.encodeIfPresent(error, forKey: .error)
    }

    public func validate() throws {
        var issues = serviceWireIssues(
            protocolVersion: protocolVersion,
            requestID: requestID,
            serviceID: serviceID,
            serviceVersion: serviceVersion
        )
        if value == nil, error == nil {
            issues.append(.init(path: "value", message: "or error must be present"))
        }
        if let error {
            if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "error", message: "must not be empty when present"))
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

/// The successful provider result returned by Threading's host broker to the consumer.
public struct ExtensionServiceCallResult: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let providerIdentifier: String
    public let serviceID: String
    public let serviceVersion: Int
    public let value: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        providerIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        value: ExtensionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.providerIdentifier = providerIdentifier
        self.serviceID = serviceID
        self.serviceVersion = serviceVersion
        self.value = value
    }
}

private func serviceWireIssues(
    protocolVersion: Int,
    requestID: String,
    serviceID: String,
    serviceVersion: Int
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
    if !ExtensionIdentifierRules.isContributionIdentifier(serviceID) {
        issues.append(.init(
            path: "serviceID",
            message: ExtensionIdentifierRules.contributionMessage
        ))
    }
    if serviceVersion < 1 {
        issues.append(.init(path: "serviceVersion", message: "must be at least 1"))
    }
    return issues
}

private func serviceTextIssues(
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
