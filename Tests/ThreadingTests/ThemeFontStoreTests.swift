import Foundation
import XCTest
@testable import Threading

/// A theme carries a font file only for a face the Mac does not already have.
///
/// The first agent-made theme reviewed named Chalkboard SE by family and also stored a copy of
/// the system's own file: half a megabyte that changed nothing, and a copy of Apple's font that
/// travelled with every shared theme.
final class ThemeFontStoreTests: XCTestCase {

    private var themeID = AppThemeID("custom-font-store-\(UUID().uuidString.lowercased())")

    override func tearDown() {
        ThemeFontStore.removeAll(for: themeID)
        if let folder = ThemeFontStore.folder(for: themeID) {
            try? FileManager.default.removeItem(at: folder)
        }
        super.tearDown()
    }

    func testAFaceThatShipsWithMacOSIsRefusedAndNothingIsStored() throws {
        let system = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: system.path), "Menlo ships with macOS")
        let data = try Data(contentsOf: system)

        XCTAssertThrowsError(try ThemeFontStore.store(fontData: data, for: themeID)) { error in
            guard case ThemeFontStore.StoreError.shipsWithMacOS(let families) = error else {
                return XCTFail("refused for the wrong reason: \(error)")
            }
            XCTAssertEqual(families, ["Menlo"])
            XCTAssertTrue(error.localizedDescription.contains("font_family"), error.localizedDescription)
        }
        let folder = try XCTUnwrap(ThemeFontStore.folder(for: themeID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused font wrote a file")
    }

    func testAFaceTheMacDoesNotHaveIsStored() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = repository.appendingPathComponent("Sources/Threading/Resources/Fonts/W95FA/W95FA.otf")
        let data = try Data(contentsOf: bundled)

        let stored = try ThemeFontStore.store(fontData: data, for: themeID)
        XCTAssertFalse(stored.families.isEmpty)
        XCTAssertEqual(ThemeFontStore.storedFonts(for: themeID).map(\.fileName), [stored.fileName])
    }
}
