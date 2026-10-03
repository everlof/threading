import OSLog
import QuickLookUI
import ThreadingMarkdownKit
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let logger = Logger(subsystem: "codes.threading.markdown-preview", category: "preview")

    /// Implement the actual Objective-C protocol entry point. Its async importer convenience
    /// is not an optional protocol implementation that Quick Look can discover at runtime.
    func providePreview(for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        let completion = PreviewCompletion(handler: handler)
        Task { @MainActor in
            do {
                let document = try await MarkdownPreviewWorker.shared.read(url)
                let themes = await MarkdownPreviewWorker.shared.themes()
                try Task.checkCancellation()
                let excerptMessage = NSLocalizedString("This is a preview of the beginning of this document. Open it in Threading to read the complete source.", comment: "Large Markdown Quick Look preview")
                let html = MarkdownPreviewHTML.render(document, themes: themes, title: url.lastPathComponent, excerptMessage: excerptMessage)
                let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 700)) { reply in
                    reply.stringEncoding = .utf8
                    return Data(html.utf8)
                }
                Self.logger.debug("Prepared Markdown Quick Look with \(document.blocks.count) blocks")
                completion.handler(reply, nil)
            } catch {
                Self.logger.error("Markdown Quick Look preparation failed: \(error.localizedDescription, privacy: .private)")
                completion.handler(nil, error)
            }
        }
    }
}

/// Quick Look's Objective-C callback predates Sendable. Ownership transfers to one task,
/// which calls it exactly once after success or failure; the provider never accesses it again.
private struct PreviewCompletion: @unchecked Sendable {
    let handler: (QLPreviewReply?, Error?) -> Void
}
