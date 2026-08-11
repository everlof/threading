import AppKit
import ImageIO

/// Who is reading a paste, which is what decides whether a dropped image is already in a form
/// they can use.
enum TerminalDropReader: Equatable {

    /// A shell, or anything else for which Threading has no measured image-rewrite contract.
    /// A path is the answer and the file is left exactly as it is: dropping a photo onto a
    /// half-typed `sips -s format png` must name *that* photo, not a copy Threading made.
    case shell

    /// An agent CLI, which lifts an image out of a pasted path when the extension is one it
    /// takes and otherwise leaves the path as text.
    case agent(AgentKind)

    /// Extensions this reader turns into an attached image, lowercased.
    ///
    /// Read out of each measured CLI rather than guessed: Claude Code matches
    /// `/\.(png|jpe?g|gif|webp)$/i` on the pasted string, Codex maps `png`, `jpg` and `jpeg` to
    /// its two encoded formats and refuses the rest. A shell has no such list — every path is
    /// equally readable to it — which is why `nil` is not "none".
    var attachableExtensions: Set<String>? {
        switch self {
        case .shell:
            return nil
        case .agent(.claude):
            return ["png", "jpg", "jpeg", "gif", "webp"]
        case .agent(.codex):
            return ["png", "jpg", "jpeg"]
        case .agent(.grok):
            // Grok's path-paste attachment contract has not been measured. Preserve the
            // user's original path instead of assuming that converting it to PNG adds support.
            return nil
        case .agent(.openCode):
            return ["png", "jpg", "jpeg", "gif", "webp"]
        }
    }
}

/// A dropped image the reader on the other end cannot open, made into one it can.
///
/// The drop itself already arrives as a paste, which is what makes an image an image rather
/// than a line of path — see `TerminalDrop`. This is the other half: the paste only works for
/// the handful of formats each CLI matches on, and a photo out of Finder is a HEIC, which is
/// on neither list. Before this, dropping one on Claude Code left the path sitting in the
/// prompt looking exactly like a drop that had worked.
///
/// **Converted, not preferred.** Only a format the reader refuses is rewritten. A PNG stays
/// the PNG the user dropped, at the path they dropped it from, because a copy would be a
/// second file to reason about for no gain — and a shell converts nothing at all.
enum TerminalDropImage {

    /// The paths to paste for `paths`: each one either as dropped, or the PNG written for it.
    static func readable(_ paths: [String], for reader: TerminalDropReader) -> [String] {
        guard let attachable = reader.attachableExtensions else { return paths }
        return paths.map { readable($0, attachableTo: attachable) }
    }

    // MARK: - Private Methods

    /// One path. Anything that is not a convertible image — a source file, an archive, a format
    /// macOS itself cannot read — comes back untouched, so the drop degrades to what it always
    /// was rather than to nothing.
    private static func readable(_ path: String, attachableTo attachable: Set<String>) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !attachable.contains(ext), convertible.contains(ext) else { return path }

        guard let converted = writePNG(from: path) else {
            ThreadingLogger.session.error(
                "Could not convert dropped image: \(path, privacy: .private(mask: .hash))"
            )
            return path
        }
        return converted
    }

    /// Formats macOS reads through ImageIO that at least one agent refuses.
    ///
    /// Deliberately a list rather than "whatever `NSImage` opens". A PDF and an SVG both load,
    /// and rasterising either would be the wrong answer — an agent reads an SVG as source and a
    /// PDF page by page, both better than a picture of one. An animated GIF converts to its
    /// first frame, which is what a still-image reader was going to see regardless.
    private static let convertible: Set<String> = [
        "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "avif", "jp2", "ico"
    ]

    /// Decoded and re-encoded on the calling thread, which is the main thread inside the drop.
    /// Input bytes and decoded dimensions are both bounded: compressed size alone does not stop
    /// a tiny image bomb expanding into an arbitrary bitmap. ImageIO makes a 4096px thumbnail
    /// directly, keeping ordinary camera images useful without allocating their full sensor size.
    /// Paying the bounded work inline preserves the order in which files were dropped.
    private static func writePNG(from path: String) -> String? {
        guard let data = try? BoundedFileReader.read(
            URL(fileURLWithPath: path),
            maximumBytes: TerminalDropImageDefaults.maximumSourceBytes
        ), let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize:
                        TerminalDropImageDefaults.maximumPixelDimension
                ] as CFDictionary
              ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }

        // Its own directory, so the file keeps the name it was dropped with. The agent quotes
        // that name back, and `photo.png` says which photo where a UUID says nothing.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(PromptViewDefaults.attachmentPrefix)\(UUID().uuidString)")
        let destination = directory
            .appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            .appendingPathExtension(PromptViewDefaults.attachmentExtension)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            ThreadingLogger.session.error(
                "Failed to write converted drop: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }
}

enum TerminalDropImageDefaults {
    static let maximumSourceBytes = 32 * 1_024 * 1_024
    static let maximumPixelDimension = 4_096
}
