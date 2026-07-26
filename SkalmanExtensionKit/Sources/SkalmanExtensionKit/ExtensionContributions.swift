import Foundation

public enum ExtensionCommandScope: String, Codable, Equatable, Sendable {
    case application
    case project
    case session
}

/// The consequence category of a user-triggered command.
///
/// Extensions declare semantics, never confirmation copy. Skalman decides whether and how to
/// confirm the command and owns every word and control in that presentation.
public enum ExtensionCommandRisk: String, Codable, Equatable, Sendable {
    case ordinary
    case destructive
}

public enum ExtensionShortcutModifier: String, Codable, CaseIterable, Equatable, Sendable {
    case control
    case option
    case shift
    case command
}

/// A portable menu shortcut. Skalman owns conflict resolution and the final AppKit key equivalent.
public struct ExtensionKeyboardShortcut: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: [ExtensionShortcutModifier]

    public init(key: String, modifiers: [ExtensionShortcutModifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if key.count != 1 {
            issues.append(.init(path: "\(path).key", message: "must contain exactly one character"))
        }
        if Set(modifiers).count != modifiers.count {
            issues.append(.init(path: "\(path).modifiers", message: "must not contain duplicates"))
        }
        if !modifiers.contains(.command)
            && !modifiers.contains(.control)
            && !modifiers.contains(.option) {
            issues.append(.init(
                path: "\(path).modifiers",
                message: "must contain command, control, or option"
            ))
        }
        return issues
    }
}

/// Stable host-owned menu anchors. Extensions contribute commands, never AppKit menu items.
public enum ExtensionMenuPlacement: String, Codable, CaseIterable, Equatable, Sendable {
    /// Skalman's top-level Extensions menu.
    case extensions
    /// A host-owned Extensions group at the end of Skalman's Project menu.
    case project
    /// A host-owned Extensions group at the end of Skalman's View menu.
    case view
}

public struct ExtensionCommand: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let scope: ExtensionCommandScope
    public let risk: ExtensionCommandRisk
    public let defaultShortcut: ExtensionKeyboardShortcut?
    public let menuPlacements: [ExtensionMenuPlacement]

    public init(
        id: String,
        title: String,
        description: String? = nil,
        scope: ExtensionCommandScope = .application,
        risk: ExtensionCommandRisk = .ordinary,
        defaultShortcut: ExtensionKeyboardShortcut? = nil,
        menuPlacements: [ExtensionMenuPlacement] = [.extensions]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.scope = scope
        self.risk = risk
        self.defaultShortcut = defaultShortcut
        self.menuPlacements = menuPlacements
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, scope, risk, defaultShortcut, menuPlacements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        scope = try container.decodeIfPresent(
            ExtensionCommandScope.self,
            forKey: .scope
        ) ?? .application
        risk = try container.decodeIfPresent(
            ExtensionCommandRisk.self,
            forKey: .risk
        ) ?? .ordinary
        defaultShortcut = try container.decodeIfPresent(
            ExtensionKeyboardShortcut.self,
            forKey: .defaultShortcut
        )
        menuPlacements = try container.decodeIfPresent(
            [ExtensionMenuPlacement].self,
            forKey: .menuPlacements
        ) ?? [.extensions]
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(path: "\(path).id", message: ExtensionIdentifierRules.contributionMessage))
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).title", message: "must not be empty"))
        } else if title.count > 120 {
            issues.append(.init(path: "\(path).title", message: "must contain at most 120 characters"))
        }
        if let description,
           description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).description", message: "must not be empty when present"))
        } else if let description, description.count > 500 {
            issues.append(.init(
                path: "\(path).description",
                message: "must contain at most 500 characters"
            ))
        }
        if let defaultShortcut {
            issues.append(contentsOf: defaultShortcut.validationIssues(
                path: "\(path).defaultShortcut"
            ))
        }
        if Set(menuPlacements.map(\.rawValue)).count != menuPlacements.count {
            issues.append(.init(path: "\(path).menuPlacements", message: "must not contain duplicates"))
        }
        return issues
    }
}

