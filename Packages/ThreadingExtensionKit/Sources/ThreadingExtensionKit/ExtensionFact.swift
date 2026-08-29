import Foundation

/// The stable, versioned name of one queryable fact.
///
/// Versions are separate from `id` so a host can publish an old and a new vocabulary together
/// while extensions migrate. Changing a value's meaning or scalar type requires a new version.
public struct ExtensionFactKey: Codable, Equatable, Hashable, Sendable {
    public static let maximumIDBytes = 128
    public static let versionRange = 1...1_000_000

    public let id: String
    public let version: Int

    public init(id: String, version: Int = 1) {
        self.id = id
        self.version = version
    }

    public func validationIssues(path: String = "key") -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if id.utf8.count > Self.maximumIDBytes {
            issues.append(.init(
                path: "\(path).id",
                message: "must be at most \(Self.maximumIDBytes) UTF-8 bytes"
            ))
        }
        if !Self.versionRange.contains(version) {
            issues.append(.init(
                path: "\(path).version",
                message: "must be between 1 and 1000000"
            ))
        }
        return issues
    }
}

public enum ExtensionFactSubjectKind: String, Codable, CaseIterable, Equatable, Hashable,
    Sendable
{
    case session
    case project
    case terminal
    case repository
    case repositoryBranch
}

/// Boundary-safe forge identity. It deliberately contains no URL, credentials, checkout path,
/// git-directory path, or local repository identity.
public struct ExtensionRepositoryKey: Codable, Equatable, Hashable, Sendable {
    public static let maximumHostBytes = 255
    public static let maximumPathBytes = 512

    public let host: String
    public let path: String

    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    fileprivate func validationIssues(path valuePath: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostParts = host.split(separator: ".", omittingEmptySubsequences: false)
        let isCanonicalHost = !hostParts.isEmpty && hostParts.allSatisfy { part in
            guard !part.isEmpty, part.first != "-", part.last != "-" else { return false }
            return part.allSatisfy { character in
                character.isLowercaseASCII || character.isASCIINumber || character == "-"
            }
        }
        if trimmedHost.isEmpty || host != trimmedHost || !isCanonicalHost {
            issues.append(.init(
                path: "\(valuePath).host",
                message: "must be a canonical lowercase host without credentials, port, scheme, or path"
            ))
        }
        if host.utf8.count > Self.maximumHostBytes {
            issues.append(.init(
                path: "\(valuePath).host",
                message: "must be at most \(Self.maximumHostBytes) UTF-8 bytes"
            ))
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        let isCanonicalPath = !pathParts.isEmpty && pathParts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
        }
        if trimmedPath.isEmpty || path != trimmedPath || !isCanonicalPath
            || path.contains("\\") || path.contains("?") || path.contains("#")
            || path.lowercased().hasSuffix(".git")
        {
            issues.append(.init(
                path: "\(valuePath).path",
                message: "must be a canonical repository path without traversal, URL syntax, or '.git'"
            ))
        }
        if path.utf8.count > Self.maximumPathBytes {
            issues.append(.init(
                path: "\(valuePath).path",
                message: "must be at most \(Self.maximumPathBytes) UTF-8 bytes"
            ))
        }
        return issues
    }
}

/// The entity or domain identity a fact describes.
public enum ExtensionFactSubject: Codable, Equatable, Hashable, Sendable {
    public static let maximumOpaqueIDBytes = 256
    public static let maximumBranchBytes = 512

    case session(String)
    case project(String)
    case terminal(String)
    case repository(ExtensionRepositoryKey)
    case repositoryBranch(repository: ExtensionRepositoryKey, branch: String)

    public var kind: ExtensionFactSubjectKind {
        switch self {
        case .session: .session
        case .project: .project
        case .terminal: .terminal
        case .repository: .repository
        case .repositoryBranch: .repositoryBranch
        }
    }

