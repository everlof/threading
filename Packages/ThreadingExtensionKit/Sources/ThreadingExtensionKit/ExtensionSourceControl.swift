import Foundation

/// A read-only hosted-Git provider contributed by an extension.
///
/// Local Git, publication, and mutation remain host-owned. This declaration describes only the
/// forge vocabulary and the authentication shapes the host may attach to brokered read requests.
public struct ExtensionSourceControlProviderDefinition: Codable, Equatable, Hashable, Sendable {
    public static let maximumCount = 8

    public let id: String
    public let displayName: String
    public let changeRequestName: String
    public let changeRequestPluralName: String
    public let apiPathPrefix: String
    public let authenticationKinds: [ExtensionSourceControlAuthenticationKind]
    public let reportsChecks: Bool
    public let reportsApprovals: Bool
    public let reportsChangesRequested: Bool

    public init(
        id: String,
        displayName: String,
        changeRequestName: String,
        changeRequestPluralName: String,
        apiPathPrefix: String,
        authenticationKinds: [ExtensionSourceControlAuthenticationKind],
        reportsChecks: Bool = true,
        reportsApprovals: Bool = true,
        reportsChangesRequested: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.changeRequestName = changeRequestName
        self.changeRequestPluralName = changeRequestPluralName
        self.apiPathPrefix = apiPathPrefix
        self.authenticationKinds = authenticationKinds
        self.reportsChecks = reportsChecks
        self.reportsApprovals = reportsApprovals
        self.reportsChangesRequested = reportsChangesRequested
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        for (field, value, maximum) in [
            ("displayName", displayName, 80),
            ("changeRequestName", changeRequestName, 40),
            ("changeRequestPluralName", changeRequestPluralName, 60),
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append(.init(path: "\(path).\(field)", message: "must not be empty"))
            } else if value.count > maximum {
                issues.append(.init(
                    path: "\(path).\(field)",
                    message: "must contain at most \(maximum) characters"
                ))
            }
        }
        if !Self.isCanonicalAPIPathPrefix(apiPathPrefix) {
            issues.append(.init(
                path: "\(path).apiPathPrefix",
                message: "must be a canonical absolute path without query, fragment, '.', or '..' components"
            ))
        }
        if authenticationKinds.isEmpty {
            issues.append(.init(
                path: "\(path).authenticationKinds",
                message: "must contain at least one authentication kind"
            ))
        } else if Set(authenticationKinds).count != authenticationKinds.count {
            issues.append(.init(
                path: "\(path).authenticationKinds",
                message: "must not contain duplicates"
            ))
        }
        return issues
    }

    private static func isCanonicalAPIPathPrefix(_ value: String) -> Bool {
        guard value.first == "/", value.count <= 160,
              !value.contains("?"), !value.contains("#"), !value.contains("\\") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropFirst().allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

/// Closed credential vocabulary whose concrete header is constructed by Threading.
public enum ExtensionSourceControlAuthenticationKind: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case none
    case bearerToken = "bearer-token"
    case authorizationToken = "authorization-token"
    case basicUsernameToken = "basic-username-token"
}

/// Host-owned repository identity supplied to a forge provider.
///
/// It contains no checkout path, complete remote URL, or credential.
public struct ExtensionSourceControlRepository: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let namespace: String
    public let name: String
    public let branch: String
    public let headRevision: String

    public init(
        host: String,
        namespace: String,
        name: String,
        branch: String,
        headRevision: String
    ) {
        self.host = host
        self.namespace = namespace
        self.name = name
        self.branch = branch
        self.headRevision = headRevision
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !Self.isCanonicalHost(host) {
            issues.append(.init(
                path: "\(path).host",
                message: "must be a canonical lowercase host without scheme, path, port, or credentials"
            ))
        }
        for (field, value, maximum) in [
            ("namespace", namespace, 512),
            ("name", name, 256),
            ("branch", branch, 512),
            ("headRevision", headRevision, 128),
        ] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).\(field)", message: "must not be empty"))
            } else if value.count > maximum {
                issues.append(.init(
                    path: "\(path).\(field)",
                    message: "must contain at most \(maximum) characters"
                ))
            }
        }
        if namespace.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
            issues.append(.init(
                path: "\(path).namespace",
                message: "must not contain traversal components"
            ))
        }
        if name.contains("/") || name == "." || name == ".." {
            issues.append(.init(
                path: "\(path).name",
                message: "must be one repository path component"
            ))
        }
        return issues
    }

    private static func isCanonicalHost(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.lowercased(), value.count <= 253,
              !value.contains(":"), !value.contains("/"), !value.contains("@"),
              value.first != ".", value.last != ".", !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
                .contains($0)
        }
    }
}

