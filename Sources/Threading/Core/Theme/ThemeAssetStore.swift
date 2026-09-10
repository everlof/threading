import AppKit

// MARK: - Theme Asset Store

/// Owns the image files a custom theme references — its sidebar's logo and background, and its
/// material's backdrop — under Application Support.
///
/// A theme document lives in `PreferenceStore` as JSON and stays hand-writable; bytes would
/// end both. So the document names an asset and this store owns the file — the same split
/// `ProjectIcon` records already use, and the normalisation gate is *literally* the same:
/// `ProjectIconStore.normalizedPNGData`, because a second copy of the ImageIO pipeline is how
/// one of the two stops rejecting an HTML error page served with a 200.
///
/// Files live one folder per theme, named by `ThemeAssetSlot`, so replacing an asset
/// overwrites in place and deleting a theme is `removeAll(for:)` — no orphan sweep.
/// Contributed (extension) themes never touch this store; their bytes come from the package
/// via `ExtensionAppearanceRegistry`, read at inspection time.
@MainActor
enum ThemeAssetStore {

    enum StoreError: LocalizedError {
        case invalidPath

        var errorDescription: String? {
            "The theme asset path is invalid."
        }
    }

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

    private static func folder(for themeID: AppThemeID) -> URL? {
        guard themeID.isSafeAssetDirectoryName else { return nil }
        return directory.appendingPathComponent(themeID.rawValue, isDirectory: true)
    }

    private static func assetURL(named assetName: String, for themeID: AppThemeID) -> URL? {
        guard AppThemeID.isSafePathComponent(assetName), let folder = folder(for: themeID) else {
            return nil
        }
        return folder.appendingPathComponent(assetName, isDirectory: false)
    }

    // MARK: - Public Methods

    /// Normalises and writes one slot's image, returning the asset name the theme document
    /// should reference, or nil when the bytes are not a usable image.
    static func store(
        imageData: Data,
        for themeID: AppThemeID,
        slot: ThemeAssetSlot,
        variant: AppTheme.VariantKind
    ) -> String? {
        let fileName = slot.fileName(for: variant)
        return store(
            imageData: imageData,
            for: themeID,
            fileName: fileName,
            maximumBytes: slot.maximumImageBytes,
            maximumPixelSize: ThemeAssetDefaults.storedPixelSize(for: slot)
        )
    }

    /// Stores the sprite sheet extracted from a user-selected classic `.wsz` archive.
    /// The original archive is not retained. ImageIO both validates the input and converts
    /// BMP/PNG to one bounded PNG while preserving native-sized sheets without upscaling.
    static func storeClassicSkinTitleBar(
        imageData: Data,
        for themeID: AppThemeID
    ) -> String? {
        store(
            imageData: imageData,
            for: themeID,
            fileName: ThemeAssetDefaults.classicSkinTitleBarFileName,
            maximumBytes: ClassicSkinLimits.maximumImageBytes,
            maximumPixelSize: ClassicSkinLimits.maximumImagePixelSize
        )
    }

