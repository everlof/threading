import Foundation

/// The on-disk description Skalman reads before starting an extension.
///
/// The manifest is intentionally data-only. Discovering an extension must never require
/// loading or executing its code.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let identifier: String
    public let name: String
    public let version: String
    public let executable: String
    public let capabilities: Set<ExtensionCapability>

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        identifier: String,
        name: String,
        version: String,
        executable: String,
        capabilities: Set<ExtensionCapability> = []
    ) {
        self.formatVersion = formatVersion
        self.identifier = identifier
        self.name = name
        self.version = version
        self.executable = executable
        self.capabilities = capabilities
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []

        if formatVersion != Self.currentFormatVersion {
            issues.append(
                .init(
                    path: "formatVersion",
                    message: "expected \(Self.currentFormatVersion), got \(formatVersion)"
                )
            )
        }

        if !ExtensionIdentifierRules.isReverseDNSIdentifier(identifier) {
            issues.append(
                .init(
                    path: "identifier",
                    message: "must be a lowercase reverse-DNS identifier"
                )
            )
        }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "name", message: "must not be empty"))
        }

        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "version", message: "must not be empty"))
        }

        if !ExtensionIdentifierRules.isSafeRelativePath(executable) {
            issues.append(
                .init(
                    path: "executable",
                    message: "must be a relative path without '.' or '..' components"
                )
            )
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// A named authority requested by an extension.
///
/// This is a raw-value type rather than a closed enum so a newer extension's manifest remains
/// inspectable by an older host. The host can report an unsupported capability before running
/// the extension instead of failing to decode the manifest.
public struct ExtensionCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let commands = Self(rawValue: "commands")
    public static let panels = Self(rawValue: "panels")
    public static let projectRead = Self(rawValue: "project.read")
    public static let sessionEvents = Self(rawValue: "session.events")
}

enum ExtensionIdentifierRules {
    static func isReverseDNSIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLowercaseASCII else { return false }
            return part.allSatisfy { $0.isLowercaseASCII || $0.isASCIINumber || $0 == "-" }
        }
    }

    static func isContributionIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLowercaseASCII else { return false }
        return value.allSatisfy {
            $0.isLowercaseASCII || $0.isASCIINumber || $0 == "-" || $0 == "."
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !NSString(string: value).isAbsolutePath else { return false }
        let components = NSString(string: value).pathComponents
        return components.allSatisfy { $0 != "." && $0 != ".." && $0 != "/" }
    }
}

private extension Character {
    var isLowercaseASCII: Bool {
        ("a"..."z").contains(self)
    }

    var isASCIINumber: Bool {
        ("0"..."9").contains(self)
    }
}
