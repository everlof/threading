import Foundation

/// A finite Quick Look model. Ordinary notes render completely; large documents say when the
/// preview is an excerpt. Files, decoding and source planning belong to a serial worker.
public struct MarkdownPreviewDocument: Sendable {
    public static let maximumFileBytes = 1_048_576
    public static let maximumPreviewBytes = 131_072
    public static let maximumBlockBytes = 32_768
    public static let maximumBlocks = 256
    public let blocks: [String]
    public let isExcerpt: Bool

    public init(source: String) {
        let sources = Markdown.sourceBlocks(source)
        var selected: [String] = []
        var bytes = 0
        for block in sources {
            let count = block.utf8.count
            guard selected.count < Self.maximumBlocks, count <= Self.maximumBlockBytes,
                  bytes + count <= Self.maximumPreviewBytes else { break }
            selected.append(block)
            bytes += count
        }
        blocks = selected
        isExcerpt = selected.count != sources.count
    }
}

public actor MarkdownPreviewWorker {
    public static let shared = MarkdownPreviewWorker()

    public func read(_ url: URL) throws -> MarkdownPreviewDocument {
        try Task.checkCancellation()
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MarkdownPreviewDocument.maximumFileBytes + 1) ?? Data()
        guard data.count <= MarkdownPreviewDocument.maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        try Task.checkCancellation()
        return MarkdownPreviewDocument(source: text)
    }

    public func themes() -> MarkdownPreviewThemes? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MarkdownPreviewThemes.groupIdentifier) else { return nil }
        let url = directory.appendingPathComponent(MarkdownPreviewThemes.filename)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(MarkdownPreviewThemes.self, from: data)
    }

    public func publish(_ themes: MarkdownPreviewThemes) throws {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MarkdownPreviewThemes.groupIdentifier) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(themes)
        guard data.count <= 16_384 else { return }
        try data.write(to: directory.appendingPathComponent(MarkdownPreviewThemes.filename), options: .atomic)
    }
}
