import AppKit
import XCTest
@testable import Threading

@MainActor
final class ClassicSkinImporterTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var importedThemes: [AppTheme] = []

    override func tearDown() async throws {
        for theme in importedThemes {
            _ = AppThemeLibrary.delete(theme)
        }
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    func testImportsNestedCaseInsensitiveTitleBarAndResolvesStoredSprite() throws {
        let image = try bitmap(width: 344, height: 87)
        let url = try skinArchive(entries: [
            .init(path: "Retro/TiTlEbAr.BmP", data: image),
            .init(path: "README.TXT", data: Data("local test skin".utf8))
        ], name: "Night Driver")

        let theme = try ClassicSkinImporter.importSkin(at: url)
        importedThemes.append(theme)

        XCTAssertEqual(theme.name, "Night Driver")
        XCTAssertTrue(AppThemeLibrary.isCustom(theme))
        let chrome = try XCTUnwrap(theme.variants[.dark]?.chrome)
        XCTAssertEqual(chrome.titleBar.buttonGlyphStyle, .classicPlayer)
        XCTAssertEqual(chrome.titleBar.height, 14)
        let asset = try XCTUnwrap(chrome.titleBar.classicSkin?.titleBarAsset)
        let stored = try XCTUnwrap(ThemeAssetStore.pngData(named: asset, for: theme.id))
        XCTAssertTrue(stored.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let resolved = WindowChromeAppearance.resolved(from: chrome, themeID: theme.id)
        XCTAssertEqual(resolved.classicSkin?.assetName, asset)
        XCTAssertEqual(resolved.classicSkin?.titleBarImage.size, NSSize(width: 344, height: 87))
    }

    func testRejectsAnArchiveWithoutTitleBarArtwork() throws {
        let url = try skinArchive(entries: [
            .init(path: "PLEDIT.TXT", data: Data("[Text]".utf8))
        ], name: "No Artwork")

        XCTAssertThrowsError(try ClassicSkinImporter.importSkin(at: url)) { error in
            XCTAssertEqual(error as? ClassicSkinImporter.Failure, .missingTitleBar)
        }
    }

    func testRejectsTitleBarThatCannotContainClassicSprites() throws {
        let url = try skinArchive(entries: [
            .init(path: "TITLEBAR.BMP", data: try bitmap(width: 275, height: 14))
        ], name: "Too Small")

        XCTAssertThrowsError(try ClassicSkinImporter.importSkin(at: url)) { error in
            XCTAssertEqual(
                error as? ClassicSkinImporter.Failure,
                .titleBarTooSmall(width: 275, height: 14)
            )
        }
    }

    func testRejectsAnArchivePastTheByteLimitBeforeParsingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Oversized.wsz")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ClassicSkinLimits.maximumArchiveBytes) + 1)
        try handle.close()
        temporaryURLs.append(directory)

        XCTAssertThrowsError(try ClassicSkinImporter.importSkin(at: url)) { error in
            XCTAssertEqual(error as? ClassicSkinImporter.Failure, .archiveTooLarge)
        }
    }

    private func skinArchive(entries: [ZipArchive.Entry], name: String) throws -> URL {
        let data = try ZipArchive.archive(entries, modified: Date(timeIntervalSince1970: 0))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).wsz")
        try data.write(to: url, options: .atomic)
        temporaryURLs.append(directory)
        return url
    }

    /// A repetitive BMP exercises the ZIP reader's deflate path and ImageIO's classic bitmap
    /// decoder in the same fixture. The pixels are original test data, not a bundled skin.
    private func bitmap(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        representation.size = NSSize(width: width, height: height)
        let pixels = try XCTUnwrap(representation.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * representation.bytesPerRow + x * 4
                let bright = (x + y).isMultiple(of: 5)
                pixels[offset] = bright ? 199 : 31
                pixels[offset + 1] = bright ? 209 : 36
                pixels[offset + 2] = bright ? 82 : 51
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(representation.representation(using: .bmp, properties: [:]))
    }
}