public enum ExtensionSourceControlOperation: String, Codable, Equatable, Sendable {
    case probe
    case discover
    case lifecycle
}

/// One host-to-provider request on the extension process stream.
public struct ExtensionSourceControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let providerID: String
    public let connectionID: String
    public let operation: ExtensionSourceControlOperation
    public let repository: ExtensionSourceControlRepository?
    public let changeRequestNumber: Int?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        providerID: String,
        connectionID: String,
        operation: ExtensionSourceControlOperation,
        repository: ExtensionSourceControlRepository? = nil,
        changeRequestNumber: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.providerID = providerID
        self.connectionID = connectionID
        self.operation = operation
        self.repository = repository
        self.changeRequestNumber = changeRequestNumber
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        for (path, value) in [("requestID", requestID), ("connectionID", connectionID)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: path, message: "must not be empty"))
            } else if value.count > 256 {
                issues.append(.init(path: path, message: "must contain at most 256 characters"))
            }
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(providerID) {
            issues.append(.init(
                path: "providerID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if let repository {
            issues.append(contentsOf: repository.validationIssues(path: "repository"))
        }
        switch operation {
        case .probe:
            if repository != nil || changeRequestNumber != nil {
                issues.append(.init(
                    path: "operation",
                    message: "probe must not carry repository or changeRequestNumber"
                ))
            }
        case .discover:
            if repository == nil {
                issues.append(.init(path: "repository", message: "is required for discover"))
            }
            if changeRequestNumber != nil {
                issues.append(.init(
                    path: "changeRequestNumber",
                    message: "must be omitted for discover"
                ))
            }
        case .lifecycle:
            if repository == nil {
                issues.append(.init(path: "repository", message: "is required for lifecycle"))
            }
            if !(1...Int(Int32.max)).contains(changeRequestNumber ?? 0) {
                issues.append(.init(
                    path: "changeRequestNumber",
                    message: "must be a positive 32-bit integer for lifecycle"
                ))
            }
        }
        if !issues.isEmpty { throw ExtensionValidationError(issues: issues) }
    }
}

/// Forward-compatible lifecycle: `normalized` drives host behavior while `providerValue`
/// preserves an unfamiliar value for diagnostics and accessibility.
public struct ExtensionChangeRequestLifecycle: Codable, Equatable, Sendable {
    public enum Normalized: String, Codable, Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
        case unknown
    }

    public let normalized: Normalized
    public let providerValue: String?

    public init(_ normalized: Normalized, providerValue: String? = nil) {
        self.normalized = normalized
        self.providerValue = providerValue
    }
}

public struct ExtensionChangeRequestChecks: Codable, Equatable, Sendable {
    public let successful: Int
    public let nonBlocking: Int
    public let active: Int
    public let needsAttention: Int
    public let unknown: Int
    public let isIncomplete: Bool

    public init(
        successful: Int = 0,
        nonBlocking: Int = 0,
        active: Int = 0,
        needsAttention: Int = 0,
        unknown: Int = 0,
        isIncomplete: Bool = false
    ) {
        self.successful = successful
        self.nonBlocking = nonBlocking
        self.active = active
        self.needsAttention = needsAttention
        self.unknown = unknown
        self.isIncomplete = isIncomplete
    }
}

public struct ExtensionChangeRequestReviews: Codable, Equatable, Sendable {
    public let approvals: Int
    public let changesRequested: Int
    public let requested: Int

    public init(approvals: Int = 0, changesRequested: Int = 0, requested: Int = 0) {
        self.approvals = approvals
        self.changesRequested = changesRequested
        self.requested = requested
    }
}

