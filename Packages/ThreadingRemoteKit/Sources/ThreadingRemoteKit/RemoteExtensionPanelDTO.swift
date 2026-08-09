import Foundation
import ThreadingExtensionKit

/// One live extension panel resolved by the Mac for a particular session.
///
/// The value is the extension SDK's semantic panel contract, not a screenshot, HTML document, or
/// private AppKit archive. Every client owns its native renderer. `processGeneration` lets a
/// client distinguish a replacement process from an ordinary action update without learning any
/// process identifier.
public struct RemoteExtensionPanelDTO: Codable, Equatable, Sendable {
    public let extensionIdentifier: String
    public let extensionName: String
    public let processGeneration: String
    public let panel: ExtensionPanel

    public init(
        extensionIdentifier: String,
        extensionName: String,
        processGeneration: String,
        panel: ExtensionPanel
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.extensionName = extensionName
        self.processGeneration = processGeneration
        self.panel = panel
    }
}

/// A native control event raised by the remote renderer.
///
/// Extension and panel identity stay in the authenticated URL selected by the host-issued route;
/// the body names only an action already present in that panel and its bounded semantic value.
public struct RemoteExtensionPanelActionRequestDTO: Codable, Equatable, Sendable {
    public let processGeneration: String
    public let actionID: String
    public let value: ExtensionJSONValue?

    public init(
        processGeneration: String,
        actionID: String,
        value: ExtensionJSONValue? = nil
    ) {
        self.processGeneration = processGeneration
        self.actionID = actionID
        self.value = value
    }
}

/// The useful projection of `ExtensionActionResponse` for a remote native renderer.
///
/// The Mac keeps correlation and process protocol details at the extension boundary. A phone only
/// needs the replacement semantic panel and the mutually exclusive success/error copy.
public struct RemoteExtensionPanelActionResponseDTO: Codable, Equatable, Sendable {
    public let processGeneration: String
    public let panel: ExtensionPanel?
    public let message: String?
    public let error: String?

    public init(
        processGeneration: String,
        panel: ExtensionPanel? = nil,
        message: String? = nil,
        error: String? = nil
    ) {
        self.processGeneration = processGeneration
        self.panel = panel
        self.message = message
        self.error = error
    }
}
