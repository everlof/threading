import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Project Icon Store

/// Owns the image files behind `ProjectIcon` records, under Application Support.
///
/// Every icon is normalised on the way in — decoded with ImageIO, reduced to the largest
/// frame (`.ico` files carry several), capped at `storedPixelSize`, re-encoded as PNG — so
/// the sidebar never holds a 1024px app icon in memory per row, and whatever arrives
/// (favicon, avatar, screenshot crop) is stored in exactly one shape.
enum ProjectIconStore {

    // MARK: - Properties

    /// In-memory cache of decoded icons, keyed by file name. Emptied for a file when it is
    /// rewritten, so a replaced icon never shows its predecessor.
    private static let cache = NSCache<NSString, NSImage>()

    private static var directory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(ProjectIconDefaults.iconDirectoryName)
    }

    // MARK: - Public Methods

    /// Whether ImageIO can decode this data into something at least icon-sized.
    static func isUsableImage(_ data: Data) -> Bool {
        guard data.count <= ProjectIconDefaults.maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return largestFrame(of: source).width >= ProjectIconDefaults.minimumPixelSize
    }

    /// Normalises and writes an icon for a project, returning the stored file name.
    ///
    /// The file is named after the project, so replacing a project's icon overwrites in
    /// place rather than accumulating orphans.
    static func store(imageData: Data, for projectID: ProjectID) -> String? {
        guard let png = normalizedPNGData(from: imageData) else { return nil }

        let fileName = projectID.uuidString + "." + ProjectIconDefaults.storedExtension
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            ThreadingLogger.agent.error("Failed to store project icon: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        cache.removeObject(forKey: fileName as NSString)
        invalidateDerived(fileName: fileName)
        return fileName
    }

    /// The decoded icon, cached across the sidebar's frequent row reconfigures.
    static func image(for icon: ProjectIcon) -> NSImage? {
        if let cached = cache.object(forKey: icon.fileName as NSString) {
            return cached
        }

        guard let image = NSImage(contentsOf: directory.appendingPathComponent(icon.fileName)),
              image.isValid else { return nil }

        cache.setObject(image, forKey: icon.fileName as NSString)
        return image
    }

    /// The stored PNG bytes as written, for handing the icon to a system service that draws
    /// it itself — the notification avatar — rather than drawing it ourselves.
    static func pngData(for icon: ProjectIcon) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(icon.fileName))
    }

    static func remove(fileName: String) {
        invalidateDerived(fileName: fileName)
        cache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    // MARK: - Display Composition

    /// The icon as the sidebar draws it: clipped to a continuous-feeling rounded rect, and —
    /// when its own tone would vanish against the current appearance — set on a small
    /// opposing backplate. A dark mark on the dark sidebar gets a light plate; a light mark
    /// on the light sidebar gets a dark one. Cached per file and appearance.
    static func displayImage(for icon: ProjectIcon, darkAppearance: Bool) -> NSImage? {
        let key = displayKey(icon.fileName, darkAppearance: darkAppearance)
        if let cached = displayCache.object(forKey: key) {
            return cached
        }

        guard let base = image(for: icon) else { return nil }

        let plated = needsBackplate(
            luminance: luminance(for: icon),
            darkAppearance: darkAppearance
        )
        let composed = compose(base, plated: plated, darkAppearance: darkAppearance)
        displayCache.setObject(composed, forKey: key)
        return composed
    }

    /// Whether a mark of this tone disappears against the appearance's sidebar.
    ///
    /// The rule itself lives in `IconBackplate`, which states it as a separation from the
    /// ground the mark is actually drawn on. A project tile's ground is always the sidebar's
    /// surface, so the appearance is a fair proxy for it here — and stating it as one keeps a
    /// single decision for every plated mark in the app, including the ones whose ground moves
    /// under them, like a session row's when it is selected.
    static func needsBackplate(luminance: CGFloat?, darkAppearance: Bool) -> Bool {
        IconBackplate.isNeeded(
            markTone: luminance,
            groundTone: darkAppearance
                ? IconBackplate.Defaults.darkAppearanceGroundTone
                : IconBackplate.Defaults.lightAppearanceGroundTone
        )
    }

    /// The icon's alpha-weighted mean luminance over its visible pixels, 0 (black) to 1
    /// (white). Transparent regions carry no weight, so a small dark glyph on a clear
    /// background reads as dark, not as mostly-nothing.
    static func luminance(for icon: ProjectIcon) -> CGFloat? {
        if let cached = luminanceByFile[icon.fileName] {
            return cached
        }

        guard let image = image(for: icon),
              let luminance = meanVisibleLuminance(of: image) else { return nil }

        luminanceByFile[icon.fileName] = luminance
        return luminance
    }

    private static let displayCache = NSCache<NSString, NSImage>()
    private static var luminanceByFile: [String: CGFloat] = [:]

    private static func displayKey(_ fileName: String, darkAppearance: Bool) -> NSString {
        (fileName + (darkAppearance ? "|dark" : "|light")) as NSString
    }

    /// Drops everything derived from a file's pixels, for when the file is rewritten.
    private static func invalidateDerived(fileName: String) {
        displayCache.removeObject(forKey: displayKey(fileName, darkAppearance: true))
        displayCache.removeObject(forKey: displayKey(fileName, darkAppearance: false))
        luminanceByFile.removeValue(forKey: fileName)
    }

    /// Draws the composite at the sidebar's display size. The drawing-handler image
    /// re-renders per backing scale, so the rounded clip stays crisp on Retina.
    ///
    /// **The clip rounds a tile and nothing else.** A mark that arrives on transparency has
    /// no corners to round, so clipping it can only take ink: `sonda`'s wordmark runs the
    /// full width of its canvas along the bottom, and the corner arcs bit the outer edge off
    /// the `s` and the `a` — about 0.8pt each at the slot's 16pt, which on a 2pt-wide letter
    /// is most of a stem. A plate keeps its own rounded shape either way; only what the ink
    /// is clipped to depends on `fillsItsBounds`, measured once here rather than inside the
    /// handler, which runs again per backing scale.
    private static func compose(_ base: NSImage, plated: Bool, darkAppearance: Bool) -> NSImage {
        let side = ProjectIconDefaults.displayPointSize
        let isTile = fillsItsBounds(base)
        return NSImage(
            size: NSSize(width: side, height: side),
            flipped: false
        ) { bounds in
            let clip = NSBezierPath(
                roundedRect: bounds,
                xRadius: ProjectIconDefaults.displayCornerRadius,
                yRadius: ProjectIconDefaults.displayCornerRadius
            )

            if plated {
                let plate = darkAppearance
                    ? ProjectIconDefaults.lightPlateColor
                    : ProjectIconDefaults.darkPlateColor
                plate.setFill()
                clip.fill()
            }

            if isTile { clip.addClip() }

            let content = plated
                ? bounds.insetBy(
                    dx: ProjectIconDefaults.plateInset,
                    dy: ProjectIconDefaults.plateInset
                )
                : bounds
            base.draw(
                in: aspectFitRect(for: base.size, in: content),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    /// Centres an image in bounds at its own aspect ratio — a wordmark must not be
    /// stretched square.
    private static func aspectFitRect(for size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }

        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Whether the artwork is a **tile** — opaque out to its own edges, the way an app icon
    /// or an avatar is — rather than a loose mark standing on transparency.
    ///
    /// This is the question the rounded clip actually asks. A tile has square corners that
    /// want rounding into the app's shape language; a loose mark has nothing there to round,
    /// and letting the clip run over it merely trims whatever ink reaches the corners.
    ///
    /// Measured as the mean alpha around the border of a small render, so an antialiased or
    /// slightly soft edge still counts as a tile, while a wordmark on a clear background —
    /// three of its four edges empty — cannot. An undecodable image reports `false`: a mark
    /// we cannot measure is one we decline to cut.
    static func fillsItsBounds(_ image: NSImage) -> Bool {
        let side = ProjectIconDefaults.luminanceSampleSize
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let alphaChannel = 3
        var alphaSum = 0.0

        for step in 0..<side {
            let border = [
                step,                             // bottom row
                (side - 1) * side + step,         // top row
                step * side,                      // leading column
                step * side + side - 1            // trailing column
            ]
            for pixel in border {
                alphaSum += Double(pixels[pixel * 4 + alphaChannel])
            }
        }

        let samples = Double(side * 4)
        return CGFloat(alphaSum / samples / 255) >= ProjectIconDefaults.tileEdgeOpacity
    }

    /// The measurement lives with the rule that consumes it, in `IconBackplate`.
    private static func meanVisibleLuminance(of image: NSImage) -> CGFloat? {
        IconBackplate.tone(of: image)
    }

    // MARK: - Private Methods

    /// The index and pixel width of the source's largest frame.
    private static func largestFrame(of source: CGImageSource) -> (index: Int, width: Int) {
        var best = (index: 0, width: 0)

        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > best.width {
                best = (index, width)
            }
        }

        return best
    }

    /// A base image composed exactly as the sidebar displays icons — rounded, unplated.
    /// Shared with account avatars, which follow the same shape language.
    static func roundedDisplay(_ base: NSImage) -> NSImage {
        compose(base, plated: false, darkAppearance: false)
    }

    /// Decodes any supported format and re-encodes the largest frame as a small PNG.
    /// ImageIO caps at `maxPixelSize` without upscaling anything smaller. Internal so
    /// `AccountAvatarStore` normalises what it fetches by the same rules.
    ///
    /// `maxPixelSize` is a parameter rather than the constant it used to be because the app
    /// icon's contributed mark goes through this same gate at a far larger size — the value is
    /// the only thing that differs, and a second copy of the ImageIO pipeline is how one of the
    /// two ends up not rejecting an HTML error page served with a 200.
    static func normalizedPNGData(
        from data: Data,
        maxPixelSize: Int = ProjectIconDefaults.storedPixelSize
    ) -> Data? {
        guard data.count <= ProjectIconDefaults.maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            largestFrame(of: source).index,
            options as CFDictionary
        ) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }
}

// MARK: - Project Icon Defaults

enum ProjectIconDefaults {
    /// Matches `StateManager`'s directory, which owns the app's Application Support root.
    static let applicationDirectoryName = "Threading"
    static let iconDirectoryName = "ProjectIcons"
    static let storedExtension = "png"

    /// Stored at 4× the sidebar's 16pt slot, so Retina rendering never upsamples.
    static let storedPixelSize = 64

    /// Anything smaller than this cannot survive being drawn at 16pt.
    static let minimumPixelSize = 16

    // MARK: Display

    /// Matches the sidebar's icon slot.
    static let displayPointSize: CGFloat = 16
    static let displayCornerRadius: CGFloat = 4
    static let plateInset: CGFloat = 2
    static let luminanceSampleSize = 32

    /// How opaque an icon's border must read before the rounded clip is allowed to run over
    /// it — see `ProjectIconStore.fillsItsBounds`. High enough that a mark with any real
    /// clear margin is left alone, low enough that a tile with a soft or antialiased edge is
    /// still rounded.
    static let tileEdgeOpacity: CGFloat = 0.9

    /// Tones beyond these vanish against the matching appearance's sidebar and earn a plate.
    static let darkAppearanceLuminanceFloor: CGFloat = 0.4
    static let lightAppearanceLuminanceCeiling: CGFloat = 0.75

    /// Fixed neutrals, deliberately outside the system palette: a plate exists to *oppose*
    /// the appearance, and every system colour follows it.
    static let lightPlateColor = NSColor(white: 0.93, alpha: 0.96)
    static let darkPlateColor = NSColor(white: 0.16, alpha: 0.92)

    /// Ceiling on a candidate image read into memory, local or fetched.
    static let maximumSourceBytes = 5 * 1024 * 1024

    // MARK: Discovery

    /// Icon file names worth probing, in preference order — a touch icon is the highest
    /// resolution mark a web project publishes.
    static let candidateFileNames = [
        "apple-touch-icon.png",
        "apple-touch-icon-precomposed.png",
        "favicon.png",
        "favicon.ico",
        "icon.png",
        "logo.png"
    ]

    /// Directories conventionally owned by the project itself, probed beside its root.
    static let candidateSubdirectories = ["public", "static", "assets", "web", "www", "site", "docs"]

    /// Dependency and build-output directories whose assets belong to someone else's
    /// project — the reason a bare recursive scan would be wrong.
    static let excludedDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", "dist", "build", "out",
        "target", "third_party", "external", "deps", "DerivedData", "venv"
    ]

    /// An Xcode project's own icon lives here; the largest rendition wins.
    static let appIconSetName = "AppIcon.appiconset"

    static let maximumScanDepth = 4
    static let maximumScannedEntries = 4000

    /// Where a repository's GitHub owner publishes an avatar. Square, any size via `size`.
    static func gitHubAvatarURL(owner: String) -> URL? {
        URL(string: "https://github.com/\(owner).png?size=\(avatarPixelSize)")
    }

    /// The API record saying whether an owner is a person or an organisation.
    static func gitHubAccountURL(owner: String) -> URL? {
        URL(string: "https://api.github.com/users/\(owner)")
    }

    static let gitHubAccountTypeKey = "type"
    static let gitHubOrganizationType = "Organization"

    static let avatarPixelSize = 128
    static let gitHubHost = "github.com"

    /// Paths probed under a declared homepage, same preference order as local files.
    static let homepageProbes = ["apple-touch-icon.png", "favicon.png", "favicon.ico"]

    static let packageManifestName = "package.json"
    static let homepageKey = "homepage"

    static let requestTimeout: TimeInterval = 10
}