    public func validationIssues(path: String = "subject") -> [ExtensionValidationIssue] {
        switch self {
        case .session(let id), .project(let id), .terminal(let id):
            guard !id.isEmpty, id.utf8.count <= Self.maximumOpaqueIDBytes else {
                return [.init(
                    path: "\(path).id",
                    message: "must be 1 to \(Self.maximumOpaqueIDBytes) UTF-8 bytes"
                )]
            }
            return []
        case .repository(let repository):
            return repository.validationIssues(path: "\(path).repository")
        case .repositoryBranch(let repository, let branch):
            var issues = repository.validationIssues(path: "\(path).repository")
            if branch.isEmpty || branch.utf8.count > Self.maximumBranchBytes {
                issues.append(.init(
                    path: "\(path).branch",
                    message: "must be 1 to \(Self.maximumBranchBytes) UTF-8 bytes"
                ))
            }
            return issues
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case repository
        case branch
    }

    private enum Kind: String, Codable {
        case session
        case project
        case terminal
        case repository
        case repositoryBranch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .session:
            self = .session(try container.decode(String.self, forKey: .id))
        case .project:
            self = .project(try container.decode(String.self, forKey: .id))
        case .terminal:
            self = .terminal(try container.decode(String.self, forKey: .id))
        case .repository:
            self = .repository(
                try container.decode(ExtensionRepositoryKey.self, forKey: .repository)
            )
        case .repositoryBranch:
            self = .repositoryBranch(
                repository: try container.decode(
                    ExtensionRepositoryKey.self,
                    forKey: .repository
                ),
                branch: try container.decode(String.self, forKey: .branch)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let id):
            try container.encode(Kind.session, forKey: .type)
            try container.encode(id, forKey: .id)
        case .project(let id):
            try container.encode(Kind.project, forKey: .type)
            try container.encode(id, forKey: .id)
        case .terminal(let id):
            try container.encode(Kind.terminal, forKey: .type)
            try container.encode(id, forKey: .id)
        case .repository(let repository):
            try container.encode(Kind.repository, forKey: .type)
            try container.encode(repository, forKey: .repository)
        case .repositoryBranch(let repository, let branch):
            try container.encode(Kind.repositoryBranch, forKey: .type)
            try container.encode(repository, forKey: .repository)
            try container.encode(branch, forKey: .branch)
        }
    }
}

public enum ExtensionFactValueType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case string
    case boolean
    case integer
    case number
    case date
}

/// One scalar value used by navigator filters, buckets and sorts.
public enum ExtensionFactValue: Codable, Equatable, Hashable, Sendable {
    public static let maximumStringBytes = 1_024

    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case date(Date)

    public var type: ExtensionFactValueType {
        switch self {
        case .string: .string
        case .boolean: .boolean
        case .integer: .integer
        case .number: .number
        case .date: .date
        }
    }

    public func validationIssues(path: String = "value") -> [ExtensionValidationIssue] {
        switch self {
        case .string(let value):
            guard value.utf8.count <= Self.maximumStringBytes else {
                return [.init(
                    path: path,
                    message: "must be at most \(Self.maximumStringBytes) UTF-8 bytes"
                )]
            }
        case .number(let value):
            guard value.isFinite else {
                return [.init(path: path, message: "must be finite")]
            }
        case .date(let value):
            guard value.timeIntervalSinceReferenceDate.isFinite else {
                return [.init(path: path, message: "must be finite")]
            }
        case .boolean, .integer:
            break
        }
        return []
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ExtensionFactValueType.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .string(let value): try container.encode(value, forKey: .value)
        case .boolean(let value): try container.encode(value, forKey: .value)
        case .integer(let value): try container.encode(value, forKey: .value)
        case .number(let value): try container.encode(value, forKey: .value)
        case .date(let value): try container.encode(value, forKey: .value)
        }
    }
}

public enum ExtensionFactUsage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case filterable
    case sortable
    case groupable
    case searchable
    case presentable
}

/// Self-describing metadata for one fact key.
public struct ExtensionFactDefinition: Codable, Equatable, Hashable, Sendable {
    public static let maximumDisplayNameBytes = 256

