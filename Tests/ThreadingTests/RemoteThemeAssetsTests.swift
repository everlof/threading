import AppKit
import ThreadingRemoteKit
@testable import Threading
import XCTest

/// The admitted theme-asset set a paired phone is told about. An edit that leaves the current
/// theme's pictures and fonts alone must not tell phones the theme has none (they would drop
/// their fonts, pictures, shader and sound receipts and fetch them all again), and a
/// collaborator is not told about owner-only assets the route would refuse them.
@MainActor
final class RemoteThemeAssetsTests: XCTestCase {
    private final class Counter: @unchecked Sendable { var value = 0 }

    func testAnUnrelatedEditKeepsServingTheSetAndACollaboratorSeesNoOwnerAssets() async throws {
        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Remote assets \(UUID())")
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(custom)
        }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.green.setFill(); rect.fill(); return true
        }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(AppThemePreviewService.pngData(cg))
        let picture = try XCTUnwrap(ThemeAssetStore.store(imageData: png, for: custom.id, slot: .backdrop, variant: .dark))
        let fontURL = try XCTUnwrap(Bundle.main.url(forResource: "W95FA", withExtension: "otf"))
        let fontFolder = try XCTUnwrap(ThemeFontStore.folder(for: custom.id))
        try await Task.detached {
            try FileManager.default.createDirectory(at: fontFolder, withIntermediateDirectories: true)
            try Data(contentsOf: fontURL).write(to: fontFolder.appendingPathComponent("font-fixture.otf"))
        }.value
        let variant = try XCTUnwrap(custom.variant(.dark))
        var material = variant.material
        material.fontFamily = "W95FA"
        material.backdrop = ThemeBackdrop(image: .init(asset: picture, opacity: 0.2))
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: variant.replacing(material: material)])
        AppThemeLibrary.installResolved(theme)
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        _ = RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance)?.count ?? 0) < 2,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let published = try XCTUnwrap(RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance))
        XCTAssertTrue(published.contains { $0.kind == .image })
        XCTAssertTrue(published.contains { $0.kind == .font })

        let announcements = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: RemoteThemeAssetsDidChange.name, object: nil, queue: nil
        ) { _ in announcements.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        // A library event that does not touch these assets, then a repaint of the same theme.
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        XCTAssertEqual(RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance), published,
                       "the published set keeps serving while its replacement is prepared")
        AppThemeLibrary.installResolved(theme)
        XCTAssertEqual(RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance), published)
        try await Task.sleep(for: RemoteThemeAssets.preparationDelay * 4)
        XCTAssertEqual(RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance), published)
        XCTAssertEqual(announcements.value, 0, "an unchanged set is not announced again")

        let owner = RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions)
        let guest = RemoteAuthorization(shareID: "guest", capability: .view, scope: .session(SessionID()))
        let ownerView = RemoteThemeBridge.appTheme(for: owner)
        let guestView = RemoteThemeBridge.appTheme(for: guest)
        XCTAssertTrue(ownerView.assets?.contains { $0.kind == .font } == true)
        XCTAssertEqual(guestView.assets?.contains { $0.kind == .font }, false,
                       "a collaborator is not told about fonts the route refuses them")
        XCTAssertTrue(guestView.assets?.contains { $0.kind == .image } == true)
        XCTAssertNil(guestView.surface)

        // Switching theme retires the set at once, before anything replaces it.
        AppThemeLibrary.installResolved(previous)
        XCTAssertNil(RemoteThemeAssets.shared.descriptor(for: published[0].digest))
    }
}
