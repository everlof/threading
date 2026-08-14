import AppKit
import Foundation
import ImageIO

/// Resource ceilings for classic `.wsz` imports. A skin is a small collection of indexed
/// bitmaps; values above these are malformed for this use even when a general ZIP tool would
/// accept them.
enum ClassicSkinLimits {
    static let maximumArchiveBytes = 20 * 1_024 * 1_024
    static let maximumEntryCount = 256
    static let maximumEntryBytes = 8 * 1_024 * 1_024
    static let maximumExpandedBytes = 32 * 1_024 * 1_024
    static let maximumImageBytes = 5 * 1_024 * 1_024
    static let maximumImagePixelSize = 1_024
    static let minimumTitleBarWidth = 302
    static let minimumTitleBarHeight = 29
}

/// Imports the title-band portion of a classic Winamp 2 `.wsz` as a local custom theme.
///
/// A `.wsz` is a ZIP, but extracting one is unnecessary and unsafe. This reader walks the
/// central directory, expands only `TITLEBAR.BMP` (or PNG), verifies it against the directory's
/// CRC, and hands those bytes to the shared ImageIO normalisation gate. Nothing else in a skin
/// is executable or interpreted.
@MainActor
enum ClassicSkinImporter {

    enum Failure: LocalizedError, Equatable {
        case wrongExtension
        case archiveTooLarge
        case invalidArchive
        case encryptedArchive
        case unsupportedCompression
        case tooManyEntries
        case expandedArchiveTooLarge
        case missingTitleBar
        case invalidTitleBar
        case titleBarTooSmall(width: Int, height: Int)
        case titleBarTooLarge(width: Int, height: Int)
        case couldNotStoreAsset

        var errorDescription: String? {
            switch self {
            case .wrongExtension:
                return L10n.string("Choose a classic .wsz skin file.")
            case .archiveTooLarge:
                return L10n.string("The skin archive is too large to import.")
            case .invalidArchive:
                return L10n.string("The skin is not a valid ZIP archive.")
            case .encryptedArchive:
                return L10n.string("Encrypted skin archives are not supported.")
            case .unsupportedCompression:
                return L10n.string("The skin uses an unsupported ZIP compression method.")
            case .tooManyEntries:
                return L10n.string("The skin contains too many files.")
            case .expandedArchiveTooLarge:
                return L10n.string("The expanded skin is too large to import safely.")
            case .missingTitleBar:
                return L10n.string("The skin does not contain TITLEBAR.BMP.")
            case .invalidTitleBar:
                return L10n.string("The skin's TITLEBAR image could not be read.")
            case .titleBarTooSmall(let width, let height):
                return L10n.format(
                    "The skin's TITLEBAR image is too small (%lld×%lld).",
                    Int64(width),
                    Int64(height)
                )
            case .titleBarTooLarge(let width, let height):
                return L10n.format(
                    "The skin's TITLEBAR image is too large (%lld×%lld).",
                    Int64(width),
                    Int64(height)
                )
            case .couldNotStoreAsset:
                return L10n.string("The skin artwork could not be stored.")
            }
        }

        /// The shared archive reader's refusals, in this importer's own words.
        ///
        /// The reader is deliberately generic — a `.lottie` container and a `.wsz` skin are the
        /// same attack surface — so each caller keeps its own vocabulary for what a user should
        /// be told.
        init(_ failure: BoundedZipArchive.Failure) {
            switch failure {
            case .invalidArchive: self = .invalidArchive
            case .encryptedArchive: self = .encryptedArchive
            case .unsupportedCompression: self = .unsupportedCompression
            case .tooManyEntries: self = .tooManyEntries
            case .expandedArchiveTooLarge: self = .expandedArchiveTooLarge
            }
        }

        var diagnosticCode: String {
            switch self {
            case .wrongExtension: return "wrong_extension"
            case .archiveTooLarge: return "archive_too_large"
            case .invalidArchive: return "invalid_archive"
            case .encryptedArchive: return "encrypted_archive"
            case .unsupportedCompression: return "unsupported_compression"
            case .tooManyEntries: return "too_many_entries"
            case .expandedArchiveTooLarge: return "expanded_archive_too_large"
            case .missingTitleBar: return "missing_title_bar"
            case .invalidTitleBar: return "invalid_title_bar"
            case .titleBarTooSmall: return "title_bar_too_small"
            case .titleBarTooLarge: return "title_bar_too_large"
            case .couldNotStoreAsset: return "asset_write_failed"
            }
        }
    }

