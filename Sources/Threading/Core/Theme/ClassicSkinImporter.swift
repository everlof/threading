import AppKit
import Compression
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
    }

    /// Creates and returns a custom theme. The caller decides whether to make it current.
    static func importSkin(at url: URL) throws -> AppTheme {
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
        let reader = try ClassicSkinZip(data: archive)
        guard let titleBar = try reader.data(forLastEntryNamed: ["titlebar.bmp", "titlebar.png"])
        else { throw Failure.missingTitleBar }
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

/// A bounded, read-only ZIP central-directory reader for classic skin imports.
private struct ClassicSkinZip {

    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private let entries: [Entry]

    init(data: Data) throws {
        bytes = data
        guard let end = Self.endRecordOffset(in: data),
              let disk = data.uint16(at: end + 4),
              let directoryDisk = data.uint16(at: end + 6),
              let entriesOnDisk = data.uint16(at: end + 8),
              let entryCount = data.uint16(at: end + 10),
              let directorySize = data.uint32(at: end + 12),
              let directoryOffset = data.uint32(at: end + 16),
              disk == 0,
              directoryDisk == 0,
              entriesOnDisk == entryCount,
              entryCount != UInt16.max,
              directorySize != UInt32.max,
              directoryOffset != UInt32.max else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }
        guard Int(entryCount) <= ClassicSkinLimits.maximumEntryCount else {
            throw ClassicSkinImporter.Failure.tooManyEntries
        }

        let start = Int(directoryOffset)
        let size = Int(directorySize)
        guard start >= 0, size >= 0, start <= data.count,
              size <= data.count - start, start + size <= end else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }

        var parsed: [Entry] = []
        var cursor = start
        var expandedTotal = 0
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= start + size,
                  data.uint32(at: cursor) == 0x0201_4B50,
                  let flags = data.uint16(at: cursor + 8),
                  let method = data.uint16(at: cursor + 10),
                  let checksum = data.uint32(at: cursor + 16),
                  let compressed = data.uint32(at: cursor + 20),
                  let expanded = data.uint32(at: cursor + 24),
                  let nameLength = data.uint16(at: cursor + 28),
                  let extraLength = data.uint16(at: cursor + 30),
                  let commentLength = data.uint16(at: cursor + 32),
                  let localOffset = data.uint32(at: cursor + 42) else {
                throw ClassicSkinImporter.Failure.invalidArchive
            }
            guard compressed != UInt32.max, expanded != UInt32.max,
                  localOffset != UInt32.max else {
                throw ClassicSkinImporter.Failure.invalidArchive
            }

            let variableLength = Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard cursor + 46 + variableLength <= start + size else {
                throw ClassicSkinImporter.Failure.invalidArchive
            }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + Int(nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
            guard let name else { throw ClassicSkinImporter.Failure.invalidArchive }

            let expandedInt = Int(expanded)
            guard flags & 0x1 == 0 else {
                throw ClassicSkinImporter.Failure.encryptedArchive
            }
            guard method == 0 || method == 8 else {
                throw ClassicSkinImporter.Failure.unsupportedCompression
            }
            guard expandedInt <= ClassicSkinLimits.maximumEntryBytes,
                  Int(compressed) <= ClassicSkinLimits.maximumEntryBytes else {
                throw ClassicSkinImporter.Failure.expandedArchiveTooLarge
            }
            guard expandedTotal <= ClassicSkinLimits.maximumExpandedBytes - expandedInt else {
                throw ClassicSkinImporter.Failure.expandedArchiveTooLarge
            }
            expandedTotal += expandedInt
            parsed.append(Entry(
                name: name,
                flags: flags,
                method: method,
                checksum: checksum,
                compressedSize: Int(compressed),
                expandedSize: expandedInt,
                localHeaderOffset: Int(localOffset)
            ))
            cursor += 46 + variableLength
        }
        guard cursor == start + size else { throw ClassicSkinImporter.Failure.invalidArchive }
        entries = parsed
    }

    func data(forLastEntryNamed names: [String]) throws -> Data? {
        let wanted = Set(names.map { $0.lowercased() })
        guard let entry = entries.last(where: { wanted.contains(Self.basename($0.name)) }) else {
            return nil
        }
        guard entry.flags & 0x1 == 0 else {
            throw ClassicSkinImporter.Failure.encryptedArchive
        }
        guard entry.method == 0 || entry.method == 8 else {
            throw ClassicSkinImporter.Failure.unsupportedCompression
        }

        let offset = entry.localHeaderOffset
        guard offset >= 0, offset + 30 <= bytes.count,
              bytes.uint32(at: offset) == 0x0403_4B50,
              let localFlags = bytes.uint16(at: offset + 6),
              let localMethod = bytes.uint16(at: offset + 8),
              let nameLength = bytes.uint16(at: offset + 26),
              let extraLength = bytes.uint16(at: offset + 28),
              localFlags & 0x1 == 0,
              localMethod == entry.method else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }
        let payloadStart = offset + 30 + Int(nameLength) + Int(extraLength)
        guard payloadStart <= bytes.count,
              entry.compressedSize <= bytes.count - payloadStart else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }
        let payload = bytes.subdata(
            in: payloadStart..<payloadStart + entry.compressedSize
        )
        let expanded: Data
        switch entry.method {
        case 0:
            guard payload.count == entry.expandedSize else {
                throw ClassicSkinImporter.Failure.invalidArchive
            }
            expanded = payload
        case 8:
            expanded = try Self.inflate(payload, expectedSize: entry.expandedSize)
        default:
            throw ClassicSkinImporter.Failure.unsupportedCompression
        }
        guard ZipArchive.crc32(expanded) == entry.checksum else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }
        return expanded
    }

    private static func basename(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init)?.lowercased() ?? ""
    }

    private static func endRecordOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let earliest = max(0, data.count - (65_535 + 22))
        var cursor = data.count - 22
        while cursor >= earliest {
            if data.uint32(at: cursor) == 0x0605_4B50,
               let commentLength = data.uint16(at: cursor + 20),
               cursor + 22 + Int(commentLength) == data.count {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            guard source.isEmpty else { throw ClassicSkinImporter.Failure.invalidArchive }
            return Data()
        }
        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { output -> Int in
            guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return source.withUnsafeBytes { input -> Int in
                guard let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase,
                    expectedSize,
                    inputBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ClassicSkinImporter.Failure.invalidArchive
        }
        return destination
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
