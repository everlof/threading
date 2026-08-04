import AppKit

// MARK: - App Theme Tools

/// Agent-facing lifecycle for app-chrome themes.
///
/// The deliberate workflow for “change Cyberpunk” is duplicate then patch. A built-in never
/// becomes mutable, and the agent does not have to reconstruct a future version's fields from a
/// `get` response just to make one colour different.
extension AgentToolCoordinator {

    /// Three origins, not two: a contributed theme belongs to an extension — present while it
    /// is enabled, and editable only by updating the package, which the wording below states
    /// so an agent does not try `update_app_theme` on one and misread the refusal.
    static func origin(of theme: AppTheme) -> String {
        if AppThemeLibrary.isStock(theme) { return "built-in" }
        if AppThemeLibrary.isContributed(theme) {
            let contributor = AppThemeLibrary.contributorName(of: theme)
                .map { " “\($0)”" } ?? ""
            return "extension\(contributor)"
        }
        return "custom"
    }

    func listAppThemes() -> MCPToolResult {
        let themes = AppThemeLibrary.all
        let lines = themes.map { theme in
            let origin = Self.origin(of: theme)
            let active = theme.id == AppThemeLibrary.current.id ? ", active" : ""
            let variants = theme.isSystem
                ? "light+dark system"
                : theme.availableVariants.map(\.rawValue).joined(separator: "+")
            return "  \(theme.id.rawValue) — \(theme.name) "
                + "(\(origin)\(active), \(theme.mode.appearanceName), variants: \(variants))"
        }
        return .success(
            "App themes (\(themes.count)):\n\(lines.joined(separator: "\n"))\n\n"
                + "Use IDs, not names. Built-ins must be duplicated before they can be updated."
        )
    }

    func getAppTheme(_ arguments: AppThemeReferenceArguments) -> MCPToolResult {
        guard let theme = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        return .success(appThemeDocument(theme))
    }

    func setAppTheme(_ arguments: SetAppThemeArguments) -> MCPToolResult {
        guard let theme = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        AppThemeLibrary.apply(theme)
        return .success("Applied \(theme.name) (\(theme.id.rawValue)) app-wide.")
    }

    func createAppTheme(_ arguments: CreateAppThemeArguments) -> MCPToolResult {
        guard let rawName = arguments.name else {
            return .failure("Provide a name for the app theme.")
        }
        let base: AppTheme
        if let baseID = arguments.baseID, !baseID.isEmpty {
            guard let found = appTheme(referencedBy: baseID) else {
                return missingAppTheme(baseID)
            }
            base = found
        } else {
            base = AppThemeLibrary.current
        }

        // Minted before the variants are built: a sidebar patch may carry image bytes, and
        // the store files them under the theme's id. A failure anywhere below removes the
        // folder again, so a refused create leaves nothing behind.
        let newID = AppThemeLibrary.makeCustomID()
        do {
            let patches = try appThemeVariantPatches(arguments.variants)
            let usesLegacyPatch = hasLegacyVariantPatch(
                roles: arguments.roles,
                material: arguments.material,
                terminalColors: arguments.terminalColors
            )
            guard patches.isEmpty || !usesLegacyPatch else {
                throw AppThemeEditingError.invalid(
                    "Use variants or the legacy top-level role/material fields, not both."
                )
            }
            let mode = try appThemeMode(
                arguments.appearance ?? arguments.mode,
                fallback: inferredMode(
                    base: base,
                    patchedKinds: Set(patches.keys),
                    usesLegacyPatch: usesLegacyPatch
                )
            )
            let summary = cleaned(arguments.summary)
                ?? "Custom theme based on \(base.name)."
            var kinds = Set(base.availableVariants)
            kinds.formUnion(patches.keys)
            switch mode {
            case .system:
                kinds.formUnion(AppTheme.VariantKind.allCases)
            case .light:
                kinds.insert(.light)
            case .dark:
                kinds.insert(.dark)
            }

            let legacyKind = mode == .system
                ? AppTheme.VariantKind.current(in: NSApp.effectiveAppearance)
                : AppTheme.VariantKind(mode: mode)
            var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
            for kind in kinds {
                let patch = patches[kind]
                let receivesLegacy = usesLegacyPatch && kind == legacyKind
                variants[kind] = try patchedVariant(
                    named: rawName,
                    base: base,
                    kind: kind,
                    themeID: newID,
                    patch: patch,
                    legacyRoles: receivesLegacy ? arguments.roles : nil,
                    legacyMaterial: receivesLegacy ? arguments.material : nil,
                    legacyTerminalColors: receivesLegacy ? arguments.terminalColors : nil
                )
            }
            let theme = try AppThemeEditing.assemble(
                id: newID,
                name: rawName,
                mode: mode,
                summary: summary,
                variants: variants
            )
            try AppThemeLibrary.create(theme)
            if arguments.apply ?? true {
                AppThemeLibrary.apply(theme)
                return .success(
                    "Created and applied \(theme.name) (\(theme.id.rawValue))."
                )
            }
            return .success(
                "Created \(theme.name) (\(theme.id.rawValue)) without applying it."
            )
        } catch {
            ThemeAssetStore.removeAll(for: newID)
            return .failure(error.localizedDescription)
        }
    }

