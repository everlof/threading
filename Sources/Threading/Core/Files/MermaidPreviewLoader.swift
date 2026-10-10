import Foundation
import CryptoKit

enum MermaidPreviewLimits {
    /// The pane's one source-preview cap, shared with the DOT/GV text path.
    static let maximumSourceBytes = SessionAttachmentDefaults.maximumSourcePreviewBytes
    static let maximumRenderBytes = 64 * 1024
    static let maximumRenderLines = 1_000
    static let maximumEdges = 500
    static let renderTimeoutSeconds: UInt64 = 10
    /// A theme face is handed to the canvas only under the cap a theme may store one at.
    static let maximumFontBytes = ThemeFontStore.maximumFontBytes
    /// Transient renderer failures (timeout, content-process exit, failed navigation) an unchanged
    /// file may retry on an attachment-list refresh before it stays on source.
    static let maximumRendererRetries = 2
}

/// Bounded reads for the Mermaid reader. Every call runs on its own worker, so one file stuck on a
/// stalled mount holds only its own preview; file IO and decoding never run in a frame.
enum MermaidPreviewLoader {
    struct Document: Sendable {
        enum Admission: Sendable, Equatable {
            case render
            case tooLarge
            /// Neither UTF-8 nor BOM-marked UTF-16. The source is shown decoded leniently, the
            /// way the DOT/GV path shows it, and is never handed to the renderer.
            case notText
        }

        let source: String
        let admission: Admission
        let fingerprint: [UInt8]
    }

    private static let workers = DispatchQueue(
        label: "com.threading.mermaid-preview-loader",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func document(at url: URL) async throws -> Document {
        try await onWorker { try readDocument(at: url) }
    }

    /// A process-registered theme face as base64, so the canvas can add it as a `FontFace`.
    static func fontData(at url: URL) async throws -> String {
        try await onWorker {
            try BoundedFileReader.read(url, maximumBytes: MermaidPreviewLimits.maximumFontBytes)
                .base64EncodedString()
        }
    }

    static func readDocument(at url: URL) throws -> Document {
        let data = try BoundedFileReader.read(url, maximumBytes: MermaidPreviewLimits.maximumSourceBytes)
        let fingerprint = Array(SHA256.hash(data: data))
        guard let source = decodedText(data) else {
            return Document(source: String(decoding: data, as: UTF8.self), admission: .notText,
                            fingerprint: fingerprint)
        }
        return Document(source: source, admission: canRender(source) ? .render : .tooLarge,
                        fingerprint: fingerprint)
    }

    /// UTF-8 (with or without a BOM), or UTF-16 that says which it is. Anything else is not text
    /// this reader can vouch for.
    static func decodedText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    static func canRender(_ source: String) -> Bool {
        let bytes = source.utf8
        guard bytes.count <= MermaidPreviewLimits.maximumRenderBytes else { return false }
        return lineCount(of: bytes) <= MermaidPreviewLimits.maximumRenderLines
    }

    /// Lines as an editor counts them: LF, CRLF and a lone CR each end one, and a last line without
    /// a terminator still counts. Counted in bytes, because `"\r\n"` is one `Character` that is
    /// not equal to `"\n"`, and a CRLF file counted by `Character` had no lines at all.
    static func lineCount(of bytes: String.UTF8View) -> Int {
        var lines = 0
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 0x0D || (byte == 0x0A && previous != 0x0D) { lines += 1 }
            previous = byte
        }
        if let last = bytes.last, last != 0x0A, last != 0x0D { lines += 1 }
        return lines
    }

    private static func onWorker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            workers.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