    public let key: ExtensionFactKey
    public let displayName: String
    public let valueType: ExtensionFactValueType
    public let subjectKinds: Set<ExtensionFactSubjectKind>
    public let usages: Set<ExtensionFactUsage>

    public init(
        key: ExtensionFactKey,
        displayName: String,
        valueType: ExtensionFactValueType,
        subjectKinds: Set<ExtensionFactSubjectKind>,
        usages: Set<ExtensionFactUsage>
    ) {
        self.key = key
        self.displayName = displayName
        self.valueType = valueType
        self.subjectKinds = subjectKinds
        self.usages = usages
    }

    public func validate() throws {
        var issues = key.validationIssues()
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "displayName", message: "must not be empty"))
        }
        if displayName.utf8.count > Self.maximumDisplayNameBytes {
            issues.append(.init(
                path: "displayName",
                message: "must be at most \(Self.maximumDisplayNameBytes) UTF-8 bytes"
            ))
        }
        if subjectKinds.isEmpty {
            issues.append(.init(path: "subjectKinds", message: "must not be empty"))
        }
        if usages.isEmpty {
            issues.append(.init(path: "usages", message: "must not be empty"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// A scalar fact plus optional presentation that never participates in comparison.
public struct ExtensionFact: Codable, Equatable, Hashable, Sendable {
    public static let maximumLabelBytes = 256
    public static let maximumIconReferenceBytes = 512

    public let key: ExtensionFactKey
    public let subject: ExtensionFactSubject
    public let value: ExtensionFactValue
    public let label: String?
    public let status: ExtensionStatusRole?
    public let icon: ExtensionImageReference?
    public let observedAt: Date

    public init(
        key: ExtensionFactKey,
        subject: ExtensionFactSubject,
        value: ExtensionFactValue,
        label: String? = nil,
        status: ExtensionStatusRole? = nil,
        icon: ExtensionImageReference? = nil,
        observedAt: Date
    ) {
        self.key = key
        self.subject = subject
        self.value = value
        self.label = label
        self.status = status
        self.icon = icon
        self.observedAt = observedAt
    }

    public func validate() throws {
        var issues = key.validationIssues()
        issues.append(contentsOf: subject.validationIssues())
        issues.append(contentsOf: value.validationIssues())
        if let label, label.utf8.count > Self.maximumLabelBytes {
            issues.append(.init(
                path: "label",
                message: "must be at most \(Self.maximumLabelBytes) UTF-8 bytes"
            ))
        }
        if !observedAt.timeIntervalSinceReferenceDate.isFinite {
            issues.append(.init(path: "observedAt", message: "must be finite"))
        }
        if let icon {
            switch icon {
            case .hostAsset(let id):
                if !Self.isBoundedPresentationString(id) {
                    issues.append(.init(
                        path: "icon",
                        message: "host asset ID must be 1 to \(Self.maximumIconReferenceBytes) UTF-8 bytes"
                    ))
                }
            case .extensionResource(let resourcePath):
                if !Self.isBoundedPresentationString(resourcePath)
                    || !ExtensionIdentifierRules.isSafeRelativePath(resourcePath)
                {
                    issues.append(.init(path: "icon", message: "resource must be a safe relative path"))
                }
            case .systemSymbol(let name):
                if !Self.isBoundedPresentationString(name) {
                    issues.append(.init(
                        path: "icon",
                        message: "symbol name must be 1 to \(Self.maximumIconReferenceBytes) UTF-8 bytes"
                    ))
                }
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    private static func isBoundedPresentationString(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumIconReferenceBytes
    }
}

/// Threading-owned fact keys. These IDs are reserved and always resolve ahead of extension facts.
public enum ExtensionHostFactKey {
    /// Namespace reservation applies to every version, including IDs Threading adds later.
    public static let reservedIDPrefixes = [
        "session.", "project.", "terminal.", "repository.", "checkout.",
    ]

    public static func isReserved(_ key: ExtensionFactKey) -> Bool {
        reservedIDPrefixes.contains { key.id.hasPrefix($0) }
    }

    private static func key(_ id: String) -> ExtensionFactKey { .init(id: id, version: 1) }

    public static let sessionProjectID = key("session.project-id")
    public static let sessionCheckoutID = key("session.checkout-id")
    public static let sessionTitle = key("session.title")
    public static let sessionProviderID = key("session.provider-id")
    public static let sessionAccountID = key("session.account-id")
    public static let sessionActivity = key("session.activity")
    public static let sessionDetailedActivity = key("session.activity.detailed")
    public static let sessionBranch = key("session.branch")
    public static let sessionParentID = key("session.parent-id")
    public static let sessionIsSideChat = key("session.is-side-chat")
    public static let sessionIsArchived = key("session.is-archived")
    public static let sessionUsesNativeUI = key("session.uses-native-ui")
    public static let sessionIsPinned = key("session.is-pinned")
    public static let sessionIsSnoozed = key("session.is-snoozed")
    public static let sessionSnoozedAt = key("session.snoozed-at")
    public static let sessionSnoozedUntil = key("session.snoozed-until")
    public static let sessionWakeReason = key("session.wake-reason")
    public static let sessionWokeAt = key("session.woke-at")
    public static let sessionCreatedAt = key("session.created-at")
    public static let sessionLastActiveAt = key("session.last-active-at")
    public static let sessionLastTurnAt = key("session.last-turn-at")
    public static let sessionLastUsedAt = key("session.last-used-at")
    public static let sessionManualOrder = key("session.manual-order")
    public static let sessionModel = key("session.model")
    public static let sessionManagerID = key("session.manager-id")
    public static let sessionIsManager = key("session.is-manager")
    public static let sessionHasCustomConduct = key("session.has-custom-conduct")
    public static let sessionHasScheduledStart = key("session.has-scheduled-start")
    public static let sessionScheduledStartAt = key("session.scheduled-start-at")

    public static let projectName = key("project.name")
    public static let projectManualOrder = key("project.manual-order")
    public static let projectIsScratchpad = key("project.is-scratchpad")
    public static let projectCreatedAt = key("project.created-at")
    public static let projectRepositoryHost = key("project.repository-host")
    public static let projectRepositoryPath = key("project.repository-path")
    public static let projectBranch = key("project.branch")

    public static let terminalProjectID = key("terminal.project-id")
    public static let terminalTitle = key("terminal.title")
    public static let terminalBranch = key("terminal.branch")
    public static let terminalManualOrder = key("terminal.manual-order")
    public static let terminalCreatedAt = key("terminal.created-at")

    public static let all: [ExtensionFactKey] = [
        sessionProjectID, sessionCheckoutID, sessionTitle, sessionProviderID, sessionAccountID,
        sessionActivity, sessionDetailedActivity, sessionBranch, sessionParentID,
        sessionIsSideChat, sessionIsArchived, sessionUsesNativeUI, sessionIsPinned,
        sessionIsSnoozed, sessionSnoozedAt, sessionSnoozedUntil, sessionWakeReason,
        sessionWokeAt, sessionCreatedAt, sessionLastActiveAt, sessionLastTurnAt,
        sessionLastUsedAt, sessionManualOrder, sessionModel, sessionManagerID,
        sessionIsManager, sessionHasCustomConduct, sessionHasScheduledStart,
        sessionScheduledStartAt,
        projectName, projectManualOrder, projectIsScratchpad, projectCreatedAt,
        projectRepositoryHost, projectRepositoryPath, projectBranch,
        terminalProjectID, terminalTitle, terminalBranch, terminalManualOrder, terminalCreatedAt,
    ]
}

private extension Character {
    var isLowercaseASCII: Bool { ("a"..."z").contains(self) }
    var isASCIINumber: Bool { ("0"..."9").contains(self) }
}
