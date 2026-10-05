import CoreText
import Foundation

// MARK: - Theme Font Store

/// The font files a custom theme carries, so its wordmark or its prose can be set in a face the
/// Mac does not otherwise have — a script for a brand's name, a period face for a desktop.
///
/// Files live beside the theme's images in its `ThemeAssetStore` folder, named `font-<uuid>`
/// with the format's own extension, so the lifecycle that already governs a theme's assets
/// governs its fonts too: duplicating a theme copies the folder, deleting it removes the folder.
/// The document never names a file. It names a *family* (`title.font_family`,
/// `material.font_family`), exactly as it names an installed one, so a theme that loses its font
/// file degrades one rung like any missing family rather than failing.
///
/// Registered **process-scoped** through `CTFontManager`, the extension tier's arrangement and
/// for its measured reasons: a process registration is visible to `Design.Typography`'s
/// descriptor matching live, and to `Design.Typography.availableFamilies`, which the authoring
/// gate uses. Nothing is installed for the user's other apps.
///
/// **Off the main actor by construction.** Every function here reads, writes, parses or
/// registers files, so the type is not isolated; callers run it from a detached task (the
/// tool) or at launch for exactly one bounded folder (the theme being restored). A font is an
/// untrusted file parsed in process — the same posture the extension tier documents for a
/// declared font resource — so each is bounded in bytes, must parse to at least one face, and
/// a theme may carry at most `maximumFonts`.
enum ThemeFontStore {

    enum StoreError: LocalizedError {
        case tooLarge(maximumBytes: Int)
        case notAFont
        case tooMany(maximum: Int)
        case invalidTheme
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let maximumBytes):
                return "The font file exceeds \(maximumBytes / (1024 * 1024)) MB."
            case .notAFont:
                return "The file is not a font CoreText can read."
            case .tooMany(let maximum):
                return "A theme carries at most \(maximum) font files; remove the existing ones first."
            case .invalidTheme:
                return "The theme id is not a safe folder name."
            case .writeFailed(let reason):
                return "The font could not be stored: \(reason)"
            }
        }
    }

    /// A family a stored file supplies, and which file.
    struct StoredFont: Equatable, Sendable {
        let fileName: String
        let families: [String]
    }

    /// Big enough for a full CJK face; small enough that a theme is not a font library.
    static let maximumFontBytes = 16 * 1024 * 1024
    static let maximumFonts = 4
    private static let filePrefix = "font-"

    // MARK: - Public Methods

    /// Stores and registers one font for `themeID`, returning the families it supplies.
    static func store(fontData: Data, for themeID: AppThemeID) throws -> StoredFont {
        guard fontData.count <= maximumFontBytes else {
            throw StoreError.tooLarge(maximumBytes: maximumFontBytes)
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData)
            as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw StoreError.notAFont
        }
        guard let folder = folder(for: themeID) else { throw StoreError.invalidTheme }
        guard storedFileNames(in: folder).count < maximumFonts else {
            throw StoreError.tooMany(maximum: maximumFonts)
        }

        let fileName = filePrefix + UUID().uuidString.lowercased() + "." + fileExtension(of: fontData)
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fontData.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return StoredFont(fileName: fileName, families: families(of: descriptors))
    }

    /// Unregisters and deletes every font `themeID` carries.
    static func removeAll(for themeID: AppThemeID) {
        guard let folder = folder(for: themeID) else { return }
        for name in storedFileNames(in: folder) {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Unregisters without deleting — for a theme whose folder is about to go with it.
    static func unregisterAll(for themeID: AppThemeID) {
        guard let folder = folder(for: themeID) else { return }
        for name in storedFileNames(in: folder) {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Registers every font the listed themes carry. Called at launch for the theme being
    /// restored (so its first window resolves the family) and in the background for the rest.
    static func registerFonts(for themeIDs: [AppThemeID]) {
        for themeID in themeIDs {
            guard let folder = folder(for: themeID) else { continue }
            for name in storedFileNames(in: folder) {
                let url = folder.appendingPathComponent(name, isDirectory: false)
                _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// What `themeID` carries, for `get_app_theme` to report by family.
    static func storedFonts(for themeID: AppThemeID) -> [StoredFont] {
        guard let folder = folder(for: themeID) else { return [] }
        return storedFileNames(in: folder).map { name in
            let url = folder.appendingPathComponent(name, isDirectory: false)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor] ?? []
            return StoredFont(fileName: name, families: families(of: descriptors))
        }
    }

    // MARK: - Private Methods

    static func folder(for themeID: AppThemeID) -> URL? {
        guard themeID.isSafeAssetDirectoryName else { return nil }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(ThemeAssetDefaults.assetDirectoryName)
            .appendingPathComponent(themeID.rawValue, isDirectory: true)
    }

    private static func storedFileNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(filePrefix) }.sorted()
    }

    private static func families(of descriptors: [CTFontDescriptor]) -> [String] {
        let names = descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }
        return Array(Set(names)).sorted()
    }

    /// The container's own extension, so the file on disk says what it is: a collection, a
    /// CFF-flavoured OpenType face, or TrueType-flavoured (the default).
    private static func fileExtension(of data: Data) -> String {
        let tag = data.prefix(4)
        if tag == Data("ttcf".utf8) { return "ttc" }
        if tag == Data("OTTO".utf8) { return "otf" }
        return "ttf"
    }
}