    private static func store(
        imageData: Data,
        for themeID: AppThemeID,
        fileName: String,
        maximumBytes: Int,
        maximumPixelSize: Int
    ) -> String? {
        guard imageData.count <= maximumBytes,
              let themeFolder = folder(for: themeID),
              let target = assetURL(named: fileName, for: themeID),
              let png = ProjectIconStore.normalizedPNGData(
                  from: imageData,
                  maxPixelSize: maximumPixelSize
              ) else { return nil }

        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: themeFolder,
                withIntermediateDirectories: true
            )
            try png.write(
                to: target,
                options: .atomic
            )
        } catch {
            ThreadingLogger.theme.error(
                "Theme asset write failed theme=\(themeID.rawValue, privacy: .private(mask: .hash)) file=\(fileName, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
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

        guard let url = assetURL(named: assetName, for: themeID),
              let data = try? BoundedFileReader.read(
                url,
                maximumBytes: ThemeAssetDefaults.maximumStoredBytes
              ),
              let image = NSImage(data: data), image.isValid else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    /// The stored bytes as written, for the update path's backup-and-restore: a slot's file
    /// is overwritten in place, and an update that then fails must put the old image back or
    /// the standing document shows the new one.
    static func pngData(named assetName: String, for themeID: AppThemeID) -> Data? {
        guard let url = assetURL(named: assetName, for: themeID) else { return nil }
        return try? BoundedFileReader.read(
            url,
            maximumBytes: ThemeAssetDefaults.maximumStoredBytes
        )
    }

    static func assetExists(named assetName: String, for themeID: AppThemeID) -> Bool {
        guard let url = assetURL(named: assetName, for: themeID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes bytes back exactly as they were, bypassing normalisation — they came out of
    /// this store, so they already passed it.
    static func restore(
        pngData: Data,
        named assetName: String,
        for themeID: AppThemeID
    ) throws {
        cache.removeObject(forKey: cacheKey(themeID, assetName))
        guard let url = assetURL(named: assetName, for: themeID) else {
            throw StoreError.invalidPath
        }
        try pngData.write(
            to: url,
            options: .atomic
        )
    }

    static func remove(assetName: String, for themeID: AppThemeID) throws {
        cache.removeObject(forKey: cacheKey(themeID, assetName))
        guard let url = assetURL(named: assetName, for: themeID) else {
            throw StoreError.invalidPath
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deleting a theme deletes its folder; called from the library's delete path so assets
    /// cannot outlive the document that referenced them.
    static func removeAll(for themeID: AppThemeID) {
        for slot in ThemeAssetSlot.allCases {
            for kind in AppTheme.VariantKind.allCases {
                cache.removeObject(forKey: cacheKey(themeID, slot.fileName(for: kind)))
            }
        }
        cache.removeObject(forKey: cacheKey(
            themeID,
            ThemeAssetDefaults.classicSkinTitleBarFileName
        ))
        guard let folder = folder(for: themeID) else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            ThreadingLogger.theme.warning(
                "Theme asset cleanup failed theme=\(themeID.rawValue, privacy: .private(mask: .hash)) path=\(folder.path, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    /// Duplicating a theme copies its assets, so the copy's sidebar and backdrop survive the
    /// original's deletion.
    static func copyAssets(from sourceID: AppThemeID, to targetID: AppThemeID) throws {
        let fileManager = FileManager.default
        guard let source = folder(for: sourceID), let target = folder(for: targetID) else {
            throw StoreError.invalidPath
        }
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: target)
    }

    // MARK: - Private Methods

    private static func cacheKey(_ themeID: AppThemeID, _ fileName: String) -> NSString {
        "\(themeID.rawValue)/\(fileName)" as NSString
    }
}

// MARK: - Theme Asset Defaults

enum ThemeAssetDefaults {
    /// Covers the sidebar assets, the larger material backdrop and the classic-skin title
    /// strip. Stored files are normalized PNGs, but the read side repeats the byte boundary
    /// because Application Support can be externally replaced between launches.
    static let maximumStoredBytes = max(
        SidebarStyleLimits.maximumImageBytes,
        ThemeBackdropLimits.maximumImageBytes,
        ClassicSkinLimits.maximumImageBytes
    )
    static let assetDirectoryName = "ThemeAssets"
    static let classicSkinTitleBarFileName = "classic-titlebar.png"

    /// A sidebar background is stored at 2× the sidebar's widest column; a logo at 4× its slot;
    /// a material backdrop at 2× of a wide pane — enough that Retina rendering never upsamples,
    /// small enough that a theme cannot smuggle a wallpaper library into Application Support.
    static func storedPixelSize(for slot: ThemeAssetSlot) -> Int {
        switch slot {
        case .background: return 1024
        case .logo: return 128
        case .backdrop: return 2048
        }
    }
}
