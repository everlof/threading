import Foundation
import ThreadingDesignKit

/// Where a project's Bluetooth definitions are, and what became of reading them.
///
/// The file belongs to the session's checkout (the host's `checkoutPath`, which follows a managed
/// worktree), so the definitions travel with the app's source and its history. Reading is file
/// work and never happens on the main actor; the capture worker re-stats at most once a second so
/// saving the file takes effect on the next packet without a Rescan.
enum BluetoothDefinitionStatus: Sendable, Equatable {
    case noCheckout
    case missing(expected: URL)
    case loaded(URL, characteristics: Int, types: Int)
    case failed(URL, message: String)

    /// The file this status is about, or where one would go.
    var url: URL? {
        switch self {
        case .noCheckout: return nil
        case .missing(let url), .loaded(let url, _, _), .failed(let url, _): return url
        }
    }

    /// One line for the pane's footer and the agent's `visible` answer.
    var summary: String {
        switch self {
        case .noCheckout:
            return L10n.string("Packet definitions: this tab has no project checkout")
        case .missing(let url):
            return L10n.format("Packet definitions: none (add %@)", BluetoothDefinitionsFile.displayPath(url))
        case .loaded(let url, let characteristics, let types):
            return L10n.format("Packet definitions: %@ · %d characteristics, %d types",
                BluetoothDefinitionsFile.displayPath(url), characteristics, types)
        case .failed(let url, let message):
            return L10n.format("Packet definitions: %@ %@", BluetoothDefinitionsFile.displayPath(url), message)
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum BluetoothDefinitionsFile {
    static let maximumBytes = YAMLSubset.Limits.bytes

    /// What identifies one version of the file without reading it.
    struct Stamp: Equatable, Sendable {
        let path: String
        let size: Int
        let modified: Date
    }

    static func candidates(checkout: String?) -> [URL] {
        guard let checkout, !checkout.isEmpty else { return [] }
        let root = URL(fileURLWithPath: checkout, isDirectory: true)
        return BluetoothPacketDefinitions.relativePaths.map { root.appendingPathComponent($0) }
    }

    /// The path relative to its checkout, which is what the author recognises.
    static func displayPath(_ url: URL) -> String {
        let components = url.pathComponents
        return components.suffix(2).joined(separator: "/")
    }

    static func stamp(checkout: String?) -> Stamp? {
        for url in candidates(checkout: checkout) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            return Stamp(
                path: url.path,
                size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                modified: attributes[.modificationDate] as? Date ?? .distantPast
            )
        }
        return nil
    }

    /// Reads and compiles. Must not run on the main actor.
    static func load(checkout: String?) -> (BluetoothPacketDefinitions?, BluetoothDefinitionStatus) {
        let urls = candidates(checkout: checkout)
        guard let expected = urls.first else { return (nil, .noCheckout) }
        guard let stamp = stamp(checkout: checkout) else { return (nil, .missing(expected: expected)) }
        let url = URL(fileURLWithPath: stamp.path)
        do {
            let data = try BoundedFileReader.read(url, maximumBytes: maximumBytes)
            guard let text = String(data: data, encoding: .utf8) else {
                return (nil, .failed(url, message: L10n.string("is not UTF-8 text")))
            }
            let definitions = try BluetoothPacketDefinitions.compile(text)
            return (definitions, .loaded(url, characteristics: definitions.characteristics.count,
                                         types: definitions.types.count))
        } catch let error as BluetoothDefinitionError {
            return (nil, .failed(url, message: error.localizedDescription))
        } catch BoundedFileReadError.exceedsLimit {
            return (nil, .failed(url, message: L10n.format("is larger than %d KiB", maximumBytes / 1_024)))
        } catch {
            return (nil, .failed(url, message: error.localizedDescription))
        }
    }
}
