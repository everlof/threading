import AppKit
import os

// MARK: - Current Palette

/// The palette every themed colour reads at draw time.
///
/// Held outside `AppThemeLibrary`'s main-actor isolation because the readers are colour
/// providers, which AppKit may call from its own drawing callbacks. The palette is a value snapshot
/// behind a lock: a provider sees the old or new complete theme, never a concurrent mutation hidden
/// from the compiler by `nonisolated(unsafe)`.
enum AppThemePalette {

    private static let storage = OSAllocatedUnfairLock(initialState: AppThemeStyles.threading)

    static var current: AppTheme { storage.withLock { $0 } }

    static func set(_ theme: AppTheme) {
        storage.withLock { $0 = theme }
    }

    /// A colour that resolves through the *current* theme every time it is drawn.
    ///
    /// This is what makes the refactor tractable, and it was measured rather than assumed: a
    /// dynamic `NSColor` re-runs its provider when the theme changes, not only when the system
    /// appearance does. So the ~150 label call sites need nothing but a token swap, and a
    /// redraw picks the new colour up.
    ///
    /// The exception, also measured, is `CALayer.backgroundColor`: a `CGColor` is resolved once
    /// at assignment and frozen. Those sites are re-applied by `AppThemeRefresh`.
    static func color(_ role: AppThemeRole) -> NSColor {
        NSColor(name: NSColor.Name("threading.\(role.rawValue)")) { appearance in
            current.resolved(role, appearance: appearance)
        }
    }
}

// MARK: - Library

/// The themes the app offers for its own chrome, and which one is in force.
@MainActor
enum AppThemeLibrary {

    private enum Keys {
        static let currentThemeID = "appThemeID"
    }

    /// The standing choice is a *user* preference, so it is written through `PreferenceStore`
    /// rather than to `UserDefaults.standard` — see that type for why the difference matters
    /// here of all places.
    private static var defaults: UserDefaults { PreferenceStore.shared }

    /// The product dress used whenever no user-owned choice exists. Recovery remains the one
    /// deliberate exception: it wears System in memory so authored theme machinery cannot take
    /// part in recovering from a failed launch.
    static var defaultTheme: AppTheme { AppThemeStyles.threading }

    // MARK: Catalogue

    /// Stock themes, System first.
    ///
    /// Written in Swift rather than loaded from a bundled JSON on purpose: the roles a theme
    /// states are few enough that a literal is shorter than the document, and it is checked by
    /// the compiler and readable in a diff. The `Codable` path serves the persistent themes an
    /// agent or a user creates through `AppThemeStore`.
    static var stock: [AppTheme] { [.system] + AppThemeStyles.all }

    /// Themes enabled extensions contribute — a third tier between stock and custom: present
    /// while their extension is enabled, never editable (an update to the package is how they
    /// change), and namespaced ids (`ext.<extension>.<theme>`) so they cannot collide with or
    /// impersonate anything in the other two tiers.
    static var contributed: [AppTheme] { ExtensionAppearanceRegistry.shared.themes }

    static var custom: [AppTheme] { AppThemeStore.shared.themes }

    static var all: [AppTheme] { stock + contributed + custom }

    /// `stock`, filed — the house group with System at its head, then the named families.
    ///
    /// System leads the house group rather than standing in a section of its own: it is not a
    /// style, it is the app in the system's clothes, and a head over one row saying "System"
    /// would only repeat it.
    static var stockSections: [AppThemeSection] {
        [AppThemeSection([.system] + AppThemeStyles.house.themes)] + AppThemeStyles.styleFamilies
    }

