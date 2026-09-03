import CoreGraphics
import Foundation
import ImageIO

/// The pictures a render actually produced.
///
/// `ProjectStore.render` in the companion exports into `<package>/Exports`, and the Marketeer CLI
/// names each file `Screenshot_<slot>_<size>in.png` — with a locale subfolder when the render was
/// asked for locales. So a slide can be matched to its own exported picture by slot, which is what
/// turns the pane from a drawing of the document into the artwork itself.
///
/// Nothing here is required for the pane to work. A project that has never been rendered has no
/// `Exports` folder, and every row falls back to the miniature drawn from the document.
public enum MarketeerExports {

    /// Directory entries this will look at, ever.
    ///
    /// `Exports` is a folder on disk, so its size is not ours to assume — a stale render of many
    /// locales and sizes is ordinary, and a folder someone else wrote into is possible. The cap
    /// bounds the *scan*, not the result: without it, a cheap "find sixty pictures" walks whatever
    /// is there first.
    public static let inspectedEntryCap = 512

    /// Locale subfolders mean the pictures are one level down. Two levels is enough for every
    /// shape the companion asks for and stops a symlink turning this into a filesystem walk.
    public static let maximumDepth = 2

    public static func directory(forProjectID projectID: String, root: URL? = nil) -> URL {
        MarketeerProjectLocator.packageDirectory(forProjectID: projectID, root: root)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    /// The slot number a file name carries, or `nil` when it is not one of ours.
    ///
    /// `Screenshot_01_6.9in.png` is slot 1, which is slide `slotPosition` 0. The CLI writes the
    /// slot one-based because that is what the App Store calls it.
    public static func slot(inFileNamed name: String) -> Int? {
        guard name.lowercased().hasSuffix(".png") else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "_")
        guard parts.count >= 2, parts[0].lowercased() == "screenshot" else { return nil }
        return Int(parts[1])
    }

    /// Exported pictures by slide `slotPosition`.
    ///
    /// When a render covered several locales or sizes, one slot has several files and the first in
    /// sorted order wins. That is a deliberate simplification rather than an oversight: the pane
    /// shows one row per slide, so it needs one picture per slide, and "the first locale
    /// alphabetically" is at least stable between reads. Choosing per locale is a later slice and
    /// wants a locale control to go with it.
    public static func index(forProjectID projectID: String, root: URL? = nil) -> [Int: URL] {
        let base = directory(forProjectID: projectID, root: root)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }

        var found: [Int: [URL]] = [:]
        var inspected = 0
        while inspected < inspectedEntryCap, let entry = enumerator.nextObject() as? URL {
            inspected += 1
            if enumerator.level > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let slot = slot(inFileNamed: entry.lastPathComponent) else { continue }
            found[slot - 1, default: []].append(entry)
        }
        return found.compactMapValues { $0.sorted { $0.path < $1.path }.first }
    }

    // MARK: - Thumbnails

    /// The longest edge a row thumbnail is decoded at.
    ///
    /// An App Store screenshot is 1290×2796, and sixty of them decoded at full size to fill a
    /// 110-point row would be hundreds of megabytes for pictures nobody can see the detail of.
    /// ImageIO downsamples while decoding, so the large pixels are never materialized at all.
    public static let thumbnailMaximumPixelSize = 320

    /// Decode one export, downsampled. Off the main actor by construction: this is file reading
    /// and image decoding, which the Scaling Gate keeps off the main thread unless it is bounded
    /// and frame-cheap, and a full-size PNG decode is neither.
    public static func thumbnail(at url: URL, maximumPixelSize: Int = thumbnailMaximumPixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
