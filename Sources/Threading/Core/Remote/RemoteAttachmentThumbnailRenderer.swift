import AppKit
import PDFKit
import ThreadingRemoteKit

/// The raster a paired phone's gallery ledger shows for one attachment.
///
/// Bounded twice. The decode runs under `BoundedImageDecodePolicy.thumbnail`, which refuses a
/// source past the app's pixel and byte limits before a frame exists, and renders at most
/// `RemoteAttachmentThumbnail.maximumPixelDimension` on a side whatever the file holds — so the
/// route can never be asked to do the full attachment route's work. A PDF is its first page at
/// the same bound. Anything else has no raster here: the phone draws the kind's glyph instead.
enum RemoteAttachmentThumbnailRenderer {
    /// Thumbnails are looked at, not kept; a lower JPEG quality keeps a ledger of them cheap to
    /// send over a phone's link.
    static let jpegQuality: CGFloat = 0.78

    static var policy: BoundedImageDecodePolicy {
        .thumbnail(maximumPixelDimension: RemoteAttachmentThumbnail.maximumPixelDimension)
    }

    static func jpeg(at url: URL) -> Data? {
        guard let frame = thumbnailFrame(at: url) else { return nil }
        return NSBitmapImageRep(cgImage: frame).representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        )
    }

    static func thumbnailFrame(at url: URL) -> CGImage? {
        if url.pathExtension.lowercased() == "pdf" {
            return firstPage(ofPDFAt: url)
        }
        return BoundedImageDecoder.thumbnailFrame(at: url, policy: policy)
    }

    private static func firstPage(ofPDFAt url: URL) -> CGImage? {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: policy.maximumBytes),
              let document = PDFDocument(data: data),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return nil }
        let scale = min(1, CGFloat(policy.maximumRenderedPixelDimension) / longest)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
