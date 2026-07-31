import AppKit

// MARK: - Theme Asset Store

/// Owns the image files a custom theme's sidebar references, under Application Support.
///
/// A theme document lives in `PreferenceStore` as JSON and stays hand-writable; bytes would
/// end both. So the document names an asset and this store owns the file — the same split
/// `ProjectIcon` records already use, and the normalisation gate is *literally* the same:
/// `ProjectIconStore.normalizedPNGData`, because a second copy of the ImageIO pipeline is how
/// one of the two stops rejecting an HTML error page served with a 200.
///
/// Files live one folder per theme, named by `SidebarAssetSlot`, so replacing an asset
/// overwrites in place and deleting a theme is `removeAll(for:)` — no orphan sweep.
/// Contributed (extension) themes never touch this store; their bytes come from the package
/// via `ExtensionAppearanceRegistry`, read at inspection time.
@MainActor
enum ThemeAssetStore {

    // MARK: - Properties

    /// Decoded images keyed by theme, slot and variant. Emptied for a file when it is
    /// rewritten, so a replaced background never shows its predecessor.
    private static let cache = NSCache<NSString, NSImage>()

    private static var directory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(ThemeAssetDefaults.assetDirectoryName)
    }

    private static func folder(for themeID: AppThemeID) -> URL {
        directory.appendingPathComponent(themeID.rawValue, isDirectory: true)
    }

    // MARK: - Public Methods

    /// Normalises and writes one slot's image, returning the asset name the theme document
    /// should reference, or nil when the bytes are not a usable image.
    static func store(
        imageData: Data,
        for themeID: AppThemeID,
        slot: SidebarAssetSlot,
        variant: AppTheme.VariantKind
    ) -> String? {
        guard imageData.count <= SidebarStyleLimits.maximumImageBytes,
              let png = ProjectIconStore.normalizedPNGData(
                  from: imageData,
                  maxPixelSize: ThemeAssetDefaults.storedPixelSize(for: slot)
              ) else { return nil }

        let fileName = slot.fileName(for: variant)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: folder(for: themeID),
                withIntermediateDirectories: true
            )
            try png.write(
                to: folder(for: themeID).appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            ThreadingLogger.agent.error(
                "Failed to store theme asset: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        cache.removeObject(forKey: cacheKey(themeID, fileName))
        return fileName
    }

    /// The decoded asset, cached across the sidebar's redraws. Nil for a name that resolves
    /// to nothing — which callers treat as "never stated", never as an error.
    static func image(named assetName: String, for themeID: AppThemeID) -> NSImage? {
        let key = cacheKey(themeID, assetName)
        if let cached = cache.object(forKey: key) { return cached }

        let url = folder(for: themeID).appendingPathComponent(assetName)
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    /// The stored bytes as written, for the update path's backup-and-restore: a slot's file
    /// is overwritten in place, and an update that then fails must put the old image back or
    /// the standing document shows the new one.
    static func pngData(named assetName: String, for themeID: AppThemeID) -> Data? {
        try? Data(contentsOf: folder(for: themeID).appendingPathComponent(assetName))
    }

    /// Writes bytes back exactly as they were, bypassing normalisation — they came out of
    /// this store, so they already passed it.
    static func restore(pngData: Data, named assetName: String, for themeID: AppThemeID) {
        cache.removeObject(forKey: cacheKey(themeID, assetName))
        try? pngData.write(
            to: folder(for: themeID).appendingPathComponent(assetName),
            options: .atomic
        )
    }

    static func remove(assetName: String, for themeID: AppThemeID) {
        cache.removeObject(forKey: cacheKey(themeID, assetName))
        try? FileManager.default.removeItem(
            at: folder(for: themeID).appendingPathComponent(assetName)
        )
    }

    /// Deleting a theme deletes its folder; called from the library's delete path so assets
    /// cannot outlive the document that referenced them.
    static func removeAll(for themeID: AppThemeID) {
        for slot in SidebarAssetSlot.allCases {
            for kind in AppTheme.VariantKind.allCases {
                cache.removeObject(forKey: cacheKey(themeID, slot.fileName(for: kind)))
            }
        }
        try? FileManager.default.removeItem(at: folder(for: themeID))
    }

    /// Duplicating a theme copies its assets, so the copy's sidebar survives the original's
    /// deletion.
    static func copyAssets(from sourceID: AppThemeID, to targetID: AppThemeID) {
        let fileManager = FileManager.default
        let source = folder(for: sourceID)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let target = folder(for: targetID)
        try? fileManager.removeItem(at: target)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.copyItem(at: source, to: target)
    }

    // MARK: - Private Methods

    private static func cacheKey(_ themeID: AppThemeID, _ fileName: String) -> NSString {
        "\(themeID.rawValue)/\(fileName)" as NSString
    }
}

// MARK: - Theme Asset Defaults

enum ThemeAssetDefaults {
    static let assetDirectoryName = "ThemeAssets"

    /// A background is stored at 2× the sidebar's widest column; a logo at 4× its slot —
    /// enough that Retina rendering never upsamples, small enough that a theme cannot smuggle
    /// a wallpaper library into Application Support.
    static func storedPixelSize(for slot: SidebarAssetSlot) -> Int {
        switch slot {
        case .background: return 1024
        case .logo: return 128
        }
    }
}
