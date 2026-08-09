import Foundation

/// Resolved images available while Threading renders a `sidebar.session-identity` replacement.
///
/// These references are contextual: they resolve for the session targeted by the patch. The
/// provider value already includes side-chat lineage and the selected primitive provider
/// resolver. The account value already includes explicit user-image precedence and the selected
/// primitive account resolver.
public enum ExtensionSessionIdentityAsset {
    public static let providerImage: ExtensionImageReference =
        .hostAsset("session.provider-image")
    public static let accountImage: ExtensionImageReference =
        .hostAsset("session.account-image")
}

/// A provider's presentation identity. The image is an opaque host reference which may be
/// returned unchanged in a resolver publication; it does not reveal a file path or image bytes.
public struct ExtensionProviderSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let displayName: String
    public let image: ExtensionImageReference

    public init(
        version: Int = Self.currentVersion,
        id: String,
        displayName: String,
        image: ExtensionImageReference
    ) {
        self.version = version
        self.id = id
        self.displayName = displayName
        self.image = image
    }
}

/// Presentation-only account metadata. Login email, handle paths, credentials, and CLI config
/// locations are deliberately absent.
public struct ExtensionAccountSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let providerID: String
    public let displayName: String
    public let isDefault: Bool
    public let hasUserSelectedImage: Bool
    public let image: ExtensionImageReference?

    public init(
        version: Int = Self.currentVersion,
        id: String,
        providerID: String,
        displayName: String,
        isDefault: Bool,
        hasUserSelectedImage: Bool,
        image: ExtensionImageReference? = nil
    ) {
        self.version = version
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.isDefault = isDefault
        self.hasUserSelectedImage = hasUserSelectedImage
        self.image = image
    }
}

public struct ExtensionProviderSnapshotPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let providers: [ExtensionProviderSnapshot]

    public init(cursor: Int64, providers: [ExtensionProviderSnapshot]) {
        self.cursor = cursor
        self.providers = providers
    }
}

public struct ExtensionProviderSnapshotResult: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let provider: ExtensionProviderSnapshot

    public init(cursor: Int64, provider: ExtensionProviderSnapshot) {
        self.cursor = cursor
        self.provider = provider
    }
}

public struct ExtensionAccountSnapshotPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let accounts: [ExtensionAccountSnapshot]

    public init(cursor: Int64, accounts: [ExtensionAccountSnapshot]) {
        self.cursor = cursor
        self.accounts = accounts
    }
}

public struct ExtensionAccountSnapshotResult: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let account: ExtensionAccountSnapshot

    public init(cursor: Int64, account: ExtensionAccountSnapshot) {
        self.cursor = cursor
        self.account = account
    }
}

public struct ExtensionProviderIconResolution: Codable, Equatable, Sendable {
    public let providerID: String
    public let image: ExtensionImageReference

    public init(providerID: String, image: ExtensionImageReference) {
        self.providerID = providerID
        self.image = image
    }
}

public struct ExtensionAccountIconResolution: Codable, Equatable, Sendable {
    public let accountID: String
    public let image: ExtensionImageReference

    public init(accountID: String, image: ExtensionImageReference) {
        self.accountID = accountID
        self.image = image
    }
}

/// One generation's complete primitive identity resolver output. Publishing again replaces the
/// old value atomically; empty arrays clear that primitive contribution.
public struct ExtensionIdentityResolutionPublication: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let providerIcons: [ExtensionProviderIconResolution]
    public let accountIcons: [ExtensionAccountIconResolution]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        providerIcons: [ExtensionProviderIconResolution] = [],
        accountIcons: [ExtensionAccountIconResolution] = []
    ) {
        self.protocolVersion = protocolVersion
        self.providerIcons = providerIcons
        self.accountIcons = accountIcons
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        validate(
            providerIcons.map(\.providerID),
            path: "providerIcons",
            issues: &issues
        )
        validate(
            accountIcons.map(\.accountID),
            path: "accountIcons",
            issues: &issues
        )
        for (index, value) in providerIcons.enumerated() {
            validate(value.image, path: "providerIcons[\(index)].image", issues: &issues)
        }
        for (index, value) in accountIcons.enumerated() {
            validate(value.image, path: "accountIcons[\(index)].image", issues: &issues)
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    private func validate(
        _ identifiers: [String],
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        var seen: Set<String> = []
        for (index, identifier) in identifiers.enumerated() {
            if identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path)[\(index)]", message: "ID must not be empty"))
            } else if !seen.insert(identifier).inserted {
                issues.append(.init(
                    path: "\(path)[\(index)]",
                    message: "duplicates '\(identifier)'"
                ))
            }
        }
    }

    private func validate(
        _ image: ExtensionImageReference,
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        switch image {
        case .hostAsset(let identifier):
            if identifier.isEmpty {
                issues.append(.init(path: path, message: "host asset ID must not be empty"))
            }
        case .extensionResource(let relativePath):
            if !ExtensionIdentityPathRules.isSafeRelativePath(relativePath) {
                issues.append(.init(
                    path: path,
                    message: "extension resource must be a safe package-relative path"
                ))
            }
        case .systemSymbol(let name):
            if name.isEmpty || name.count > 128 {
                issues.append(.init(
                    path: path,
                    message: "system symbol name must contain 1...128 characters"
                ))
            }
        }
    }
}

private enum ExtensionIdentityPathRules {
    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !NSString(string: value).isAbsolutePath else { return false }
        return NSString(string: value).pathComponents.allSatisfy {
            $0 != "." && $0 != ".." && $0 != "/"
        }
    }
}
