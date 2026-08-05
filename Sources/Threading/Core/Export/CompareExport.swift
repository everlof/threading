import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Document

/// A comparison, frozen into everything needed to draw it somewhere Threading is not.
///
/// The Compare tab shows two files against each other and is the one surface in the app whose
/// content is *about* something outside the app — which is exactly what a reviewer, a designer
/// or a colleague wants sent to them. Sending the two files loses the comparison; sending a
/// screenshot loses the pixels. So the export is the comparison itself: one HTML document with
/// the same modes the tab has, and no dependency on anything the recipient must install.
///
/// A value, not a view: the tab builds it on the main actor and the packaging — base64 of up to
/// two 64 MB images, deflate, the whole diff — runs off it.
struct CompareExport: Sendable {

    /// One image side, with the bytes as they are on disk rather than a re-encode. The pixel
    /// size travels with them because the page lays both sides out at one shared scale, the
    /// same rule as `ImageCompareLayout`, and a browser cannot be asked for it before it paints.
    struct ImageSide: Sendable {
        let title: String
        /// The leaf name the file takes inside an archive.
        let fileName: String
        let data: Data
        let pixelSize: CGSize
        let mediaType: String
    }

    /// One text side, kept whole beside the diff so the recipient gets the sources too.
    struct TextSide: Sendable {
        let title: String
        let fileName: String
        let data: Data
    }

    enum Body: Sendable {
        /// Both sides drew as images. A nil side is a file that no longer exists.
        case images(old: ImageSide?, new: ImageSide?)
        /// Both sides were text; the diff is what `git diff --no-index` already produced.
        case text(files: [GitFileDiff], old: TextSide?, new: TextSide?)
    }

    let oldTitle: String
    let newTitle: String
    /// The mode the tab was left in — the exported page opens on it, so what was sent is what
    /// was being looked at.
    let mode: ImageCompareMode
    let body: Body
    let exportedAt: Date

    /// The name offered in the save panel, without an extension.
    ///
    /// Built from both sides because half a name answers the wrong question: `icon` in a
    /// downloads folder says nothing, while `icon-vs-icon@2x` still says it a week later.
    var suggestedFileName: String {
        let old = Self.stem(of: oldTitle)
        let new = Self.stem(of: newTitle)
        guard !old.isEmpty || !new.isEmpty else { return CompareExportDefaults.fallbackFileName }
        guard !old.isEmpty, !new.isEmpty, old != new else {
            return old.isEmpty ? new : old
        }
        return "\(old)-vs-\(new)"
    }

    /// A title's filename-safe stem: no extension, no separator, no run of spaces.
    private static func stem(of title: String) -> String {
        let withoutExtension = (title as NSString).deletingPathExtension
        let cleaned = withoutExtension.map { character -> Character in
            CompareExportDefaults.unsafeFileNameCharacters.contains(character) ? "-" : character
        }
        return String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(CompareExportDefaults.maximumStemLength)
            .description
    }
}

// MARK: - Defaults

enum CompareExportDefaults {
    /// What a comparison is called when neither side has a usable name.
    static let fallbackFileName = "comparison"

    /// Characters a filename should not carry across the platforms this file gets mailed to —
    /// the Windows reserved set plus the separators and whitespace, since the point of the name
    /// is that it survives being an email attachment.
    static let unsafeFileNameCharacters: Set<Character> = [
        "/", "\\", ":", "*", "?", "\"", "<", ">", "|", " ", "\t", "\n"
    ]

    static let maximumStemLength = 40

    /// Lines one file's diff writes into the page before it says how many it left out.
    ///
    /// An order of magnitude above the tab's own `DiffDefaults.displayCap`, and for the opposite
    /// reason: in the app a truncated diff is one click from the rest of it, while the recipient
    /// of an export has no such click — so the cap is about the size of the attachment, not
    /// about attention.
    static let maximumDiffLines = 5_000

    /// Where the two sides land inside an archive. Two folders rather than a prefix, so an
    /// expanded export reads as "here is the old one, here is the new one" in any file browser.
    static let oldDirectory = "old"
    static let newDirectory = "new"
    static let documentName = "index.html"

    /// The image types a browser can be relied on to draw. Anything else — TIFF, HEIC — is
    /// re-encoded to PNG before it is exported: a comparison that arrives as two broken image
    /// icons is worse than a slightly larger file.
    static let webSafeImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp"
    ]

    static let pngMediaType = "image/png"
}

// MARK: - Format

/// What the export is packaged as.
///
/// Both exist because they answer different questions. A single page is one file to drag into a
/// chat window and one double-click to read — the fastest possible share, at the cost of
/// base64's third again on every image byte. The archive keeps the images as files, so the
/// recipient also receives the originals, and it survives mail clients that strip `.html`
/// attachments outright.
enum CompareExportFormat: String, CaseIterable, Sendable {
    case singlePage
    case archive

