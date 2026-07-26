import Foundation

/// One semantic action raised by extension-rendered content inside a host component.
///
/// The contributing extension identity is not carried on the wire: Skalman already selected
/// the owning supervised process from the accepted patch's provenance.
public struct ExtensionComponentActionRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let target: ExtensionComponentTarget
    public let actionID: String

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        target: ExtensionComponentTarget,
        actionID: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.target = target
        self.actionID = actionID
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if target.component.rawValue.isEmpty {
            issues.append(.init(path: "target.component", message: "must not be empty"))
        }
        if target.contractVersion < 1 {
            issues.append(.init(path: "target.contractVersion", message: "must be at least 1"))
        }
        if let entityID = target.entityID,
           entityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "target.entityID", message: "must not be empty"))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(actionID) {
            issues.append(.init(
                path: "actionID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// One button action sent from Skalman to a running extension.
///
/// The process protocol is newline-delimited JSON. Every value occupies exactly one line and
/// stdout is reserved for these values; extensions must write diagnostics to stderr.
public struct ExtensionActionRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let panelID: String
    public let actionID: String
    public let context: ExtensionCommandContext

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        panelID: String,
        actionID: String,
        context: ExtensionCommandContext = .init()
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.panelID = panelID
        self.actionID = actionID
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, requestID, panelID, actionID, context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestID = try container.decode(String.self, forKey: .requestID)
        panelID = try container.decode(String.self, forKey: .panelID)
        actionID = try container.decode(String.self, forKey: .actionID)
        context = try container.decodeIfPresent(
            ExtensionCommandContext.self,
            forKey: .context
        ) ?? .init()
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []

        if protocolVersion != Self.currentProtocolVersion {
            issues.append(
                .init(
                    path: "protocolVersion",
                    message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
                )
            )
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(panelID) {
            issues.append(.init(path: "panelID", message: ExtensionIdentifierRules.contributionMessage))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(actionID) {
            issues.append(.init(path: "actionID", message: ExtensionIdentifierRules.contributionMessage))
        }
        issues.append(contentsOf: context.validationIssues(path: "context"))

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// The correlated result of one extension action.
///
/// A successful action may return a replacement for the panel that raised it, a short message,
/// or both. An error is mutually exclusive with those success values.
public struct ExtensionActionResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let panel: ExtensionPanel?
    public let message: String?
    public let error: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        panel: ExtensionPanel? = nil,
        message: String? = nil,
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.panel = panel
        self.message = message
        self.error = error
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []

        if protocolVersion != Self.currentProtocolVersion {
            issues.append(
                .init(
                    path: "protocolVersion",
                    message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
                )
            )
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if let error {
            if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "error", message: "must not be empty when present"))
            }
            if panel != nil || message != nil {
                issues.append(
                    .init(
                        path: "error",
                        message: "cannot be combined with a panel or success message"
                    )
                )
            }
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// The current host selection supplied to a user-invoked extension command.
///
/// IDs are opaque routing values. Receiving one does not grant access to project or session
/// snapshots; those remain gated by their own host-data capabilities.
public struct ExtensionCommandContext: Codable, Equatable, Sendable {
    public let projectID: String?
    public let sessionID: String?

    public init(projectID: String? = nil, sessionID: String? = nil) {
        self.projectID = projectID
        self.sessionID = sessionID
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if let projectID,
           projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).projectID", message: "must not be empty when present"))
        }
        if let sessionID,
           sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).sessionID", message: "must not be empty when present"))
        }
        return issues
    }
}