public struct ExtensionChangeRequestSummary: Codable, Equatable, Sendable {
    public let number: Int
    public let title: String
    public let webURL: String
    public let lifecycle: ExtensionChangeRequestLifecycle
    public let baseBranch: String
    public let headBranch: String
    public let headRevision: String
    public let checks: ExtensionChangeRequestChecks
    public let reviews: ExtensionChangeRequestReviews

    public init(
        number: Int,
        title: String,
        webURL: String,
        lifecycle: ExtensionChangeRequestLifecycle,
        baseBranch: String,
        headBranch: String,
        headRevision: String,
        checks: ExtensionChangeRequestChecks = .init(),
        reviews: ExtensionChangeRequestReviews = .init()
    ) {
        self.number = number
        self.title = title
        self.webURL = webURL
        self.lifecycle = lifecycle
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.headRevision = headRevision
        self.checks = checks
        self.reviews = reviews
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !(1...Int(Int32.max)).contains(number) {
            issues.append(.init(path: "\(path).number", message: "must be a positive 32-bit integer"))
        }
        for (field, value, maximum) in [
            ("title", title, 256),
            ("baseBranch", baseBranch, 512),
            ("headBranch", headBranch, 512),
            ("headRevision", headRevision, 128),
        ] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).\(field)", message: "must not be empty"))
            } else if value.count > maximum {
                issues.append(.init(
                    path: "\(path).\(field)",
                    message: "must contain at most \(maximum) characters"
                ))
            }
        }
        guard let url = URL(string: webURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil else {
            issues.append(.init(path: "\(path).webURL", message: "must be an absolute HTTPS URL"))
            return issues
        }
        for (field, value) in [
            ("successful", checks.successful),
            ("nonBlocking", checks.nonBlocking),
            ("active", checks.active),
            ("needsAttention", checks.needsAttention),
            ("unknown", checks.unknown),
            ("approvals", reviews.approvals),
            ("changesRequested", reviews.changesRequested),
            ("requested", reviews.requested),
        ] where !(0...100_000).contains(value) {
            issues.append(.init(
                path: "\(path).\(field)",
                message: "must be between 0 and 100000"
            ))
        }
        if let providerValue = lifecycle.providerValue, providerValue.count > 40 {
            issues.append(.init(
                path: "\(path).lifecycle.providerValue",
                message: "must contain at most 40 characters"
            ))
        }
        return issues
    }
}

public enum ExtensionSourceControlErrorCode: String, Codable, Equatable, Sendable {
    case unavailable
    case authenticationRequired = "authentication-required"
    case forbidden
    case notFound = "not-found"
    case rateLimited = "rate-limited"
    case transport
    case malformedResponse = "malformed-response"
    case incomplete
}

public struct ExtensionSourceControlProviderError: Codable, Equatable, Sendable {
    public let code: ExtensionSourceControlErrorCode
    public let message: String
    public let retryAfterSeconds: Int?

    public init(
        code: ExtensionSourceControlErrorCode,
        message: String,
        retryAfterSeconds: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct ExtensionSourceControlResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let providerID: String
    public let serverVersion: String?
    public let defaultBranch: String?
    public let changeRequest: ExtensionChangeRequestSummary?
    public let error: ExtensionSourceControlProviderError?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        providerID: String,
        serverVersion: String? = nil,
        defaultBranch: String? = nil,
        changeRequest: ExtensionChangeRequestSummary? = nil,
        error: ExtensionSourceControlProviderError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.providerID = providerID
        self.serverVersion = serverVersion
        self.defaultBranch = defaultBranch
        self.changeRequest = changeRequest
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
        if !ExtensionIdentifierRules.isContributionIdentifier(providerID) {
            issues.append(.init(
                path: "providerID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if error != nil && (serverVersion != nil || defaultBranch != nil || changeRequest != nil) {
            issues.append(.init(
                path: "error",
                message: "must be exclusive with successful response values"
            ))
        }
        if let serverVersion, serverVersion.count > 80 {
            issues.append(.init(path: "serverVersion", message: "must contain at most 80 characters"))
        }
        if let defaultBranch {
            if defaultBranch.isEmpty {
                issues.append(.init(path: "defaultBranch", message: "must not be empty"))
            } else if defaultBranch.count > 512 {
                issues.append(.init(path: "defaultBranch", message: "must contain at most 512 characters"))
            }
        }
        if let changeRequest {
            issues.append(contentsOf: changeRequest.validationIssues(path: "changeRequest"))
        }
        if let error {
            if error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "error.message", message: "must not be empty"))
            } else if error.message.count > 500 {
                issues.append(.init(path: "error.message", message: "must contain at most 500 characters"))
            }
            if let retry = error.retryAfterSeconds, !(1...86_400).contains(retry) {
                issues.append(.init(
                    path: "error.retryAfterSeconds",
                    message: "must be between 1 and 86400"
                ))
            }
        }
        if !issues.isEmpty { throw ExtensionValidationError(issues: issues) }
    }
}

