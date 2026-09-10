import Foundation

/// The on-disk description Threading reads before starting an extension.
///
/// The manifest is intentionally data-only. Discovering an extension must never require
/// loading or executing its code.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let identifier: String
    public let name: String
    public let version: String
    public let dataVersion: Int
    public let runtime: ExtensionRuntime
    public let executable: String
    public let capabilities: Set<ExtensionCapability>
    /// Host-evaluated navigator declarations inspectable before the process starts.
    ///
    /// Materialized v1 navigators remain runtime-only for compatibility. Every pipeline
    /// navigator must appear here and the running generation must register the exact same value.
    public let workspaceNavigators: [ExtensionWorkspaceNavigator]
    public let mcpTools: [ExtensionMCPTool]
    public let settings: ExtensionSettingsContribution
    public let services: [ExtensionServiceDefinition]
    public let factDefinitions: [ExtensionFactDefinition]
    /// Read-only hosted-Git providers inspectable before the process starts.
    public let sourceControlProviders: [ExtensionSourceControlProviderDefinition]
    public let serviceDependencies: [ExtensionServiceDependency]
    public let companions: [ExtensionCompanion]
    public let themes: [ExtensionThemeContribution]
    public let fonts: [ExtensionFontContribution]
    public let localizations: [ExtensionLocalizationContribution]
    public let networkGrants: [ExtensionNetworkGrant]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        identifier: String,
        name: String,
        version: String,
        dataVersion: Int = 1,
        runtime: ExtensionRuntime,
        executable: String,
        capabilities: Set<ExtensionCapability> = [],
        workspaceNavigators: [ExtensionWorkspaceNavigator] = [],
        mcpTools: [ExtensionMCPTool] = [],
        settings: ExtensionSettingsContribution = .init(),
        services: [ExtensionServiceDefinition] = [],
        factDefinitions: [ExtensionFactDefinition] = [],
        sourceControlProviders: [ExtensionSourceControlProviderDefinition] = [],
        serviceDependencies: [ExtensionServiceDependency] = [],
        companions: [ExtensionCompanion] = [],
        themes: [ExtensionThemeContribution] = [],
        fonts: [ExtensionFontContribution] = [],
        localizations: [ExtensionLocalizationContribution] = [],
        networkGrants: [ExtensionNetworkGrant] = []
    ) {
        self.formatVersion = formatVersion
        self.identifier = identifier
        self.name = name
        self.version = version
        self.dataVersion = dataVersion
        self.runtime = runtime
        self.executable = executable
        self.capabilities = capabilities
        self.workspaceNavigators = workspaceNavigators
        self.mcpTools = mcpTools
        self.settings = settings
        self.services = services
        self.factDefinitions = factDefinitions
        self.sourceControlProviders = sourceControlProviders
        self.serviceDependencies = serviceDependencies
        self.companions = companions
        self.themes = themes
        self.fonts = fonts
        self.localizations = localizations
        self.networkGrants = networkGrants
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, identifier, name, version, dataVersion, runtime, executable, capabilities
        case workspaceNavigators, mcpTools, settings
        case services, factDefinitions, sourceControlProviders, serviceDependencies, companions, themes, fonts
        case localizations, networkGrants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        dataVersion = try container.decodeIfPresent(Int.self, forKey: .dataVersion) ?? 1
        runtime = try container.decode(ExtensionRuntime.self, forKey: .runtime)
        executable = try container.decode(String.self, forKey: .executable)
        capabilities = try container.decode(Set<ExtensionCapability>.self, forKey: .capabilities)
        workspaceNavigators = if container.contains(.workspaceNavigators) {
            try container.decode(
                [ExtensionWorkspaceNavigator].self,
                forKey: .workspaceNavigators
            )
        } else {
            []
        }
        mcpTools = try container.decodeIfPresent([ExtensionMCPTool].self, forKey: .mcpTools) ?? []
        settings = try container.decodeIfPresent(
            ExtensionSettingsContribution.self,
            forKey: .settings
        ) ?? .init()
        services = try container.decodeIfPresent(
            [ExtensionServiceDefinition].self,
            forKey: .services
        ) ?? []
        factDefinitions = try container.decodeIfPresent(
            [ExtensionFactDefinition].self,
            forKey: .factDefinitions
        ) ?? []
        sourceControlProviders = try container.decodeIfPresent(
            [ExtensionSourceControlProviderDefinition].self,
            forKey: .sourceControlProviders
        ) ?? []
        serviceDependencies = try container.decodeIfPresent(
            [ExtensionServiceDependency].self,
            forKey: .serviceDependencies
        ) ?? []
        companions = try container.decodeIfPresent(
            [ExtensionCompanion].self,
            forKey: .companions
        ) ?? []
        themes = try container.decodeIfPresent(
            [ExtensionThemeContribution].self,
            forKey: .themes
        ) ?? []
        fonts = try container.decodeIfPresent(
            [ExtensionFontContribution].self,
            forKey: .fonts
        ) ?? []
        localizations = try container.decodeIfPresent(
            [ExtensionLocalizationContribution].self,
            forKey: .localizations
        ) ?? []
        networkGrants = try container.decodeIfPresent(
            [ExtensionNetworkGrant].self,
            forKey: .networkGrants
        ) ?? []
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
        if !(1...1_000_000).contains(dataVersion) {
            issues.append(.init(
                path: "dataVersion",
                message: "must be between 1 and 1000000"
            ))
        }

        if !ExtensionIdentifierRules.isSafeRelativePath(executable) {
            issues.append(
                .init(
                    path: "executable",
                    message: "must be a relative path without '.' or '..' components"
                )
            )
        }
        if runtime == .webAssembly,
           URL(fileURLWithPath: executable).pathExtension.lowercased() != "wasm" {
            issues.append(
                .init(
                    path: "executable",
                    message: "must end in '.wasm' for the 'webAssembly' runtime"
                )
            )
        }

        var seenNavigatorIDs: Set<String> = []
        for (index, navigator) in workspaceNavigators.enumerated() {
            let path = "workspaceNavigators[\(index)]"
            issues.append(contentsOf: navigator.validationIssues(path: path))
            if navigator.pipeline == nil {
                issues.append(.init(
                    path: "\(path).pipeline",
                    message: "must declare a host-evaluated pipeline; v1 navigators stay runtime-only"
                ))
            }
            if !seenNavigatorIDs.insert(navigator.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicates '\(navigator.id)'"))
            }
        }
        if workspaceNavigators.count > 8 {
            issues.append(.init(
                path: "workspaceNavigators",
                message: "must contain at most 8 navigators"
            ))
        }
        if !workspaceNavigators.isEmpty,
           !capabilities.contains(.workspaceNavigation) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'ui.workspace-navigation' when pipeline navigators are declared"
            ))
        }

        var seenToolIDs: Set<String> = []
        for (index, tool) in mcpTools.enumerated() {
            let path = "mcpTools[\(index)]"
            issues.append(contentsOf: tool.validationIssues(
                path: path,
                extensionIdentifier: identifier
            ))
            if !seenToolIDs.insert(tool.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicates '\(tool.id)'"))
            }
        }
        if mcpTools.count > ExtensionMCPTool.maximumCount {
            issues.append(.init(
                path: "mcpTools",
                message: "must contain at most \(ExtensionMCPTool.maximumCount) tools"
            ))
        }
        if !mcpTools.isEmpty, !capabilities.contains(.mcpTools) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'mcp.tools' when MCP tools are declared"
            ))
        }

        issues.append(contentsOf: settings.validationIssues())
        if !settings.isEmpty, !capabilities.contains(.settings) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'settings' when settings are declared"
            ))
        }

        var seenServices: Set<String> = []
        for (index, service) in services.enumerated() {
            let path = "services[\(index)]"
            issues.append(contentsOf: service.validationIssues(path: path))
            let key = "\(service.id)@\(service.version)"
            if !seenServices.insert(key).inserted {
                issues.append(.init(path: path, message: "duplicates '\(key)'"))
            }
        }
        if services.count > 32 {
            issues.append(.init(path: "services", message: "must contain at most 32 services"))
        }
        if !services.isEmpty, !capabilities.contains(.servicesProvide) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'services.provide' when services are declared"
            ))
        }

        var seenFactKeys: Set<ExtensionFactKey> = []
        for (index, definition) in factDefinitions.enumerated() {
            let path = "factDefinitions[\(index)]"
            issues.append(contentsOf: definition.providerValidationIssues(path: path))
            if !seenFactKeys.insert(definition.key).inserted {
                issues.append(.init(path: "\(path).key", message: "duplicates this fact key"))
            }
        }
        if factDefinitions.count > ExtensionFactProviderLimits.maximumDefinitions {
            issues.append(.init(
                path: "factDefinitions",
                message: "must contain at most "
                    + "\(ExtensionFactProviderLimits.maximumDefinitions) definitions"
            ))
        }
        if !factDefinitions.isEmpty, !capabilities.contains(.factsProvide) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'facts.provide' when fact definitions are declared"
            ))
        }
        if capabilities.contains(.factsProvide), factDefinitions.isEmpty {
            issues.append(.init(
                path: "factDefinitions",
                message: "must declare at least one definition for 'facts.provide'"
            ))
        }

        var seenSourceControlProviderIDs: Set<String> = []
        for (index, provider) in sourceControlProviders.enumerated() {
            let path = "sourceControlProviders[\(index)]"
            issues.append(contentsOf: provider.validationIssues(path: path))
            if !seenSourceControlProviderIDs.insert(provider.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicates '\(provider.id)'"))
            }
        }
        if sourceControlProviders.count > ExtensionSourceControlProviderDefinition.maximumCount {
            issues.append(.init(
                path: "sourceControlProviders",
                message: "must contain at most \(ExtensionSourceControlProviderDefinition.maximumCount) providers"
            ))
        }
        if !sourceControlProviders.isEmpty, !capabilities.contains(.sourceControlRead) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'source-control.read' when source-control providers are declared"
            ))
        }
        if capabilities.contains(.sourceControlRead), sourceControlProviders.isEmpty {
            issues.append(.init(
                path: "sourceControlProviders",
                message: "must declare at least one provider for 'source-control.read'"
            ))
        }

        var seenDependencies: Set<String> = []
        for (index, dependency) in serviceDependencies.enumerated() {
            let path = "serviceDependencies[\(index)]"
            issues.append(contentsOf: dependency.validationIssues(
                path: path,
                consumerIdentifier: identifier
            ))
            let key = "\(dependency.providerIdentifier)/\(dependency.serviceID)@\(dependency.version)"
            if !seenDependencies.insert(key).inserted {
                issues.append(.init(path: path, message: "duplicates this dependency"))
            }
        }
        if serviceDependencies.count > 64 {
            issues.append(.init(
                path: "serviceDependencies",
                message: "must contain at most 64 dependencies"
            ))
        }
        if !serviceDependencies.isEmpty, !capabilities.contains(.servicesConsume) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'services.consume' when dependencies are declared"
            ))
        }

        if networkGrants.count > ExtensionBrokeredNetwork.maximumGrants {
            issues.append(.init(
                path: "networkGrants",
                message: "must contain at most \(ExtensionBrokeredNetwork.maximumGrants) grants"
            ))
        }
        var seenGrantHosts: Set<String> = []
        for (index, grant) in networkGrants.enumerated() {
            let path = "networkGrants[\(index)]"
            issues.append(contentsOf: grant.validationIssues(path: path))
            if !seenGrantHosts.insert(grant.host).inserted {
                issues.append(.init(
                    path: "\(path).host",
                    message: "duplicates '\(grant.host)'"
                ))
            }
        }
        if !networkGrants.isEmpty, !capabilities.contains(.networkBrokered) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'network.brokered' when network grants are declared"
            ))
        }
        if capabilities.contains(.networkBrokered), networkGrants.isEmpty {
            issues.append(.init(
                path: "networkGrants",
                message: "must declare at least one grant for 'network.brokered'"
            ))
        }
        // Brokered responses only ever land inside the sandboxed guest — unless the same
        // extension also owns a raw socket through a companion, which is the one pairing that
        // would let data fetched with the user's credentials leave the machine.
        let hasNetworkCompanion = companions.contains {
            $0.capabilities.contains(.networkClient)
        }
        if hasNetworkCompanion, networkGrants.contains(where: { $0.credential != nil }) {
            issues.append(.init(
                path: "networkGrants",
                message: "credentialed grants cannot be combined with a companion holding "
                    + "'network.client'"
            ))
        }

        if companions.count > ExtensionCompanion.maximumCount {
            issues.append(.init(
                path: "companions",
                message: "must contain at most \(ExtensionCompanion.maximumCount) companions"
            ))
        }
        if !companions.isEmpty, runtime != .webAssembly {
            issues.append(.init(
                path: "companions",
                message: "advanced companions require a 'webAssembly' core runtime"
            ))
        }
        var seenCompanionIDs: Set<String> = []
        var seenCompanionPaths: Set<String> = []
        for (index, companion) in companions.enumerated() {
            let path = "companions[\(index)]"
            issues.append(contentsOf: companion.validationIssues(
                path: path,
                extensionIdentifier: identifier
            ))
            if !seenCompanionIDs.insert(companion.id).inserted {
                issues.append(.init(
                    path: "\(path).id",
                    message: "duplicates '\(companion.id)'"
                ))
            }
            if !seenCompanionPaths.insert(companion.bundlePath).inserted {
                issues.append(.init(
                    path: "\(path).bundlePath",
                    message: "duplicates '\(companion.bundlePath)'"
                ))
            }
        }
        if companions.contains(where: { !$0.operations.isEmpty }),
           !capabilities.contains(.companionOperations) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'companions.invoke' when companion operations are declared"
            ))
        }

        if themes.count > ExtensionThemeContribution.maximumCount {
            issues.append(.init(
                path: "themes",
                message: "must contain at most \(ExtensionThemeContribution.maximumCount) themes"
            ))
        }
        var seenThemeIDs: Set<String> = []
        var seenThemeResources: Set<String> = []
        for (index, theme) in themes.enumerated() {
            let path = "themes[\(index)]"
            if !ExtensionIdentifierRules.isContributionIdentifier(theme.id) {
                issues.append(.init(
                    path: "\(path).id",
                    message: ExtensionIdentifierRules.contributionMessage
                ))
            }
            if !ExtensionIdentifierRules.isSafeRelativePath(theme.resource) {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "must be a relative path without '.' or '..' components"
                ))
            }
            if let mark = theme.iconMark, !ExtensionIdentifierRules.isSafeRelativePath(mark) {
                issues.append(.init(
                    path: "\(path).iconMark",
                    message: "must be a relative path without '.' or '..' components"
                ))
            }
            if !seenThemeIDs.insert(theme.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicates '\(theme.id)'"))
            }
            if !seenThemeResources.insert(theme.resource).inserted {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "duplicates '\(theme.resource)'"
                ))
            }
        }
        if !themes.isEmpty, !capabilities.contains(.themeProvider) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'appearance.themes' when themes are declared"
            ))
        }

        if fonts.count > ExtensionFontContribution.maximumCount {
            issues.append(.init(
                path: "fonts",
                message: "must contain at most \(ExtensionFontContribution.maximumCount) fonts"
            ))
        }
        var seenFontResources: Set<String> = []
        for (index, font) in fonts.enumerated() {
            let path = "fonts[\(index)]"
            if !ExtensionIdentifierRules.isSafeRelativePath(font.resource) {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "must be a relative path without '.' or '..' components"
                ))
            }
            let fileExtension = (font.resource as NSString).pathExtension.lowercased()
            if !ExtensionFontContribution.allowedExtensions.contains(fileExtension) {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "must end in one of: "
                        + ExtensionFontContribution.allowedExtensions.sorted().joined(separator: ", ")
                ))
            }
            if !seenFontResources.insert(font.resource).inserted {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "duplicates '\(font.resource)'"
                ))
            }
        }
        if !fonts.isEmpty, !capabilities.contains(.fontProvider) {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'appearance.fonts' when fonts are declared"
            ))
        }

        if localizations.count > ExtensionLocalizationContribution.maximumCount {
            issues.append(.init(
                path: "localizations",
                message: "must contain at most "
                    + "\(ExtensionLocalizationContribution.maximumCount) localizations"
            ))
        }
        var seenLocalizationLocales: Set<String> = []
        var seenLocalizationResources: Set<String> = []
        for (index, localization) in localizations.enumerated() {
            let path = "localizations[\(index)]"
            issues.append(contentsOf: localization.validationIssues(path: path))
            let locale = localization.locale.lowercased()
            if !seenLocalizationLocales.insert(locale).inserted {
                issues.append(.init(
                    path: "\(path).locale",
                    message: "duplicates '\(localization.locale)'"
                ))
            }
            if !seenLocalizationResources.insert(localization.resource).inserted {
                issues.append(.init(
                    path: "\(path).resource",
                    message: "duplicates '\(localization.resource)'"
                ))
            }
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// One app-chrome theme a package offers the host's theme library.
///
/// Deliberately a *reference to a document*, not the document: the theme file is written in the
/// host's own app-theme vocabulary (the same JSON Threading stores for a custom theme), so the
/// vocabulary can grow — a new material field, a new role — without an SDK release. The kit
/// only says where the file is; the host reads and validates it at inspection time, before any
/// extension code runs, exactly as it treats a Metal `shaderResource`.
public struct ExtensionThemeContribution: Codable, Equatable, Sendable {
    public static let maximumCount = 16

    /// Stable within the package; the host namespaces it under the extension's identifier, so
    /// two extensions may both ship a theme called `storm` without colliding.
    public let id: String
    /// Package-relative path to the theme document.
    public let resource: String

    /// Package-relative path to a PNG **mark** the app icon wears while this theme is selected.
    ///
    /// A mark, not a tile. The host draws the plate from the theme's own `ground` and composites
    /// this on top, so one asset serves both appearances and the Dock icon stays recognisably
    /// Threading's — a package cannot ship a pixel-perfect copy of some other app's icon and have
    /// the host present it as this one. The host **rejects a mark that fills its own bounds**,
    /// at inspection time, before any extension code runs: an opaque rectangle is a tile.
    ///
    /// Optional. A theme without one is drawn with the app's own chevron in the theme's accent,
    /// which is what every stock style gets.
    public let iconMark: String?

    public init(id: String, resource: String, iconMark: String? = nil) {
        self.id = id
        self.resource = resource
        self.iconMark = iconMark
    }
}

/// One font file a package offers the host while the extension is enabled.
///
/// The family name is not declared here — it belongs to the font file, and stating it twice
/// invites drift. The host reads it from the file at inspection time and registers the font
/// process-scoped on enable, which is what makes the family appear in the font pickers and
/// resolvable by theme documents that name it.
public struct ExtensionFontContribution: Codable, Equatable, Sendable {
    public static let maximumCount = 16
    public static let allowedExtensions: Set<String> = ["otf", "ttf", "ttc"]

    /// Package-relative path to the font file.
    public let resource: String

    public init(resource: String) {
        self.resource = resource
    }
}

/// The execution boundary declared by an extension package.
///
/// Native remains the decode default for format-1 development packages. New distributable
/// extensions use `webAssembly`, which runs behind Threading's capability-only Wasm host.
public enum ExtensionRuntime: String, Codable, Equatable, Sendable {
    case native
    case webAssembly
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
    public static let mcpTools = Self(rawValue: "mcp.tools")
    public static let settings = Self(rawValue: "settings")
    public static let servicesProvide = Self(rawValue: "services.provide")
    public static let servicesConsume = Self(rawValue: "services.consume")
    public static let factsProvide = Self(rawValue: "facts.provide")
    public static let companionOperations = Self(rawValue: "companions.invoke")
    public static let componentCustomization = Self(rawValue: "ui.components")
    public static let workspaceNavigation = Self(rawValue: "ui.workspace-navigation")
    public static let customMetalSurfaces = Self(rawValue: "ui.rendering.metal")
    /// Permission to place a `media` node — a document the host plays — in a contribution.
    ///
    /// Independent of `panels` and of `ui.components`, so no existing contract silently gains a
    /// player when this SDK ships: a surface that carries one has to say so, and a user granting
    /// panels has not thereby granted animation.
    public static let mediaDocuments = Self(rawValue: "ui.media-documents")
    /// Permission to offer a preview body for an attachment Threading has no renderer for.
    ///
    /// Grants no attachment read authority: a candidate learns an attachment's name, kind, size,
    /// origin and the host's content hint, and nothing about its content that the host did not
    /// already publish.
    public static let attachmentsPreview = Self(rawValue: "attachments.preview")
    /// Permission to add file extensions to the attachments scanner's allow-list.
    ///
    /// The store still decides recording, copying, ceilings and pruning. A registration may not
    /// claim an extension the host already classifies.
    public static let attachmentFileTypes = Self(rawValue: "attachments.file-types")
    public static let hostProjectsRead = Self(rawValue: "host.projects.read")
    /// Bounded, cursor-paged enumeration of a project's own documents as opaque **handles**.
    ///
    /// Deliberately not implied by `host.projects.read`: that authority returns a sanitized
    /// snapshot with no filesystem in it at all, and this one returns names, project-relative
    /// paths, byte sizes and modification dates. Installation and enablement disclose it
    /// separately because it is a different question.
    public static let hostProjectFilesRead = Self(rawValue: "host.project.files.read")
    public static let hostSessionsRead = Self(rawValue: "host.sessions.read")
    public static let hostSessionRuntimeRead = Self(rawValue: "host.sessions.runtime.read")
    public static let hostRepositoriesRead = Self(rawValue: "host.repositories.read")
    public static let hostProvidersRead = Self(rawValue: "host.providers.read")
    public static let hostAccountsPresentationRead = Self(
        rawValue: "host.accounts.presentation.read"
    )
    public static let hostEvents = Self(rawValue: "host.events")
    public static let providerIconResolver = Self(rawValue: "appearance.provider-icons")
    public static let accountIconResolver = Self(rawValue: "appearance.account-icons")
    public static let sessionIdentityRenderer = Self(rawValue: "appearance.session-identity")
    public static let themeProvider = Self(rawValue: "appearance.themes")
    public static let fontProvider = Self(rawValue: "appearance.fonts")
    public static let keyValueStorage = Self(rawValue: "storage.kv")
    public static let cacheStorage = Self(rawValue: "storage.cache")
    public static let secrets = Self(rawValue: "storage.secrets")
    public static let networkClient = Self(rawValue: "network.client")
    public static let networkBrokered = Self(rawValue: "network.brokered")
    /// Permission to answer host-owned, read-only change-request queries and make connection-
    /// scoped broker requests. It grants neither local Git access nor forge mutation.
    public static let sourceControlRead = Self(rawValue: "source-control.read")
}

public enum ExtensionIdentifierRules {
    public static let contributionMessage =
        "must start with a lowercase letter and contain only lowercase letters, digits, '-', or '.'"

    public static func isReverseDNSIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLowercaseASCII else { return false }
            return part.allSatisfy { $0.isLowercaseASCII || $0.isASCIINumber || $0 == "-" }
        }
    }

    public static func isContributionIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLowercaseASCII else { return false }
        return value.allSatisfy {
            $0.isLowercaseASCII || $0.isASCIINumber || $0 == "-" || $0 == "."
        }
    }

    public static func isSafeRelativePath(_ value: String) -> Bool {
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