public struct ExtensionPanel: Codable, Equatable, Sendable {
    public static let nodeConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 24,
        maximumNodes: 500,
        maximumTextLength: 10_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.allCases,
        allowedButtonRoles: ExtensionButtonRole.allCases,
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true
    )

    public let id: String
    public let title: String
    public let root: ExtensionNode
    /// Optional companion-owned pixels for the panel. `root` remains the semantic loading,
    /// accessibility, and unavailable fallback.
    public let remoteSurface: ExtensionRemoteSurfaceReference?
    /// An optional action invoked once when this panel is connected to a running extension
    /// generation. The request carries the same project/session context as a button action.
    ///
    /// `root` remains the immediate loading and fallback UI. Return an updated panel from the
    /// action to replace it with context-dependent content.
    public let loadActionID: String?

    public init(
        id: String,
        title: String,
        root: ExtensionNode,
        loadActionID: String? = nil,
        remoteSurface: ExtensionRemoteSurfaceReference? = nil
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.loadActionID = loadActionID
        self.remoteSurface = remoteSurface
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            issues.append(.init(path: "\(path).title", message: "must not be empty"))
        } else if title.count > 120 {
            issues.append(.init(
                path: "\(path).title",
                message: "must contain at most 120 characters"
            ))
        }
        if let loadActionID,
           !ExtensionIdentifierRules.isContributionIdentifier(loadActionID) {
            issues.append(.init(
                path: "\(path).loadActionID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if let remoteSurface {
            issues.append(contentsOf: remoteSurface.validationIssues(
                path: "\(path).remoteSurface"
            ))
        }
        do {
            try Self.nodeConstraints.validate(root, path: "\(path).root")
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues)
        } catch {
            issues.append(.init(
                path: "\(path).root",
                message: error.localizedDescription
            ))
        }
        return issues
    }
}

/// Everything an extension asks Skalman to add when it starts.
///
/// Registration is a value so it can cross a process boundary. The later host runtime can
/// transport this exact type without giving the extension access to an AppKit object.
public struct ExtensionRegistration: Codable, Equatable, Sendable {
    public let commands: [ExtensionCommand]
    public let panels: [ExtensionPanel]
    public let mcpTools: [ExtensionMCPTool]
    public let services: [ExtensionServiceDefinition]

    public init(
        commands: [ExtensionCommand] = [],
        panels: [ExtensionPanel] = [],
        mcpTools: [ExtensionMCPTool] = [],
        services: [ExtensionServiceDefinition] = []
    ) {
        self.commands = commands
        self.panels = panels
        self.mcpTools = mcpTools
        self.services = services
    }

    private enum CodingKeys: String, CodingKey {
        case commands, panels, mcpTools, services
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commands = try container.decodeIfPresent([ExtensionCommand].self, forKey: .commands) ?? []
        panels = try container.decodeIfPresent([ExtensionPanel].self, forKey: .panels) ?? []
        mcpTools = try container.decodeIfPresent([ExtensionMCPTool].self, forKey: .mcpTools) ?? []
        services = try container.decodeIfPresent(
            [ExtensionServiceDefinition].self,
            forKey: .services
        ) ?? []
    }

