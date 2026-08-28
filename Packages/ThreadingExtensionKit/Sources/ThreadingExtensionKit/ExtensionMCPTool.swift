import Foundation

/// A JSON value that can cross the extension process boundary without exposing host types.
///
/// MCP arguments and JSON schemas both need the full JSON vocabulary. Keeping the value in the
/// safe SDK lets generated extensions decode requests without importing an MCP implementation.
public enum ExtensionJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ExtensionJSONValue])
    case object([String: ExtensionJSONValue])

    public static let emptyObject = Self.object([:])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ExtensionJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ExtensionJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// Static, inspectable metadata for one MCP tool contributed by an extension.
///
/// The same value is repeated in the running process registration. Threading only exposes a tool
/// after the runtime definition matches this manifest declaration, so enabling an extension
/// cannot silently broaden the schema the user inspected.
public struct ExtensionMCPTool: Codable, Equatable, Sendable {
    /// The install proposal renders every accepted declaration, so these bounds are also the
    /// maximum package-supplied disclosure the confirmation sheet must lay out.
    public static let maximumCount = 32
    public static let maximumTitleLength = 120
    public static let maximumDescriptionLength = 500

    public let id: String
    public let title: String
    public let description: String
    public let inputSchema: ExtensionJSONValue

    public init(
        id: String,
        title: String,
        description: String,
        inputSchema: ExtensionJSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    public func qualifiedName(extensionIdentifier: String) -> String {
        let namespace = extensionIdentifier.replacingOccurrences(of: ".", with: "__")
        let contribution = id.replacingOccurrences(of: ".", with: "__")
        return "ext__\(namespace)__\(contribution)"
    }

    func validationIssues(path: String, extensionIdentifier: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []

        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).title", message: "must not be empty"))
        } else if title.count > Self.maximumTitleLength {
            issues.append(.init(
                path: "\(path).title",
                message: "must contain at most \(Self.maximumTitleLength) characters"
            ))
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).description", message: "must not be empty"))
        } else if description.count > Self.maximumDescriptionLength {
            issues.append(.init(
                path: "\(path).description",
                message: "must contain at most \(Self.maximumDescriptionLength) characters"
            ))
        }

        guard case .object(let schema) = inputSchema,
              schema["type"] == .string("object") else {
            issues.append(.init(
                path: "\(path).inputSchema",
                message: "must be a JSON Schema object whose top-level type is 'object'"
            ))
            return issues
        }

        if qualifiedName(extensionIdentifier: extensionIdentifier).count > 128 {
            issues.append(.init(
                path: "\(path).id",
                message: "produces an MCP tool name longer than 128 characters"
            ))
        }
        return issues
    }
}