    var fileExtension: String {
        switch self {
        case .singlePage: return "html"
        case .archive: return "zip"
        }
    }

    var contentType: UTType {
        switch self {
        case .singlePage: return .html
        case .archive: return .zip
        }
    }

    var title: String {
        switch self {
        case .singlePage: return L10n.string("Single Page (.html)")
        case .archive: return L10n.string("Folder in a Zip (.zip)")
        }
    }
}

// MARK: - Packaging

/// Turns a `CompareExport` into the bytes that get written to disk.
///
/// `nonisolated` throughout: the caller hands it a value and gets `Data` back, so the work can
/// happen off the main thread while the save panel's sheet is already gone.
enum CompareExportPackager {

    static func data(for export: CompareExport, format: CompareExportFormat) throws -> Data {
        switch format {
        case .singlePage:
            return CompareExportPage.document(for: export, assets: .inline)
        case .archive:
            return try ZipArchive.archive(entries(for: export), modified: export.exportedAt)
        }
    }

    /// The archive's contents: the document, then each side as the file it was.
    static func entries(for export: CompareExport) -> [ZipArchive.Entry] {
        var entries = [
            ZipArchive.Entry(
                path: CompareExportDefaults.documentName,
                data: CompareExportPage.document(for: export, assets: .files)
            )
        ]
        switch export.body {
        case .images(let old, let new):
            if let old {
                entries.append(.init(path: path(for: old.fileName, isOld: true), data: old.data))
            }
            if let new {
                entries.append(.init(path: path(for: new.fileName, isOld: false), data: new.data))
            }
        case .text(_, let old, let new):
            if let old {
                entries.append(.init(path: path(for: old.fileName, isOld: true), data: old.data))
            }
            if let new {
                entries.append(.init(path: path(for: new.fileName, isOld: false), data: new.data))
            }
        }
        return entries
    }

    /// Where one side sits inside the archive, which is also the `src` the document uses for it.
    static func path(for fileName: String, isOld: Bool) -> String {
        let directory = isOld
            ? CompareExportDefaults.oldDirectory
            : CompareExportDefaults.newDirectory
        return "\(directory)/\(fileName)"
    }
}

// MARK: - Image Types

/// What an image's bytes actually are, decided from their magic number.
///
/// The extension is not asked, for the same reason `CompareFileClassifier` does not ask it: the
/// pair being compared is frequently a screenshot named whatever the tool that wrote it chose.
enum CompareExportImageType {

    private static let signatures: [(prefix: [UInt8], mediaType: String)] = [
        ([0x89, 0x50, 0x4E, 0x47], "image/png"),
        ([0xFF, 0xD8, 0xFF], "image/jpeg"),
        ([0x47, 0x49, 0x46, 0x38], "image/gif"),
        ([0x49, 0x49, 0x2A, 0x00], "image/tiff"),
        ([0x4D, 0x4D, 0x00, 0x2A], "image/tiff"),
        ([0x42, 0x4D], "image/bmp")
    ]

    /// The media type, or nil when nothing here recognises the bytes.
    static func mediaType(of data: Data) -> String? {
        for signature in signatures where data.starts(with: signature.prefix) {
            return signature.mediaType
        }
        // RIFF containers name their form four bytes in: `RIFF····WEBP`.
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]), data.count >= 12,
           Array(data[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        // ISO base media: `····ftypheic`, and its siblings.
        if data.count >= 12, Array(data[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            return "image/heic"
        }
        return nil
    }

    /// Whether a browser can be relied on to draw these bytes as they are.
    static func isWebSafe(_ mediaType: String?) -> Bool {
        guard let mediaType else { return false }
        return CompareExportDefaults.webSafeImageTypes.contains(mediaType)
    }

    /// The image's pixel grid, read from the file's own header rather than decoded.
    ///
    /// Pixels, not points: a 2× screenshot reports half its pixels as its size, and a comparison
    /// of pixels should say what the pixels say — the same rule as `ImageCompareView.pixelSize`,
    /// stated here because packaging runs where there is no `NSImage`.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The bytes to export for one side, and what they are.
    ///
    /// A TIFF or a HEIC pair is a perfectly good comparison in the app and two broken image icons
    /// in most browsers, which would make the export worse than useless — it would look like the
    /// files were empty. Those are re-encoded to PNG here; everything a browser draws is passed
    /// through untouched, so the recipient of a PNG pair receives the actual files.
    static func webReadable(_ data: Data, fileName: String) -> (
        data: Data, mediaType: String, fileName: String
    )? {
        let sniffed = mediaType(of: data)
        if isWebSafe(sniffed), let sniffed {
            return (data, sniffed, fileName)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let renamed = (fileName as NSString).deletingPathExtension + ".png"
        return (encoded as Data, CompareExportDefaults.pngMediaType, renamed)
    }
}