    public func validate(for manifest: ExtensionManifest) throws {
        var issues: [ExtensionValidationIssue] = []

        for (index, command) in commands.enumerated() {
            issues.append(contentsOf: command.validationIssues(path: "commands[\(index)]"))
        }
        issues.append(contentsOf: duplicateIdentifierIssues(
            commands.map(\.id),
            collectionPath: "commands"
        ))
        for (index, panel) in panels.enumerated() {
            issues.append(contentsOf: panel.validationIssues(path: "panels[\(index)]"))
        }
        issues.append(contentsOf: duplicateIdentifierIssues(
            panels.map(\.id),
            collectionPath: "panels"
        ))
        issues.append(contentsOf: identifierIssues(
            mcpTools.map(\.id),
            collectionPath: "mcpTools"
        ))
        for (index, service) in services.enumerated() {
            issues.append(contentsOf: service.validationIssues(path: "services[\(index)]"))
        }
        var seenServices: Set<String> = []
        for (index, service) in services.enumerated() {
            let key = "\(service.id)@\(service.version)"
            if !seenServices.insert(key).inserted {
                issues.append(.init(
                    path: "services[\(index)]",
                    message: "duplicates '\(key)'"
                ))
            }
        }

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
        if panels.count > 32 {
            issues.append(.init(
                path: "panels",
                message: "must contain at most 32 panels"
            ))
        }
        for (index, panel) in panels.enumerated() {
            guard let reference = panel.remoteSurface else { continue }
            guard let companion = manifest.companions.first(where: {
                $0.id == reference.companionID
            }) else {
                issues.append(.init(
                    path: "panels[\(index)].remoteSurface.companionID",
                    message: "does not name a declared companion"
                ))
                continue
            }
            if !companion.capabilities.contains(.remoteSurfaces) {
                issues.append(.init(
                    path: "panels[\(index)].remoteSurface",
                    message: "requires companion capability 'ui.remote-surfaces'"
                ))
            }
            if !companion.surfaces.contains(where: { $0.id == reference.surfaceID }) {
                issues.append(.init(
                    path: "panels[\(index)].remoteSurface.surfaceID",
                    message: "does not name a surface declared by companion '\(companion.id)'"
                ))
            }
        }

        if !mcpTools.isEmpty, !manifest.capabilities.contains(.mcpTools) {
            issues.append(
                .init(
                    path: "capabilities",
                    message: "must contain 'mcp.tools' when MCP tools are registered"
                )
            )
        }
        if !services.isEmpty, !manifest.capabilities.contains(.servicesProvide) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'services.provide' when services are registered"
            ))
        }

        let declaredTools = Dictionary(
            manifest.mcpTools.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (index, tool) in mcpTools.enumerated() {
            issues.append(contentsOf: tool.validationIssues(
                path: "mcpTools[\(index)]",
                extensionIdentifier: manifest.identifier
            ))
            guard let declaration = declaredTools[tool.id] else {
                issues.append(.init(
                    path: "mcpTools[\(index)].id",
                    message: "is not declared in the manifest"
                ))
                continue
            }
            if declaration != tool {
                issues.append(.init(
                    path: "mcpTools[\(index)]",
                    message: "must match the manifest declaration exactly"
                ))
            }
        }

        let declaredServices = Dictionary(
            manifest.services.map { ("\($0.id)@\($0.version)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (index, service) in services.enumerated() {
            let key = "\(service.id)@\(service.version)"
            guard let declaration = declaredServices[key] else {
                issues.append(.init(
                    path: "services[\(index)]",
                    message: "is not declared in the manifest"
                ))
                continue
            }
            if declaration != service {
                issues.append(.init(
                    path: "services[\(index)]",
                    message: "must match the manifest declaration exactly"
                ))
            }
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
                        message: ExtensionIdentifierRules.contributionMessage
                    )
                )
            }
            if !seen.insert(identifier).inserted {
                issues.append(.init(path: path, message: "duplicates '\(identifier)'"))
            }
        }
        return issues
    }

    private func duplicateIdentifierIssues(
        _ identifiers: [String],
        collectionPath: String
    ) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        var seen: Set<String> = []
        for (index, identifier) in identifiers.enumerated()
            where !seen.insert(identifier).inserted {
            issues.append(.init(
                path: "\(collectionPath)[\(index)].id",
                message: "duplicates '\(identifier)'"
            ))
        }
        return issues
    }
}