    /// The same catalogue `all` holds, filed under the heads a picker draws over it.
    ///
    /// Every theme, exactly once, so a picker built from this and a caller reasoning about `all`
    /// cannot disagree — `testSectionsAreTheWholeCatalogueInOrder` holds the two together. The
    /// stock tier keeps the catalogue's own order; the contributed tier is *grouped* by its
    /// extension, which is the one place the two lists may run in a different sequence.
    ///
    /// The three tiers become three kinds of section rather than three suffixes repeated on
    /// every row: the stock families as the catalogue files them, then **one section per
    /// contributing extension** — which is what tells two extensions shipping a "Storm" apart,
    /// and where a user goes to update or remove either — and the user's own copies last, being
    /// the only ones they can edit.
    static var sections: [AppThemeSection] {
        var sections = stockSections

        var contributions: [(name: String, themes: [AppTheme])] = []
        for theme in contributed {
            // A theme whose contributor cannot be named still has to appear somewhere; the
            // generic head is the one case where the section is not the extension's own name.
            let name = contributorName(of: theme) ?? L10n.string("Extensions")
            if let index = contributions.firstIndex(where: { $0.name == name }) {
                contributions[index].themes.append(theme)
            } else {
                contributions.append((name, [theme]))
            }
        }
        sections += contributions.map { AppThemeSection($0.name, $0.themes) }

        let owned = custom
        if !owned.isEmpty {
            sections.append(AppThemeSection(L10n.string("Custom"), owned))
        }
        return sections
    }

    static func theme(withID id: AppThemeID) -> AppTheme? {
        all.first { $0.id == id }
    }

    static func isStock(_ theme: AppTheme) -> Bool {
        stock.contains { $0.id == theme.id }
    }

    static func isContributed(_ theme: AppTheme) -> Bool {
        contributed.contains { $0.id == theme.id }
    }

    /// The name of the extension a contributed theme came from, for the picker and MCP listing.
    static func contributorName(of theme: AppTheme) -> String? {
        ExtensionAppearanceRegistry.shared.contributorName(forThemeID: theme.id)
    }

    static func isCustom(_ theme: AppTheme) -> Bool {
        custom.contains { $0.id == theme.id }
    }

    /// Called by the appearance registry when the contributed tier changes.
    ///
    /// A vanished theme falls back exactly the way a deleted custom theme does — to the product
    /// default,
    /// recorded as the new choice, so it does not snap back on a later re-enable. The one
    /// divergence `restore()` can leave — the stored choice unresolvable at launch because its
    /// extension had not started the session enabled — heals here: the moment the standing
    /// choice becomes resolvable again it is taken again. A *deliberate* pick made while
    /// fallen back is safe from that, because `apply` records even a pick that changed
    /// nothing on screen.
    static func contributedThemesDidChange() {
        if theme(withID: current.id) == nil {
            ThreadingLogger.theme.warning(
                "Active contributed theme became unavailable theme=\(current.id.rawValue, privacy: .private(mask: .hash)); falling back to default"
            )
            apply(defaultTheme)
        } else if let stored = defaults.string(forKey: Keys.currentThemeID),
                  stored != current.id.rawValue,
                  let standing = theme(withID: AppThemeID(stored)) {
            apply(standing)
        } else if let refreshed = theme(withID: current.id), refreshed != current {
            // The active theme kept its identity and changed its answers — a live-reloaded
            // document, or a package update. `current` is a value copy, so without this the
            // window keeps wearing the old colours while every list already shows the new
            // ones; re-applying is what lets a chrome follow the weather or the hour.
            apply(refreshed)
        }
        NotificationCenter.default.post(AppThemeLibraryDidChange())
    }