/// One command selected from Skalman's menu or invoked through its resolved keyboard shortcut.
public struct ExtensionCommandRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let commandID: String
    public let context: ExtensionCommandContext

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        commandID: String,
        context: ExtensionCommandContext = .init()
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.commandID = commandID
        self.context = context
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(commandID) {
            issues.append(.init(path: "commandID", message: ExtensionIdentifierRules.contributionMessage))
        }
        issues.append(contentsOf: context.validationIssues(path: "context"))
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// The correlated result of an extension command.
///
/// A message is optional because many commands communicate by publishing new component state.
/// An error is mutually exclusive with a success message.
public struct ExtensionCommandResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let commandID: String
    public let message: String?
    public let error: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        commandID: String,
        message: String? = nil,
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.commandID = commandID
        self.message = message
        self.error = error
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(commandID) {
            issues.append(.init(path: "commandID", message: ExtensionIdentifierRules.contributionMessage))
        }
        if let message,
           message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "message", message: "must not be empty when present"))
        }
        if let error {
            if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "error", message: "must not be empty when present"))
            }
            if message != nil {
                issues.append(.init(path: "error", message: "cannot be combined with a success message"))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// A host-validated settings change delivered to a running extension.
///
/// At launch, current values are also available in `ExtensionSettingsEnvironment.valuesJSON`.
/// Runtime updates contain one or more complete field values and never expose host storage.
public struct ExtensionSettingsUpdateRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let currentSettingsVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let settingsVersion: Int
    public let values: [String: ExtensionJSONValue]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        settingsVersion: Int = Self.currentSettingsVersion,
        values: [String: ExtensionJSONValue]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.settingsVersion = settingsVersion
        self.values = values
    }

    public func validate(against settings: ExtensionSettingsContribution) throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if settingsVersion != Self.currentSettingsVersion {
            issues.append(.init(
                path: "settingsVersion",
                message: "expected \(Self.currentSettingsVersion), got \(settingsVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if values.isEmpty {
            issues.append(.init(path: "values", message: "must not be empty"))
        }
        for (id, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let field = settings.field(id: id) else {
                issues.append(.init(path: "values.\(id)", message: "is not a declared setting"))
                continue
            }
            if !field.control.accepts(value) {
                issues.append(.init(
                    path: "values.\(id)",
                    message: "does not match the declared control"
                ))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// The correlated acknowledgement for an `ExtensionSettingsUpdateRequest`.
///
/// `settingIDs` is required so this response remains distinguishable from every other response
/// in the JSONL protocol. On success it must echo exactly the IDs supplied by the host.
public struct ExtensionSettingsUpdateResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let settingIDs: [String]
    public let error: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        settingIDs: [String],
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.settingIDs = settingIDs
        self.error = error
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if settingIDs.isEmpty {
            issues.append(.init(path: "settingIDs", message: "must not be empty"))
        }
        if Set(settingIDs).count != settingIDs.count {
            issues.append(.init(path: "settingIDs", message: "must not contain duplicates"))
        }
        for (index, id) in settingIDs.enumerated()
            where !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "settingIDs[\(index)]",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if let error,
           error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "error", message: "must not be empty when present"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// One MCP invocation forwarded by Skalman to the extension that registered the tool.
///
/// `sessionID` is an opaque routing identifier. It lets an extension correlate cache entries or
/// future host-data requests with the conversation that called it without exposing Skalman's
/// internal session model.
public struct ExtensionMCPToolRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let toolID: String
    public let arguments: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        sessionID: String,
        toolID: String,
        arguments: ExtensionJSONValue = .emptyObject
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.toolID = toolID
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
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "sessionID", message: "must not be empty"))
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(toolID) {
            issues.append(.init(path: "toolID", message: ExtensionIdentifierRules.contributionMessage))
        }
        if case .object = arguments {
            // MCP input schemas are object-rooted, so calls use the same shape.
        } else {
            issues.append(.init(path: "arguments", message: "must be a JSON object"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Plain-text MCP output returned by an extension.
///
/// Rich content can be added later without changing routing. Starting with text mirrors
/// Skalman's built-in tools and keeps results cheap for the calling conversation.
public struct ExtensionMCPToolResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let text: String
    public let isError: Bool

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        text: String,
        isError: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.text = text
        self.isError = isError
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}