/// A connection-scoped read request. The extension supplies only a path beneath its declared API
/// prefix; Threading selects the origin and attaches the credential.
public struct ExtensionSourceControlFetchRequest: Codable, Equatable, Sendable {
    public static let maximumQueryItems = 32
    public static let maximumHeaders = 16

    public let connectionID: String
    public let method: String
    public let path: String
    public let queryItems: [ExtensionSourceControlQueryItem]
    public let headers: [String: String]

    public init(
        connectionID: String,
        method: String = "GET",
        path: String,
        queryItems: [ExtensionSourceControlQueryItem] = [],
        headers: [String: String] = [:]
    ) {
        self.connectionID = connectionID
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if connectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "connectionID", message: "must not be empty"))
        } else if connectionID.count > 256 {
            issues.append(.init(path: "connectionID", message: "must contain at most 256 characters"))
        }
        if method != "GET" && method != "HEAD" {
            issues.append(.init(path: "method", message: "must be GET or HEAD"))
        }
        guard path.first == "/", path.count <= 2_048,
              !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              !path.contains("//") else {
            issues.append(.init(
                path: "path",
                message: "must be a canonical absolute API-relative path without query or fragment"
            ))
            if !issues.isEmpty { throw ExtensionValidationError(issues: issues) }
            return
        }
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in pathComponents.dropFirst() {
            let decoded = String(component).removingPercentEncoding ?? String(component)
            if component.isEmpty || decoded == "." || decoded == ".."
                || decoded.contains("/") || decoded.contains("\\") {
                issues.append(.init(path: "path", message: "must not contain ambiguous or traversal components"))
                break
            }
        }
        if queryItems.count > Self.maximumQueryItems {
            issues.append(.init(
                path: "queryItems",
                message: "must contain at most \(Self.maximumQueryItems) items"
            ))
        }
        for (index, item) in queryItems.enumerated() {
            if item.name.isEmpty || item.name.count > 128 || item.value.count > 1_024 {
                issues.append(.init(
                    path: "queryItems[\(index)]",
                    message: "has an empty or oversized name or value"
                ))
            }
        }
        if headers.count > Self.maximumHeaders {
            issues.append(.init(
                path: "headers",
                message: "must contain at most \(Self.maximumHeaders) headers"
            ))
        }
        let denied = ExtensionBrokeredNetwork.deniedRequestHeaders
        let headerNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        for (name, value) in headers {
            let lowered = name.lowercased()
            if denied.contains(lowered) || name.isEmpty || name.count > 128
                || !name.unicodeScalars.allSatisfy(headerNameCharacters.contains)
                || value.count > ExtensionBrokeredNetwork.maximumHeaderValueLength
                || value.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }) {
                issues.append(.init(
                    path: "headers.\(name)",
                    message: "is forbidden or exceeds the brokered header bounds"
                ))
            }
        }
        if !issues.isEmpty { throw ExtensionValidationError(issues: issues) }
    }
}

public struct ExtensionSourceControlQueryItem: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public typealias ExtensionSourceControlFetchResponse = ExtensionBrokeredFetchResponse
public typealias ExtensionSourceControlFetchResult = ExtensionBrokeredFetchResult
