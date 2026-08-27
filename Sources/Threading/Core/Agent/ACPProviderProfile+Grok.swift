import Foundation

/// Grok's ACP profile, verified against Grok 0.2.118 and ACP protocol version 1.
extension ACPProviderProfile {
    static var grok: ACPProviderProfile {
        ACPProviderProfile(
            displayName: GrokACPDefaults.displayName,
            diagnosticsLabel: GrokACPDefaults.diagnosticsLabel,
            unknownEventPrefix: GrokACPDefaults.unknownEventPrefix,
            // Grok needs no private handshake flag, so `initialize` carries no `_meta` at all
            // rather than an empty object the agent would have to ignore.
            clientCapabilitiesMeta: [:],
            extendedModelID: GrokACPExtensions.modelStateModelID(in:),
            initializeCommands: GrokACPExtensions.availableCommands(in:),
            initialCommandCatalog: .initializeResponse,
            commandCatalog: GrokACPComposerCatalog.policy
        )
    }
}

// MARK: - Wire Extensions

/// The two places Grok answers outside the standard ACP shapes, both under `_meta`.
enum GrokACPExtensions {
    static func modelStateModelID(in result: [String: Any]?) -> String? {
        let metadata = result?["_meta"] as? [String: Any]
        let modelState = metadata?["modelState"] as? [String: Any]
        return modelState?["currentModelId"] as? String
    }

    static func availableCommands(in result: [String: Any]?) -> [[String: Any]]? {
        let metadata = result?["_meta"] as? [String: Any]
        return metadata?["availableCommands"] as? [[String: Any]]
    }
}

// MARK: - Composer Catalog

enum GrokACPComposerCatalog {
    /// Computed rather than stored: the refusal reason is localized, and a stored global would
    /// freeze the first language the process resolved.
    static var policy: ACPCommandCatalogPolicy {
        ACPCommandCatalogPolicy(
            identifierPrefix: GrokACPDefaults.commandIdentifierPrefix,
            hostOnlyNames: [
                "always-approve", "clear", "exit", "feedback", "fork", "login", "logout",
                "model", "new", "permissions", "quit", "resume"
            ],
            hostOnlyReason: L10n.string(
                "Available in Grok Terminal; not available in native Chat yet"
            ),
            sessionCommandNames: ["compact", "context", "session-info"]
        )
    }
}

// MARK: - Constants

private enum GrokACPDefaults {
    static let displayName = "Grok"
    static let diagnosticsLabel = "Grok ACP"
    static let unknownEventPrefix = "grok.acp."
    static let commandIdentifierPrefix = "grok.command:"
}
