import AppKit
import ImageIO
import ThreadingExtensionKit

/// The authoritative decode boundary for package-owned images.
///
/// `ExtensionManager.imageResourceURL` proves containment and provides a cheap metadata refusal,
/// but the package remains mutable after that lookup. Reading one byte past the documented cap
/// closes that race, while ImageIO properties let us refuse decompression bombs before AppKit is
/// asked to allocate their pixels. Decoding the one accepted frame here also keeps every host
/// surface on the same policy instead of relying on `NSImage(contentsOf:)`'s lazy behaviour.
@MainActor
enum ExtensionImageResourceLoader {
    static let maximumBytes = ExtensionImageResourcePolicy.maximumBytes
    static let maximumPixelDimension = ExtensionImageResourcePolicy.maximumPixelDimension

    static func image(at url: URL) -> NSImage? {
        guard let data = ExtensionImageResourcePolicy.validatedData(at: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
                  ] as CFDictionary
              ) else {
            return nil
        }

        return NSImage(
            cgImage: decoded,
            size: NSSize(width: decoded.width, height: decoded.height)
        )
    }
}

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
            return ExtensionImageResourceLoader.image(at: url)
        case .hostAsset:
            return nil
        }
    }
}
