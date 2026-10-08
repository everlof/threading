import Foundation
import CryptoKit

enum MermaidPreviewLimits {
    static let maximumSourceBytes = 512 * 1024
    static let maximumRenderBytes = 64 * 1024
    static let maximumRenderLines = 1_000
    static let maximumEdges = 500
    static let renderTimeoutSeconds: UInt64 = 10
}

/// Selection submits one bounded read; file IO and UTF-8 validation never run in a frame.
actor MermaidPreviewLoader {
    static let shared = MermaidPreviewLoader()

    struct Document: Sendable {
        let source: String
        let canRender: Bool
        let fingerprint: [UInt8]
    }

    func document(at url: URL) throws -> Document {
        try Task.checkCancellation()
        let data = try BoundedFileReader.read(url, maximumBytes: MermaidPreviewLimits.maximumSourceBytes)
        guard let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        try Task.checkCancellation()
        return Document(source: source, canRender: Self.canRender(source), fingerprint: Array(SHA256.hash(data: data)))
    }

    nonisolated static func canRender(_ source: String) -> Bool {
        guard source.utf8.count <= MermaidPreviewLimits.maximumRenderBytes else { return false }
        return source.lazy.filter { $0 == "\n" }.prefix(MermaidPreviewLimits.maximumRenderLines).count
            < MermaidPreviewLimits.maximumRenderLines
    }
}
