import Foundation

struct CheckoutTranscriptCopyPair: Sendable {
    let sourceTranscript: URL
    let destinationTranscript: URL
    let sourceSubagents: URL?
    let destinationSubagents: URL?
}

enum CheckoutTranscriptCopyError: Error, LocalizedError {
    case sourceNotRegular(String)
    case commitRefused
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotRegular(let path): return "The Claude transcript is not a regular file: \(path)"
        case .commitRefused: return "The checkout move could not be saved."
        case .rollbackFailed(let path): return "Transcript rollback needs recovery at \(path)."
        }
    }
}

/// A prepared, multi-transcript copy whose expensive bytes are copied off the main actor.
final class CheckoutTranscriptCopyTransaction: @unchecked Sendable {
    private struct Item {
        let destination: URL
        let candidate: URL
        let backup: URL
    }

    private let items: [Item]
    private let fileManager: FileManager

    static func prepare(
        _ pairs: [CheckoutTranscriptCopyPair],
        fileManager: FileManager = .default
    ) throws -> CheckoutTranscriptCopyTransaction {
        var items: [Item] = []
        do {
            for pair in pairs {
                try appendPrepared(
                    source: pair.sourceTranscript,
                    destination: pair.destinationTranscript,
                    expectsDirectory: false,
                    fileManager: fileManager,
                    items: &items
                )
                if let source = pair.sourceSubagents,
                   let destination = pair.destinationSubagents,
                   fileManager.fileExists(atPath: source.path) {
                    try appendPrepared(
                        source: source,
                        destination: destination,
                        expectsDirectory: true,
                        fileManager: fileManager,
                        items: &items
                    )
                }
            }
            return CheckoutTranscriptCopyTransaction(items: items, fileManager: fileManager)
        } catch {
            for item in items { try? fileManager.removeItem(at: item.candidate) }
            throw error
        }
    }

    /// Promotes candidates, runs the graph commit, then removes backups; any refusal restores all
    /// destinations in reverse order before returning.
    @MainActor
    func install(commit: () -> Bool) throws -> Bool {
        var promoted: [Item] = []
        do {
            for item in items {
                try fileManager.createDirectory(
                    at: item.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: item.destination.path) {
                    try? fileManager.removeItem(at: item.backup)
                    try fileManager.moveItem(at: item.destination, to: item.backup)
                }
                do {
                    try fileManager.moveItem(at: item.candidate, to: item.destination)
                } catch {
                    if fileManager.fileExists(atPath: item.backup.path) {
                        try? fileManager.moveItem(at: item.backup, to: item.destination)
                    }
                    throw error
                }
                promoted.append(item)
            }
            guard commit() else { throw CheckoutTranscriptCopyError.commitRefused }
            for item in promoted { try? fileManager.removeItem(at: item.backup) }
            return true
        } catch {
            var recoveryPath: String?
            for item in promoted.reversed() {
                try? fileManager.removeItem(at: item.destination)
                if fileManager.fileExists(atPath: item.backup.path) {
                    do { try fileManager.moveItem(at: item.backup, to: item.destination) }
                    catch { recoveryPath = item.backup.path }
                }
            }
            for item in items { try? fileManager.removeItem(at: item.candidate) }
            if let recoveryPath { throw CheckoutTranscriptCopyError.rollbackFailed(recoveryPath) }
            throw error
        }
    }

    private init(items: [Item], fileManager: FileManager) {
        self.items = items
        self.fileManager = fileManager
    }

    private static func appendPrepared(
        source: URL,
        destination: URL,
        expectsDirectory: Bool,
        fileManager: FileManager,
        items: inout [Item]
    ) throws {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true,
              expectsDirectory ? values.isDirectory == true : values.isRegularFile == true else {
            throw CheckoutTranscriptCopyError.sourceNotRegular(source.path)
        }
        let token = UUID().uuidString.lowercased()
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let candidate = parent.appendingPathComponent(".threading-checkout-\(token).candidate")
        let backup = parent.appendingPathComponent(".threading-checkout-\(token).backup")
        try fileManager.copyItem(at: source, to: candidate)
        items.append(Item(destination: destination, candidate: candidate, backup: backup))
    }
}
