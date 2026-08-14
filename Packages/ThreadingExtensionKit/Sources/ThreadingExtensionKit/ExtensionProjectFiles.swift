import Foundation

/// One bounded request for the documents an extension may point a host renderer at.
///
/// The extension supplies **no path, glob, command or root** — only an authorized project ID and,
/// for a session workspace, the exact session whose execution checkout it wants. The broker never
/// infers a workspace from what happens to be selected in the UI.
public struct ExtensionFileQuery: Codable, Equatable, Sendable {
    public static let defaultMaximumResults = 200
    public static let resultLimit = 1_000
    public static let maximumFileExtensions = 16
    public static let maximumFileExtensionLength = 12

    public let projectID: String
    public let scope: ExtensionFileScope
    /// Lowercased, no dot, no globs. Empty asks for nothing rather than everything: an
    /// unfiltered walk of a checkout is not a query, it is an enumeration of the user's source.
    public let fileExtensions: [String]
    public let maximumResults: Int
    /// An opaque page marker from a previous answer. Bound to the generation, the root's identity
    /// and the normalized query — a changed root or query invalidates it rather than silently
    /// continuing in a different workspace.
    public let cursor: String?

    public init(
        projectID: String,
        scope: ExtensionFileScope = .projectCheckout,
        fileExtensions: [String],
        maximumResults: Int = ExtensionFileQuery.defaultMaximumResults,
        cursor: String? = nil
    ) {
        self.projectID = projectID
        self.scope = scope
        self.fileExtensions = fileExtensions
        self.maximumResults = maximumResults
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, scope, fileExtensions, maximumResults, cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        scope = try container.decodeIfPresent(
            ExtensionFileScope.self,
            forKey: .scope
        ) ?? .projectCheckout
        fileExtensions = try container.decode([String].self, forKey: .fileExtensions)
        maximumResults = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumResults
        ) ?? Self.defaultMaximumResults
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "projectID", message: "must not be empty"))
        }
        if fileExtensions.isEmpty {
            issues.append(.init(path: "fileExtensions", message: "must not be empty"))
        }
        if fileExtensions.count > Self.maximumFileExtensions {
            issues.append(.init(
                path: "fileExtensions",
                message: "must contain at most \(Self.maximumFileExtensions) extensions"
            ))
        }
        var seen: Set<String> = []
        for (index, value) in fileExtensions.enumerated() {
            let path = "fileExtensions[\(index)]"
            if value.isEmpty || value.count > Self.maximumFileExtensionLength {
                issues.append(.init(
                    path: path,
                    message: "must be 1 to \(Self.maximumFileExtensionLength) characters"
                ))
                continue
            }
            // No dot and no glob: a filter is a suffix, not a pattern language, and a pattern
            // language is how "give me the JSON files" becomes "walk everything".
            guard value.allSatisfy({ $0.isASCIILowercaseLetterOrDigit }) else {
                issues.append(.init(
                    path: path,
                    message: "must contain only lowercase letters and digits"
                ))
                continue
            }
            if !seen.insert(value).inserted {
                issues.append(.init(path: path, message: "duplicates '\(value)'"))
            }
        }
        if maximumResults < 1 || maximumResults > Self.resultLimit {
            issues.append(.init(
                path: "maximumResults",
                message: "must be between 1 and \(Self.resultLimit)"
            ))
        }
        issues.append(contentsOf: scope.validationIssues(path: "scope"))
        if let cursor, cursor.isEmpty {
            issues.append(.init(path: "cursor", message: "must not be empty when present"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Which root a query resolves against.
public enum ExtensionFileScope: Codable, Equatable, Sendable {
    /// The logical project's own source checkout.
    case projectCheckout
    /// That session's execution directory — a managed worktree, where it has one. Refused unless
    /// the session belongs to the query's project.
    case sessionWorkspace(sessionID: String)

    private enum CodingKeys: String, CodingKey {
        case type, sessionID
    }

    private enum Kind: String, Codable {
        case projectCheckout
        case sessionWorkspace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .projectCheckout:
            self = .projectCheckout
        case .sessionWorkspace:
            self = .sessionWorkspace(
                sessionID: try container.decode(String.self, forKey: .sessionID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectCheckout:
            try container.encode(Kind.projectCheckout, forKey: .type)
        case .sessionWorkspace(let sessionID):
            try container.encode(Kind.sessionWorkspace, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
        }
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        switch self {
        case .projectCheckout:
            return []
        case .sessionWorkspace(let sessionID):
            return sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [.init(path: "\(path).sessionID", message: "must not be empty")]
                : []
        }
    }

    /// A stable string for the cursor's query fingerprint.
    public var fingerprint: String {
        switch self {
        case .projectCheckout: "project"
        case .sessionWorkspace(let sessionID): "session:\(sessionID)"
        }
    }
}

/// What the host recognized inside a file, without handing over the bytes that said so.
public struct ExtensionFileContentHint: RawRepresentable, Codable, Hashable, Sendable,
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

    public static let lottie: Self = "lottie"
    public static let dotLottie: Self = "dot-lottie"
    public static let mermaid: Self = "mermaid"
    public static let graphviz: Self = "graphviz"
    public static let openAPI: Self = "openapi"
    public static let svg: Self = "svg"
}

/// A document the host will open on the extension's behalf.
///
/// The load-bearing property is that **`id` is a content handle, not bytes and not a path that can
/// be opened**. It is what `ExtensionMediaSource.fileHandle` takes, and the host resolves it at
/// render time — so a 5 MiB animation never crosses the broker and the extension never learns an
/// absolute path.
///
/// It *does* learn bounded filesystem metadata: name, project-relative path, byte size,
/// modification date, and the host's own content hint. Without those an asset browser cannot
/// present or filter a list, so the disclosure is explicit rather than disguised as "handles only",
/// and the installation copy says so.
public struct ExtensionFileHandle: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let byteSize: Int
    public let modifiedAt: Date
    public let contentHint: ExtensionFileContentHint?

    public init(
        id: String,
        name: String,
        relativePath: String,
        byteSize: Int,
        modifiedAt: Date,
        contentHint: ExtensionFileContentHint? = nil
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.contentHint = contentHint
    }
}

/// One page of an enumeration, in stable lexical order.
public struct ExtensionFilePage: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let handles: [ExtensionFileHandle]
    /// Nil when the walk is finished.
    public let nextCursor: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        handles: [ExtensionFileHandle],
        nextCursor: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.handles = handles
        self.nextCursor = nextCursor
    }
}

private extension Character {
    var isASCIILowercaseLetterOrDigit: Bool {
        ("a"..."z").contains(self) || ("0"..."9").contains(self)
    }
}
