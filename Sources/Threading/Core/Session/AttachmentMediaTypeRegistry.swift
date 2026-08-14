import Foundation
import ThreadingExtensionKit

/// The file extensions enabled extensions have asked the attachments scanner to notice.
///
/// It adds to the scanner's allow-list and **nothing else**: the store still decides recording,
/// copying, ceilings, pruning and every question about custody. A registration is a request to be
/// looked at, not an authority over what is kept.
///
/// Lock-guarded rather than main-actor-isolated because the answer is needed where the scan runs.
/// Detection reads a terminal buffer on a worker — that is the whole reason it is off the main
/// actor — and a registry only the main actor could read would force the hot path back onto it.
final class AttachmentMediaTypeRegistry: @unchecked Sendable {

    static let shared = AttachmentMediaTypeRegistry()

    private let lock = NSLock()
    private var typesByExtension: [String: String] = [:]
    private var identifiersByExtension: [String: String] = [:]

    private init() {}

    /// Whether the scanner should notice this extension. Lowercased, no dot.
    func isRegistered(_ fileExtension: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return typesByExtension[fileExtension] != nil
    }

    /// The display name a registration gave its type, for the pane's own detail line.
    func displayName(for fileExtension: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return typesByExtension[fileExtension]
    }

    var registeredExtensions: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(typesByExtension.keys)
    }

    /// Replaces one extension's registrations.
    ///
    /// **First registration wins a contested extension.** The alternative — last wins — would let
    /// an extension enabled later silently take a type from one the user already had, and the
    /// scanner's allow-list is not a place for a race.
    func register(
        _ types: [ExtensionPreviewableFileType],
        extensionIdentifier: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(extensionIdentifier: extensionIdentifier)
        for type in types {
            let key = type.fileExtension.lowercased()
            guard !ExtensionPreviewableFileType.reservedExtensions.contains(key),
                  typesByExtension[key] == nil else { continue }
            typesByExtension[key] = type.displayName
            identifiersByExtension[key] = extensionIdentifier
        }
    }

    func remove(extensionIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(extensionIdentifier: extensionIdentifier)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        typesByExtension.removeAll()
        identifiersByExtension.removeAll()
    }

    private func removeLocked(extensionIdentifier: String) {
        for (key, owner) in identifiersByExtension where owner == extensionIdentifier {
            identifiersByExtension.removeValue(forKey: key)
            typesByExtension.removeValue(forKey: key)
        }
    }
}