    static func uniqueCopyName(of theme: AppTheme) -> String {
        let names = Set(all.map { $0.name.lowercased() })
        var candidate = "\(theme.name) Copy"
        var index = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(theme.name) Copy \(index)"
            index += 1
        }
        return candidate
    }

    static func makeCustomID() -> AppThemeID {
        AppThemeID("custom-\(UUID().uuidString.lowercased())")
    }

    /// Duplicates any theme into the custom tier, **assets included** — the one step
    /// `AppThemeEditing.duplicate` (a pure value copy) cannot take. A custom source's asset
    /// folder is copied under the new id; a contributed source's bytes are lifted out of its
    /// package registry and materialised into the store, with the document's asset names
    /// rewritten to the store's slot names — the copy has to own its images, or disabling
    /// the extension would strip the sidebar off a theme the user now owns.
    static func duplicate(_ source: AppTheme, name: String) throws -> AppTheme {
        var copy = try AppThemeEditing.duplicate(
            source,
            id: makeCustomID(),
            name: name
        )
        do {
            if isContributed(source) {
                copy = try materializeContributedSidebarAssets(of: copy, from: source)
            } else {
                try ThemeAssetStore.copyAssets(from: source.id, to: copy.id)
            }
            try create(copy)
        } catch {
            ThemeAssetStore.removeAll(for: copy.id)
            ThreadingLogger.theme.error(
                "App theme duplication failed source=\(source.id.rawValue, privacy: .private(mask: .hash)) target=\(copy.id.rawValue, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
        ThreadingLogger.theme.info(
            "App theme duplicated source=\(source.id.rawValue, privacy: .private(mask: .hash)) target=\(copy.id.rawValue, privacy: .private(mask: .hash))"
        )
        return copy
    }

    private static func materializeContributedSidebarAssets(
        of copy: AppTheme,
        from source: AppTheme
    ) throws -> AppTheme {
        var variants = copy.variants
        for (kind, variant) in variants {
            guard var sidebar = variant.sidebar else { continue }

            if let layer = sidebar.background?.image {
                guard let data = ExtensionAppearanceRegistry.shared.sidebarAssetData(
                    named: layer.asset, forThemeID: source.id
                ), let stored = ThemeAssetStore.store(
                    imageData: data, for: copy.id, slot: .background, variant: kind
                ) else {
                    throw AppThemeEditingError.invalid(
                        "The contributed theme’s sidebar background could not be copied."
                    )
                }
                sidebar.background?.image?.asset = stored
            }

            if case .asset(let name) = sidebar.brand?.logo {
                guard let data = ExtensionAppearanceRegistry.shared.sidebarAssetData(
                    named: name, forThemeID: source.id
                ), let stored = ThemeAssetStore.store(
                    imageData: data, for: copy.id, slot: .logo, variant: kind
                ) else {
                    throw AppThemeEditingError.invalid(
                        "The contributed theme’s sidebar logo could not be copied."
                    )
                }
                sidebar.brand?.logo = .asset(stored)
            }

            variants[kind] = variant.replacingSidebar(sidebar)
        }
        return AppTheme(
            id: copy.id,
            name: copy.name,
            mode: copy.mode,
            summary: copy.summary,
            variants: variants
        )
    }

    static func create(_ theme: AppTheme) throws {
        guard theme.id != .system, self.theme(withID: theme.id) == nil else {
            throw AppThemeEditingError.invalid(
                "An app theme with id \"\(theme.id.rawValue)\" already exists."
            )
        }
        guard !all.contains(where: {
            $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
        }) else {
            throw AppThemeEditingError.invalid(
                "An app theme named \"\(theme.name)\" already exists."
            )
        }
        try AppThemeEditing.validate(theme)
        guard AppThemeStore.shared.insert(theme) else {
            ThreadingLogger.theme.error(
                "App theme creation persistence failed theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
            )
            throw AppThemeEditingError.invalid(
                "The custom app theme could not be saved."
            )
        }
        ThreadingLogger.theme.info(
            "App theme created theme=\(theme.id.rawValue, privacy: .private(mask: .hash)) variants=\(theme.variants.count, privacy: .public)"
        )
        NotificationCenter.default.post(AppThemeLibraryDidChange())
    }

    static func update(_ theme: AppTheme) throws {
        guard isCustom(theme) else {
            throw AppThemeEditingError.invalid(
                isContributed(theme)
                    ? "Extension-contributed app themes cannot be edited here. Duplicate this "
                        + "theme to make an editable copy, or update the extension that ships it."
                    : "Built-in app themes cannot be edited. Duplicate this theme first."
            )
        }
        guard !all.contains(where: {
            $0.id != theme.id && $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
        }) else {
            throw AppThemeEditingError.invalid(
                "Another app theme is already named \"\(theme.name)\"."
            )
        }
        try AppThemeEditing.validate(theme)
        guard AppThemeStore.shared.replace(theme) else {
            ThreadingLogger.theme.error(
                "App theme update persistence failed theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
            )
            throw AppThemeEditingError.invalid("The custom app theme no longer exists.")
        }
        ThreadingLogger.theme.info(
            "App theme updated theme=\(theme.id.rawValue, privacy: .private(mask: .hash)) variants=\(theme.variants.count, privacy: .public)"
        )
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        if current.id == theme.id {
            apply(theme)
        }
    }

    @discardableResult
    static func delete(_ theme: AppTheme) -> Bool {
        guard isCustom(theme) else {
            ThreadingLogger.theme.notice(
                "App theme deletion refused theme=\(theme.id.rawValue, privacy: .private(mask: .hash)) reason=not_custom"
            )
            return false
        }
        guard AppThemeStore.shared.remove(id: theme.id) else {
            ThreadingLogger.theme.error(
                "App theme deletion persistence failed theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
            )
            return false
        }
        // The document owned files too: sidebar assets die with the theme that referenced
        // them, or Application Support accumulates folders no document can reach.
        ThemeAssetStore.removeAll(for: theme.id)
        if current.id == theme.id {
            apply(defaultTheme)
        }
        ThreadingLogger.theme.info(
            "App theme deleted theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
        )
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        return true
    }

    // MARK: Current

    private(set) static var current: AppTheme = AppThemeStyles.threading

    /// The user's standing choice, whatever is in force right now.
    ///
    /// Exposed for the one screen where the two can differ: in recovery the app wears System and
    /// the Appearance page must still show what the user actually chose, or opening the page and
    /// clicking the entry that looks selected would overwrite their theme with System.
    static var storedThemeID: AppThemeID? {
        defaults.string(forKey: Keys.currentThemeID).map { AppThemeID($0) }
    }

    /// Reads the stored choice at launch. Called before the first window is built, so nothing
    /// has to be refreshed — everything is created already themed.
    ///
    /// **A recovery launch pins System, in memory only.** Nothing here writes, today or after —
    /// the write lives in `apply`, which records even a pick that changes nothing on screen — so
    /// "recovery cannot re-persist the theme" is bought by taking this path and never that one.
    ///
    /// System rather than "the stored choice if it happens to be stock": a stock theme carrying a
    /// `WindowChromeStyle` opts the main window into the app-drawn frame, which is a great deal
    /// of launch-time machinery and a plausible place to die. System is the one theme that needs
    /// no theme document, no asset store, no contributed package and no chrome takeover.
    static func restore(_ mode: LaunchMode = .normal) {
        let restored: AppTheme
        switch mode {
        case .normal:
            restored = storedThemeID.flatMap { theme(withID: $0) } ?? defaultTheme
        case .recovery:
            restored = .system
        }
        current = restored
        AppThemePalette.set(restored)
        applyAppearance(for: restored)
        ThreadingLogger.theme.info(
            "App theme restored mode=\(mode.rawValue, privacy: .public) theme=\(restored.id.rawValue, privacy: .private(mask: .hash))"
        )
    }

    /// Pins the system appearance to the theme's own mode.
    ///
    /// Shared by `restore` and `apply`, because leaving it out of the launch path is a bug that
    /// hides: a dark style launched under a dark system looks correct by luck, and the same
    /// build launches a *light* style as a white app wearing dark scrollers, dark menus and a
    /// dark switch. Every system-drawn control follows this and nothing else.
    private static func applyAppearance(for theme: AppTheme) {
        NSApp.appearance = theme.mode.appearance
    }

    /// Switches the app's theme and repaints everything already on screen.
    static func apply(_ theme: AppTheme) {
        // Recorded before the no-op guard: a pick that changes nothing on screen is still the
        // user's answer. The case that found this: launch falls back because a contributed
        // theme's extension is disabled, the user then picks System deliberately — a choice
        // the early return used to swallow, leaving the stored id pointing at the old theme.
        defaults.set(theme.id.rawValue, forKey: Keys.currentThemeID)
        guard theme != current else {
            ThreadingLogger.theme.debug(
                "App theme selection persisted without visual change theme=\(theme.id.rawValue, privacy: .private(mask: .hash))"
            )
            return
        }

        current = theme
        AppThemePalette.set(theme)

        // A dark theme under the light system appearance gets light scrollers, menus and text
        // selection drawn over it, which is the give-away that a theme is a paint job. Setting
        // the app's appearance is what makes the system-drawn parts follow.
        applyAppearance(for: theme)

        AppThemeRefresh.repaintEverything()
        NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
        ThreadingLogger.theme.info(
            "App theme applied theme=\(theme.id.rawValue, privacy: .private(mask: .hash)) mode=\(theme.mode.rawValue, privacy: .public)"
        )
    }
}

// MARK: - Event

struct AppThemeDidChange: AppEvent {
    static let name = Notification.Name("appThemeDidChange")
    let themeID: AppThemeID
}

struct AppThemeLibraryDidChange: AppEvent {
    static let name = Notification.Name("appThemeLibraryDidChange")
}
