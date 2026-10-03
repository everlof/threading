import Foundation

/// One serial worker owns bounded document reads, UTF-8 conversion and coordinated writes.
/// A baseline is the exact bytes opened/saved, so an external edit is never silently replaced.
actor MarkdownEditorFileStore {
    static let shared = MarkdownEditorFileStore()
    static let maximumBytes = 1_048_576

    struct Contents: Sendable {
        let url: URL
        let text: String
        let bytes: Data
    }

    enum Failure: Error, LocalizedError {
        case tooLarge, invalidUTF8, changedOnDisk, notRegularFile

        var errorDescription: String? {
            switch self {
            case .tooLarge: L10n.string("The Markdown editor supports files up to 1 MB.")
            case .invalidUTF8: L10n.string("This file is not valid UTF-8 text.")
            case .changedOnDisk: L10n.string("This file changed on disk after it was opened.")
            case .notRegularFile: L10n.string("Choose a regular Markdown text file.")
            }
        }
    }

    func read(_ url: URL) throws -> Contents {
        let resolvedURL = url.resolvingSymlinksInPath()
        let bytes = try readBytes(resolvedURL)
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return Contents(url: resolvedURL, text: text, bytes: bytes)
    }

    func save(_ text: String, to url: URL, baseline: Data?) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.maximumBytes else { throw Failure.tooLarge }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                if let baseline {
                    guard try readBytes(target) == baseline else { throw Failure.changedOnDisk }
                }
                try bytes.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return bytes
    }

    private func readBytes(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure.notRegularFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard bytes.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return bytes
    }
}