    /// Creates and returns a custom theme. The caller decides whether to make it current.
    static func importSkin(at url: URL) throws -> AppTheme {
        ThreadingLogger.theme.info(
            "Classic skin import started source=\(url.path, privacy: .private(mask: .hash))"
        )
        do {
            let theme = try importSkinContents(at: url)
            ThreadingLogger.theme.info(
                "Classic skin import completed source=\(url.path, privacy: .private(mask: .hash)) theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
            )
            return theme
        } catch {
            let diagnosticCode = (error as? Failure)?.diagnosticCode ?? "unexpected"
            ThreadingLogger.theme.error(
                "Classic skin import failed source=\(url.path, privacy: .private(mask: .hash)) reason=\(diagnosticCode, privacy: .public)"
            )
            throw error
        }
    }

    private static func importSkinContents(at url: URL) throws -> AppTheme {
        guard url.pathExtension.caseInsensitiveCompare("wsz") == .orderedSame else {
            throw Failure.wrongExtension
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { throw Failure.invalidArchive }
        if let size = values?.fileSize, size > ClassicSkinLimits.maximumArchiveBytes {
            throw Failure.archiveTooLarge
        }

        let archive: Data
        do {
            archive = try BoundedFileReader.read(
                url,
                maximumBytes: ClassicSkinLimits.maximumArchiveBytes
            )
        } catch BoundedFileReadError.exceedsLimit {
            throw Failure.archiveTooLarge
        } catch {
            throw Failure.invalidArchive
        }
        let titleBar: Data
        do {
            let reader = try BoundedZipArchive(
                data: archive,
                limits: BoundedZipArchive.Limits(
                    maximumEntryCount: ClassicSkinLimits.maximumEntryCount,
                    maximumEntryBytes: ClassicSkinLimits.maximumEntryBytes,
                    maximumExpandedBytes: ClassicSkinLimits.maximumExpandedBytes
                )
            )
            guard let found = try reader.data(
                forLastEntryNamed: ["titlebar.bmp", "titlebar.png"]
            ) else { throw Failure.missingTitleBar }
            titleBar = found
        } catch let failure as BoundedZipArchive.Failure {
            throw Failure(failure)
        }
        try validateTitleBar(titleBar)

        let id = AppThemeLibrary.makeCustomID()
        guard let assetName = ThemeAssetStore.storeClassicSkinTitleBar(
            imageData: titleBar,
            for: id
        ) else {
            throw Failure.couldNotStoreAsset
        }

        do {
            guard var variant = AppThemeStyles.classicPlayer.variants[.dark],
                  var chrome = variant.chrome else {
                throw Failure.couldNotStoreAsset
            }
            chrome.titleBar.classicSkin = .init(titleBarAsset: assetName)
            variant = variant.replacingChrome(chrome)

            let requestedName = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = uniqueName(
                requestedName.isEmpty ? L10n.string("Imported Classic Skin") : requestedName
            )
            let theme = AppTheme(
                id: id,
                name: name,
                mode: .dark,
                summary: L10n.string(
                    "Imported classic .wsz window skin. Stored only on this Mac."
                ),
                variants: [.dark: variant]
            )
            try AppThemeLibrary.create(theme)
            return theme
        } catch {
            ThemeAssetStore.removeAll(for: id)
            throw error
        }
    }

    private static func uniqueName(_ base: String) -> String {
        let existing = Set(AppThemeLibrary.all.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var number = 2
        while existing.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private static func validateTitleBar(_ data: Data) throws {
        guard data.count <= ClassicSkinLimits.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure.invalidTitleBar
        }
        guard width >= ClassicSkinLimits.minimumTitleBarWidth,
              height >= ClassicSkinLimits.minimumTitleBarHeight else {
            throw Failure.titleBarTooSmall(width: width, height: height)
        }
        guard width <= ClassicSkinLimits.maximumImagePixelSize,
              height <= ClassicSkinLimits.maximumImagePixelSize else {
            throw Failure.titleBarTooLarge(width: width, height: height)
        }
    }
}

