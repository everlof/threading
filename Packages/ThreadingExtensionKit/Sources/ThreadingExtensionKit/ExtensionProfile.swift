import Foundation

/// A contribution surface an extension adds to Threading.
///
/// These are composable. They are deliberately not a manifest `type`: a panel may later add a
/// command or an agent tool without changing its identity or migrating its package format.
public enum ExtensionContributionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case commands
    case panels
    case agentTools
    case settings
    case services
    case componentCustomization
    case workspaceNavigation
    case providerIcons
    case accountIcons
    case sessionIdentity
    case sourceControl

    public var displayName: String {
        switch self {
        case .commands: return "Commands"
        case .panels: return "Panels"
        case .agentTools: return "Agent tools"
        case .settings: return "Settings"
        case .services: return "Services"
        case .componentCustomization: return "Component customization"
        case .workspaceNavigation: return "Workspace navigator"
        case .providerIcons: return "Provider icons"
        case .accountIcons: return "Account icons"
        case .sessionIdentity: return "Session identity"
        case .sourceControl: return "Source-control provider"
        }
    }
}

/// A concise description derived from the contribution set for UI and authoring guidance.
public enum ExtensionProfile: String, Codable, Equatable, Sendable {
    case runtime
    case command
    case panel
    case agentTool
    case settings
    case service
    case component
    case navigator
    case hybrid

    public var displayName: String {
        switch self {
        case .runtime: return "Runtime extension"
        case .command: return "Command extension"
        case .panel: return "Panel extension"
        case .agentTool: return "Agent-tool extension"
        case .settings: return "Settings extension"
        case .service: return "Service extension"
        case .component: return "Component extension"
        case .navigator: return "Navigator extension"
        case .hybrid: return "Hybrid extension"
        }
    }
}

public extension ExtensionManifest {
    /// The contribution surfaces declared by this manifest's capabilities.
    var contributionKinds: Set<ExtensionContributionKind> {
        var result: Set<ExtensionContributionKind> = []
        if capabilities.contains(.commands) {
            result.insert(.commands)
        }
        if capabilities.contains(.panels) {
            result.insert(.panels)
        }
        if capabilities.contains(.mcpTools) {
            result.insert(.agentTools)
        }
        if capabilities.contains(.settings) {
            result.insert(.settings)
        }
        if capabilities.contains(.servicesProvide) {
            result.insert(.services)
        }
        if capabilities.contains(.componentCustomization) {
            result.insert(.componentCustomization)
        }
        if capabilities.contains(.workspaceNavigation) {
            result.insert(.workspaceNavigation)
        }
        if capabilities.contains(.providerIconResolver) {
            result.insert(.providerIcons)
        }
        if capabilities.contains(.accountIconResolver) {
            result.insert(.accountIcons)
        }
        if capabilities.contains(.sessionIdentityRenderer) {
            result.insert(.sessionIdentity)
        }
        if capabilities.contains(.sourceControlRead) {
            result.insert(.sourceControl)
        }
        return result
    }

    /// A display profile derived from contributions, never an additional source of truth.
    var profile: ExtensionProfile {
        switch contributionKinds {
        case []:
            return .runtime
        case [.commands]:
            return .command
        case [.panels]:
            return .panel
        case [.agentTools]:
            return .agentTool
        case [.settings]:
            return .settings
        case [.services]:
            return .service
        case [.componentCustomization],
             [.providerIcons],
             [.accountIcons],
             [.sessionIdentity],
             [.providerIcons, .accountIcons]:
            return .component
        case [.workspaceNavigation]:
            return .navigator
        case [.sourceControl]:
            return .service
        default:
            return .hybrid
        }
    }
}
