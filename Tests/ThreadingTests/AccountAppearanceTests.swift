import AppKit
import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class AccountAppearanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: AccountPreferencesStore!
    private let suite = "codes.threading.tests.account-appearance"
    private var account: AgentAccount {
        AgentAccount(provider: .codex, handle: .named("appearance-fixture"),
                     configPath: "/nonexistent/account-appearance", displayName: "Research",
                     displayNameOverride: "Research", presentationNameIsResolved: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        store = AccountPreferencesStore(defaults: defaults)
    }
    override func tearDown() async throws {
        store = nil
        defaults = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        AppThemePalette.set(.system)
        try await super.tearDown()
    }

    func testSurfaceOverridesInheritSharedValuesAndPreserveExplicitFalse() {
        var shared = AccountAppearancePreferences()
        var base = AccountAppearance()
        base.backgroundHex = "#123456"
        base.showBadge = true
        shared.shared = base
        store.setAppearance(shared, for: nil)
        var own = AccountAppearancePreferences()
        own.shortName = "R&D"
        var chooser = AccountAppearance()
        chooser.useShortName = true
        chooser.showBadge = false
        own.surfaces = ["chooser": chooser]
        store.setAppearance(own, for: account.id)
        let resolved = AccountPresentation.resolve(account, surface: .chooser, store: store)
        XCTAssertEqual(resolved.visibleName, "R&D")
        XCTAssertEqual(resolved.background.hexString.uppercased(), "#123456")
        XCTAssertFalse(resolved.showsBadge(isDefault: false, surface: .chooser))
        XCTAssertEqual(AccountPresentation.resolve(account, surface: .sidebar, store: store).visibleName, "Research")
    }

    func testEmojiAndMultipleLettersAreExplicitContentNotDerivedInitials() {
        for (mode, glyph) in [("emoji", "👩‍💻"), ("text", "DV")] {
            var own = AccountAppearancePreferences()
            var appearance = AccountAppearance()
            appearance.badgeMode = mode
            appearance.badgeText = glyph
            own.shared = appearance
            store.setAppearance(own, for: account.id)
            let result = AccountPresentation.resolve(account, store: store)
            XCTAssertEqual(result.glyph, glyph)
            XCTAssertEqual(result.isEmoji, mode == "emoji")
        }
    }

    func testAutomaticForegroundContrastsWithChosenBackground() {
        for (background, foreground) in [("#FFFFFF", "#000000"), ("#000000", "#FFFFFF")] {
            var own = AccountAppearancePreferences()
            var style = AccountAppearance()
            style.backgroundHex = background
            own.shared = style
            store.setAppearance(own, for: account.id)
            XCTAssertEqual(AccountPresentation.resolve(account, store: store).foreground.hexString.uppercased(), foreground)
        }
    }

    func testRestoreClearsEveryPresentationChoiceButRetainsOperationalPreferences() {
        var own = AccountAppearancePreferences()
        own.shortName = "R"
        var style = AccountAppearance()
        style.badgeMode = "none"
        own.shared = style
        store.setAppearance(own, for: account.id)
        store.setEnabled(false, for: account.id)
        store.setLastReportedModel("fixture-model", for: account.id)
        store.setDisplayNameOverride("Changed", for: account.id)
        store.setEmoji("🦊", for: account.id)
        store.clearPresentation(for: account.id)
        XCTAssertEqual(store.appearance(for: account.id), AccountAppearancePreferences())
        XCTAssertNil(store.emoji(for: account.id))
        XCTAssertNil(store.displayNameOverride(for: account.id))
        XCTAssertFalse(store.isEnabled(account.id))
        XCTAssertEqual(store.lastReportedModel(for: account.id), "fixture-model")
    }

    func testDefaultBadgeCanBeShownAndNameCanBeHiddenWithoutLosingSpokenIdentity() {
        var own = AccountAppearancePreferences()
        var style = AccountAppearance()
        style.showDefaultBadge = true
        style.showName = false
        own.shared = style
        store.setAppearance(own, for: account.id)
        let result = AccountPresentation.resolve(account, surface: .sidebar, store: store)
        XCTAssertEqual(result.name, "Research")
        XCTAssertEqual(result.visibleName, "")
        XCTAssertTrue(result.showsBadge(isDefault: true, surface: .sidebar))
    }

    func testResolverSuppressionTracksOnlyEffectiveSidebarBadgeChoices() {
        XCTAssertFalse(AccountPresentation.hasUserSelectedBadge(
            for: account,
            surface: .sidebar,
            store: store
        ))

        var defaultsAppearance = AccountAppearancePreferences()
        var unrelatedStyle = AccountAppearance()
        unrelatedStyle.showDefaultBadge = true
        unrelatedStyle.showName = false
        unrelatedStyle.showEmail = false
        defaultsAppearance.shared = unrelatedStyle
        store.setAppearance(defaultsAppearance, for: nil)
        XCTAssertFalse(AccountPresentation.hasUserSelectedBadge(
            for: account,
            surface: .sidebar,
            store: store
        ))

        var hiddenStyle = AccountAppearance()
        hiddenStyle.showBadge = false
        defaultsAppearance.shared = hiddenStyle
        store.setAppearance(defaultsAppearance, for: nil)
        XCTAssertTrue(AccountPresentation.hasUserSelectedBadge(
            for: account,
            surface: .sidebar,
            store: store
        ))

        var sidebarStyle = AccountAppearance()
        sidebarStyle.backgroundHex = "#123456"
        defaultsAppearance.shared = unrelatedStyle
        defaultsAppearance.surfaces = [AccountAppearanceSurface.sidebar.rawValue: sidebarStyle]
        store.setAppearance(defaultsAppearance, for: nil)
        XCTAssertTrue(AccountPresentation.hasUserSelectedBadge(
            for: account,
            surface: .sidebar,
            store: store
        ))

        let legacyEmojiAccount = AgentAccount(
            provider: .codex,
            handle: .named("legacy-emoji"),
            configPath: "/nonexistent/legacy-emoji",
            displayName: "Legacy",
            emoji: "🦊",
            presentationNameIsResolved: true
        )
        store.setAppearance(AccountAppearancePreferences(), for: nil)
        XCTAssertTrue(AccountPresentation.hasUserSelectedBadge(
            for: legacyEmojiAccount,
            surface: .sidebar,
            store: store
        ))
    }

    func testPersistenceNormalizesBoundsAndIgnoresUnknownSurfaces() {
        var own = AccountAppearancePreferences()
        var style = AccountAppearance()
        style.badgeText = " 👩‍💻🦊ABCD "
        style.backgroundHex = "not a color"
        own.shared = style
        own.surfaces = ["future": style]
        store.setAppearance(own, for: account.id)
        let reloaded = AccountPreferencesStore(defaults: defaults).appearance(for: account.id)
        XCTAssertEqual(reloaded.shared?.badgeText, "👩‍💻🦊A")
        XCTAssertNil(reloaded.shared?.backgroundHex)
        XCTAssertNil(reloaded.surfaces?["future"])
    }

    func testLegacyRemoteIdentityDecodesAndNewPresentationRoundTrips() throws {
        let legacy = Data(#"{"name":"Work","glyph":"W","isEmoji":false,"hue":0.5}"#.utf8)
        let old = try JSONDecoder().decode(RemoteSessionAccountDTO.self, from: legacy)
        XCTAssertEqual(old.visibleName, "Work")
        XCTAssertNil(old.badgeHidden)
        let new = RemoteSessionAccountDTO(
            name: "Research", glyph: "🦊", isEmoji: true, hue: nil,
            backgroundHex: "#102030", foregroundHex: "#FFFFFF", imageID: UUID().uuidString,
            badgeHidden: false, displayLabel: "R"
        )
        XCTAssertEqual(try JSONDecoder().decode(RemoteSessionAccountDTO.self,
            from: JSONEncoder().encode(new)), new)
    }

    func testEachPreviewResolvesItsOwnSurfaceAndPhoneFollowsSelection() throws {
        var own = AccountAppearancePreferences()
        own.shortName = "R&D"
        var details = AccountAppearance()
        details.useShortName = true
        var usage = AccountAppearance()
        usage.showName = false
        own.surfaces = ["details": details, "usage": usage]
        store.setAppearance(own, for: account.id)
        store.setDisplayNameOverride("Research", for: account.id)
        let controller = AccountAppearanceViewController(account: account, store: store)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(controller.view)
        func label(_ location: String) throws -> NSTextField {
            try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "account-appearance.preview." + location
            })
        }
        XCTAssertEqual(try label("sidebar").stringValue, "Research")
        XCTAssertEqual(try label("chooser").stringValue, "Research")
        XCTAssertEqual(try label("details").stringValue, "R&D")
        XCTAssertEqual(try label("usage").stringValue, "")
        XCTAssertEqual(try label("notifications").stringValue, "Research")
        let scope = try XCTUnwrap(views.compactMap { $0 as? ThemedPopUp }.first {
            $0.accessibilityIdentifier() == "account-appearance.scope"
        })
        scope.selectItem(at: 4)
        NSApp.sendAction(try XCTUnwrap(scope.action), to: scope.target, from: scope)
        XCTAssertEqual(try label("iphone").stringValue, "")
        scope.selectItem(at: 3)
        NSApp.sendAction(try XCTUnwrap(scope.action), to: scope.target, from: scope)
        XCTAssertEqual(try label("iphone").stringValue, "R&D")
    }

    func testWarmResolutionAtExpectedAndStressRosterSizes() {
        for count in [8, 256] {
            let roster = (0..<count).map { index in
                AgentAccount(provider: .codex, handle: .named("appearance-\(index)"),
                    configPath: "/nonexistent/appearance-\(index)", displayName: "Research \(index)",
                    presentationNameIsResolved: true)
            }
            for account in roster { _ = AccountPresentation.resolve(account, store: store) }
            let start = ContinuousClock.now
            for _ in 0..<10 {
                for account in roster {
                    let value = AccountPresentation.resolve(account, surface: .chooser, store: store)
                    XCTAssertEqual(value.name, account.displayName)
                }
            }
            print("Account appearance warm resolution: \(count) accounts × 10: \(start.duration(to: .now))")
        }
    }

    func testRendersAccountAppearanceEditor() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ThreadingRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var own = AccountAppearancePreferences()
        own.shortName = "R&D"
        var style = AccountAppearance()
        style.badgeMode = "emoji"
        style.badgeText = "🦊"
        style.backgroundHex = "#263859"
        own.shared = style
        store.setAppearance(own, for: account.id)

        for (name, theme, appearance) in [
            ("light", AppTheme.system, NSAppearance.Name.aqua),
            ("dark", AppTheme.system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ] {
            AppThemePalette.set(theme)
            let controller = AccountAppearanceViewController(account: account, store: store)
            let view = controller.view
            let size = controller.preferredContentSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = controller
            view.frame = NSRect(origin: .zero, size: size)
            view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
            view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
            AppThemeRefresh.repaint(view)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(view.bounds.height, size.height, accuracy: 1)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("account-appearance-\(name).png"))
            func descendants(_ node: NSView) -> [NSView] {
                [node] + node.subviews.flatMap(descendants)
            }
            let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "the lower appearance controls must be reachable")
            let lower = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: lower)
            try XCTUnwrap(lower.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("account-appearance-\(name)-scrolled.png"))
            withExtendedLifetime(window) {}
        }
    }
}
