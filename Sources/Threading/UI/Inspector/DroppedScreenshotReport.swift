import AppKit
import UniformTypeIdentifiers

/// A picture taken *outside* Threading, filed as a report.
///
/// # Why this exists
///
/// The inspector captures the window itself, which is the right evidence for almost everything and
/// the wrong evidence for a **hover**: the capture is taken from a menu the pointer had to travel
/// to, and by then the row has un-highlighted, the tooltip has gone, and the state being reported
/// is the one thing not in the picture. macOS's own ⌘⇧4 has no such problem, because the pointer
/// never leaves the state it is photographing.
///
/// So the report sheet accepts a file. What it loses is the geometry the inspector knows by
/// construction — which view, which frame, which point was marked — and what it keeps is the two
/// things that made the sheet worth opening: the picture, and the marks a person puts on it.
enum DroppedScreenshotReport {

    /// Whether a dropped file is something this sheet can be opened with.
    ///
    /// By declared type rather than by extension, so a screenshot saved as HEIC or renamed by
    /// hand is answered by what it *is*. A directory is not an image and is deliberately still
    /// the app icon's other meaning: folders dropped there become projects.
    static func isReportable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]),
              values.isDirectory != true,
              let type = values.contentType else { return false }
        return type.conforms(to: .image)
    }

    /// What the report says about a picture nobody here took.
    ///
    /// The pixel dimensions come from the representation rather than from `NSImage.size`, which
    /// is in points: a Retina screenshot is half its own resolution when asked politely, and half
    /// is exactly the confusion this line exists to remove — an agent measuring the PNG counts
    /// the other number.
    ///
    /// The path carries the marker `publicDetails` strips, because a file on this machine means
    /// nothing to an intake service and everything to an agent standing next to it.
    static func markdown(for url: URL, image: NSImage) -> String {
        var lines = ["## Screenshot report"]
        if let pixels = pixelSize(of: image) {
            lines.append("- Image: \(Int(pixels.width))×\(Int(pixels.height)) pixels")
        }
        lines.append("- Dropped screenshot, taken outside Threading: \(url.path)")
        return lines.joined(separator: "\n")
    }

    static func pixelSize(of image: NSImage) -> NSSize? {
        let widest = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        guard let widest, widest.pixelsWide > 0, widest.pixelsHigh > 0 else { return nil }
        return NSSize(width: widest.pixelsWide, height: widest.pixelsHigh)
    }

    /// The two ways one arrives, named so the journal can tell them apart.
    enum Source: String {
        case appIcon
        case titlebar
    }
}
