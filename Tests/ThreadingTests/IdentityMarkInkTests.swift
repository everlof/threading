import AppKit
import ThreadingRemoteKit
@testable import Threading
import XCTest

/// A theme's `identity_marks`: generated project tiles, agent marks and account chips inked in
/// the accent under `tinted`, while a person's own choices keep their pixels.
@MainActor
final class IdentityMarkInkTests: XCTestCase {

    private var previousTheme: AppTheme?
    private let suite = "codes.threading.tests.identity-mark-ink"
    private var store: AccountPreferencesStore!
    private let accent = NSColor(hex: "#00FF41")!

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = AppThemePalette.current
        UserDefaults.standard.removePersistentDomain(forName: suite)
        store = AccountPreferencesStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() async throws {
        if let previousTheme { AppThemePalette.set(previousTheme) }
        store = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func useTheme(marks: AppTheme.Material.IdentityMarks) throws {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        var material = base.material
        material.identityMarks = marks
        var roles = base.roles
        roles[.accent] = accent
        AppThemePalette.set(AppTheme(
            id: AppThemeID("custom-identity-ink-\(UUID().uuidString)"),
            name: "Ink",
            mode: .dark,
            summary: nil,
            variants: [.dark: base.replacing(roles: roles, material: material)]
        ))
    }

    private var darkAppearance: NSAppearance { NSAppearance(named: .darkAqua)! }

    // MARK: - Wire form

    func testTheMarksDefaultToNaturalAndRoundTrip() throws {
        let natural = try JSONDecoder().decode(AppTheme.Material.self, from: Data("{}".utf8))
        XCTAssertEqual(natural.identityMarks, .natural, "an older document reads natural")
        var tinted = AppTheme.Material.system
        tinted.identityMarks = .tinted
        let decoded = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: JSONEncoder().encode(tinted)
        )
        XCTAssertEqual(decoded.identityMarks, .tinted)
        XCTAssertTrue(AppThemeStyles.all.allSatisfy { theme in
            AppTheme.VariantKind.allCases.compactMap(theme.variant).allSatisfy {
                $0.material.identityMarks == .natural
            }
        }, "every stock theme keeps its marks' own colours")
    }

    // MARK: - Drawing

    func testATintedThemeInksTheGeneratedTileInItsAccent() throws {
        let natural = GeneratedProjectIcon.image(for: "threading-marketeer")
        let tinted = GeneratedProjectIcon.image(for: "threading-marketeer", tint: accent)
        XCTAssertFalse(natural === tinted, "the cache is keyed by what is drawn")
        let edge = try pixel(of: tinted, atFraction: NSPoint(x: 0.5, y: 0.02))
        XCTAssertGreaterThan(edge.greenComponent, 0.8, "the outline is the accent")
        XCTAssertLessThan(edge.redComponent, 0.2)
        let naturalCorner = try pixel(of: natural, atFraction: NSPoint(x: 0.5, y: 0.02))
        XCTAssertGreaterThan(naturalCorner.alphaComponent, 0.9, "the natural tile is a solid fill")

        try useTheme(marks: .tinted)
        XCTAssertTrue(IdentityMarkInk.isTinted(for: darkAppearance))
        try useTheme(marks: .natural)
        XCTAssertFalse(IdentityMarkInk.isTinted(for: darkAppearance))
    }

    func testATintedThemeRingsAnInitialChipButKeepsAColourThePersonChose() throws {
        let account = AgentAccount(
            provider: .codex, handle: .named("identity-ink-fixture"),
            configPath: "/nonexistent/identity-ink", displayName: "Research",
            displayNameOverride: "Research", presentationNameIsResolved: true
        )
        try useTheme(marks: .natural)
        let natural = try XCTUnwrap(AccountBadge.chip(for: account, store: store))
        try useTheme(marks: .tinted)
        let tinted = try XCTUnwrap(NSApp.effectiveAppearance.performAsCurrentDrawingAppearanceReturning {
            AccountBadge.chip(for: account, store: store)
        })
        XCTAssertFalse(natural === tinted)

        var chosen = AccountAppearancePreferences()
        var appearance = AccountAppearance()
        appearance.backgroundHex = "#123456"
        chosen.shared = appearance
        store.setAppearance(chosen, for: account.id)
        let personal = try XCTUnwrap(AccountBadge.chip(for: account, store: store))
        let centre = try pixel(of: personal, atFraction: NSPoint(x: 0.14, y: 0.5))
        XCTAssertEqual(centre.blueComponent, 0x56 / 255.0, accuracy: 0.08, "the person's colour stays")
    }

    // MARK: - Tools

    func testAnAgentCanTintATheme() async throws {
        let name = "Ink \(UUID().uuidString)"
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        let arguments = try JSONDecoder().decode(CreateAppThemeArguments.self, from: Data("""
            {"name": "\(name)", "base_id": "threading", "appearance": "dark", "apply": false,
             "variants": {"dark": {"material": {"identity_marks": "tinted"}}}}
            """.utf8))
        let created = await coordinator.createAppTheme(arguments)
        XCTAssertFalse(created.isError, created.text)
        let stored = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: stored.id) { _ = AppThemeLibrary.delete(latest) }
        }
        XCTAssertEqual(stored.variant(.dark)?.material.identityMarks, .tinted)
        let get = coordinator.getAppTheme(AppThemeReferenceArguments(themeID: stored.id.rawValue))
        XCTAssertTrue(get.text.contains("\"identity_marks\" : \"tinted\""), get.text)

        let refused = try JSONDecoder().decode(CreateAppThemeArguments.self, from: Data("""
            {"name": "\(name) 2", "base_id": "threading", "appearance": "dark", "apply": false,
             "variants": {"dark": {"material": {"identity_marks": "rainbow"}}}}
            """.utf8))
        let refusal = await coordinator.createAppTheme(refused)
        XCTAssertTrue(refusal.isError)
    }

    // MARK: - Helpers

    private func pixel(of image: NSImage, atFraction point: NSPoint) throws -> NSColor {
        let side = 64
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let x = min(side - 1, Int(point.x * CGFloat(side)))
        let y = min(side - 1, Int((1 - point.y) * CGFloat(side)))
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
}

private extension NSAppearance {
    func performAsCurrentDrawingAppearanceReturning<T>(_ body: () -> T) -> T {
        var result: T?
        performAsCurrentDrawingAppearance { result = body() }
        return result!
    }
}
