import AppKit
import SkalmanExtensionKit

/// Shared resolution for component contracts without contextual host assets.
///
/// Entity-backed rows layer their own host-asset vocabulary on top. Generic presentations and
/// composers use this resolver so system symbols and package images behave consistently.
@MainActor
enum ExtensionComponentResourceResolver {
    static func image(
        _ reference: ExtensionImageReference,
        extensionIdentifier: String?
    ) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            )
        case .extensionResource(let path):
            guard let extensionIdentifier,
                  let url = ExtensionManager.shared.imageResourceURL(
                      relativePath: path,
                      extensionIdentifier: extensionIdentifier
                  ) else {
                return nil
            }
            return NSImage(contentsOf: url)
        case .hostAsset:
            return nil
        }
    }
}
