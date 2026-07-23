import Foundation

public struct ExtensionCommand: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?

    public init(id: String, title: String, description: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
    }
}

public struct ExtensionPanel: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let root: ExtensionNode

    public init(id: String, title: String, root: ExtensionNode) {
        self.id = id
        self.title = title
        self.root = root
    }
}

/// Everything an extension asks Skalman to add when it starts.
///
/// Registration is a value so it can cross a process boundary. The later host runtime can
/// transport this exact type without giving the extension access to an AppKit object.
public struct ExtensionRegistration: Codable, Equatable, Sendable {
    public let commands: [ExtensionCommand]
    public let panels: [ExtensionPanel]

    public init(
        commands: [ExtensionCommand] = [],
        panels: [ExtensionPanel] = []
    ) {
        self.commands = commands
        self.panels = panels
    }

    public func validate(for manifest: ExtensionManifest) throws {
        var issues: [ExtensionValidationIssue] = []

        issues.append(contentsOf: identifierIssues(
            commands.map(\.id),
            collectionPath: "commands"
        ))
        issues.append(contentsOf: identifierIssues(
            panels.map(\.id),
            collectionPath: "panels"
        ))

        if !commands.isEmpty, !manifest.capabilities.contains(.commands) {
            issues.append(
                .init(
                    path: "capabilities",
                    message: "must contain 'commands' when commands are registered"
                )
            )
        }

        if !panels.isEmpty, !manifest.capabilities.contains(.panels) {
            issues.append(
                .init(
                    path: "capabilities",
                    message: "must contain 'panels' when panels are registered"
                )
            )
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    private func identifierIssues(
        _ identifiers: [String],
        collectionPath: String
    ) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        var seen: Set<String> = []

        for (index, identifier) in identifiers.enumerated() {
            let path = "\(collectionPath)[\(index)].id"
            if !ExtensionIdentifierRules.isContributionIdentifier(identifier) {
                issues.append(
                    .init(
                        path: path,
                        message: "must start with a lowercase letter and contain only lowercase letters, digits, '-', or '.'"
                    )
                )
            }
            if !seen.insert(identifier).inserted {
                issues.append(.init(path: path, message: "duplicates '\(identifier)'"))
            }
        }
        return issues
    }
}
