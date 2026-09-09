import Foundation

/// The user's desired leading-navigator source.
///
/// Availability is deliberately separate: a selected extension may stop or reload, in which
/// case the visible navigator falls back to Native while this identity remains available for
/// the replacement process generation.
enum WorkspaceNavigatorSelection: Codable, Equatable, Sendable {
    case native
    case extensionNavigator(extensionIdentifier: String, navigatorID: String)
    case nativePluginNavigator(pluginIdentifier: String, navigatorID: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case extensionIdentifier
        case pluginIdentifier
        case navigatorID
    }

    private enum Kind: String, Codable {
        case native
        case extensionNavigator
        case nativePluginNavigator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .native:
            self = .native
        case .extensionNavigator:
            self = .extensionNavigator(
                extensionIdentifier: try container.decode(
                    String.self,
                    forKey: .extensionIdentifier
                ),
                navigatorID: try container.decode(String.self, forKey: .navigatorID)
            )
        case .nativePluginNavigator:
            self = .nativePluginNavigator(
                pluginIdentifier: try container.decode(String.self, forKey: .pluginIdentifier),
                navigatorID: try container.decode(String.self, forKey: .navigatorID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native:
            try container.encode(Kind.native, forKey: .type)
        case .extensionNavigator(let extensionIdentifier, let navigatorID):
            try container.encode(Kind.extensionNavigator, forKey: .type)
            try container.encode(extensionIdentifier, forKey: .extensionIdentifier)
            try container.encode(navigatorID, forKey: .navigatorID)
        case .nativePluginNavigator(let pluginIdentifier, let navigatorID):
            try container.encode(Kind.nativePluginNavigator, forKey: .type)
            try container.encode(pluginIdentifier, forKey: .pluginIdentifier)
            try container.encode(navigatorID, forKey: .navigatorID)
        }
    }
}