    func duplicateAppTheme(_ arguments: DuplicateAppThemeArguments) -> MCPToolResult {
        guard let source = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }

        do {
            let name = cleaned(arguments.name) ?? AppThemeLibrary.uniqueCopyName(of: source)
            let copy = try AppThemeLibrary.duplicate(source, name: name)
            if arguments.apply ?? false {
                AppThemeLibrary.apply(copy)
                return .success(
                    "Duplicated \(source.name) as \(copy.name) (\(copy.id.rawValue)) and applied it."
                )
            }
            return .success(
                "Duplicated \(source.name) as editable \(copy.name) (\(copy.id.rawValue))."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func updateAppTheme(_ arguments: UpdateAppThemeArguments) -> MCPToolResult {
        guard let source = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        guard AppThemeLibrary.isCustom(source) else {
            return .failure(
                "\(source.name) is built in and cannot be edited. Call duplicate_app_theme with "
                    + "theme_id=\"\(source.id.rawValue)\", then update the returned custom ID."
            )
        }

        // A sidebar image patch overwrites a slot file in place before validation can refuse
        // the document that references it, so the slots about to be replaced are snapshotted
        // first and put back on any failure — otherwise the standing document would show the
        // new image under the old everything-else.
        var replacedAssets: [(name: String, data: Data)] = []
        for (rawKind, patch) in arguments.variants ?? [:] {
            guard let sidebar = patch.sidebar,
                  let kind = AppTheme.VariantKind(rawValue: rawKind.lowercased()) else { continue }
            var slots: [SidebarAssetSlot] = []
            if sidebar.image?.source != nil { slots.append(.background) }
            if case .image = sidebar.logo { slots.append(.logo) }
            for slot in slots {
                let fileName = slot.fileName(for: kind)
                if let existing = ThemeAssetStore.pngData(named: fileName, for: source.id) {
                    replacedAssets.append((fileName, existing))
                }
            }
        }
        do {
            let name = cleaned(arguments.name) ?? source.name
            let patches = try appThemeVariantPatches(arguments.variants)
            let usesLegacyPatch = hasLegacyVariantPatch(
                roles: arguments.roles,
                material: arguments.material,
                terminalColors: arguments.terminalColors
            )
            guard patches.isEmpty || !usesLegacyPatch else {
                throw AppThemeEditingError.invalid(
                    "Use variants or the legacy top-level role/material fields, not both."
                )
            }
            let mode = try appThemeMode(
                arguments.appearance ?? arguments.mode,
                fallback: source.mode
            )
            let summary: String?
            if let supplied = arguments.summary {
                summary = cleaned(supplied)
            } else {
                summary = source.summary
            }

            var variants = source.variants
            var kindsToPatch = Set(patches.keys)
            switch mode {
            case .system:
                for kind in AppTheme.VariantKind.allCases where variants[kind] == nil {
                    kindsToPatch.insert(kind)
                }
            case .light where variants[.light] == nil:
                kindsToPatch.insert(.light)
            case .dark where variants[.dark] == nil:
                kindsToPatch.insert(.dark)
            default:
                break
            }
            let legacyKind = mode == .system
                ? AppTheme.VariantKind.current(in: NSApp.effectiveAppearance)
                : AppTheme.VariantKind(mode: mode)
            if usesLegacyPatch { kindsToPatch.insert(legacyKind) }

            for kind in kindsToPatch {
                let patch = patches[kind]
                let receivesLegacy = usesLegacyPatch && kind == legacyKind
                variants[kind] = try patchedVariant(
                    named: name,
                    base: source,
                    kind: kind,
                    themeID: source.id,
                    patch: patch,
                    legacyRoles: receivesLegacy ? arguments.roles : nil,
                    legacyMaterial: receivesLegacy ? arguments.material : nil,
                    legacyTerminalColors: receivesLegacy ? arguments.terminalColors : nil
                )
            }

            let updated = try AppThemeEditing.assemble(
                id: source.id,
                name: name,
                mode: mode,
                summary: summary,
                variants: variants
            )
            let wasActive = AppThemeLibrary.current.id == source.id
            try AppThemeLibrary.update(updated)
            if arguments.apply == true && !wasActive {
                AppThemeLibrary.apply(updated)
            }

            let state = (wasActive || arguments.apply == true)
                ? " It is active and the app repainted immediately."
                : " It remains inactive; call set_app_theme to inspect it live."
            return .success("Updated \(updated.name) (\(updated.id.rawValue)).\(state)")
        } catch {
            for (fileName, data) in replacedAssets {
                ThemeAssetStore.restore(pngData: data, named: fileName, for: source.id)
            }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Parsing

    private func appTheme(referencedBy rawID: String?) -> AppTheme? {
        guard let rawID = cleaned(rawID) else { return nil }
        return AppThemeLibrary.theme(withID: AppThemeID(rawID))
    }

    private func missingAppTheme(_ rawID: String?) -> MCPToolResult {
        guard let rawID = cleaned(rawID) else {
            return .failure("Provide theme_id from list_app_themes.")
        }
        return .failure(
            "No app theme has id \"\(rawID)\". Call list_app_themes for stable IDs."
        )
    }

    private func appThemeMode(
        _ raw: String?,
        fallback: AppTheme.Mode
    ) throws -> AppTheme.Mode {
        guard let raw = cleaned(raw) else { return fallback }
        switch raw.lowercased() {
        case "adaptive", "system":
            return .system
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            throw AppThemeEditingError.invalid(
                "appearance must be \"light\", \"dark\", or \"adaptive\"."
            )
        }
    }

    private func inferredMode(
        base: AppTheme,
        patchedKinds: Set<AppTheme.VariantKind>,
        usesLegacyPatch: Bool
    ) -> AppTheme.Mode {
        if usesLegacyPatch, base.mode == .system {
            return AppTheme.VariantKind.current(in: NSApp.effectiveAppearance) == .dark
                ? .dark
                : .light
        }
        if patchedKinds == [.light] { return .light }
        if patchedKinds == [.dark] { return .dark }
        return base.mode
    }

    private func appThemeVariantPatches(
        _ values: [String: AppThemeVariantArguments]?
    ) throws -> [AppTheme.VariantKind: AppThemeVariantArguments] {
        var parsed: [AppTheme.VariantKind: AppThemeVariantArguments] = [:]
        for (name, patch) in values ?? [:] {
            guard let kind = AppTheme.VariantKind(rawValue: name.lowercased()) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not a variant. Use \"light\" or \"dark\"."
                )
            }
            parsed[kind] = patch
        }
        return parsed
    }

    private func hasLegacyVariantPatch(
        roles: [String: String]?,
        material: AppThemeMaterialArguments?,
        terminalColors: [String: String]?
    ) -> Bool {
        roles != nil || material != nil || terminalColors != nil
    }

    private func patchedVariant(
        named name: String,
        base: AppTheme,
        kind: AppTheme.VariantKind,
        themeID: AppThemeID,
        patch: AppThemeVariantArguments?,
        legacyRoles: [String: String]?,
        legacyMaterial: AppThemeMaterialArguments?,
        legacyTerminalColors: [String: String]?
    ) throws -> AppTheme.Variant {
        let source = base.variant(kind)
            ?? base.variant(kind == .light ? .dark : .light)
        let rolePatch = patch?.roles ?? legacyRoles
        let materialPatch = patch?.material ?? legacyMaterial
        let terminalPatch = patch?.terminalColors ?? legacyTerminalColors
        let roles = try appThemeRoles(rolePatch)
        let baseMaterial = source?.material ?? base.material
        let material = try appThemeMaterial(materialPatch, base: baseMaterial)
        let baseTerminal = source?.terminalPalette ?? base.terminalPalette
        let terminal = try appTerminalPalette(terminalPatch, base: baseTerminal)
        let sidebar = try appThemeSidebar(
            patch?.sidebar,
            base: source?.sidebar,
            themeID: themeID,
            kind: kind
        )
        let chrome = try appThemeChrome(patch?.chrome, base: source?.chrome)
        return AppThemeEditing.makeVariant(
            named: name,
            from: base,
            kind: kind,
            roles: roles,
            material: material,
            terminalPalette: terminal,
            sidebar: sidebar,
            chrome: chrome
        )
    }

    // MARK: Chrome Parsing

    /// Turns a chrome patch into the change `makeVariant` applies — the sidebar's idiom, for
    /// the block whose presence hands the whole window frame to the theme.
    private func appThemeChrome(
        _ patch: AppThemeChromeArguments?,
        base: WindowChromeStyle?
    ) throws -> AppThemeEditing.ChromeChange {
        guard let patch else { return .inherit }
        if patch.remove == true {
            guard patch.titleBar == nil, patch.frame == nil else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set fields and remove in the same patch."
                )
            }
            return .remove
        }

        var style: WindowChromeStyle
        if let base {
            style = base
        } else {
            guard let active = patch.titleBar?.activeGradient else {
                throw AppThemeEditingError.invalid(
                    "A theme stating chrome for the first time needs "
                        + "chrome.title_bar.active_gradient."
                )
            }
            style = WindowChromeStyle(
                titleBar: WindowChromeStyle.TitleBar(
                    activeGradient: try sidebarGradient(active)
                )
            )
        }

        if let titleBar = patch.titleBar {
            guard titleBar.inactiveGradient == nil
                || titleBar.removeInactiveGradient != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_gradient and remove_inactive_gradient "
                        + "in the same patch."
                )
            }
            guard titleBar.ink == nil || titleBar.removeInk != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set ink and remove_ink in the same patch."
                )
            }
            guard titleBar.inactiveInk == nil || titleBar.removeInactiveInk != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_ink and remove_inactive_ink in the same patch."
                )
            }
            guard titleBar.height == nil || titleBar.removeHeight != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set height and remove_height in the same patch."
                )
            }
            guard titleBar.activeTexture == nil || titleBar.removeActiveTexture != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set active_texture and remove_active_texture in the same patch."
                )
            }
            guard titleBar.inactiveTexture == nil
                || titleBar.removeInactiveTexture != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_texture and remove_inactive_texture "
                        + "in the same patch."
                )
            }
            guard titleBar.tabWidth == nil || titleBar.removeTabWidth != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set tab_width and remove_tab_width in the same patch."
                )
            }
            guard titleBar.visibleButtons == nil
                || titleBar.resetVisibleButtons != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set visible_buttons and reset_visible_buttons "
                        + "in the same patch."
                )
            }
            if let active = titleBar.activeGradient {
                style.titleBar.activeGradient = try sidebarGradient(active)
            }
            if titleBar.removeInactiveGradient == true {
                style.titleBar.inactiveGradient = nil
            } else if let inactive = titleBar.inactiveGradient {
                style.titleBar.inactiveGradient = try sidebarGradient(inactive)
            }
            if titleBar.removeInk == true {
                style.titleBar.ink = nil
            } else if let rawInk = cleaned(titleBar.ink) {
                guard let color = NSColor(hex: rawInk) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.ink must be #RRGGBB or #RRGGBBAA."
                    )
                }
                style.titleBar.ink = color
            }
            if titleBar.removeInactiveInk == true {
                style.titleBar.inactiveInk = nil
            } else if let rawInk = cleaned(titleBar.inactiveInk) {
                guard let color = NSColor(hex: rawInk) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.inactive_ink must be #RRGGBB or #RRGGBBAA."
                    )
                }
                style.titleBar.inactiveInk = color
            }
            if let rawAlignment = cleaned(titleBar.titleAlignment) {
                guard let parsed = WindowChromeStyle.TitleBar.Alignment(
                    rawValue: rawAlignment
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.title_alignment must be \"leading\" or \"center\"."
                    )
                }
                style.titleBar.titleAlignment = parsed
            }
            if let rawFontStyle = cleaned(titleBar.titleFontStyle) {
                guard let parsed = WindowChromeStyle.TitleBar.TitleFontStyle(
                    rawValue: rawFontStyle
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.title_font_style must be \"upright\" or \"italic\"."
                    )
                }
                style.titleBar.titleFontStyle = parsed
            }
            if titleBar.removeHeight == true {
                style.titleBar.height = nil
            } else if let height = titleBar.height {
                style.titleBar.height = height
            }
            if let rawGlyphs = cleaned(titleBar.buttonGlyphStyle) {
                guard let parsed = WindowChromeStyle.TitleBar.ButtonGlyphStyle(
                    rawValue: rawGlyphs
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.button_glyph_style must be \"squares\", "
                            + "\"platinum\", \"beos\", \"openstep\", \"irix\", or \"plain\"."
                    )
                }
                style.titleBar.buttonGlyphStyle = parsed
            }
            if let rawPlacement = cleaned(titleBar.buttonPlacement) {
                guard let parsed = WindowChromeStyle.TitleBar.ButtonPlacement(
                    rawValue: rawPlacement
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.button_placement must be \"trailing\", \"split\", "
                            + "or \"bookends\"."
                    )
                }
                style.titleBar.buttonPlacement = parsed
            }
            if let showsAppIcon = titleBar.showsAppIcon {
                style.titleBar.showsAppIcon = showsAppIcon
            }
            if let rawShape = cleaned(titleBar.shape) {
                guard let parsed = WindowChromeStyle.TitleBar.Shape(rawValue: rawShape) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.shape must be \"full_width\" or \"leading_tab\"."
                    )
                }
                style.titleBar.shape = parsed
            }
            if titleBar.removeTabWidth == true {
                style.titleBar.tabWidth = nil
            } else if let tabWidth = titleBar.tabWidth {
                style.titleBar.tabWidth = tabWidth
            }
            if titleBar.resetVisibleButtons == true {
                style.titleBar.visibleButtons = WindowChromeStyle.TitleBar.ButtonRole
                    .standardOperations
            } else if let rawButtons = titleBar.visibleButtons {
                let parsed = rawButtons.compactMap { raw -> WindowChromeStyle.TitleBar.ButtonRole? in
                    guard let value = cleaned(raw) else { return nil }
                    return WindowChromeStyle.TitleBar.ButtonRole(rawValue: value)
                }
                guard parsed.count == rawButtons.count else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.visible_buttons accepts only \"close\", "
                            + "\"minimize\", \"zoom\", and \"window_menu\"."
                    )
                }
                style.titleBar.visibleButtons = parsed
            }
            if titleBar.removeActiveTexture == true {
                style.titleBar.activeTexture = nil
            } else if let texture = titleBar.activeTexture {
                style.titleBar.activeTexture = try appThemeChromeTexture(
                    texture,
                    base: style.titleBar.activeTexture,
                    path: "chrome.title_bar.active_texture"
                )
            }
            if titleBar.removeInactiveTexture == true {
                style.titleBar.inactiveTexture = nil
            } else if let texture = titleBar.inactiveTexture {
                style.titleBar.inactiveTexture = try appThemeChromeTexture(
                    texture,
                    base: style.titleBar.inactiveTexture,
                    path: "chrome.title_bar.inactive_texture"
                )
            }
        }

        guard patch.frame == nil || patch.removeFrame != true else {
            throw AppThemeEditingError.invalid(
                "chrome cannot set frame and remove_frame in the same patch."
            )
        }
        if patch.removeFrame == true {
            style.frame = nil
        } else if let frame = patch.frame {
            guard let width = frame.width else {
                throw AppThemeEditingError.invalid("chrome.frame needs a width in points.")
            }
            style.frame = WindowChromeStyle.Frame(width: width)
        }

        return .set(style)
    }

    private func appThemeChromeTexture(
        _ patch: AppThemeChromeTextureArguments,
        base: WindowChromeStyle.TitleBar.Texture?,
        path: String
    ) throws -> WindowChromeStyle.TitleBar.Texture {
        guard patch.color == nil || patch.removeColor != true else {
            throw AppThemeEditingError.invalid(
                "\(path) cannot set color and remove_color in the same patch."
            )
        }
        guard patch.spacing == nil || patch.removeSpacing != true else {
            throw AppThemeEditingError.invalid(
                "\(path) cannot set spacing and remove_spacing in the same patch."
            )
        }

        let kind: WindowChromeStyle.TitleBar.Texture.Kind
        if let rawKind = cleaned(patch.kind) {
            guard let parsed = WindowChromeStyle.TitleBar.Texture.Kind(rawValue: rawKind) else {
                throw AppThemeEditingError.invalid(
                    "\(path).kind must be \"pinstripes\" or \"dither\"."
                )
            }
            kind = parsed
        } else if let base {
            kind = base.kind
        } else {
            throw AppThemeEditingError.invalid("\(path) needs a kind.")
        }

        let color: NSColor?
        if patch.removeColor == true {
            color = nil
        } else if let rawColor = cleaned(patch.color) {
            guard let parsed = NSColor(hex: rawColor) else {
                throw AppThemeEditingError.invalid(
                    "\(path).color must be #RRGGBB or #RRGGBBAA."
                )
            }
            color = parsed
        } else {
            color = base?.color
        }

        let spacing = patch.removeSpacing == true ? nil : (patch.spacing ?? base?.spacing)
        return WindowChromeStyle.TitleBar.Texture(
            kind: kind,
            color: color,
            spacing: spacing
        )
    }

    // MARK: Sidebar Parsing

    /// Turns a sidebar patch into the change `makeVariant` applies. Image bytes are stored
    /// under the theme's id as a side effect — the callers own cleanup on failure, which is
    /// why create removes the fresh folder and update restores the slots it replaced.
    private func appThemeSidebar(
        _ patch: AppThemeSidebarArguments?,
        base: SidebarStyle?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> AppThemeEditing.SidebarChange {
        guard let patch else { return .inherit }
        if patch.remove == true {
            let statesAnything = patch.gradient != nil || patch.image != nil
                || patch.logo != nil || patch.title != nil || patch.navigatorWell != nil
            guard !statesAnything else {
                throw AppThemeEditingError.invalid(
                    "sidebar cannot set fields and remove in the same patch."
                )
            }
            return .remove
        }
        guard patch.gradient == nil || patch.removeGradient != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set gradient and remove_gradient in the same patch."
            )
        }
        guard patch.image == nil || patch.removeImage != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set image and remove_image in the same patch."
            )
        }
        guard patch.title == nil || patch.removeTitle != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set title and remove_title in the same patch."
            )
        }
        guard patch.navigatorWell == nil || patch.removeNavigatorWell != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set navigator_well and remove_navigator_well in the same patch."
            )
        }

        var style = base ?? SidebarStyle()
        var background = style.background ?? SidebarStyle.Background()

        if patch.removeGradient == true {
            background.gradient = nil
        } else if let gradient = patch.gradient {
            background.gradient = try sidebarGradient(gradient)
        }

        if patch.removeImage == true {
            background.image = nil
        } else if let image = patch.image {
            guard let source = image.source else {
                throw AppThemeEditingError.invalid(
                    "sidebar.image needs a source: {path} or {base64}."
                )
            }
            let data = try imageBytes(source, describing: "sidebar.image.source")
            guard let stored = ThemeAssetStore.store(
                imageData: data,
                for: themeID,
                slot: .background,
                variant: kind
            ) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.image.source is not a readable image (or exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB)."
                )
            }
            let mode: SidebarStyle.ImageLayer.Mode
            if let rawMode = cleaned(image.mode) {
                guard let parsed = SidebarStyle.ImageLayer.Mode(rawValue: rawMode) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.image.mode must be \"tile\", \"fill\" or \"fit\"."
                    )
                }
                mode = parsed
            } else {
                mode = .fill
            }
            background.image = SidebarStyle.ImageLayer(
                asset: stored,
                mode: mode,
                opacity: image.opacity ?? 1
            )
        }

        if patch.removeNavigatorWell == true {
            style.navigatorWell = nil
        } else if let wellPatch = patch.navigatorWell {
            let fill: NSColor
            if let rawFill = cleaned(wellPatch.fill) {
                guard let parsed = NSColor(hex: rawFill) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.navigator_well.fill must be #RRGGBB or #RRGGBBAA."
                    )
                }
                fill = parsed
            } else if let existing = style.navigatorWell?.fill {
                fill = existing
            } else {
                throw AppThemeEditingError.invalid(
                    "A newly stated sidebar.navigator_well needs an opaque fill."
                )
            }

            let bevel: SidebarStyle.NavigatorWell.Bevel
            if let rawBevel = cleaned(wellPatch.bevel) {
                guard let parsed = SidebarStyle.NavigatorWell.Bevel(rawValue: rawBevel) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.navigator_well.bevel must be \"sunken\", \"raised\" or \"none\"."
                    )
                }
                bevel = parsed
            } else {
                bevel = style.navigatorWell?.bevel ?? .sunken
            }
            style.navigatorWell = SidebarStyle.NavigatorWell(fill: fill, bevel: bevel)
        }

        var brand = style.brand ?? SidebarStyle.Brand()
        if let logo = patch.logo {
            switch logo {
            case .mark:
                brand.logo = .mark
            case .hidden:
                brand.logo = .hidden
            case .image(let source):
                let data = try imageBytes(source, describing: "sidebar.logo")
                guard let stored = ThemeAssetStore.store(
                    imageData: data,
                    for: themeID,
                    slot: .logo,
                    variant: kind
                ) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.logo is not a readable image."
                    )
                }
                brand.logo = .asset(stored)
            }
        }

        if patch.removeTitle == true {
            brand.title = nil
        } else if let title = patch.title {
            let weight: SidebarStyle.Brand.Title.Weight?
            if let rawWeight = cleaned(title.weight) {
                guard let parsed = SidebarStyle.Brand.Title.Weight(rawValue: rawWeight) else {
                    throw AppThemeEditingError.invalid(
                        "title.weight must be \"regular\", \"medium\", \"semibold\" or \"bold\"."
                    )
                }
                weight = parsed
            } else {
                weight = nil
            }
            let parsed = SidebarStyle.Brand.Title(
                text: cleaned(title.text),
                fontFamily: cleaned(title.fontFamily),
                fontSize: title.fontSize,
                weight: weight,
                hidden: title.hidden ?? false
            )
            brand.title = parsed.isEmpty ? nil : parsed
        }

        style.background = background.isEmpty ? nil : background
        style.brand = brand.isEmpty ? nil : brand
        return .set(style)
    }

    private func sidebarGradient(
        _ arguments: AppThemeGradientArguments
    ) throws -> SidebarStyle.Gradient {
        let stops = try (arguments.stops ?? []).map { stop -> SidebarStyle.Gradient.Stop in
            guard let hex = cleaned(stop.color), let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "A gradient stop's color must be #RRGGBB or #RRGGBBAA."
                )
            }
            guard let position = stop.position else {
                throw AppThemeEditingError.invalid(
                    "A gradient stop needs a position between 0 and 1."
                )
            }
            return SidebarStyle.Gradient.Stop(color: color, position: position)
        }
        return SidebarStyle.Gradient(
            stops: stops,
            angleDegrees: arguments.angleDegrees ?? 180
        )
    }

    private func imageBytes(
        _ source: AppThemeImageArguments,
        describing field: String
    ) throws -> Data {
        if let rawPath = cleaned(source.path) {
            let path = (rawPath as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path) else {
                throw AppThemeEditingError.invalid("\(field): no readable file at \(path).")
            }
            guard data.count <= SidebarStyleLimits.maximumImageBytes else {
                throw AppThemeEditingError.invalid(
                    "\(field): file exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB."
                )
            }
            return data
        }
        if let base64 = cleaned(source.base64) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw AppThemeEditingError.invalid("\(field): base64 did not decode.")
            }
            guard data.count <= SidebarStyleLimits.maximumImageBytes else {
                throw AppThemeEditingError.invalid(
                    "\(field): image exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB."
                )
            }
            return data
        }
        throw AppThemeEditingError.invalid("\(field): provide {path} or {base64}.")
    }

    private func appThemeRoles(
        _ values: [String: String]?
    ) throws -> [AppThemeRole: NSColor] {
        var parsed: [AppThemeRole: NSColor] = [:]
        for (name, hex) in values ?? [:] {
            guard let role = AppThemeRole.named(name) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not an app-theme role. Valid roles: "
                        + AppThemeRole.allCases.map(\.wireName).joined(separator: ", ") + "."
                )
            }
            guard let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "\"\(hex)\" is not a colour. Use #RRGGBB or #RRGGBBAA."
                )
            }
            parsed[role] = color
        }
        return parsed
    }

    private func appThemeMaterial(
        _ patch: AppThemeMaterialArguments?,
        base: AppTheme.Material
    ) throws -> AppTheme.Material {
        guard let patch else { return base }
        guard patch.glow == nil || patch.removeGlow != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set glow and remove_glow in the same patch."
            )
        }
        guard patch.fontFamily == nil || patch.removeFontFamily != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set font_family and remove_font_family in the same patch."
            )
        }

        guard patch.bevel == nil || patch.removeBevel != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set bevel and remove_bevel in the same patch."
            )
        }

        var material = base
        if let value = patch.panelRadius { material.panelRadius = CGFloat(value) }
        if let value = patch.controlRadius { material.controlRadius = CGFloat(value) }
        if let value = patch.borderWidth { material.borderWidth = CGFloat(value) }
        if let value = patch.textScale { material.textScale = CGFloat(value) }

        if let rawPlacement = cleaned(patch.scrollerPlacement) {
            guard let parsed = AppTheme.Material.ScrollerPlacement(rawValue: rawPlacement) else {
                throw AppThemeEditingError.invalid(
                    "material.scroller_placement must be \"trailing\" or \"leading\"."
                )
            }
            material.scrollerPlacement = parsed
        }
        if let rawTrack = cleaned(patch.scrollerTrackStyle) {
            guard let parsed = AppTheme.Material.ScrollerTrackStyle(rawValue: rawTrack) else {
                throw AppThemeEditingError.invalid(
                    "material.scroller_track_style must be \"solid\" or \"stippled\"."
                )
            }
            material.scrollerTrackStyle = parsed
        }

        if patch.removeBevel == true {
            material.bevel = nil
        } else if let bevel = patch.bevel {
            material.bevel = AppTheme.Bevel(
                width: CGFloat(bevel.width ?? Double(base.bevel?.width ?? 2))
            )
        }

        if let rawTypeface = cleaned(patch.typeface) {
            // Named rather than positional, and the accepted list travels with the refusal: an
            // agent that guessed "sans-serif" from the style brief it is reading has no other
            // way to learn that this vocabulary calls it "default".
            guard let parsed = AppTheme.Material.Typeface(rawValue: rawTypeface) else {
                let accepted = AppTheme.Material.Typeface.allCases
                    .map(\.rawValue)
                    .joined(separator: ", ")
                throw AppThemeEditingError.invalid(
                    "\"\(rawTypeface)\" is not a valid typeface. Accepted: \(accepted)."
                )
            }
            material.typeface = parsed
        }

        if patch.removeFontFamily == true {
            material.fontFamily = nil
        } else if let family = cleaned(patch.fontFamily) {
            // Checked here rather than left to resolve silently, because a theme is authored on
            // one machine and read on another: an agent that names a family this machine does
            // not have should be told at the point it can still choose a different one, not have
            // its theme quietly fall back to the typeface. A theme that *arrives* naming an
            // absent family still degrades rather than failing — that is the document's rule,
            // and this is the authoring path. The live CoreText list, so a family an enabled
            // extension registered counts as installed here too.
            guard Design.Typography.availableFamilies.contains(family) else {
                throw AppThemeEditingError.invalid(
                    "\"\(family)\" is not an installed font family on this machine."
                )
            }
            material.fontFamily = family
        }
        if patch.removeGlow == true {
            material.glow = nil
        } else if let glow = patch.glow {
            let role: AppThemeRole
            if let rawRole = cleaned(glow.role) {
                guard let parsed = AppThemeRole.named(rawRole) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(rawRole)\" is not a valid glow role."
                    )
                }
                role = parsed
            } else {
                role = base.glow?.role ?? .accent
            }
            material.glow = AppTheme.Glow(
                role: role,
                radius: CGFloat(glow.radius ?? Double(base.glow?.radius ?? 6)),
                opacity: glow.opacity ?? base.glow?.opacity ?? 0.2,
                offsetX: CGFloat(glow.offsetX ?? Double(base.glow?.offsetX ?? 0)),
                offsetY: CGFloat(glow.offsetY ?? Double(base.glow?.offsetY ?? 0))
            )
        }
        return material
    }

    private func appTerminalPalette(
        _ values: [String: String]?,
        base: TerminalTheme
    ) throws -> TerminalTheme {
        var palette = base
        for (name, hex) in values ?? [:] {
            guard let key = ThemeColorKey.named(name) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not a terminal colour. Valid names: "
                        + ThemeColorKey.allCases.map(\.wireName).joined(separator: ", ") + "."
                )
            }
            guard let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "\"\(hex)\" is not a colour. Use #RRGGBB or #RRGGBBAA."
                )
            }
            palette[key] = color
        }
        return palette
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    // MARK: Document

    private func appThemeDocument(_ theme: AppTheme) -> String {
        let kinds = theme.isSystem ? AppTheme.VariantKind.allCases : theme.availableVariants
        var variants: [String: Any] = [:]
        for kind in kinds {
            variants[kind.rawValue] = appThemeVariantDocument(
                theme: theme,
                kind: kind,
                variant: theme.variant(kind)
            )
        }

        var document: [String: Any] = [
            "id": theme.id.rawValue,
            "name": theme.name,
            "origin": Self.origin(of: theme),
            "active": theme.id == AppThemeLibrary.current.id,
            "appearance": theme.mode.appearanceName,
            "available_variants": kinds.map(\.rawValue),
            "variants": variants
        ]
        if let summary = theme.summary { document["summary"] = summary }

        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "Could not encode \(theme.name)."
        }
        return json
    }

    private func appThemeVariantDocument(
        theme: AppTheme,
        kind: AppTheme.VariantKind,
        variant: AppTheme.Variant?
    ) -> [String: Any] {
        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        var resolved: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            for role in AppThemeRole.allCases {
                resolved[role.wireName] = theme.resolved(role, appearance: appearance).hexString
            }
        }
        let explicit = Dictionary(uniqueKeysWithValues: (variant?.roles ?? [:]).map {
            ($0.key.wireName, $0.value.hexString)
        })
        let material = variant?.material ?? .system
        let terminal = variant?.terminalPalette ?? theme.terminalPalette
        var document: [String: Any] = [
            // `roles`, `material`, and `terminal_colors` can be copied directly into the
            // corresponding create/update variant patch. `resolved_roles` is inspection-only.
            "roles": explicit,
            "resolved_roles": resolved,
            "material": appThemeMaterialDocument(material),
            "terminal_palette_id": terminal.id.rawValue,
            "terminal_colors": terminalColorDocument(terminal)
        ]
        if let sidebar = variant?.sidebar {
            document["sidebar"] = appThemeSidebarDocument(sidebar)
        }
        if let chrome = variant?.chrome {
            document["chrome"] = appThemeChromeDocument(chrome)
        }
        return document
    }

    /// The chrome block as create/update speak it; everything round-trips.
    private func appThemeChromeDocument(_ chrome: WindowChromeStyle) -> [String: Any] {
        func gradientDocument(_ gradient: SidebarStyle.Gradient) -> [String: Any] {
            [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ]
        }

        var titleBar: [String: Any] = [
            "active_gradient": gradientDocument(chrome.titleBar.activeGradient),
            "title_alignment": chrome.titleBar.titleAlignment.rawValue,
            "title_font_style": chrome.titleBar.titleFontStyle.rawValue,
            "button_glyph_style": chrome.titleBar.buttonGlyphStyle.rawValue,
            "button_placement": chrome.titleBar.buttonPlacement.rawValue,
            "shows_app_icon": chrome.titleBar.showsAppIcon,
            "shape": chrome.titleBar.shape.rawValue,
            "visible_buttons": chrome.titleBar.visibleButtons.map(\.rawValue)
        ]
        if let inactive = chrome.titleBar.inactiveGradient {
            titleBar["inactive_gradient"] = gradientDocument(inactive)
        }
        if let ink = chrome.titleBar.ink { titleBar["ink"] = ink.hexString }
        if let ink = chrome.titleBar.inactiveInk { titleBar["inactive_ink"] = ink.hexString }
        if let height = chrome.titleBar.height { titleBar["height"] = height }
        if let width = chrome.titleBar.tabWidth { titleBar["tab_width"] = width }
        if let texture = chrome.titleBar.activeTexture {
            titleBar["active_texture"] = appThemeChromeTextureDocument(texture)
        }
        if let texture = chrome.titleBar.inactiveTexture {
            titleBar["inactive_texture"] = appThemeChromeTextureDocument(texture)
        }

        var document: [String: Any] = ["title_bar": titleBar]
        if let frame = chrome.frame {
            document["frame"] = ["width": frame.width]
        }
        return document
    }

    private func appThemeChromeTextureDocument(
        _ texture: WindowChromeStyle.TitleBar.Texture
    ) -> [String: Any] {
        var document: [String: Any] = ["kind": texture.kind.rawValue]
        if let color = texture.color { document["color"] = color.hexString }
        if let spacing = texture.spacing { document["spacing"] = spacing }
        return document
    }

    /// The sidebar block as create/update speak it, with asset names in place of bytes — an
    /// agent re-supplying an image sends a new {path}/{base64}; everything else round-trips.
    private func appThemeSidebarDocument(_ sidebar: SidebarStyle) -> [String: Any] {
        var document: [String: Any] = [:]
        if let gradient = sidebar.background?.gradient {
            document["gradient"] = [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ] as [String: Any]
        }
        if let image = sidebar.background?.image {
            document["image"] = [
                "asset": image.asset,
                "mode": image.mode.rawValue,
                "opacity": image.opacity
            ] as [String: Any]
        }
        if let brand = sidebar.brand {
            switch brand.logo {
            case .mark: document["logo"] = "mark"
            case .hidden: document["logo"] = "hidden"
            case .asset(let name): document["logo"] = ["asset": name]
            }
            if let title = brand.title {
                var titleDocument: [String: Any] = ["hidden": title.hidden]
                if let text = title.text { titleDocument["text"] = text }
                if let family = title.fontFamily { titleDocument["font_family"] = family }
                if let size = title.fontSize { titleDocument["font_size"] = size }
                if let weight = title.weight { titleDocument["weight"] = weight.rawValue }
                document["title"] = titleDocument
            }
        }
        if let well = sidebar.navigatorWell {
            document["navigator_well"] = [
                "fill": well.fill.hexString,
                "bevel": well.bevel.rawValue
            ]
        }
        return document
    }

    private func appThemeMaterialDocument(_ material: AppTheme.Material) -> [String: Any] {
        var document: [String: Any] = [
            "panel_radius": Double(material.panelRadius),
            "control_radius": Double(material.controlRadius),
            "border_width": Double(material.borderWidth),
            "text_scale": Double(material.textScale),
            "typeface": material.typeface.rawValue,
            "scroller_placement": material.scrollerPlacement.rawValue,
            "scroller_track_style": material.scrollerTrackStyle.rawValue
        ]
        if let family = material.fontFamily { document["font_family"] = family }
        if let bevel = material.bevel {
            document["bevel"] = ["width": Double(bevel.width)]
        }
        if let glow = material.glow {
            document["glow"] = [
                "role": glow.role.wireName,
                "radius": Double(glow.radius),
                "opacity": glow.opacity,
                "offset_x": Double(glow.offsetX),
                "offset_y": Double(glow.offsetY)
            ]
        }
        return document
    }

    private func terminalColorDocument(_ theme: TerminalTheme) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ThemeColorKey.allCases.map {
            ($0.wireName, theme[$0].hexString)
        })
    }
}
